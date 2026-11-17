"""Weather Twins: an agent that finds places whose climate and current weather
resemble a given city.

Claude proposes candidate cities and checks them against real Open-Meteo data
through the tools below, then returns a ranked list. The Flutter app calls this
service so the Anthropic API key never ships in the app.

The model, effort and instructions come from the LaunchDarkly AI Config
`weather-twins-agent` (agent mode), evaluated for the app user's context, and
each run is tracked against the variation that was served. The config's
attached judge (`weather-twins-judge`) scores answers in the background. With
no LaunchDarkly SDK key, or when LaunchDarkly serves a disabled variation, the
built-in defaults below are used and nothing is tracked.

With an SDK key, the LaunchDarkly observability plugin also traces each request
(FastAPI, Open-Meteo calls, and the Anthropic SDK's own spans for each Claude
call and tool use) and ships logs. The app sends a `traceparent` header, so a
request's spans join the app's `weather.twins` trace. The agent run and each tool call get spans here.

Run:  ./go.sh  (loads keys from .env; see .env.example)
Needs ANTHROPIC_API_KEY (or another credential the SDK can resolve), and
optionally LAUNCHDARKLY_SDK_KEY (a server-side key for the Production env).
"""

import contextlib
import functools
import json
import logging
import os
import random
import threading
from pathlib import Path
import time
from collections import defaultdict
from contextvars import ContextVar
from dataclasses import dataclass, field

import anthropic
import httpx
import ldclient
from anthropic import beta_tool
from fastapi import BackgroundTasks, FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from ldai import JudgeResult, LDAIClient
from ldai.models import AIAgentConfigDefault, ModelConfig, ProviderConfig
from ldai.tracker import TokenUsage
from ldclient import Context
from ldclient.config import Config
from ldobserve import ObservabilityConfig, ObservabilityPlugin, observe
from opentelemetry import trace
from opentelemetry.instrumentation.fastapi import FastAPIInstrumentor
from pydantic import BaseModel

AGENT_CONFIG_KEY = "weather-twins-agent"
MODEL = "claude-opus-5-5"
EFFORT = "medium"
MAX_ITERATIONS = 12
JUDGE_MAX_TOKENS = 4000

log = logging.getLogger("twins")
logging.basicConfig(level=logging.INFO)


class _IgnoreJudgeRunnerWarnings(logging.Filter):
    """Drops the AI SDK's warnings about not finding a judge runner.

    agent_config() builds the SDK's own judge evaluator whenever the variation
    has judges attached. Its runners only cover OpenAI and LangChain, so for
    an Anthropic judge it warns on every request. That evaluator is never
    used: run_judges() calls Claude itself.
    """

    def filter(self, record: logging.LogRecord) -> bool:
        message = record.getMessage()
        return not (
            message == "All providers failed or are unavailable"
            or message.startswith("Could not load provider 'langchain'")
        )


logging.getLogger("ldclient.util").addFilter(_IgnoreJudgeRunnerWarnings())

client = anthropic.Anthropic()
http = httpx.Client(timeout=20)

ld_sdk_key = os.environ.get("LAUNCHDARKLY_SDK_KEY")
if ld_sdk_key:
    ldclient.set_config(
        Config(
            ld_sdk_key,
            plugins=[
                ObservabilityPlugin(ObservabilityConfig(service_name="twins_backend"))
            ],
        )
    )
    ai_client: LDAIClient | None = LDAIClient(ldclient.get())
else:
    log.warning("LAUNCHDARKLY_SDK_KEY not set: using built-in agent settings.")
    ai_client = None

# Tool calls and results for the current request, for the judge to check
# the answer against. Tools run on the request's thread, so a ContextVar works.
_transcript: ContextVar[list] = ContextVar("transcript")


def _record(tool: str, args: dict, result: str) -> str:
    if (transcript := _transcript.get(None)) is not None:
        transcript.append(f"{tool}({json.dumps(args)}) -> {result}")
    return result


def _start_span(name: str, attributes: dict | None = None):
    """A span when observability is on; otherwise a no-op, so running without
    an SDK key doesn't log a warning per span."""
    if ai_client is None:
        return contextlib.nullcontext(trace.INVALID_SPAN)
    return observe.start_span(name, attributes)


def _traced_tool(fn):
    """Runs a tool inside a `tool.<name>` span. Tool errors come back to the
    agent as "Error: ..." strings, which the SDK's own tool span reports as OK,
    so this span is what marks them as errors."""

    @functools.wraps(fn)
    def wrapper(**kwargs):
        with _start_span(
            f"tool.{fn.__name__}",
            {"gen_ai.tool.name": fn.__name__, "gen_ai.tool.arguments": json.dumps(kwargs)},
        ) as span:
            result = fn(**kwargs)
            if result.startswith("Error:"):
                span.set_status(trace.StatusCode.ERROR, result)
            return result

    return wrapper

SYSTEM_PROMPT = """You find "weather twins": places elsewhere in the world whose \
weather resembles a given city.

Use the tools to check every candidate against real data before you include it. \
A good twin matches on long-term climate (yearly temperature range and rainfall) \
and, ideally, on today's conditions. Geography that explains the match - latitude, \
coastline, elevation, ocean currents - makes a good reason.

Return 3 to 5 twins from different countries than the input city, ranked best \
first. Keep each reason to one or two plain sentences that cite the numbers you \
checked. The summary is one sentence for a phone screen."""

OUTPUT_SCHEMA = {
    "type": "object",
    "properties": {
        "summary": {"type": "string"},
        "twins": {
            "type": "array",
            "items": {
                "type": "object",
                "properties": {
                    "name": {"type": "string"},
                    "country": {"type": "string"},
                    "latitude": {"type": "number"},
                    "longitude": {"type": "number"},
                    "similarity": {
                        "type": "integer",
                        "description": "0-100, how closely it matches",
                    },
                    "today_temperature_c": {"type": "number"},
                    "reason": {"type": "string"},
                },
                "required": [
                    "name",
                    "country",
                    "latitude",
                    "longitude",
                    "similarity",
                    "today_temperature_c",
                    "reason",
                ],
                "additionalProperties": False,
            },
        },
    },
    "required": ["summary", "twins"],
    "additionalProperties": False,
}


def _get(url: str, params: dict) -> dict:
    response = http.get(url, params=params)
    response.raise_for_status()
    return response.json()


@beta_tool
@_traced_tool
def geocode(name: str) -> str:
    """Look up a city by name and return its coordinates, country and elevation.

    Args:
        name: City name only, e.g. "Cape Town" (no country suffix).
    """
    try:
        data = _get(
            "https://geocoding-api.open-meteo.com/v1/search",
            {"name": name, "count": 1, "language": "en", "format": "json"},
        )
    except httpx.HTTPError as e:
        return f"Error: geocoding failed ({e})."
    results = data.get("results") or []
    if not results:
        return _record("geocode", {"name": name}, f"No place found for {name!r}.")
    r = results[0]
    return _record(
        "geocode",
        {"name": name},
        json.dumps(
            {
                "name": r.get("name"),
                "country": r.get("country"),
                "latitude": r.get("latitude"),
                "longitude": r.get("longitude"),
                "elevation_m": r.get("elevation"),
                "population": r.get("population"),
            }
        ),
    )


@beta_tool
@_traced_tool
def get_current_weather(latitude: float, longitude: float) -> str:
    """Get current conditions and today's high/low at a location (Celsius, km/h).

    Args:
        latitude: Latitude in degrees.
        longitude: Longitude in degrees.
    """
    try:
        data = _get(
            "https://api.open-meteo.com/v1/forecast",
            {
                "latitude": latitude,
                "longitude": longitude,
                "current": "temperature_2m,apparent_temperature,"
                "relative_humidity_2m,wind_speed_10m,weather_code",
                "daily": "temperature_2m_max,temperature_2m_min,"
                "precipitation_probability_max",
                "timezone": "auto",
                "forecast_days": 1,
            },
        )
    except httpx.HTTPError as e:
        return f"Error: forecast failed ({e})."
    current, daily = data["current"], data["daily"]
    result = json.dumps(
        {
            "temperature_c": current["temperature_2m"],
            "feels_like_c": current["apparent_temperature"],
            "humidity_pct": current["relative_humidity_2m"],
            "wind_kmh": current["wind_speed_10m"],
            "weather_code": current["weather_code"],
            "high_c": daily["temperature_2m_max"][0],
            "low_c": daily["temperature_2m_min"][0],
            "rain_chance_pct": daily["precipitation_probability_max"][0],
        }
    )
    return _record(
        "get_current_weather", {"latitude": latitude, "longitude": longitude}, result
    )


# Climate history doesn't change, so summaries are cached on disk by location.
# Open-Meteo weights requests by size (5 years of daily data counts as ~26
# calls against its hourly limit), and without this a few agent runs an hour
# exhaust it and the agent can't check climates.
CLIMATE_CACHE = Path(__file__).with_name("climate_cache.json")
CLIMATE_YEARS = (2020, 2024)
_climate_lock = threading.Lock()
try:
    _climate_cache: dict = json.loads(CLIMATE_CACHE.read_text())
except (FileNotFoundError, ValueError):
    _climate_cache = {}


@beta_tool
@_traced_tool
def get_climate_summary(latitude: float, longitude: float) -> str:
    """Summarise a location's climate from 2020-2024 daily history: yearly mean
    temperature, warmest and coldest month averages, and yearly rainfall.

    Args:
        latitude: Latitude in degrees.
        longitude: Longitude in degrees.
    """
    args = {"latitude": latitude, "longitude": longitude}
    # ~1 km, so the same city geocoded twice hits the cache.
    key = f"{latitude:.2f},{longitude:.2f}"
    if (cached := _climate_cache.get(key)) is not None:
        log.info("climate cache hit for %s", key)
        return _record("get_climate_summary", args, cached)
    log.info("climate cache miss for %s; asking Open-Meteo", key)
    first, last = CLIMATE_YEARS
    try:
        data = _get(
            "https://archive-api.open-meteo.com/v1/archive",
            {
                "latitude": latitude,
                "longitude": longitude,
                "start_date": f"{first}-01-01",
                "end_date": f"{last}-12-31",
                "daily": "temperature_2m_mean,precipitation_sum",
                "timezone": "auto",
            },
        )
    except httpx.HTTPStatusError as e:
        if e.response.status_code == 429:
            return "Error: the climate service's hourly limit is used up; try again later."
        return f"Error: climate lookup failed ({e})."
    except httpx.HTTPError as e:
        return f"Error: climate lookup failed ({e})."
    daily = data["daily"]
    temps, rain = defaultdict(list), defaultdict(float)
    for day, t, p in zip(
        daily["time"], daily["temperature_2m_mean"], daily["precipitation_sum"]
    ):
        month = int(day[5:7])
        if t is not None:
            temps[month].append(t)
        rain[month] += p or 0.0
    years = last - first + 1
    monthly_temp = {m: sum(v) / len(v) for m, v in temps.items() if v}
    monthly_rain = {m: total / years for m, total in rain.items()}
    warmest = max(monthly_temp, key=monthly_temp.get)
    coldest = min(monthly_temp, key=monthly_temp.get)
    result = json.dumps(
        {
            "mean_temperature_c": round(
                sum(monthly_temp.values()) / len(monthly_temp), 1
            ),
            "warmest_month": warmest,
            "warmest_month_mean_c": round(monthly_temp[warmest], 1),
            "coldest_month": coldest,
            "coldest_month_mean_c": round(monthly_temp[coldest], 1),
            "yearly_rainfall_mm": round(sum(monthly_rain.values())),
            "wettest_month": max(monthly_rain, key=monthly_rain.get),
        }
    )
    with _climate_lock:
        _climate_cache[key] = result
        CLIMATE_CACHE.write_text(json.dumps(_climate_cache))
    return _record("get_climate_summary", args, result)


TOOLS = [geocode, get_current_weather, get_climate_summary]


class TwinsRequest(BaseModel):
    name: str
    country: str | None = None
    latitude: float
    longitude: float
    # The app's LaunchDarkly context in JSON form (usually `kind: multi` with
    # user, ld_device and ld_application), so the AI Config is targeted and
    # tracked with the same context as the app's flags, device rules included.
    context: dict | None = None


DEFAULT_AGENT = AIAgentConfigDefault(
    enabled=True,
    model=ModelConfig(MODEL, parameters={"effort": EFFORT}),
    provider=ProviderConfig("anthropic"),
    instructions=SYSTEM_PROMPT,
)


@dataclass
class AgentSettings:
    """What one run uses, from the AI Config or the built-in defaults."""

    model: str
    instructions: str
    effort: str
    max_iterations: int
    variation: str
    tracker: object | None = None
    # (judge config key, sampling rate) pairs attached to the variation.
    judges: list = field(default_factory=list)


def _model_name(model: ModelConfig | None) -> str:
    # Model config keys look like "Anthropic.claude-opus-5-5".
    name = model.name if model and model.name else MODEL
    return name.split(".", 1)[1] if "." in name else name


def resolve_agent(context: Context) -> AgentSettings:
    defaults = AgentSettings(MODEL, SYSTEM_PROMPT, EFFORT, MAX_ITERATIONS, "default")
    if ai_client is None:
        return defaults
    config = ai_client.agent_config(AGENT_CONFIG_KEY, context, DEFAULT_AGENT)
    if not config.enabled:
        log.warning("%s is disabled for this context; using defaults.", AGENT_CONFIG_KEY)
        return defaults
    model = config.model
    tracker = config.create_tracker()
    judges = config.judge_configuration.judges if config.judge_configuration else []
    return AgentSettings(
        model=_model_name(model),
        instructions=config.instructions or SYSTEM_PROMPT,
        effort=(model and model.get_parameter("effort")) or EFFORT,
        max_iterations=(model and model.get_parameter("max_iterations"))
        or MAX_ITERATIONS,
        # The tracker has no public accessor for the served variation key.
        variation=getattr(tracker, "_variation_key", None) or _model_name(model),
        tracker=tracker,
        judges=[(j.key, j.sampling_rate) for j in judges],
    )


@dataclass
class Run:
    result: dict
    request_text: str
    transcript: list


def find_twins(request: TwinsRequest, agent: AgentSettings) -> Run:
    place = request.name + (f", {request.country}" if request.country else "")
    request_text = (
        f"Find weather twins for {place} "
        f"(latitude {request.latitude}, longitude {request.longitude})."
    )
    transcript: list = []
    _transcript.set(transcript)
    runner = client.beta.messages.tool_runner(
        model=agent.model,
        max_tokens=16000,
        max_iterations=agent.max_iterations,
        system=agent.instructions,
        tools=TOOLS,
        output_config={
            "effort": agent.effort,
            "format": {"type": "json_schema", "schema": OUTPUT_SCHEMA},
        },
        # On a safety decline, re-run on Anthropic's recommended fallback model.
        betas=["server-side-fallback-2026-07-01"],
        fallbacks="default",
        messages=[{"role": "user", "content": request_text}],
    )

    # The Anthropic SDK traces the runner, each Claude call and each tool use
    # under this span; this one ties them to the served AI Config variation.
    with _start_span(
        "agent.run",
        {
            "gen_ai.agent.name": AGENT_CONFIG_KEY,
            "gen_ai.request.model": agent.model,
            "ld.ai_config.variation": agent.variation,
            "agent.effort": agent.effort,
            "agent.max_iterations": agent.max_iterations,
            "weather.place": place,
        },
    ) as span:
        final, tool_names, turns = None, [], 0
        input_tokens = output_tokens = 0
        for message in runner:
            final, turns = message, turns + 1
            tool_names += [b.name for b in message.content if b.type == "tool_use"]
            usage = message.usage
            input_tokens += (
                usage.input_tokens
                + (usage.cache_read_input_tokens or 0)
                + (usage.cache_creation_input_tokens or 0)
            )
            output_tokens += usage.output_tokens
        span.set_attributes(
            {
                "gen_ai.usage.input_tokens": input_tokens,
                "gen_ai.usage.output_tokens": output_tokens,
                "agent.turns": turns,
                "agent.tool_calls": len(tool_names),
            }
        )
        if final is not None:
            span.set_attribute("gen_ai.response.model", final.model)
            span.set_attribute("gen_ai.response.finish_reasons", [final.stop_reason or ""])
            if final.stop_reason in ("refusal", "max_tokens"):
                span.set_status(trace.StatusCode.ERROR, final.stop_reason)

    if agent.tracker is not None:
        agent.tracker.track_tokens(
            TokenUsage(
                total=input_tokens + output_tokens,
                input=input_tokens,
                output=output_tokens,
            )
        )
        agent.tracker.track_tool_calls(tool_names)

    if final is None:
        raise HTTPException(502, "The agent returned no response.")
    if final.stop_reason == "refusal":
        raise HTTPException(422, "The request was declined.")
    if final.stop_reason == "max_tokens":
        raise HTTPException(502, "The agent ran out of output tokens.")
    text = next((b.text for b in final.content if b.type == "text"), None)
    if text is None:
        # Usually means max_iterations ran out while it was still calling tools.
        raise HTTPException(502, f"The agent stopped early ({final.stop_reason}).")
    result = json.loads(text)
    result["model"] = final.model
    result["variation"] = agent.variation
    result["tool_calls"] = len(tool_names)
    return Run(result, request_text, transcript)


JUDGE_SCHEMA = {
    "type": "object",
    "properties": {
        "score": {"type": "number", "description": "0.0 to 1.0"},
        "reasoning": {"type": "string"},
    },
    "required": ["score", "reasoning"],
    "additionalProperties": False,
}


def run_judges(agent: AgentSettings, context: Context, run: Run) -> None:
    """Score the answer with each judge attached to the served variation and
    report the score against that variation. Runs after the response is sent.

    LaunchDarkly's built-in judge runners only cover OpenAI and LangChain, so
    the judge's prompt and model come from its AI Config and the call is made
    here with the Anthropic SDK.
    """
    if ai_client is None or agent.tracker is None:
        return
    evaluation_input = (
        "MESSAGE HISTORY:\n"
        + "\n".join([f"user: {run.request_text}", *run.transcript])
        + "\n\nRESPONSE TO EVALUATE:\n"
        + json.dumps({k: run.result[k] for k in ("summary", "twins")})
    )
    for judge_key, sampling_rate in agent.judges:
        if random.random() > sampling_rate:
            continue
        judge = ai_client.judge_config(judge_key, context)
        if not judge.enabled or not judge.evaluation_metric_key:
            log.warning("Judge %s is disabled or has no metric key.", judge_key)
            continue
        judge_tracker = judge.create_tracker()
        with _start_span(
            "agent.judge",
            {"ld.ai_config.key": judge_key, "ld.ai_config.variation": agent.variation},
        ) as span:
            verdict = _judge(judge, judge_key, judge_tracker, evaluation_input, span)
        if verdict is None:
            continue
        score, reasoning = verdict
        agent.tracker.track_judge_result(
            JudgeResult(
                judge_config_key=judge_key,
                success=True,
                sampled=True,
                metric_key=judge.evaluation_metric_key,
                score=score,
                reasoning=reasoning,
            )
        )
        log.info("judge %s: %.2f - %s", judge_key, score, reasoning)


def _judge(judge, judge_key: str, judge_tracker, evaluation_input: str, span):
    """One judge call. Returns (score, reasoning), or None if it failed."""
    system = "\n\n".join(m.content for m in judge.messages or [] if m.role == "system")
    started = time.monotonic()
    try:
        response = client.messages.create(
            model=_model_name(judge.model),
            max_tokens=(judge.model and judge.model.get_parameter("max_tokens"))
            or JUDGE_MAX_TOKENS,
            system=system,
            messages=[{"role": "user", "content": evaluation_input}],
            output_config={
                "effort": (judge.model and judge.model.get_parameter("effort"))
                or "low",
                "format": {"type": "json_schema", "schema": JUDGE_SCHEMA},
            },
        )
        judge_tracker.track_duration(round((time.monotonic() - started) * 1000))
        usage = response.usage
        judge_tracker.track_tokens(
            TokenUsage(
                total=usage.input_tokens + usage.output_tokens,
                input=usage.input_tokens,
                output=usage.output_tokens,
            )
        )
        if response.stop_reason in ("refusal", "max_tokens"):
            raise ValueError(f"judge stopped: {response.stop_reason}")
        verdict = json.loads(next(b.text for b in response.content if b.type == "text"))
        judge_tracker.track_success()
    except Exception as e:
        judge_tracker.track_error()
        span.record_exception(e)
        span.set_status(trace.StatusCode.ERROR, str(e))
        log.warning("Judge %s failed: %s", judge_key, e)
        return None
    score = min(max(float(verdict["score"]), 0.0), 1.0)
    span.set_attribute("judge.score", score)
    return score, verdict["reasoning"]


app = FastAPI(title="Weather Twins")
# fastapi is imported before the plugin patches it, so instrument this app
# directly. It continues the trace in the app's `traceparent` header.
if ai_client is not None:
    FastAPIInstrumentor.instrument_app(app)
# The Flutter web build calls this from another origin.
app.add_middleware(
    CORSMiddleware, allow_origins=["*"], allow_methods=["POST"], allow_headers=["*"]
)


FALLBACK_CONTEXT = Context.builder("weather-app-user").kind("user").anonymous(True).build()


def _context_for(request: "TwinsRequest | ServingRequest") -> Context:
    if request.context is None:
        return FALLBACK_CONTEXT
    context = Context.from_dict(request.context)
    if not context.valid:
        log.warning("Invalid LaunchDarkly context from app: %s", context.error)
        return FALLBACK_CONTEXT
    return context


class ServingRequest(BaseModel):
    context: dict | None = None


@app.post("/twins/serving")
def serving(request: ServingRequest) -> dict:
    """Which variation and model a /twins call with this context will use, so
    the app can show it while the agent runs. Same context, same answer."""
    agent = resolve_agent(_context_for(request))
    return {"variation": agent.variation, "model": agent.model}


@app.post("/twins")
def twins(request: TwinsRequest, background: BackgroundTasks) -> dict:
    context = _context_for(request)
    agent = resolve_agent(context)
    started = time.monotonic()
    try:
        run = find_twins(request, agent)
    except Exception as e:
        if agent.tracker is not None:
            agent.tracker.track_duration(round((time.monotonic() - started) * 1000))
            agent.tracker.track_error()
        if ai_client is not None:
            observe.record_exception(e, {"ld.ai_config.variation": agent.variation})
        if isinstance(e, HTTPException):
            raise
        if isinstance(e, anthropic.RateLimitError):
            raise HTTPException(429, "Rate limited by the Claude API; try again soon.")
        if isinstance(e, anthropic.APIStatusError):
            log.error("Claude API error %s (request %s)", e.status_code, e.request_id)
            raise HTTPException(502, "The Claude API returned an error.")
        if isinstance(e, anthropic.APIConnectionError):
            raise HTTPException(503, "Couldn't reach the Claude API.")
        raise
    duration_ms = round((time.monotonic() - started) * 1000)
    if agent.tracker is not None:
        agent.tracker.track_duration(duration_ms)
        agent.tracker.track_success()
    background.add_task(run_judges, agent, context, run)
    result = run.result
    result["duration_ms"] = duration_ms
    log.info(
        "twins for %s (%s): %d results, %d tool calls, %d ms",
        request.name,
        agent.variation,
        len(result["twins"]),
        result["tool_calls"],
        duration_ms,
    )
    return result

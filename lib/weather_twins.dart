import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:launchdarkly_flutter_client_sdk/launchdarkly_flutter_client_sdk.dart';
import 'package:launchdarkly_flutter_observability/launchdarkly_flutter_observability.dart';
import 'package:opentelemetry/api.dart' as otel;

import 'feature_flags.dart';
import 'weather_models.dart';

/// A place whose weather resembles the searched city, found by the
/// Weather Twins agent (see `twins_backend/`).
class WeatherTwin {
  final String name;
  final String country;
  final double latitude;
  final double longitude;
  final int similarity;
  final double todayTemperatureC;
  final String reason;

  const WeatherTwin({
    required this.name,
    required this.country,
    required this.latitude,
    required this.longitude,
    required this.similarity,
    required this.todayTemperatureC,
    required this.reason,
  });

  factory WeatherTwin.fromJson(Map<String, dynamic> json) => WeatherTwin(
        name: json['name'] as String,
        country: json['country'] as String,
        latitude: (json['latitude'] as num).toDouble(),
        longitude: (json['longitude'] as num).toDouble(),
        similarity: (json['similarity'] as num).round(),
        todayTemperatureC: (json['today_temperature_c'] as num).toDouble(),
        reason: json['reason'] as String,
      );
}

class TwinsResult {
  final String summary;
  final List<WeatherTwin> twins;

  const TwinsResult({required this.summary, required this.twins});

  factory TwinsResult.fromJson(Map<String, dynamic> json) => TwinsResult(
        summary: json['summary'] as String,
        twins: [
          for (final t in json['twins'] as List)
            WeatherTwin.fromJson(t as Map<String, dynamic>),
        ],
      );
}

/// Calls the Weather Twins backend. The agent runs there so the Claude API
/// key never ships in the app.
class TwinsService {
  /// Override with `--dart-define=WEATHER_TWINS_URL=...`. By default this is
  /// the backend on the dev machine; the Android emulator reaches the host's
  /// localhost at 10.0.2.2.
  static String get defaultBaseUrl {
    const configured = String.fromEnvironment('WEATHER_TWINS_URL');
    if (configured.isNotEmpty) return configured;
    final android = !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
    return android ? 'http://10.0.2.2:8787' : 'http://127.0.0.1:8787';
  }

  final http.Client _client;
  final String baseUrl;

  TwinsService({http.Client? client, String? baseUrl})
      : _client = client ?? http.Client(),
        baseUrl = baseUrl ?? defaultBaseUrl;

  /// The agent checks each candidate against real data, which usually takes
  /// 30-60 seconds.
  static const timeout = Duration(seconds: 120);

  Future<TwinsResult> find(Location location) => LDObserve.withSpan(
        'weather.twins',
        kind: SpanKind.client,
        properties: {'server.address': Uri.parse(baseUrl).host},
        (span) async {
          final http.Response response;
          try {
            response = await _client
                .post(
                  Uri.parse('$baseUrl/twins'),
                  headers: {
                    'Content-Type': 'application/json',
                    ..._traceHeaders(),
                  },
                  body: jsonEncode({
                    'name': location.name,
                    'country': location.country,
                    'latitude': location.latitude,
                    'longitude': location.longitude,
                    ..._contextBody(),
                  }),
                )
                .timeout(timeout);
          } catch (e) {
            span.setAttribute('error.type', e.runtimeType.toString());
            throw TwinsException("Couldn't reach the Weather Twins service.");
          }
          span.setAttribute('http.response.status_code', response.statusCode);
          final body = jsonDecode(response.body) as Map<String, dynamic>;
          if (response.statusCode != 200) {
            span.setAttribute('error.type', '${response.statusCode}');
            throw TwinsException(
                body['detail'] as String? ?? 'Weather Twins failed.');
          }
          span.setAttribute('agent.tool_calls', body['tool_calls']);
          span.setAttribute('agent.model', body['model']);
          return TwinsResult.fromJson(body);
        },
      );

  /// W3C `traceparent` for the current span, so the backend's spans (the
  /// agent run, its tool calls and Claude calls) join this trace. Empty when
  /// observability isn't running.
  static Map<String, String> _traceHeaders() {
    final headers = <String, String>{};
    if (otel.spanContextFromContext(otel.Context.current).isValid) {
      otel.W3CTraceContextPropagator()
          .inject(otel.Context.current, headers, _MapSetter());
    }
    return headers;
  }

  /// The full multi-context (user, ld_device, ld_application), so the
  /// backend's AI Config is targeted and tracked for the same context the
  /// app's flags are, device rules included.
  static Map<String, dynamic> _contextBody() => {
        if (currentLdContext.value case final ldContext?)
          'context': ldContextToJson(ldContext),
      };

  /// Which AI Config variation and model a [find] call will use, or null if
  /// the backend can't say. Quick: it only evaluates the config.
  Future<({String variation, String model})?> serving() async {
    try {
      final response = await _client
          .post(
            Uri.parse('$baseUrl/twins/serving'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode(_contextBody()),
          )
          .timeout(const Duration(seconds: 10));
      if (response.statusCode != 200) return null;
      final body = jsonDecode(response.body) as Map<String, dynamic>;
      return (
        variation: body['variation'] as String,
        model: body['model'] as String,
      );
    } catch (_) {
      return null;
    }
  }

  void dispose() => _client.close();
}

class TwinsException implements Exception {
  final String message;
  TwinsException(this.message);

  @override
  String toString() => message;
}

/// Opens the Weather Twins sheet for [location]. Tapping a twin calls
/// [onSelect] with its name.
class TwinsButton extends StatelessWidget {
  final Location location;
  final ValueChanged<String> onSelect;

  const TwinsButton(
      {super.key, required this.location, required this.onSelect});

  @override
  Widget build(BuildContext context) => FilledButton.tonalIcon(
        icon: const Icon(Icons.travel_explore),
        label: const Text('Find weather twins'),
        onPressed: () async {
          final picked = await showModalBottomSheet<String>(
            context: context,
            isScrollControlled: true,
            showDragHandle: true,
            // Named so LDNavigatorObserver reports it as a screen view.
            routeSettings: const RouteSettings(name: '/twins'),
            builder: (_) => _TwinsSheet(location: location),
          );
          if (picked != null) onSelect(picked);
        },
      );
}

class _TwinsSheet extends StatefulWidget {
  final Location location;

  const _TwinsSheet({required this.location});

  @override
  State<_TwinsSheet> createState() => _TwinsSheetState();
}

class _TwinsSheetState extends State<_TwinsSheet> {
  final _service = TwinsService();
  late final Future<TwinsResult> _result;
  late final Future<({String variation, String model})?> _serving;

  @override
  void initState() {
    super.initState();
    _result = _find();
    _serving = _service.serving();
  }

  @override
  void dispose() {
    _service.dispose();
    super.dispose();
  }

  /// Runs the agent and reports a `weather_twins` event whose metric value is
  /// the time in milliseconds.
  Future<TwinsResult> _find() async {
    final client =
        context.getInheritedWidgetOfExactType<LaunchDarkly>()?.client;
    final stopwatch = Stopwatch()..start();
    var count = 0;
    try {
      final result = await _service.find(widget.location);
      count = result.twins.length;
      return result;
    } finally {
      client?.track('weather_twins',
          metricValue: stopwatch.elapsedMilliseconds.toDouble(),
          data: LDValue.buildObject()
              .addBool('success', count > 0)
              .addNum('count', count)
              .build());
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ConstrainedBox(
      constraints:
          BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.85),
      child: FutureBuilder<TwinsResult>(
        future: _result,
        builder: (context, snapshot) {
          final Widget body;
          if (snapshot.hasError) {
            body = Padding(
              padding: const EdgeInsets.all(24),
              child:
                  Text(snapshot.error.toString(), textAlign: TextAlign.center),
            );
          } else if (!snapshot.hasData) {
            body = Padding(
              padding: const EdgeInsets.all(32),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const CircularProgressIndicator(),
                  const SizedBox(height: 16),
                  FutureBuilder(
                    future: _serving,
                    builder: (context, serving) => switch (serving.data) {
                      (:final variation, :final model) => Marquee(
                          'Serving variation $variation, with model $model',
                          style: theme.textTheme.titleSmall
                              ?.copyWith(color: theme.colorScheme.primary),
                        ),
                      null => const SizedBox.shrink(),
                    },
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Comparing climates around the world…\n'
                    'This takes up to a minute.',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodyMedium,
                  ),
                ],
              ),
            );
          } else {
            final result = snapshot.data!;
            body = ListView(
              shrinkWrap: true,
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
              children: [
                Text(result.summary, style: theme.textTheme.bodyMedium),
                const SizedBox(height: 12),
                for (final twin in result.twins)
                  Card(
                    child: ListTile(
                      leading: CircleAvatar(child: Text('${twin.similarity}')),
                      title: Text('${twin.name}, ${twin.country}'),
                      subtitle: Text(twin.reason),
                      trailing: Text('${twin.todayTemperatureC.round()}°',
                          style: theme.textTheme.titleMedium),
                      isThreeLine: true,
                      onTap: () {
                        LaunchDarkly.of(context)?.track('weather_twin_selected',
                            data: LDValue.buildObject()
                                .addString('twin', twin.name)
                                .addNum('similarity', twin.similarity)
                                .build());
                        Navigator.pop(context, twin.name);
                      },
                    ),
                  ),
              ],
            );
          }
          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                child: Text('Weather twins for ${widget.location.name}',
                    style: theme.textTheme.titleLarge),
              ),
              Flexible(child: body),
            ],
          );
        },
      ),
    );
  }
}

/// [text] scrolling right to left on repeat, in a single line.
class Marquee extends StatefulWidget {
  final String text;
  final TextStyle? style;

  /// Scroll speed in logical pixels per second.
  final double speed;

  const Marquee(this.text, {super.key, this.style, this.speed = 60});

  @override
  State<Marquee> createState() => _MarqueeState();
}

class _MarqueeState extends State<Marquee> with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(vsync: this);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final style = DefaultTextStyle.of(context).style.merge(widget.style);
    final painter = TextPainter(
      text: TextSpan(text: widget.text, style: style),
      textDirection: Directionality.of(context),
      maxLines: 1,
    )..layout();
    return LayoutBuilder(builder: (context, constraints) {
      final width = constraints.maxWidth;
      // One pass: enters from the right edge, leaves past the left edge.
      final distance = width + painter.width;
      final duration =
          Duration(milliseconds: (distance / widget.speed * 1000).round());
      if (_controller.duration != duration) {
        _controller
          ..duration = duration
          ..repeat();
      }
      return ClipRect(
        child: SizedBox(
          height: painter.height,
          width: width,
          child: AnimatedBuilder(
            animation: _controller,
            builder: (context, child) => Transform.translate(
              offset: Offset(width - _controller.value * distance, 0),
              child: child,
            ),
            child: OverflowBox(
              alignment: Alignment.centerLeft,
              minWidth: 0,
              maxWidth: double.infinity,
              child:
                  Text(widget.text, style: style, maxLines: 1, softWrap: false),
            ),
          ),
        ),
      );
    });
  }
}

class _MapSetter implements otel.TextMapSetter<Map<String, String>> {
  @override
  void set(Map<String, String> carrier, String key, String value) {
    if (value.isNotEmpty) carrier[key] = value;
  }
}

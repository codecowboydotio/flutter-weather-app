import 'dart:convert';

import 'package:flutter/material.dart';

import 'package:launchdarkly_flutter_client_sdk/launchdarkly_flutter_client_sdk.dart';
import 'package:launchdarkly_flutter_observability/launchdarkly_flutter_observability.dart';

import 'feature_flags.dart';
import 'session_replay.dart';
import 'weather_models.dart';
import 'weather_service.dart';
import 'weather_twins.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final ldClient = await initLaunchDarkly();
  initSessionReplay(ldClient);
  runApp(WeatherApp(ldClient: ldClient));
}

class WeatherApp extends StatelessWidget {
  final LDClient? ldClient;

  const WeatherApp({super.key, this.ldClient});

  @override
  Widget build(BuildContext context) {
    return LaunchDarkly(
      client: ldClient,
      // Hosts replay capture and tap tracking while recording is on.
      child: ReplayRecorder(
          child: MaterialApp(
        title: "Today's Weather",
        debugShowCheckedModeBanner: false,
        // Reports screen views; the home route is named "/".
        navigatorObservers: [LDNavigatorObserver()],
        theme: ThemeData(
          colorSchemeSeed: Colors.blue,
          useMaterial3: true,
        ),
        home: const WeatherScreen(),
      )),
    );
  }
}

class WeatherScreen extends StatefulWidget {
  const WeatherScreen({super.key});

  @override
  State<WeatherScreen> createState() => _WeatherScreenState();
}

class _WeatherScreenState extends State<WeatherScreen> {
  static const _defaultCity = 'San Francisco';

  final _service = WeatherService();
  final _searchController = TextEditingController(text: _defaultCity);

  Location? _location;
  TodayWeather? _weather;
  String? _error;
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _load(_defaultCity);
  }

  @override
  void dispose() {
    _service.dispose();
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _load(String city) async {
    if (city.trim().isEmpty) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    await _measureLoad('search', () async {
      try {
        final location = await _service.findLocation(city.trim());
        final weather = await _service.fetchToday(location);
        if (!mounted) return false;
        setState(() {
          _location = location;
          _weather = weather;
        });
        return true;
      } catch (e) {
        if (mounted) setState(() => _error = e.toString());
        return false;
      } finally {
        if (mounted) setState(() => _loading = false);
      }
    });
  }

  Future<void> _refresh() async {
    final location = _location;
    if (location == null) return _load(_searchController.text);
    await _measureLoad('refresh', () async {
      try {
        final weather = await _service.fetchToday(location);
        if (mounted) setState(() => _weather = weather);
        return mounted;
      } catch (e) {
        if (mounted) setState(() => _error = e.toString());
        return false;
      }
    });
  }

  /// Times [load] until its result is on screen, as a `weather.load` span and
  /// a `weather_load` event whose metric value is the time in milliseconds.
  /// Sending the event through the LaunchDarkly client makes it usable as a
  /// flag metric; the observability plugin also records it as a `track` span.
  /// [load] returns whether it succeeded.
  Future<void> _measureLoad(String source, Future<bool> Function() load) async {
    // Not LaunchDarkly.of: this also runs from initState, where depending on
    // an inherited widget isn't allowed.
    final client =
        context.getInheritedWidgetOfExactType<LaunchDarkly>()?.client;
    final stopwatch = Stopwatch()..start();
    await LDObserve.withSpan('weather.load', properties: {'source': source},
        (span) async {
      final ok = await load();
      // Wait for the frame that shows the result.
      if (mounted) await WidgetsBinding.instance.endOfFrame;
      span.setAttribute('success', ok);
      client?.track('weather_load',
          metricValue: stopwatch.elapsedMilliseconds.toDouble(),
          data: LDValue.buildObject()
              .addString('source', source)
              .addBool('success', ok)
              .build());
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: replaySupported
            ? const FeatureFlag(
                flagKey: FlagKeys.sessionReplayButton,
                child: _ReplayButton(),
              )
            : null,
        title: const Text("Today's Weather"),
        actions: [
          const _LoginButton(),
          IconButton(
            tooltip: 'Refresh',
            icon: const Icon(Icons.refresh),
            onPressed: _loading ? null : _refresh,
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _refresh,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            FeatureFlag(
              flagKey: FlagKeys.searchBar,
              child: Padding(
                padding: const EdgeInsets.only(bottom: 24),
                child: ReplayMask(
                    child: TextField(
                  controller: _searchController,
                  textInputAction: TextInputAction.search,
                  onSubmitted: _load,
                  decoration: InputDecoration(
                    labelText: 'City',
                    prefixIcon: const Icon(Icons.search),
                    border: const OutlineInputBorder(),
                    suffixIcon: IconButton(
                      icon: const Icon(Icons.arrow_forward),
                      onPressed: () => _load(_searchController.text),
                    ),
                  ),
                )),
              ),
            ),
            if (_loading)
              const Padding(
                padding: EdgeInsets.only(top: 48),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (_error != null)
              _ErrorView(
                  message: _error!,
                  onRetry: () => _load(_searchController.text))
            else if (_weather != null && _location != null)
              _WeatherView(
                location: _location!,
                weather: _weather!,
                onSelectTwin: (city) {
                  _searchController.text = city;
                  _load(city);
                },
              ),
            const FeatureFlag(
              flagKey: FlagKeys.contextTile,
              child: Padding(
                padding: EdgeInsets.only(top: 12),
                child: _ContextCard(),
              ),
            ),
            const SizedBox(height: 24),
            Text(
              'Weather data by Open-Meteo.com',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}

class _WeatherView extends StatelessWidget {
  final Location location;
  final TodayWeather weather;

  /// Called with a city name when a weather twin is tapped.
  final ValueChanged<String> onSelectTwin;

  const _WeatherView(
      {required this.location,
      required this.weather,
      required this.onSelectTwin});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final t = weather.tempUnit;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ReplayMask(
            child: Card(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              children: [
                Text(location.displayName,
                    textAlign: TextAlign.center,
                    style: theme.textTheme.titleLarge),
                const SizedBox(height: 4),
                Text('Updated ${_hhmm(weather.observedAt)} local time',
                    style: theme.textTheme.bodySmall),
                const SizedBox(height: 16),
                Icon(_iconFor(weather.weatherCode, weather.isDay),
                    size: 96, color: theme.colorScheme.primary),
                const SizedBox(height: 8),
                Text('${weather.temperature.round()}$t',
                    style: theme.textTheme.displayLarge),
                Text(weather.description, style: theme.textTheme.titleMedium),
                const SizedBox(height: 8),
                Text(
                  'H: ${weather.high.round()}$t   L: ${weather.low.round()}$t',
                  style: theme.textTheme.bodyLarge,
                ),
              ],
            ),
          ),
        )),
        // Between the main card and the detail tiles.
        FeatureFlag(
          flagKey: FlagKeys.weatherTwins,
          child: Padding(
            padding: const EdgeInsets.only(top: 12),
            child: TwinsButton(location: location, onSelect: onSelectTwin),
          ),
        ),
        const SizedBox(height: 12),
        // Each tile is behind its own flag; hidden tiles are removed from the
        // grid (not just blanked) so the remaining ones reflow.
        FeatureFlagBuilder(
          flagKeys: const {
            FlagKeys.feelsLikeTile,
            FlagKeys.humidityTile,
            FlagKeys.windTile,
            FlagKeys.rainChanceTile,
            FlagKeys.sunriseTile,
            FlagKeys.sunsetTile,
          },
          builder: (context, isOn) => GridView(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 2,
              mainAxisExtent: 72,
              mainAxisSpacing: 8,
              crossAxisSpacing: 8,
            ),
            children: [
              if (isOn(FlagKeys.feelsLikeTile))
                _Detail(Icons.thermostat, 'Feels like',
                    '${weather.feelsLike.round()}$t'),
              if (isOn(FlagKeys.humidityTile))
                _Detail(Icons.water_drop, 'Humidity', '${weather.humidity}%'),
              if (isOn(FlagKeys.windTile))
                _Detail(Icons.air, 'Wind',
                    '${weather.windSpeed.round()} ${weather.windUnit}'),
              if (isOn(FlagKeys.rainChanceTile))
                _Detail(
                    Icons.umbrella,
                    'Rain chance',
                    weather.precipitationChance == null
                        ? '—'
                        : '${weather.precipitationChance}%'),
              if (isOn(FlagKeys.sunriseTile))
                _Detail(Icons.wb_twilight, 'Sunrise', _hhmm(weather.sunrise)),
              if (isOn(FlagKeys.sunsetTile))
                _Detail(Icons.nights_stay, 'Sunset', _hhmm(weather.sunset)),
            ],
          ),
        ),
      ],
    );
  }

  static String _hhmm(DateTime d) =>
      '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';

  static IconData _iconFor(int code, bool isDay) {
    if (code == 0 || code == 1) {
      return isDay ? Icons.wb_sunny : Icons.nightlight_round;
    }
    if (code == 2) return isDay ? Icons.wb_cloudy : Icons.cloud;
    if (code == 3) return Icons.cloud;
    if (code == 45 || code == 48) return Icons.foggy;
    if (code >= 71 && code <= 77 || code == 85 || code == 86) {
      return Icons.ac_unit;
    }
    if (code >= 95) return Icons.thunderstorm;
    if (code >= 51) return Icons.grain;
    return Icons.help_outline;
  }
}

class _Detail extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;

  const _Detail(this.icon, this.label, this.value);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Every tile is masked individually in session replay.
    return ReplayMask(
        child: Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Row(
          children: [
            Icon(icon, color: theme.colorScheme.primary),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label, style: theme.textTheme.bodySmall),
                  Text(value, style: theme.textTheme.titleMedium),
                ],
              ),
            ),
          ],
        ),
      ),
    ));
  }
}

/// Logs "user1" (role: admin) in or out by re-identifying the LaunchDarkly
/// client. Flags re-evaluate for the new context and [FeatureFlagBuilder]s
/// rebuild on the resulting flag changes.
/// Values of [FlagKeys.loginButtonColor] that give the button a background.
const _loginButtonColors = {
  'red': Colors.red,
  'blue': Colors.blue,
  'green': Colors.green,
};

class _LoginButton extends StatefulWidget {
  const _LoginButton();

  @override
  State<_LoginButton> createState() => _LoginButtonState();
}

class _LoginButtonState extends State<_LoginButton> {
  bool _busy = false;

  Future<void> _toggle(LDClient client, bool loggedIn) async {
    setState(() => _busy = true);
    try {
      await client.identify(
          loggedIn ? anonymousContext() : userContext('user1', role: 'admin'));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final client = LaunchDarkly.of(context);
    return ValueListenableBuilder<LDContext?>(
      valueListenable: currentLdContext,
      builder: (context, ldContext, _) {
        final loggedIn = isLoggedIn(ldContext);
        final onPressed =
            client == null || _busy ? null : () => _toggle(client, loggedIn);
        final icon = Icon(loggedIn ? Icons.logout : Icons.login);
        final label = Text(loggedIn ? 'Log out user1' : 'Log in');
        // Background colour comes from [FlagKeys.loginButtonColor]. Updates
        // live. "default" or an unknown value keeps the plain text button.
        return StringFlagBuilder(
          flagKey: FlagKeys.loginButtonColor,
          fallback: 'default',
          builder: (context, value) {
            final color = _loginButtonColors[value];
            return color == null
                ? TextButton.icon(
                    onPressed: onPressed,
                    icon: icon,
                    label: label,
                  )
                : FilledButton.icon(
                    style: FilledButton.styleFrom(
                      backgroundColor: color,
                      foregroundColor: Colors.white,
                    ),
                    onPressed: onPressed,
                    icon: icon,
                    label: label,
                  );
          },
        );
      },
    );
  }
}

/// Starts or stops recording session replay frames.
class _ReplayButton extends StatelessWidget {
  const _ReplayButton();

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<bool>(
        valueListenable: replayRecording,
        builder: (context, recording, _) => IconButton(
          tooltip: recording ? 'Stop session replay' : 'Start session replay',
          icon: recording
              ? const Icon(Icons.stop_circle, color: Colors.red)
              : const Icon(Icons.fiber_manual_record_outlined),
          onPressed: LaunchDarkly.of(context) == null
              ? null
              : () => replayRecording.value = !recording,
        ),
      );
}

/// Shows the LaunchDarkly context this device is evaluating flags with.
class _ContextCard extends StatelessWidget {
  const _ContextCard();

  static const _json = JsonEncoder.withIndent('  ');

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ValueListenableBuilder<LDContext?>(
      valueListenable: currentLdContext,
      builder: (context, ldContext, _) => ReplayMask(
          child: Card(
        child: ExpansionTile(
          leading: Icon(Icons.badge_outlined, color: theme.colorScheme.primary),
          title: const Text('LaunchDarkly context'),
          subtitle: Text(
            ldContext == null
                ? 'Not connected'
                : ldContext.attributesByKind.keys.join(', '),
            style: theme.textTheme.bodySmall,
          ),
          childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          expandedCrossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SelectableText(
              ldContext == null
                  ? 'LaunchDarkly is disabled or has not identified yet.'
                  : _json.convert(ldContextToJson(ldContext)),
              style:
                  theme.textTheme.bodySmall?.copyWith(fontFamily: 'monospace'),
            ),
          ],
        ),
      )),
    );
  }
}

class _ErrorView extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;

  const _ErrorView({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Icon(Icons.error_outline,
            size: 48, color: Theme.of(context).colorScheme.error),
        const SizedBox(height: 8),
        Text(message, textAlign: TextAlign.center),
        const SizedBox(height: 12),
        FilledButton(onPressed: onRetry, child: const Text('Try again')),
      ],
    );
  }
}

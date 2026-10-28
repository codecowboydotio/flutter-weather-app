import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:launchdarkly_flutter_client_sdk/launchdarkly_flutter_client_sdk.dart';

/// LaunchDarkly flag keys (project: default, tag: flutter).
abstract final class FlagKeys {
  static const searchBar = 'flutter_app_search_bar';
  static const feelsLikeTile = 'flutter_app_feels_like_tile';
  static const humidityTile = 'flutter_app_humidity_tile';
  static const windTile = 'flutter_app_wind_tile';
  static const rainChanceTile = 'flutter_app_rain_chance_tile';
  static const sunriseTile = 'flutter_app_sunrise_tile';
  static const sunsetTile = 'flutter_app_sunset_tile';
  static const sessionReplay = 'flutter_app_session_replay';
  static const sessionReplayObfuscation =
      'flutter_app_session_replay_obfuscation';
  static const sessionReplayButton = 'flutter_app_session_replay_button';
  static const contextTile = 'flutter_app_context_tile';
  static const weatherTwins = 'flutter_app_weather_twins';
}

/// Value used when LaunchDarkly is unconfigured or unreachable, so the app
/// still shows its full UI.
const bool kFlagFallback = true;

/// The context the SDK actually evaluates with, after it adds the
/// auto-environment kinds (`ld_application`, `ld_device`). Null until the
/// first identify completes, or always null if LaunchDarkly is disabled.
final ValueNotifier<LDContext?> currentLdContext = ValueNotifier(null);

/// How long [initLaunchDarkly] waited for the client to start, and whether it
/// gave up at the timeout. Null if LaunchDarkly is disabled. Reported once
/// observability is up (see `initSessionReplay`), since that needs the client.
({Duration duration, bool timedOut})? ldStartTiming;

/// Records each identified context into [currentLdContext]. The client has no
/// public getter for the decorated context, but identify hooks receive it.
final class _ContextCaptureHook extends Hook {
  @override
  final HookMetadata metadata = const HookMetadata(name: 'ContextCapture');

  @override
  UnmodifiableMapView<String, dynamic> beforeIdentify(
      IdentifySeriesContext hookContext,
      UnmodifiableMapView<String, dynamic> data) {
    currentLdContext.value = hookContext.context;
    return data;
  }
}

/// [context] in the JSON shape LaunchDarkly uses (`kind: multi`), including
/// the auto-environment kinds. Used by the context card, and sent to the
/// Weather Twins backend so its AI Config is evaluated with the same context.
Map<String, dynamic> ldContextToJson(LDContext context) => {
      'kind': 'multi',
      for (final MapEntry(key: kind, value: attrs)
          in context.attributesByKind.entries)
        kind: {
          'key': attrs.key,
          if (attrs.anonymous) 'anonymous': true,
          if (attrs.name != null) 'name': attrs.name,
          for (final MapEntry(:key, :value) in attrs.customAttributes.entries)
            key: value.toDynamic(),
        },
    };

/// Context used while nobody is logged in.
LDContext anonymousContext() =>
    LDContextBuilder().kind('user', 'weather-app-user').anonymous(true).build();

/// Context for a logged-in user. The SDK keeps adding `ld_application` and
/// `ld_device` on identify, so only the `user` kind is built here.
LDContext userContext(String key, {required String role}) => LDContextBuilder()
    .kind('user', key)
    .name(key)
    .setString('role', role)
    .build();

/// Whether [context] has a non-anonymous `user` kind.
bool isLoggedIn(LDContext? context) =>
    context?.attributesByKind['user']?.anonymous == false;

/// Starts the LaunchDarkly client. Returns null (flags use [kFlagFallback])
/// if no credential was provided at build time.
///
/// Provide credentials with `--dart-define-from-file=launchdarkly.json`
/// (gitignored; copy `launchdarkly.example.json`).
/// Web builds use the client-side ID; all other platforms use the mobile key.
/// (We pick it here rather than via `CredentialSource.fromEnvironment()`,
/// which throws if both are defined.)
Future<LDClient?> initLaunchDarkly() async {
  const credential = kIsWeb
      ? String.fromEnvironment('LAUNCHDARKLY_CLIENT_SIDE_ID')
      : String.fromEnvironment('LAUNCHDARKLY_MOBILE_KEY');
  if (credential.isEmpty) {
    debugPrint('LaunchDarkly disabled: no credential for this platform.');
    return null;
  }

  final client = LDClient(
    LDConfig(credential, AutoEnvAttributes.enabled,
        hooks: [_ContextCaptureHook()]),
    anonymousContext(),
  );
  // Don't block app start for long; flags stream in when the connection is up.
  final stopwatch = Stopwatch()..start();
  var timedOut = false;
  await client.start().timeout(const Duration(seconds: 5), onTimeout: () {
    timedOut = true;
    return false;
  });
  ldStartTiming = (duration: stopwatch.elapsed, timedOut: timedOut);
  return client;
}

/// Makes the LaunchDarkly client available to [FeatureFlagBuilder]s below it.
class LaunchDarkly extends InheritedWidget {
  final LDClient? client;

  const LaunchDarkly({super.key, required this.client, required super.child});

  static LDClient? of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<LaunchDarkly>()?.client;

  @override
  bool updateShouldNotify(LaunchDarkly oldWidget) => client != oldWidget.client;
}

/// Rebuilds whenever any of [flagKeys] changes in LaunchDarkly and passes an
/// `isOn(key)` lookup to [builder].
class FeatureFlagBuilder extends StatefulWidget {
  final Set<String> flagKeys;
  final Widget Function(BuildContext context, bool Function(String key) isOn)
      builder;

  const FeatureFlagBuilder(
      {super.key, required this.flagKeys, required this.builder});

  @override
  State<FeatureFlagBuilder> createState() => _FeatureFlagBuilderState();
}

class _FeatureFlagBuilderState extends State<FeatureFlagBuilder> {
  LDClient? _client;
  StreamSubscription<FlagsChangedEvent>? _subscription;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final client = LaunchDarkly.of(context);
    if (client == _client) return;
    _subscription?.cancel();
    _client = client;
    _subscription = client?.flagChanges
        .where((event) => event.keys.any(widget.flagKeys.contains))
        .listen((_) => setState(() {}));
  }

  @override
  void dispose() {
    _subscription?.cancel();
    super.dispose();
  }

  bool _isOn(String key) =>
      _client?.boolVariation(key, kFlagFallback) ?? kFlagFallback;

  @override
  Widget build(BuildContext context) => widget.builder(context, _isOn);
}

/// Shows [child] only while [flagKey] is on.
class FeatureFlag extends StatelessWidget {
  final String flagKey;
  final Widget child;

  const FeatureFlag({super.key, required this.flagKey, required this.child});

  @override
  Widget build(BuildContext context) => FeatureFlagBuilder(
        flagKeys: {flagKey},
        builder: (context, isOn) =>
            isOn(flagKey) ? child : const SizedBox.shrink(),
      );
}

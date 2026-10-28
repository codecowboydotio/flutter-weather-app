import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:launchdarkly_flutter_client_sdk/launchdarkly_flutter_client_sdk.dart';
import 'package:launchdarkly_flutter_observability/launchdarkly_flutter_observability.dart';

import 'feature_flags.dart';

/// Whether session replay can run on this platform (iOS/Android only).
bool get replaySupported =>
    !kIsWeb &&
    (defaultTargetPlatform == TargetPlatform.iOS ||
        defaultTargetPlatform == TargetPlatform.android);

/// Whether replay frames are being recorded. Toggled by the replay button;
/// starts on if [FlagKeys.sessionReplay] is on at launch.
final ValueNotifier<bool> replayRecording = ValueNotifier(false);

/// Loads LaunchDarkly observability and session replay on every launch.
///
/// The SDK can only be initialized once per process and can't pause replay,
/// so it is always started with replay enabled. Recording is switched on and
/// off by [ReplayRecorder], which only feeds frames to the SDK while
/// [replayRecording] is true.
void initSessionReplay(LDClient? client) {
  if (client == null) return;
  replayRecording.value =
      replaySupported && client.boolVariation(FlagKeys.sessionReplay, false);
  unawaited(LDObserve.init(
    client,
    observability: const ObservabilityOptions(serviceName: 'weather_app'),
    replay: const SessionReplayOptions(
      isEnabled: true,
      // Masking is driven per component by [ReplayMask] and the
      // obfuscation flag, rather than by these screen-wide defaults.
      privacy: PrivacyOptions(maskTextInputs: false),
    ),
  ).then((ready) {
    // Anything recorded before init completes is dropped, so report the
    // LaunchDarkly start time here.
    final timing = ldStartTiming;
    if (!ready || timing == null) return;
    LDObserve.track('launchdarkly_start',
        metricValue: timing.duration.inMilliseconds,
        properties: {'timed_out': timing.timedOut});
  }));
}

/// Wraps [child] in [SessionReplayCapture] only while [replayRecording] is on.
/// Without the capture widget the SDK gets no frames (or taps), so this stops
/// and restarts recording while the library stays loaded.
class ReplayRecorder extends StatelessWidget {
  final Widget child;

  const ReplayRecorder({super.key, required this.child});

  /// Keeps [child]'s state when it moves in and out of the capture widget.
  static final _childKey = GlobalKey();

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<bool>(
        valueListenable: replayRecording,
        builder: (context, recording, _) {
          final keyed = KeyedSubtree(key: _childKey, child: child);
          return recording ? SessionReplayCapture(child: keyed) : keyed;
        },
      );
}

/// Masks [child] in session replay recordings while
/// [FlagKeys.sessionReplayObfuscation] is on. Updates live.
class ReplayMask extends StatelessWidget {
  final Widget child;

  const ReplayMask({super.key, required this.child});

  @override
  Widget build(BuildContext context) => FeatureFlagBuilder(
        flagKeys: const {FlagKeys.sessionReplayObfuscation},
        builder: (context, isOn) => isOn(FlagKeys.sessionReplayObfuscation)
            ? LDMask(child: child)
            : child,
      );
}

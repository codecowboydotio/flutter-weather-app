import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:launchdarkly_flutter_observability/launchdarkly_flutter_observability.dart';
import 'package:weather_app/feature_flags.dart';
import 'package:weather_app/session_replay.dart';

void main() {
  testWidgets(
      'without a LaunchDarkly client, flagged widgets fall back to shown',
      (tester) async {
    await tester.pumpWidget(const LaunchDarkly(
      client: null,
      child: Directionality(
        textDirection: TextDirection.ltr,
        child: FeatureFlag(flagKey: FlagKeys.searchBar, child: Text('search')),
      ),
    ));
    expect(find.text('search'), findsOneWidget);
  });

  testWidgets('ReplayMask masks its child when obfuscation resolves on',
      (tester) async {
    // With no client, flags fall back to on, so replay stays masked if
    // LaunchDarkly can't be reached.
    await tester.pumpWidget(const LaunchDarkly(
      client: null,
      child: Directionality(
        textDirection: TextDirection.ltr,
        child: ReplayMask(child: Text('tile')),
      ),
    ));
    expect(find.byType(LDMask), findsOneWidget);
    expect(find.text('tile'), findsOneWidget);
  });

  testWidgets('ReplayRecorder toggles capture without losing app state',
      (tester) async {
    addTearDown(() => replayRecording.value = false);
    await tester.pumpWidget(const MaterialApp(
      home: ReplayRecorder(child: Scaffold(body: TextField())),
    ));
    await tester.enterText(find.byType(TextField), 'kept');
    expect(find.byType(SessionReplayCapture), findsNothing);

    replayRecording.value = true;
    await tester.pump();
    expect(find.byType(SessionReplayCapture), findsOneWidget);
    expect(find.text('kept'), findsOneWidget);

    replayRecording.value = false;
    await tester.pump();
    expect(find.byType(SessionReplayCapture), findsNothing);
    expect(find.text('kept'), findsOneWidget);
  });
}

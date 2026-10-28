import 'package:flutter_test/flutter_test.dart';
import 'package:weather_app/main.dart';

void main() {
  testWidgets('app starts and finishes its first load without LaunchDarkly',
      (tester) async {
    await tester.pumpWidget(const WeatherApp());
    // Network is unavailable in tests, so the load ends in the error view.
    await tester.pumpAndSettle();
    expect(find.text("Today's Weather"), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

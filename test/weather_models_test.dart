import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:weather_app/weather_models.dart';

// Trimmed real response from api.open-meteo.com/v1/forecast.
const _sample = '''
{"current_units":{"temperature_2m":"°C","wind_speed_10m":"km/h"},
 "current":{"time":"2026-09-27T17:30","temperature_2m":15.5,"apparent_temperature":12.8,
   "relative_humidity_2m":83,"weather_code":1,"wind_speed_10m":24.4,"is_day":1},
 "daily":{"time":["2026-09-27"],"weather_code":[3],"temperature_2m_max":[18.5],
   "temperature_2m_min":[12.7],"precipitation_probability_max":[7],
   "sunrise":["2026-09-27T07:01"],"sunset":["2026-09-27T18:58"]}}
''';

void main() {
  test('parses Open-Meteo forecast response', () {
    final w =
        TodayWeather.fromJson(jsonDecode(_sample) as Map<String, dynamic>);
    expect(w.temperature, 15.5);
    expect(w.humidity, 83);
    expect(w.high, 18.5);
    expect(w.low, 12.7);
    expect(w.precipitationChance, 7);
    expect(w.isDay, isTrue);
    expect(w.description, 'Mainly clear');
    expect(w.sunset, DateTime(2026, 9, 27, 18, 58));
    expect(w.tempUnit, '°C');
  });

  test('builds location display name', () {
    final loc = Location.fromJson({
      'name': 'London',
      'admin1': 'England',
      'country': 'United Kingdom',
      'latitude': 51.5,
      'longitude': -0.12,
    });
    expect(loc.displayName, 'London, England, United Kingdom');
  });
}

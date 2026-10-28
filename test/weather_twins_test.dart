import 'package:flutter/material.dart';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:weather_app/weather_models.dart';
import 'package:weather_app/weather_twins.dart';

const _melbourne = Location(
    name: 'Melbourne', country: 'Australia', latitude: -37.8, longitude: 145);

void main() {
  test('find posts the city and parses the twins', () async {
    late Map<String, dynamic> sent;
    final service = TwinsService(
      baseUrl: 'http://backend',
      client: MockClient((request) async {
        expect(request.url.toString(), 'http://backend/twins');
        sent = jsonDecode(request.body) as Map<String, dynamic>;
        return http.Response(
            jsonEncode({
              'summary': 'Cape Town is closest.',
              'twins': [
                {
                  'name': 'Cape Town',
                  'country': 'South Africa',
                  'latitude': -33.9,
                  'longitude': 18.4,
                  'similarity': 80,
                  'today_temperature_c': 14.5,
                  'reason': 'Similar latitude and rainfall.',
                }
              ],
              'model': 'claude-opus-5-5',
              'tool_calls': 12,
            }),
            200);
      }),
    );
    final result = await service.find(_melbourne);
    expect(sent['name'], 'Melbourne');
    expect(sent['latitude'], -37.8);
    // No LaunchDarkly context yet, so the backend's default is used.
    expect(sent.containsKey('context'), isFalse);
    expect(result.twins.single.name, 'Cape Town');
    expect(result.twins.single.similarity, 80);
  });

  test('a backend error surfaces its detail message', () async {
    final service = TwinsService(
      baseUrl: 'http://backend',
      client: MockClient((_) async =>
          http.Response(jsonEncode({'detail': 'Rate limited.'}), 429)),
    );
    expect(
      service.find(_melbourne),
      throwsA(isA<TwinsException>()
          .having((e) => e.message, 'message', 'Rate limited.')),
    );
  });

  test('serving returns the variation and model, or null on failure', () async {
    final ok = TwinsService(
      baseUrl: 'http://backend',
      client: MockClient((request) async {
        expect(request.url.path, '/twins/serving');
        return http.Response(
            jsonEncode({'variation': 'yoda', 'model': 'claude-sonnet-5-5'}),
            200);
      }),
    );
    expect(await ok.serving(), (variation: 'yoda', model: 'claude-sonnet-5-5'));

    final down = TwinsService(
      baseUrl: 'http://backend',
      client: MockClient((_) async => http.Response('', 500)),
    );
    expect(await down.serving(), isNull);
  });

  testWidgets('Marquee scrolls its text on repeat', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
          body: SizedBox(width: 200, child: Marquee('Serving variation yoda'))),
    ));
    double x() => tester.getTopLeft(find.text('Serving variation yoda')).dx;
    final start = x();
    await tester.pump(const Duration(seconds: 1));
    expect(x(), lessThan(start));
    // Still animating long after one pass (it repeats).
    await tester.pump(const Duration(seconds: 30));
    expect(tester.hasRunningAnimations, isTrue);
  });
}

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:weather_app/weather_service.dart';

void main() {
  test('findLocation goes through the traced request path', () async {
    final requests = <Uri>[];
    final service = WeatherService(
      client: MockClient((request) async {
        requests.add(request.url);
        return http.Response(
            jsonEncode({
              'results': [
                {
                  'name': 'Paris',
                  'country': 'France',
                  'latitude': 48.85,
                  'longitude': 2.35,
                }
              ]
            }),
            200);
      }),
    );
    final location = await service.findLocation('Paris');
    expect(location.latitude, 48.85);
    expect(requests.single.host, 'geocoding-api.open-meteo.com');
  });

  test('a failed request surfaces as a WeatherException', () async {
    final service = WeatherService(
      client: MockClient((_) async => http.Response('nope', 503)),
    );
    expect(
      service.findLocation('Paris'),
      throwsA(isA<WeatherException>()
          .having((e) => e.message, 'message', contains('503'))),
    );
  });
}

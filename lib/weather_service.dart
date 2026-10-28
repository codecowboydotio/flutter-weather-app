import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:launchdarkly_flutter_observability/launchdarkly_flutter_observability.dart';

import 'weather_models.dart';

/// Thin REST client for the free, key-less Open-Meteo APIs.
/// Docs: https://open-meteo.com/en/docs
class WeatherService {
  final http.Client _client;

  WeatherService({http.Client? client}) : _client = client ?? http.Client();

  /// Looks up a city name and returns the best match.
  Future<Location> findLocation(String query) =>
      LDObserve.withSpan('weather.geocode', (_) => _findLocation(query));

  Future<Location> _findLocation(String query) async {
    final uri = Uri.https('geocoding-api.open-meteo.com', '/v1/search', {
      'name': query,
      'count': '1',
      'language': 'en',
      'format': 'json',
    });

    final json = await _getJson(uri);
    final results = json['results'] as List?;
    if (results == null || results.isEmpty) {
      throw WeatherException('No location found for "$query".');
    }
    return Location.fromJson(results.first as Map<String, dynamic>);
  }

  /// Fetches current conditions and today's forecast for a location.
  Future<TodayWeather> fetchToday(Location location) =>
      LDObserve.withSpan('weather.forecast', (_) => _fetchToday(location));

  Future<TodayWeather> _fetchToday(Location location) async {
    final uri = Uri.https('api.open-meteo.com', '/v1/forecast', {
      'latitude': location.latitude.toString(),
      'longitude': location.longitude.toString(),
      'current': 'temperature_2m,apparent_temperature,relative_humidity_2m,'
          'weather_code,wind_speed_10m,is_day',
      'daily': 'weather_code,temperature_2m_max,temperature_2m_min,'
          'precipitation_probability_max,sunrise,sunset',
      'timezone': 'auto',
      'forecast_days': '1',
    });

    return TodayWeather.fromJson(await _getJson(uri));
  }

  /// GETs [uri] inside a client span. Flutter HTTP calls aren't seen by the
  /// native network instrumentation, so they're traced here. Only the host and
  /// path are recorded, not the query (which holds the searched city).
  Future<Map<String, dynamic>> _getJson(Uri uri) => LDObserve.withSpan(
        'HTTP GET',
        kind: SpanKind.client,
        properties: {
          'http.request.method': 'GET',
          'server.address': uri.host,
          'url.path': uri.path,
        },
        (span) => _get(uri, span),
      );

  Future<Map<String, dynamic>> _get(Uri uri, Span span) async {
    final http.Response response;
    try {
      response = await _client.get(uri).timeout(const Duration(seconds: 15));
    } catch (e) {
      // e.g. TimeoutException, ClientException (DNS or connection failure).
      span.setAttribute('error.type', e.runtimeType.toString());
      throw WeatherException('Network error: $e');
    }
    span.setAttribute('http.response.status_code', response.statusCode);
    span.setAttribute('http.response.body.size', response.contentLength);
    if (response.statusCode != 200) {
      span.setAttribute('error.type', '${response.statusCode}');
      throw WeatherException('Request failed (HTTP ${response.statusCode}).');
    }
    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  void dispose() => _client.close();
}

class WeatherException implements Exception {
  final String message;
  WeatherException(this.message);

  @override
  String toString() => message;
}

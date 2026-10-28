/// A place returned by the Open-Meteo geocoding API.
class Location {
  final String name;
  final String? region;
  final String? country;
  final double latitude;
  final double longitude;

  const Location({
    required this.name,
    required this.latitude,
    required this.longitude,
    this.region,
    this.country,
  });

  factory Location.fromJson(Map<String, dynamic> json) => Location(
        name: json['name'] as String,
        region: json['admin1'] as String?,
        country: json['country'] as String?,
        latitude: (json['latitude'] as num).toDouble(),
        longitude: (json['longitude'] as num).toDouble(),
      );

  String get displayName => [name, if (region != name) region, country]
      .whereType<String>()
      .where((s) => s.isNotEmpty)
      .join(', ');
}

/// Today's weather: current conditions plus the daily summary.
class TodayWeather {
  final DateTime observedAt;
  final double temperature;
  final double feelsLike;
  final int humidity;
  final double windSpeed;
  final int weatherCode;
  final bool isDay;

  final double high;
  final double low;
  final int? precipitationChance;
  final DateTime sunrise;
  final DateTime sunset;

  final String tempUnit;
  final String windUnit;

  const TodayWeather({
    required this.observedAt,
    required this.temperature,
    required this.feelsLike,
    required this.humidity,
    required this.windSpeed,
    required this.weatherCode,
    required this.isDay,
    required this.high,
    required this.low,
    required this.precipitationChance,
    required this.sunrise,
    required this.sunset,
    required this.tempUnit,
    required this.windUnit,
  });

  factory TodayWeather.fromJson(Map<String, dynamic> json) {
    final current = json['current'] as Map<String, dynamic>;
    final currentUnits = json['current_units'] as Map<String, dynamic>;
    final daily = json['daily'] as Map<String, dynamic>;

    T first<T>(String key) => (daily[key] as List).first as T;

    return TodayWeather(
      observedAt: DateTime.parse(current['time'] as String),
      temperature: (current['temperature_2m'] as num).toDouble(),
      feelsLike: (current['apparent_temperature'] as num).toDouble(),
      humidity: (current['relative_humidity_2m'] as num).toInt(),
      windSpeed: (current['wind_speed_10m'] as num).toDouble(),
      weatherCode: (current['weather_code'] as num).toInt(),
      isDay: current['is_day'] == 1,
      high: first<num>('temperature_2m_max').toDouble(),
      low: first<num>('temperature_2m_min').toDouble(),
      precipitationChance:
          first<num?>('precipitation_probability_max')?.toInt(),
      sunrise: DateTime.parse(first<String>('sunrise')),
      sunset: DateTime.parse(first<String>('sunset')),
      tempUnit: currentUnits['temperature_2m'] as String,
      windUnit: currentUnits['wind_speed_10m'] as String,
    );
  }

  String get description => describeWeatherCode(weatherCode);
}

/// Maps WMO weather interpretation codes (used by Open-Meteo) to text.
String describeWeatherCode(int code) {
  switch (code) {
    case 0:
      return 'Clear sky';
    case 1:
      return 'Mainly clear';
    case 2:
      return 'Partly cloudy';
    case 3:
      return 'Overcast';
    case 45:
    case 48:
      return 'Fog';
    case 51:
    case 53:
    case 55:
      return 'Drizzle';
    case 56:
    case 57:
      return 'Freezing drizzle';
    case 61:
    case 63:
    case 65:
      return 'Rain';
    case 66:
    case 67:
      return 'Freezing rain';
    case 71:
    case 73:
    case 75:
      return 'Snow';
    case 77:
      return 'Snow grains';
    case 80:
    case 81:
    case 82:
      return 'Rain showers';
    case 85:
    case 86:
      return 'Snow showers';
    case 95:
      return 'Thunderstorm';
    case 96:
    case 99:
      return 'Thunderstorm with hail';
    default:
      return 'Unknown';
  }
}

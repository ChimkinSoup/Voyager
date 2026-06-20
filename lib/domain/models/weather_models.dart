class WeatherSnapshot {
  const WeatherSnapshot({
    required this.icon,
    required this.conditionCode,
    required this.fetchedAt,
    required this.lat,
    required this.lon,
    this.tempC,
    this.locationLabel,
    this.updatedByDeviceId,
  });

  final String icon;
  final int conditionCode;
  final double? tempC;
  final DateTime fetchedAt;
  final String? locationLabel;
  final double lat;
  final double lon;
  final String? updatedByDeviceId;

  bool isNewerThan(WeatherSnapshot? other) {
    if (other == null) return true;
    return fetchedAt.isAfter(other.fetchedAt);
  }

  Map<String, dynamic> toJson() {
    return {
      'icon': icon,
      'conditionCode': conditionCode,
      'tempC': tempC,
      'fetchedAt': fetchedAt.toUtc().toIso8601String(),
      'locationLabel': locationLabel,
      'lat': lat,
      'lon': lon,
      'updatedByDeviceId': updatedByDeviceId,
    };
  }

  factory WeatherSnapshot.fromJson(Map<String, dynamic> json) {
    return WeatherSnapshot(
      icon: json['icon'] as String,
      conditionCode: (json['conditionCode'] as num).toInt(),
      tempC: (json['tempC'] as num?)?.toDouble(),
      fetchedAt: _parseDate(json['fetchedAt']),
      locationLabel: json['locationLabel'] as String?,
      lat: (json['lat'] as num).toDouble(),
      lon: (json['lon'] as num).toDouble(),
      updatedByDeviceId: json['updatedByDeviceId'] as String?,
    );
  }

  static DateTime _parseDate(dynamic value) {
    if (value is DateTime) return value.toUtc();
    if (value == null) {
      return DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
    }
    if (value is String) return DateTime.parse(value).toUtc();
    // Firestore Timestamp exposes toDate().
    try {
      final result = value.toDate();
      if (result is DateTime) return result.toUtc();
    } catch (_) {
      // Fall through to FormatException below.
    }
    throw FormatException('Unsupported date value: $value');
  }
}

DateTime parseWeatherDate(dynamic value) => WeatherSnapshot._parseDate(value);

class WeatherFetchLock {
  const WeatherFetchLock({
    required this.deviceId,
    required this.lockedAt,
    required this.expiresAt,
  });

  final String deviceId;
  final DateTime lockedAt;
  final DateTime expiresAt;

  Map<String, dynamic> toJson() => {
    'deviceId': deviceId,
    'lockedAt': lockedAt.toUtc().toIso8601String(),
    'expiresAt': expiresAt.toUtc().toIso8601String(),
  };

  factory WeatherFetchLock.fromJson(Map<String, dynamic> json) {
    return WeatherFetchLock(
      deviceId: json['deviceId'] as String,
      lockedAt: DateTime.parse(json['lockedAt'] as String).toUtc(),
      expiresAt: DateTime.parse(json['expiresAt'] as String).toUtc(),
    );
  }

  bool isValid(String requestingDeviceId, DateTime now) {
    if (now.isAfter(expiresAt)) return true;
    return deviceId == requestingDeviceId;
  }
}

class ForecastPeriod {
  const ForecastPeriod({
    required this.time,
    required this.tempC,
    required this.pop,
    required this.icon,
    required this.conditionCode,
    required this.description,
  });

  final DateTime time;
  final double tempC;
  final double pop;
  final String icon;
  final int conditionCode;
  final String description;

  int get rainChancePercent => (pop * 100).round().clamp(0, 100);

  Map<String, dynamic> toJson() => {
    'time': time.toUtc().toIso8601String(),
    'tempC': tempC,
    'pop': pop,
    'icon': icon,
    'conditionCode': conditionCode,
    'description': description,
  };

  factory ForecastPeriod.fromJson(Map<String, dynamic> json) {
    return ForecastPeriod(
      time: WeatherSnapshot._parseDate(json['time']),
      tempC: (json['tempC'] as num).toDouble(),
      pop: (json['pop'] as num).toDouble(),
      icon: json['icon'] as String,
      conditionCode: (json['conditionCode'] as num).toInt(),
      description: json['description'] as String? ?? '',
    );
  }
}

class DailyForecastSummary {
  const DailyForecastSummary({
    required this.date,
    required this.highC,
    required this.lowC,
    required this.maxPop,
    required this.icon,
  });

  final DateTime date;
  final double highC;
  final double lowC;
  final double maxPop;
  final String icon;

  int get maxRainChancePercent => (maxPop * 100).round().clamp(0, 100);
}

class WeatherForecast {
  const WeatherForecast({
    required this.fetchedAt,
    required this.periods,
    this.locationLabel,
  });

  final DateTime fetchedAt;
  final String? locationLabel;
  final List<ForecastPeriod> periods;

  List<DailyForecastSummary> get dailySummaries =>
      buildDailyForecastSummaries(periods);

  Map<String, dynamic> toJson() => {
    'fetchedAt': fetchedAt.toUtc().toIso8601String(),
    'locationLabel': locationLabel,
    'periods': periods.map((p) => p.toJson()).toList(),
  };

  factory WeatherForecast.fromJson(Map<String, dynamic> json) {
    final rawPeriods = json['periods'] as List<dynamic>? ?? const [];
    return WeatherForecast(
      fetchedAt: WeatherSnapshot._parseDate(json['fetchedAt']),
      locationLabel: json['locationLabel'] as String?,
      periods: rawPeriods
          .map((p) => ForecastPeriod.fromJson(Map<String, dynamic>.from(p as Map)))
          .toList(),
    );
  }
}

List<DailyForecastSummary> buildDailyForecastSummaries(
  List<ForecastPeriod> periods,
) {
  if (periods.isEmpty) return const [];

  final byDay = <DateTime, List<ForecastPeriod>>{};
  for (final period in periods) {
    final local = period.time.toLocal();
    final day = DateTime(local.year, local.month, local.day);
    byDay.putIfAbsent(day, () => []).add(period);
  }

  final days = byDay.keys.toList()..sort();
  return [
    for (final day in days)
      _summaryForDay(day, byDay[day]!),
  ];
}

DailyForecastSummary _summaryForDay(
  DateTime day,
  List<ForecastPeriod> dayPeriods,
) {
  var high = dayPeriods.first.tempC;
  var low = dayPeriods.first.tempC;
  var maxPop = dayPeriods.first.pop;
  var icon = dayPeriods.first.icon;

  for (final period in dayPeriods) {
    if (period.tempC > high) high = period.tempC;
    if (period.tempC < low) low = period.tempC;
    if (period.pop > maxPop) {
      maxPop = period.pop;
      icon = period.icon;
    }
  }

  return DailyForecastSummary(
    date: day,
    highC: high,
    lowC: low,
    maxPop: maxPop,
    icon: icon,
  );
}

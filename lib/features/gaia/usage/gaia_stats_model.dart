import 'package:intl/intl.dart';

/// One rare satellite's or aurora's sightings: how many, and when the first
/// was.
class GaiaSeen {
  const GaiaSeen({this.count = 0, this.first});

  factory GaiaSeen.fromJson(Map<Object?, Object?> json) => GaiaSeen(
    count: (json['count'] as num?)?.toInt() ?? 0,
    first: switch (json['first']) {
      final int ms => DateTime.fromMillisecondsSinceEpoch(ms),
      _ => null,
    },
  );

  final int count;
  final DateTime? first;

  Map<String, Object?> toJson() => {
    'count': count,
    if (first case final first?) 'first': first.millisecondsSinceEpoch,
  };
}

/// Gaia's lifetime stats, every desktop's (GAIA_STATS_HLD.md §4.2): the rare
/// satellites and auroras seen, by their enum names; meteors and comets
/// seen; chats started; and each local day a prompt was sent, as
/// `yyyy-MM-dd`.
class GaiaStats {
  const GaiaStats({
    this.satellites = const {},
    this.auroras = const {},
    this.meteors = 0,
    this.comets = 0,
    this.chats = 0,
    this.days = const {},
  });

  /// As the Firestore document has it, its first-seen dates in milliseconds.
  factory GaiaStats.fromJson(Map<Object?, Object?> json) {
    Map<String, GaiaSeen> seen(Object? map) => {
      if (map is Map)
        for (final MapEntry(:key, :value) in map.entries)
          if (value is Map) '$key': GaiaSeen.fromJson(value),
    };
    return GaiaStats(
      satellites: seen(json['satellites']),
      auroras: seen(json['auroras']),
      meteors: (json['meteors'] as num?)?.toInt() ?? 0,
      comets: (json['comets'] as num?)?.toInt() ?? 0,
      chats: (json['chats'] as num?)?.toInt() ?? 0,
      days: {
        if (json['days'] case final Map days)
          for (final day in days.keys) '$day',
      },
    );
  }

  final Map<String, GaiaSeen> satellites;
  final Map<String, GaiaSeen> auroras;
  final int meteors;
  final int comets;
  final int chats;
  final Set<String> days;

  Map<String, Object?> toJson() => {
    'satellites': {
      for (final MapEntry(:key, :value) in satellites.entries)
        key: value.toJson(),
    },
    'auroras': {
      for (final MapEntry(:key, :value) in auroras.entries) key: value.toJson(),
    },
    'meteors': meteors,
    'comets': comets,
    'chats': chats,
    'days': {for (final day in days) day: true},
  };
}

/// [time]'s local day, as [GaiaStats.days] keeps it.
String gaiaStatsDay(DateTime time) => DateFormat('yyyy-MM-dd').format(time);

import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/domain/models/settings_models.dart';
import 'package:voyager/domain/services/color_palette_codec.dart';
import 'package:voyager/features/settings/services/backup_collections.dart';
import 'package:voyager/features/settings/services/data_import_service.dart'
    show BackupRecordUploader;

/// The one payload key every colored record uses. Each collection that has a
/// color at all stores it at the top level under this name, which is what lets
/// the sweep below be written once rather than once per collection.
const _colorField = 'colorValue';

/// How many records use a color, per collection.
///
/// Collections that hold none are absent rather than present with a zero, as
/// in a restore's per-collection summary.
class ColorUsage {
  const ColorUsage(this.byCollection);

  final Map<String, int> byCollection;

  int get total => byCollection.values.fold(0, (sum, count) => sum + count);
}

/// Rewrites every record that uses one color to use another.
///
/// Rides the backup collections rather than the repositories: every colored
/// collection already has a reader and a writer there, both keyed on the
/// Firestore payload — so a collection that gains a color is swept without
/// this file being touched, and one that changes its repository method does
/// not silently drop out of the sweep.
class ColorReplacementService {
  ColorReplacementService({
    required AppDatabase db,
    required List<BackupCollection> collections,
    required BackupRecordUploader pushRecords,
  }) : _db = db,
       _collections = collections,
       _pushRecords = pushRecords;

  final AppDatabase _db;
  final List<BackupCollection> _collections;
  final BackupRecordUploader _pushRecords;

  /// What [replace] would rewrite if it ran now, so the confirmation can say
  /// how much of the database the user is about to change.
  Future<ColorUsage> countUsage(int color) async {
    final counts = <String, int>{};
    for (final collection in _collections) {
      final count = (await collection.read())
          .where((record) => _usesColor(record.data, color))
          .length;
      if (count > 0) counts[collection.name] = count;
    }
    return ColorUsage(counts);
  }

  /// Moves every record on [from] to [to], and returns what it rewrote.
  Future<ColorUsage> replace({required int from, required int to}) async {
    // Read before the transaction opens. The rewrite is a write transaction,
    // and reading every collection inside one would block every other write
    // in the app for the length of a full-database scan.
    final matches = <String, List<BackupRecord>>{};
    for (final collection in _collections) {
      final hits = [
        for (final record in await collection.read())
          if (_usesColor(record.data, from)) record,
      ];
      if (hits.isNotEmpty) matches[collection.name] = hits;
    }
    if (matches.isEmpty) return const ColorUsage({});

    // One transaction for the whole sweep, for the same reason a restore
    // takes one: a color half-replaced because the process died partway
    // through would be worse than one not replaced at all.
    final rewritten = <String, List<Object>>{};
    await _db.transaction(() async {
      for (final collection in _collections) {
        for (final record
            in matches[collection.name] ?? const <BackupRecord>[]) {
          (rewritten[collection.name] ??= []).add(
            await collection.restore(record.id, _withColor(record.data, to)),
          );
        }
      }
    });

    // Uploads run after the commit — they are network calls, and holding a
    // write transaction open across them would block every other write in the
    // app for the duration. They take the same route as any other write, so a
    // failed one lands on the outbox exactly as it would have otherwise.
    for (final entry in rewritten.entries) {
      await _pushRecords(entry.key, entry.value);
    }

    return ColorUsage({
      for (final entry in rewritten.entries) entry.key: entry.value.length,
    });
  }

  bool _usesColor(Map<String, dynamic> data, int color) {
    // Tombstones are left alone. A soft-deleted record's color is shown
    // nowhere, so sweeping it would inflate the count the confirmation asks
    // about with rows the user cannot see.
    if (data['deletedAt'] != null) return false;
    final value = (data[_colorField] as num?)?.toInt();
    return value != null &&
        normalizeColorValue(value) == normalizeColorValue(color);
  }

  /// [data] on [color], at a version one past the stored one.
  ///
  /// The bump is what makes the rewrite stick: the local row is at least as
  /// high as whatever this device last synced, so one past it also beats the
  /// copy sitting in Firestore. Without it the next pull would see an equal
  /// remote version and put the old color back.
  ///
  /// Collections with no `version` field are append-only and never merged, so
  /// they are left alone rather than given a field they don't use.
  Map<String, dynamic> _withColor(Map<String, dynamic> data, int color) {
    final recolored = {...data, _colorField: normalizeColorValue(color)};
    if (!data.containsKey('version')) return recolored;
    final version = (data['version'] as num?)?.toInt() ?? 0;
    return {...recolored, 'version': version + 1};
  }
}

/// The settings that hold [color], named as the settings screen names them.
///
/// The palette entry itself is deliberately absent: it is the thing being
/// replaced rather than an occurrence of it, and listing it would read as
/// though the palette were one more place the color had leaked into.
List<String> settingsColorsUsing(AppSettings settings, int color) {
  final target = normalizeColorValue(color);
  bool uses(int? value) =>
      value != null && normalizeColorValue(value) == target;
  return [
    if (uses(settings.accentColor)) 'the app accent color',
    if (uses(settings.petalColor)) 'the petal color',
    if (settings.minorPetalColors.any(uses)) 'a minor petal color',
    if (uses(settings.weatherChartTempColor)) 'the weather temperature line',
    if (uses(settings.weatherChartRainColor)) 'the weather rain line',
  ];
}

/// [settings] with every use of [from] — the palette entry included — moved
/// to [to].
///
/// [to] takes [from]'s place in the palette rather than being appended, so a
/// replacement doesn't reshuffle every picker in the app. When [to] is already
/// in the palette the two entries merge into whichever slot comes first.
AppSettings replaceSettingsColor(
  AppSettings settings, {
  required int from,
  required int to,
}) {
  final source = normalizeColorValue(from);
  final target = normalizeColorValue(to);
  int swap(int value) => normalizeColorValue(value) == source ? target : value;

  final palette = <int>[];
  for (final color in settings.colorPalette) {
    final next = normalizeColorValue(swap(color));
    if (!palette.contains(next)) palette.add(next);
  }

  return settings.copyWith(
    colorPalette: palette,
    accentColor: swap(settings.accentColor),
    petalColor: swap(settings.petalColor),
    // Left at the same length and order: the slots are weighted by position
    // (see `petalColorWeights`), so merging two of them here would silently
    // rebalance every other minor color.
    minorPetalColors: [for (final c in settings.minorPetalColors) swap(c)],
    weatherChartTempColor: settings.weatherChartTempColor == null
        ? null
        : swap(settings.weatherChartTempColor!),
    weatherChartRainColor: settings.weatherChartRainColor == null
        ? null
        : swap(settings.weatherChartRainColor!),
  );
}

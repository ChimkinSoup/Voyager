import 'dart:math' as math;
import 'dart:ui' show Brightness;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/domain/models/enums.dart';
import 'package:voyager/core/sync/firestore_document_mapper.dart';
import 'package:voyager/core/tags/tag_palette.dart';
import 'package:voyager/core/utils/journal_tags.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/data/repositories/drift_repositories.dart';
import 'package:voyager/domain/models/settings_models.dart';

void main() {
  late AppDatabase db;
  late DriftSettingsRepository repo;

  setUp(() {
    db = AppDatabase.inMemory();
    repo = DriftSettingsRepository(db);
  });

  tearDown(() async {
    await db.close();
  });

  group('colorForTag', () {
    test('only ever returns a palette color', () {
      for (final tag in [
        'food',
        'thai',
        'dining_out',
        'Depth-First-Search',
        '',
        'a' * 200,
      ]) {
        expect(kTagPaletteDark, contains(colorForTag(tag)));
      }
    });

    test('is stable for the same tag and spread across the palette', () {
      expect(colorForTag('food'), colorForTag('food'));

      final seen = {
        for (var i = 0; i < 200; i++) colorForTag('tag$i'),
      };
      // Not a uniformity claim — just that the index is actually varying
      // rather than collapsing every tag onto one swatch.
      expect(seen.length, greaterThan(kTagPaletteDark.length ~/ 2));
    });
  });

  group('resolveTagColor', () {
    test('swaps a dark accent for its light twin, and only that', () {
      for (var i = 0; i < kTagPaletteDark.length; i++) {
        expect(
          resolveTagColor(kTagPaletteDark[i], Brightness.light),
          kTagPaletteLight[i],
        );
        expect(
          resolveTagColor(kTagPaletteDark[i], Brightness.dark),
          kTagPaletteDark[i],
        );
      }
    });

    test('leaves a color that is not on the palette alone', () {
      // A row a pre-palette build wrote, which the reconcile has not reached
      // yet. Guessing an index for it would be worse than showing it as-is.
      expect(resolveTagColor(0xFF3A1C77, Brightness.light), 0xFF3A1C77);
    });

    test('every accent carries small text on the surface it is for', () {
      // Tag text is labelSmall on a card, so both halves are held to WCAG AA
      // for normal text against the card they are painted on.
      for (var i = 0; i < kTagPaletteLight.length; i++) {
        expect(
          _contrast(kTagPaletteLight[i], _kLightCard),
          greaterThanOrEqualTo(4.5),
          reason: 'light accent $i',
        );
        expect(
          _contrast(kTagPaletteDark[i], _kDarkCard),
          greaterThanOrEqualTo(4.5),
          reason: 'dark accent $i',
        );
      }
    });

    test('the dark palette is what the light one exists to avoid', () {
      // Why the swap is worth its plumbing: painted straight onto the light
      // card, the dark accents are nowhere near legible.
      expect(_contrast(kTagPaletteDark.first, _kLightCard), lessThan(1.5));
    });
  });

  group('tagColorsProvider', () {
    test('hands out the palette the current theme can actually show',
        () async {
      await repo.upsertTagColor(
        TagColorRecord(
          tag: 'food',
          colorValue: colorForTag('food'),
          updatedAt: DateTime.utc(2026, 1, 1),
        ),
      );

      final container = ProviderContainer(
        overrides: [databaseProvider.overrideWithValue(db)],
      );
      addTearDown(container.dispose);

      expect(
        (await container.read(tagColorsProvider.future))['food'],
        colorForTag('food'),
        reason: 'the default theme is dark, and storage is the dark palette',
      );

      final settings = await container.read(settingsProvider.future);
      await container
          .read(settingsProvider.notifier)
          .saveSettings(settings.copyWith(themeMode: AppThemeMode.light));

      expect(
        (await container.read(tagColorsProvider.future))['food'],
        resolveTagColor(colorForTag('food'), Brightness.light),
        reason: 'the swap happens here, not at every call site that paints',
      );
    });
  });

  group('reconcileTagPalette', () {
    test('rewrites off-palette colors and leaves the rest alone', () async {
      // The old hash-RGB mash, which is what a pre-palette install stored.
      await repo.upsertTagColor(
        TagColorRecord(
          tag: 'food',
          colorValue: 0xFF3A1C77,
          updatedAt: DateTime.utc(2026, 1, 1),
          version: 4,
        ),
      );
      await repo.upsertTagColor(
        TagColorRecord(
          tag: 'thai',
          colorValue: colorForTag('thai'),
          updatedAt: DateTime.utc(2026, 1, 1),
          version: 2,
        ),
      );

      expect(await reconcileTagPalette(repo), 1);

      final colors = await repo.getTagColors();
      expect(colors['food'], colorForTag('food'));
      expect(colors['thai'], colorForTag('thai'));
    });

    test('outranks the stale remote row rather than staying local', () async {
      final stamp = DateTime.utc(2026, 1, 1);
      final stored = TagColorRecord(
        tag: 'food',
        colorValue: 0xFF3A1C77,
        updatedAt: stamp,
        version: 4,
      );
      await repo.upsertTagColor(stored);

      await reconcileTagPalette(repo);

      final record = await repo.getTagColorRecord('food');
      expect(record!.version, 5);
      expect(record.updatedAt.isAfter(stamp), isTrue);

      // The point of the bump. Firestore still holds the pre-palette row, and
      // a tie on version *and* updatedAt is broken in the remote's favour —
      // so without this the very next pull writes the old color back, and the
      // reconcile spends every launch undoing a sync that undoes it again.
      final merged = mergeTagColorFromRemote(
        tagColorToFirestore(stored),
        'food',
        local: record,
      );
      expect(merged.colorValue, colorForTag('food'));
    });

    test('is its own idempotence check — a second pass writes nothing',
        () async {
      await repo.upsertTagColor(
        TagColorRecord(
          tag: 'food',
          colorValue: 0xFF3A1C77,
          updatedAt: DateTime.utc(2026, 1, 1),
        ),
      );

      expect(await reconcileTagPalette(repo), 1);
      expect(await reconcileTagPalette(repo), 0);
    });
  });
}

/// The theme's card colors, which is where a `#tag` label is actually painted.
const _kLightCard = 0xFFFDFBF6;
const _kDarkCard = 0xFF2A2A33;

/// WCAG contrast ratio between two opaque ARGB colors.
double _contrast(int a, int b) {
  double luminance(int argb) {
    double channel(int v) {
      final c = v / 255;
      return c <= 0.03928
          ? c / 12.92
          : math.pow((c + 0.055) / 1.055, 2.4) as double;
    }

    return 0.2126 * channel((argb >> 16) & 0xFF) +
        0.7152 * channel((argb >> 8) & 0xFF) +
        0.0722 * channel(argb & 0xFF);
  }

  final x = luminance(a);
  final y = luminance(b);
  return (math.max(x, y) + 0.05) / (math.min(x, y) + 0.05);
}

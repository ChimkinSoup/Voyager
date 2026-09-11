// An integer tracker's field has to sit on the same midline as the urgency
// badge after it.
//
// The field is given a fixed 32px slot, but on desktop's compact visual density
// it only draws a 24px border — and a single-line InputDecorator handed more
// height than it asked for pins that border to the *top* of the slot. Every
// integer row in the inbox's "Log stats" drawer hung its box 4px above the
// badge, while the dropdown and switch rows beside it sat true.
//
// Invisible under the default test platform (android → standard density,
// where the field fills the slot), so this pins windows.

import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/theme/voyager_theme.dart';
import 'package:voyager/core/widgets/notification_urgency_dot.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/domain/models/analytics_models.dart';
import 'package:voyager/domain/models/enums.dart';
import 'package:voyager/features/analytics/tracker_entry_row.dart';

void main() {
  testWidgets('integer fields centre on the badge at desktop density', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    final db = AppDatabase(NativeDatabase.memory());
    final container = ProviderContainer(
      overrides: [databaseProvider.overrideWithValue(db)],
    );
    final t0 = DateTime.utc(2026, 8, 1);
    final trackers = [
      StatisticTracker(
        id: 'plain',
        name: 'Beans',
        type: TrackerType.integer,
        cadence: TrackerCadence.daily,
        createdAt: t0,
        updatedAt: t0,
      ),
      // The range line under a capped field is mirrored above it, so the
      // field's slot is still the column's midline.
      StatisticTracker(
        id: 'capped',
        name: 'Energy',
        type: TrackerType.integer,
        cadence: TrackerCadence.daily,
        integerCap: 10,
        createdAt: t0,
        updatedAt: t0,
      ),
    ];
    for (final t in trackers) {
      await container.read(trackerRepositoryProvider).upsertTracker(t);
    }
    await container.read(settingsProvider.future);

    // Today, with nothing logged, so every row carries its badge.
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: VoyagerTheme.light(),
          home: Scaffold(
            body: SizedBox(
              width: 360,
              child: Column(
                children: [
                  for (final t in trackers)
                    TrackerEntryRow(tracker: t, date: today),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 80));
    }

    final rows = find.byType(TrackerEntryRow);
    for (var i = 0; i < trackers.length; i++) {
      final row = rows.at(i);
      final border = find.descendant(
        of: row,
        matching: find.byWidgetPredicate(
          (w) =>
              w is CustomPaint &&
              w.foregroundPainter.runtimeType.toString() ==
                  '_InputBorderPainter',
        ),
      );
      final badge = find.descendant(
        of: row,
        matching: find.byType(NotificationUrgencyDot),
      );
      final box = tester.getRect(border);
      expect(
        box.height,
        lessThan(32),
        reason: 'compact density really does draw a short field here',
      );
      expect(
        box.center.dy,
        moreOrLessEquals(tester.getCenter(badge).dy, epsilon: 0.5),
        reason: '${trackers[i].id}: field box is centred on its badge',
      );
    }

    await tester.pumpWidget(const SizedBox());
    container.dispose();
    await db.close();
    debugDefaultTargetPlatformOverride = null;
  });
}

// Regressions for the Life Tracker defects catalogued in AUDIT.md.
//
// Each test asserts the behaviour that was wrong rather than the shape of the
// fix: bucket-list edits advance the version they are resolved on, a write
// made across a modal applies to the row that is actually on disk, and a stat
// that hasn't been read yet doesn't render as a real figure.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/sync/firestore_document_mapper.dart';
import 'package:voyager/core/utils/ids.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/data/repositories/drift_repositories.dart';
import 'package:voyager/domain/models/life_tracker_models.dart';
import 'package:voyager/features/life_tracker/bucket_list_popup.dart';
import 'package:voyager/features/life_tracker/life_tracker_stats.dart';
import 'package:voyager/features/life_tracker/life_tree_canvas.dart';
import 'package:voyager/features/life_tracker/life_tree_geometry.dart';
import 'package:voyager/features/life_tracker/life_tree_popover.dart';

BucketListItem _item({
  required String id,
  String title = 'Skydive',
  int sortOrder = 0,
  int version = 0,
}) {
  final now = DateTime.utc(2026, 8, 1, 12);
  return BucketListItem(
    id: id,
    title: title,
    sortOrder: sortOrder,
    createdAt: now,
    updatedAt: now,
    version: version,
  );
}

Future<void> _pumpPopup(WidgetTester tester, AppDatabase db) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [databaseProvider.overrideWithValue(db)],
      child: const MaterialApp(
        home: Scaffold(body: BucketListPopup(accentColor: Colors.pink)),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  group('bucket list writes', () {
    late AppDatabase db;
    late DriftBucketListRepository repo;

    setUp(() {
      db = AppDatabase.inMemory();
      repo = DriftBucketListRepository(db);
    });

    tearDown(() => db.close());

    test('every edit advances the version', () {
      final item = _item(id: newId());
      expect(item.copyWith(title: 'Skydive twice').version, 1);
      expect(item.copyWith(completed: true).version, 1);
      // Only an explicit version overrides it — deleteItem's own bump.
      expect(item.copyWith(version: 9).version, 9);
      expect(item.copyWith(title: 'x', bumpVersion: false).version, 0);
    });

    test('a delete and the rename it raced converge on every device', () {
      final base = _item(id: 'x');
      final deletedAt = DateTime.utc(2026, 8, 2, 9);
      // A deletes. B, offline and still holding the original, renames it.
      final deleted = base.copyWith(
        updatedAt: deletedAt,
        version: base.version + 1,
        deletedAt: deletedAt,
      );
      final renamed = base.copyWith(
        title: 'Renamed offline',
        updatedAt: DateTime.utc(2026, 8, 2, 10),
      );

      // B's outbox writes its whole document, so both revisions exist. Every
      // device has to land on the same row whichever order it sees them in —
      // which it only does while the rename carries a version of its own. Left
      // frozen at the version it was created at, it loses on A (stale version)
      // and wins on a device that never saw the delete, and the two never
      // reconcile.
      final onA = mergeBucketListItemFromRemote(
        bucketListItemToFirestore(renamed),
        'x',
        local: deleted,
      );
      final onB = mergeBucketListItemFromRemote(
        bucketListItemToFirestore(deleted),
        'x',
        local: renamed,
      );
      expect(onA.title, onB.title);
      expect(onA.deletedAt, onB.deletedAt);
    });

    test('items added in the same millisecond keep a stable order', () async {
      final stamp = DateTime.utc(2026, 8, 1, 12).millisecondsSinceEpoch;
      await repo.upsertItem(_item(id: 'b', title: 'B', sortOrder: stamp));
      await repo.upsertItem(_item(id: 'a', title: 'A', sortOrder: stamp));
      expect(
        (await repo.listItems()).map((i) => i.id),
        (await repo.listItems()).map((i) => i.id),
      );
      expect((await repo.listItems()).map((i) => i.id), ['a', 'b']);
    });

    testWidgets('completing an item does not resurrect a tombstone', (
      tester,
    ) async {
      final item = _item(id: newId());
      await repo.upsertItem(item);
      await _pumpPopup(tester, db);

      await tester.tap(find.byType(AnimatedContainer).first);
      await tester.pumpAndSettle();
      expect(find.text('Add a note?'), findsOneWidget);

      // What a background pull does while the note dialog is up.
      await repo.deleteItem(item.id);

      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      final after = await repo.getItem(item.id);
      expect(after!.deletedAt, isNotNull);
      expect(after.completed, isFalse);
    });

    testWidgets('completing an item does not revert a rename it raced', (
      tester,
    ) async {
      final item = _item(id: newId());
      await repo.upsertItem(item);
      await _pumpPopup(tester, db);

      await tester.tap(find.byType(AnimatedContainer).first);
      await tester.pumpAndSettle();

      await repo.upsertItem(
        (await repo.getItem(
          item.id,
        ))!.copyWith(title: 'Renamed elsewhere', updatedAt: utcNow()),
      );

      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      final after = await repo.getItem(item.id);
      expect(after!.title, 'Renamed elsewhere');
      expect(after.completed, isTrue);
    });

    testWidgets('renaming a second row commits the first rename', (
      tester,
    ) async {
      await repo.upsertItem(_item(id: 'a', title: 'Alpha', sortOrder: 1));
      await repo.upsertItem(_item(id: 'b', title: 'Beta', sortOrder: 2));
      await _pumpPopup(tester, db);

      await tester.tap(find.text('Alpha'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).first, 'Alpha edited');
      await tester.pump();

      // The editor is shared by every row, so opening it on another one used
      // to overwrite this text before anything had saved it.
      await tester.tap(find.text('Beta'));
      await tester.pumpAndSettle();

      expect((await repo.getItem('a'))!.title, 'Alpha edited');
    });

    testWidgets('a second Enter does not add the item twice', (tester) async {
      await _pumpPopup(tester, db);

      await tester.enterText(find.byType(TextField).last, 'Learn to sail');
      // Two Enters inside the write's own window. Submitting through the test
      // input twice is not the same thing: it settles between the two, and
      // the window is exactly the stretch where the field still holds the
      // text because the SQLite write hasn't come back yet.
      final field = tester.widget<TextField>(find.byType(TextField).last);
      field.onSubmitted!('Learn to sail');
      field.onSubmitted!('Learn to sail');
      await tester.pumpAndSettle();

      expect((await repo.listItems()).length, 1);
    });
  });

  testWidgets('a popup wider than the window still fits inside it', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(411, 700);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () => showTreePopover(
                context: context,
                anchorGlobalCenter: const Offset(200, 300),
                width: 480,
                height: 460,
                builder: (_) => const SizedBox.expand(),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    final popup = tester.getRect(find.byType(SizedBox.expand().runtimeType));
    expect(popup.width, lessThanOrEqualTo(411));
    expect(popup.right, lessThanOrEqualTo(411));
  });

  group('stat values', () {
    LifeStatValue resolve(
      LifeStat stat, {
      int? tasksConquered,
      double? lifetimeMood,
      bool moodKnown = true,
      DateTime? birthDate,
      DateTime? now,
    }) {
      return resolveLifeStat(
        stat: stat,
        birthDate: birthDate ?? DateTime(1998, 5, 20),
        now: now ?? DateTime(2026, 8, 25),
        tasksConquered: tasksConquered,
        lifetimeMood: lifetimeMood,
        moodKnown: moodKnown,
      );
    }

    test(
      'a stat still being read shows neither a count nor an empty state',
      () {
        expect(resolve(LifeStat.tasksConquered).value, isNot(contains('0')));
        expect(
          resolve(LifeStat.lifetimeMood, moodKnown: false).value,
          isNot(contains('No journal moods')),
        );
        // ...and says so once it has been read.
        expect(resolve(LifeStat.tasksConquered, tasksConquered: 0).value, '0');
        expect(
          resolve(LifeStat.lifetimeMood).value,
          contains('No journal moods'),
        );
      },
    );

    test('a birth date in the future never goes negative', () {
      final future = DateTime(2027, 1, 1);
      expect(
        resolve(
          LifeStat.heartbeats,
          now: DateTime(2026, 8, 25),
          birthDate: future,
        ).value,
        isNot(contains('-')),
      );
      expect(
        resolve(
          LifeStat.kmTraveled,
          now: DateTime(2026, 8, 25),
          birthDate: future,
        ).value,
        isNot(contains('-')),
      );
    });
  });

  // Never pumpAndSettle a page holding this: the canopy's ticker never stops.
  testWidgets('an idle canopy repaints without rebuilding', (tester) async {
    final controller = LifeTreeCanvasController();
    addTearDown(controller.dispose);
    final geometry = generateLifeTreeGeometry();

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: LifeTreeCanvas(
            geometry: geometry,
            leafColors: const [Color(0xFFF3C5CE)],
            inkColor: const Color(0xFF241F1B),
            paperColor: const Color(0xFFF3F1EA),
            grassColor: const Color(0xFF8C9A79),
            groundedLeafIndices: const <int>{},
            controller: controller,
            accentColor: const Color(0xFF7C9EFF),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 16));

    final canvas = find.descendant(
      of: find.byType(LifeTreeCanvas),
      matching: find.byType(CustomPaint),
    );
    final before = tester.widget<CustomPaint>(canvas.last).painter;
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    // A new painter instance means the whole subtree was rebuilt to deliver a
    // value only the painter reads — which is what the frame timer used to do
    // sixty times a second.
    expect(
      identical(tester.widget<CustomPaint>(canvas.last).painter, before),
      isTrue,
    );
  });

  test('the leaves are ordered by angle once, not on every read', () {
    final geometry = generateLifeTreeGeometry();
    final first = geometry.leafIndicesByAngle;
    expect(identical(geometry.leafIndicesByAngle, first), isTrue);
    expect(first.length, geometry.leaves.length);
    expect(first.toSet().length, geometry.leaves.length);
  });
}

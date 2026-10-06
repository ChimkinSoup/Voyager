// The journal and dream lists' date row carries a right-aligned image icon
// for an entry with images attached, as the todo row's metadata line does
// (see todo_row_image_icon_test.dart).

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/sync/firestore_collections.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/data/remote/in_memory_sync.dart';
import 'package:voyager/data/repositories/drift_repositories.dart';
import 'package:voyager/domain/models/dream_models.dart';
import 'package:voyager/domain/models/journal_models.dart';
import 'package:voyager/features/dream_journal/dream_journal_page.dart';
import 'package:voyager/features/journal/journal_page.dart';

import 'fakes/fake_weather_api_client.dart';
import 'support/journal_page_harness.dart';

/// Stands in for the reference query, so these tests need no media stack.
Override withImagesOn(String collection, Set<String> ids) {
  return mediaOwnersWithImagesProvider(
    collection,
  ).overrideWith((ref) async => ids);
}

Finder imageIcon() => find.byIcon(PhosphorIconsRegular.image);

/// Asserts the icon sits on [title]'s row, right of its date label.
void expectIconOnRowOf(WidgetTester tester, String title) {
  final icon = tester.getRect(imageIcon());
  final row = tester.getRect(
    find.ancestor(of: find.text(title), matching: find.byType(ListTile)),
  );
  expect(row.contains(icon.center), isTrue, reason: 'icon is on $title');
  final date = tester.getRect(
    find
        .descendant(
          of: find.ancestor(of: imageIcon(), matching: find.byType(Row)).first,
          matching: find.byType(Text),
        )
        .first,
  );
  expect(icon.left, greaterThanOrEqualTo(date.right));
  expect((icon.center.dy - date.center.dy).abs(), lessThan(4));
}

Future<void> pumpDreamPage(WidgetTester tester, Set<String> withImages) async {
  tester.view.physicalSize = const Size(1400, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);

  final db = AppDatabase.inMemory();
  addTearDown(db.close);
  final now = DateTime.now().toUtc();
  for (final (i, id) in ['dream-a', 'dream-b'].indexed) {
    await DriftDreamRepository(db).upsertEntry(
      DreamEntry(
        id: id,
        title: 'Dream $i',
        body: '',
        entryDate: now.subtract(Duration(hours: i)),
        createdAt: now,
        updatedAt: now,
      ),
    );
  }

  final container = ProviderContainer(
    overrides: [
      databaseProvider.overrideWithValue(db),
      syncRepositoryProvider.overrideWithValue(InMemorySyncRepository()),
      weatherApiClientProvider.overrideWithValue(FakeWeatherApiClient()),
      withImagesOn(FirestoreCollections.dreamEntries, withImages),
    ],
  );
  addTearDown(container.dispose);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: Scaffold(body: DreamJournalPage())),
    ),
  );
  for (var i = 0; i < 12; i++) {
    await tester.pump(const Duration(milliseconds: 60));
  }
}

void main() {
  setUpAll(() => driftRuntimeOptions.dontWarnAboutMultipleDatabases = true);

  group('journal list', () {
    List<JournalEntry> twoEntries(DateTime now) => [
      for (final (i, id) in ['entry-a', 'entry-b'].indexed)
        JournalEntry(
          id: id,
          journalId: journalHarnessId,
          title: 'Entry $i',
          body: '',
          entryDate: now.subtract(Duration(hours: i)),
          timestamp: now,
          createdAt: now,
          updatedAt: now,
        ),
    ];

    testWidgets('no icon when nothing has an image', (tester) async {
      await pumpJournalPage(
        tester,
        seedEntries: twoEntries,
        extraOverrides: (_) => [
          withImagesOn(FirestoreCollections.journalEntries, const {}),
        ],
      );
      expect(imageIcon(), findsNothing);
      await disposeJournalPage(tester);
    });

    testWidgets('icon on the date row of the entry that has one', (
      tester,
    ) async {
      await pumpJournalPage(
        tester,
        seedEntries: twoEntries,
        extraOverrides: (_) => [
          withImagesOn(FirestoreCollections.journalEntries, {'entry-b'}),
        ],
      );
      expect(imageIcon(), findsOneWidget);
      expectIconOnRowOf(tester, 'Entry 1');
      await disposeJournalPage(tester);
    });

    // The row widget is cached by a signature, so an image attached to an
    // entry already on screen only shows if that signature notices.
    testWidgets('icon appears when an image is attached to a shown entry', (
      tester,
    ) async {
      final withImages = StateProvider<Set<String>>((ref) => const {});
      await pumpJournalPage(
        tester,
        seedEntries: twoEntries,
        extraOverrides: (_) => [
          mediaOwnersWithImagesProvider(
            FirestoreCollections.journalEntries,
          ).overrideWith((ref) async => ref.watch(withImages)),
        ],
      );
      expect(imageIcon(), findsNothing);

      ProviderScope.containerOf(
        tester.element(find.byType(JournalPage)),
      ).read(withImages.notifier).state = {
        'entry-b',
      };
      for (var i = 0; i < 4; i++) {
        await tester.pump(const Duration(milliseconds: 60));
      }

      expect(imageIcon(), findsOneWidget);
      expectIconOnRowOf(tester, 'Entry 1');
      await disposeJournalPage(tester);
    });
  });

  group('dream list', () {
    testWidgets('no icon when nothing has an image', (tester) async {
      await pumpDreamPage(tester, const {});
      expect(imageIcon(), findsNothing);
    });

    testWidgets('icon on the date row of the dream that has one', (
      tester,
    ) async {
      await pumpDreamPage(tester, {'dream-b'});
      expect(imageIcon(), findsOneWidget);
      expectIconOnRowOf(tester, 'Dream 1');
    });
  });
}

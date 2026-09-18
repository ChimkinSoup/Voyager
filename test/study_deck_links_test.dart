// Deck links end to end against a real database (STUDY_DECK_LINKS_HLD.md):
// the hub's stats and sessions draw on linked decks, the placeholder's toggle
// and menu act on the link row, Fork copies with fresh progress, and a card
// reached through a link says which deck it lives in — only then.

import 'dart:io';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/soft_delete/soft_delete_toast.dart';
import 'package:voyager/core/sync/firestore_collections.dart';
import 'package:voyager/core/sync/firestore_document_mapper.dart';
import 'package:voyager/core/widgets/glass_button.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/data/remote/in_memory_sync.dart';
import 'package:voyager/data/repositories/drift_repositories.dart';
import 'package:voyager/domain/models/study_models.dart';
import 'package:voyager/features/settings/services/backup_collections.dart';
import 'package:voyager/features/settings/services/data_export_service.dart';
import 'package:voyager/features/settings/services/data_import_service.dart';
import 'package:voyager/features/study/study_card_face.dart';
import 'package:voyager/features/study/study_deck_link_actions.dart';
import 'package:voyager/features/study/study_deck_workbench_page.dart';
import 'package:voyager/features/study/study_linked_deck.dart';
import 'package:voyager/features/study/study_session_page.dart';

import 'fakes/fake_weather_api_client.dart';

const _hub = 'hub';
const _aws = 'aws';

/// A hub with one card of its own and a linked AWS deck with one card, both
/// due. The AWS card has real review history, so a fork can be seen not to
/// carry it.
Future<AppDatabase> _seed({bool linked = true}) async {
  final db = AppDatabase.inMemory();
  addTearDown(db.close);
  final repo = DriftStudyRepository(db);
  final now = DateTime.now().toUtc();
  final due = now.subtract(const Duration(days: 1));
  for (final (id, name) in [(_hub, 'System Design'), (_aws, 'AWS')]) {
    await repo.upsertDeck(
      StudyDeck(id: id, name: name, createdAt: now, updatedAt: now),
    );
  }
  await repo.upsertCard(
    StudyCard(
      id: 'hub-card',
      deckId: _hub,
      frontText: 'Hub question',
      backText: 'Hub answer',
      dueAt: due,
      createdAt: now,
      updatedAt: now,
    ),
  );
  await repo.upsertCard(
    StudyCard(
      id: 'aws-card',
      deckId: _aws,
      frontText: 'AWS question',
      backText: 'AWS answer',
      interval: 12,
      ease: 2.2,
      reviewCount: 4,
      dueAt: due,
      createdAt: now,
      updatedAt: now,
    ),
  );
  if (linked) {
    await repo.upsertDeckLink(
      StudyDeckLink(
        id: StudyDeckLink.idFor(_hub, _aws),
        parentDeckId: _hub,
        childDeckId: _aws,
        createdAt: now,
        updatedAt: now,
      ),
    );
  }
  return db;
}

ProviderContainer _container(AppDatabase db) {
  final container = ProviderContainer(
    overrides: [
      databaseProvider.overrideWithValue(db),
      syncRepositoryProvider.overrideWithValue(InMemorySyncRepository()),
      weatherApiClientProvider.overrideWithValue(FakeWeatherApiClient()),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

Future<void> _pump(
  WidgetTester tester,
  ProviderContainer container,
  Widget page,
) async {
  tester.view.physicalSize = const Size(1400, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(home: Scaffold(body: page)),
    ),
  );
  await _settle(tester);
}

/// Nothing here settles: flip cards keep tickers alive.
Future<void> _settle(WidgetTester tester, [int frames = 12]) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 60));
  }
}

Widget _workbench() => StudyDeckWorkbenchPage(
  deckId: _hub,
  folderStack: const [],
  onBack: () {},
  onJumpToRoot: () {},
  onJumpToFolder: (_) {},
  onOpenDeck: (_) {},
);

/// A [WidgetRef] for calling the link actions outside any page. Its context
/// sits under a [MaterialApp], so an action that raises a toast has an
/// overlay to raise it in.
Future<WidgetRef> _ref(WidgetTester tester, ProviderContainer container) async {
  late WidgetRef captured;
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        home: Consumer(
          builder: (context, ref, _) {
            captured = ref;
            return const SizedBox();
          },
        ),
      ),
    ),
  );
  return captured;
}

/// Lets a toast run out its dwell, so no timer outlives the test.
Future<void> _outlastToast(WidgetTester tester) async {
  await tester.pump(kSoftDeleteUndoDwell + const Duration(seconds: 1));
  await _settle(tester);
}

Future<void> _pressUndo(WidgetTester tester) async {
  await tester.tap(find.text('Undo'));
  await _settle(tester);
}

List<BackupCollection> _collectionsFor(AppDatabase db) =>
    buildBackupCollections(
      journalRepository: DriftJournalRepository(db),
      dreamRepository: DriftDreamRepository(db),
      todoRepository: DriftTodoRepository(db),
      leetCodeRepository: DriftLeetCodeRepository(db),
      studyRepository: DriftStudyRepository(db),
      workoutRepository: DriftWorkoutRepository(db),
      jobRepository: DriftJobRepository(db),
      rankingRepository: DriftRankingRepository(db),
      calendarRepository: DriftCalendarRepository(db),
      trackerRepository: DriftTrackerRepository(db),
      financeRepository: DriftFinanceRepository(db),
      notificationRepository: DriftNotificationRepository(db),
      reminderRepository: DriftReminderRepository(db),
      bucketListRepository: DriftBucketListRepository(db),
      mediaRepository: DriftMediaRepository(db),
      settingsRepository: DriftSettingsRepository(db),
    );

/// Links [child] into [parent] straight into [db], [minute]s after the epoch
/// the tests share — so which of two links is the newer is up to the test.
Future<void> _addLink(
  AppDatabase db,
  String parent,
  String child, {
  int minute = 0,
  bool enabled = true,
}) {
  final at = DateTime.utc(2026, 9, 1).add(Duration(minutes: minute));
  return DriftStudyRepository(db).upsertDeckLink(
    StudyDeckLink(
      id: StudyDeckLink.idFor(parent, child),
      parentDeckId: parent,
      childDeckId: child,
      enabled: enabled,
      createdAt: at,
      updatedAt: at,
    ),
  );
}

/// A third deck, K8s, with one due card of its own.
Future<void> _addK8s(AppDatabase db) async {
  final repo = DriftStudyRepository(db);
  final now = DateTime.now().toUtc();
  await repo.upsertDeck(
    StudyDeck(id: 'k8s', name: 'K8s', createdAt: now, updatedAt: now),
  );
  await repo.upsertCard(
    StudyCard(
      id: 'k8s-card',
      deckId: 'k8s',
      frontText: 'K8s question',
      backText: 'K8s answer',
      dueAt: now.subtract(const Duration(days: 1)),
      createdAt: now,
      updatedAt: now,
    ),
  );
}

/// Opens the AWS placeholder's sheet over the hub's workbench.
Future<void> _openAwsSheet(WidgetTester tester) async {
  await tester.tap(find.text('AWS').first);
  await _settle(tester);
}

/// The sheet's own grid tile for the AWS card — the hub's grid never shows
/// it, since linked cards live only behind their placeholder.
Finder get _awsTileInSheet => find.byKey(const ValueKey('aws-card'));

Future<void> _rightClick(WidgetTester tester, Finder target) async {
  final gesture = await tester.startGesture(
    tester.getCenter(target),
    buttons: kSecondaryButton,
    kind: PointerDeviceKind.mouse,
  );
  await gesture.up();
  await _settle(tester);
}

void main() {
  setUpAll(() => driftRuntimeOptions.dontWarnAboutMultipleDatabases = true);

  group('stats', () {
    testWidgets('a hub counts its linked cards; the library counts each once', (
      tester,
    ) async {
      final container = _container(await _seed());
      await _ref(tester, container);

      final hub = await container.read(studyDeckStatsProvider(_hub).future);
      final aws = await container.read(studyDeckStatsProvider(_aws).future);
      expect(hub, (own: 1, total: 2, due: 2));
      expect(aws, (own: 1, total: 1, due: 1));

      // The Hub's global figure is one pass over the library's cards, so the
      // AWS card reached through the hub is not counted a second time.
      final all = await container.read(studyAllCardsProvider.future);
      expect(all.map((c) => c.id).toSet(), {'hub-card', 'aws-card'});
    });

    testWidgets('turning the link off takes its cards out of the hub', (
      tester,
    ) async {
      final db = await _seed();
      final container = _container(db);
      await _pump(tester, container, _workbench());

      expect(find.byType(StudyLinkedDeckTile), findsOneWidget);
      expect(find.text('1 card · 1 linked · 2 due'), findsOneWidget);

      await tester.tap(find.byType(Switch));
      await _settle(tester);

      final link = await DriftStudyRepository(
        db,
      ).getDeckLink(StudyDeckLink.idFor(_hub, _aws));
      expect(link!.enabled, isFalse);
      expect(find.text('1 card · 1 linked · 2 due'), findsNothing);
      // The header, and the placeholder's own footer (AWS's one card, due).
      expect(find.text('1 card · 1 due'), findsNWidgets(2));
      // Parked, not removed.
      expect(find.byType(StudyLinkedDeckTile), findsOneWidget);
    });
  });

  testWidgets('fork copies the linked cards with fresh progress and unlinks', (
    tester,
  ) async {
    final db = await _seed();
    final repo = DriftStudyRepository(db);
    final container = _container(db);
    await _pump(tester, container, _workbench());

    await _rightClick(tester, find.byType(StudyLinkedDeckTile));
    await tester.tap(find.text('Fork into this deck'));
    await _settle(tester);
    // Nothing else brings AWS in, so there is nothing to warn about.
    expect(find.textContaining('alongside the copies'), findsNothing);
    await tester.tap(find.widgetWithText(GlassButton, 'Fork'));
    await _settle(tester);

    final hubCards = await repo.listCards(_hub);
    final copy = hubCards.singleWhere((c) => c.id != 'hub-card');
    expect(copy.id, isNot('aws-card'));
    expect(copy.frontText, 'AWS question');
    expect(copy.reviewCount, 0);
    expect(copy.interval, 0);
    expect(copy.ease, 2.5);

    // The source keeps its own schedule, and the link is gone.
    final source = await repo.getCard('aws-card');
    expect(source!.deckId, _aws);
    expect(source.reviewCount, 4);
    final link = await repo.getDeckLink(StudyDeckLink.idFor(_hub, _aws));
    expect(link!.deletedAt, isNotNull);
    expect(find.byType(StudyLinkedDeckTile), findsNothing);
  });

  group('linking', () {
    testWidgets('relinking revives the tombstoned row, one version up', (
      tester,
    ) async {
      final db = await _seed();
      final repo = DriftStudyRepository(db);
      final container = _container(db);
      final ref = await _ref(tester, container);
      final id = StudyDeckLink.idFor(_hub, _aws);

      await unlinkStudyDeck(
        ref.context,
        (await repo.getDeckLink(id))!,
        childName: 'AWS',
      );
      final tombstone = await repo.getDeckLink(id);
      expect(tombstone!.deletedAt, isNotNull);

      expect(
        await linkStudyDeck(ref, parentDeckId: _hub, childDeckId: _aws),
        isTrue,
      );
      final revived = await repo.getDeckLink(id);
      expect(revived!.deletedAt, isNull);
      expect(revived.enabled, isTrue);
      expect(revived.version, tombstone.version + 1);
      expect(await repo.listDeckLinks(includeDeleted: true), hasLength(1));
      await _outlastToast(tester);
    });

    testWidgets('unlink offers an undo that puts the link back as it was', (
      tester,
    ) async {
      final db = await _seed();
      final repo = DriftStudyRepository(db);
      final id = StudyDeckLink.idFor(_hub, _aws);
      // Parked, so the undo has a toggle state to get right.
      await repo.upsertDeckLink((await repo.getDeckLink(id))!.copyWith(enabled: false));
      final original = (await repo.getDeckLink(id))!;
      final container = _container(db);
      await _pump(tester, container, _workbench());

      await _rightClick(tester, find.byType(StudyLinkedDeckTile));
      await tester.tap(find.text('Unlink'));
      await _settle(tester);
      expect(find.byType(StudyLinkedDeckTile), findsNothing);
      final tombstone = (await repo.getDeckLink(id))!;
      expect(tombstone.deletedAt, isNotNull);

      await _pressUndo(tester);
      final back = (await repo.getDeckLink(id))!;
      expect(back.deletedAt, isNull);
      expect(back.enabled, isFalse);
      // Its original age, so the placeholder keeps its place in the grid.
      expect(back.createdAt, original.createdAt);
      expect(back.version, greaterThan(tombstone.version));
      expect(find.byType(StudyLinkedDeckTile), findsOneWidget);
      await _outlastToast(tester);
    });

    testWidgets('a link that would close a loop is refused', (tester) async {
      final db = await _seed();
      final container = _container(db);
      final ref = await _ref(tester, container);

      expect(
        await linkStudyDeck(ref, parentDeckId: _aws, childDeckId: _hub),
        isFalse,
      );
      expect(
        await linkStudyDeck(ref, parentDeckId: _hub, childDeckId: _hub),
        isFalse,
      );
      expect(await DriftStudyRepository(db).listDeckLinks(), hasLength(1));
    });

    testWidgets('deleting a deck tombstones the links on both sides', (
      tester,
    ) async {
      final db = await _seed();
      final repo = DriftStudyRepository(db);
      final now = DateTime.now().toUtc();
      await repo.upsertDeck(
        StudyDeck(id: 'k8s', name: 'K8s', createdAt: now, updatedAt: now),
      );
      await repo.upsertDeckLink(
        StudyDeckLink(
          id: StudyDeckLink.idFor(_aws, 'k8s'),
          parentDeckId: _aws,
          childDeckId: 'k8s',
          createdAt: now,
          updatedAt: now,
        ),
      );
      final container = _container(db);
      await _ref(tester, container);

      await softDeleteStudyDeckLinksTouching(container, {_aws});
      expect(await repo.listDeckLinks(), isEmpty);
      expect(await repo.listDeckLinks(includeDeleted: true), hasLength(2));
    });
  });

  testWidgets('fork warns when the cards still arrive through another link', (
    tester,
  ) async {
    final db = await _seed();
    final now = DateTime.now().toUtc();
    await DriftStudyRepository(db).upsertDeck(
      StudyDeck(id: 'docker', name: 'Docker', createdAt: now, updatedAt: now),
    );
    await _addLink(db, _hub, 'docker');
    await _addLink(db, 'docker', _aws);
    final container = _container(db);
    await _pump(tester, container, _workbench());

    await _rightClick(
      tester,
      find.ancestor(
        of: find.text('AWS'),
        matching: find.byType(StudyLinkedDeckTile),
      ),
    );
    await tester.tap(find.text('Fork into this deck'));
    await _settle(tester);
    expect(
      find.textContaining(
        '"Docker" also brings "AWS" into "System Design", so its original '
        'cards will still show up there alongside the copies.',
      ),
      findsOneWidget,
    );
  });

  group('linked sheet (§5.3)', () {
    testWidgets('counts, lists and studies only the deck\'s own cards', (
      tester,
    ) async {
      final db = await _seed();
      await _addK8s(db);
      await _addLink(db, _aws, 'k8s');
      final container = _container(db);
      await _pump(tester, container, _workbench());
      // The placeholder still speaks for everything AWS brings in.
      expect(find.text('2 cards · 2 due'), findsOneWidget);

      await _openAwsSheet(tester);
      expect(find.text('1 card · 1 due'), findsOneWidget);
      expect(find.byKey(const ValueKey('k8s-card')), findsNothing);

      await tester.tap(find.text('Study 1 due'));
      await _settle(tester);
      final session = tester.widget<StudySessionPage>(
        find.byType(StudySessionPage),
      );
      expect(session.cardIds, {'aws-card'});
      expect(session.frameDeckId, _aws);
    });

    testWidgets('a card deleted in it can be undone after it closes', (
      tester,
    ) async {
      final db = await _seed();
      final repo = DriftStudyRepository(db);
      final container = _container(db);
      await _pump(tester, container, _workbench());
      await _openAwsSheet(tester);

      await _rightClick(tester, _awsTileInSheet);
      await tester.tap(find.text('Delete'));
      await _settle(tester);
      await tester.tap(find.widgetWithText(GlassButton, 'Delete'));
      await _settle(tester);
      expect((await repo.getCard('aws-card'))!.deletedAt, isNotNull);

      await tester.tap(find.byTooltip('Close'));
      await _settle(tester);
      expect(find.text('This deck has no cards of its own.'), findsNothing);

      await _pressUndo(tester);
      expect((await repo.getCard('aws-card'))!.deletedAt, isNull);
      await _outlastToast(tester);
    });

    testWidgets('a deck deleted under it closes it, not the editor above it', (
      tester,
    ) async {
      final db = await _seed();
      final container = _container(db);
      await _pump(tester, container, _workbench());
      await _openAwsSheet(tester);
      await _rightClick(tester, _awsTileInSheet);
      await tester.tap(find.text('Edit…'));
      await _settle(tester);
      expect(find.byTooltip('Delete'), findsOneWidget);

      await DriftStudyRepository(db).softDeleteDeck(_aws);
      container.invalidate(studyDeckByIdProvider);
      await _settle(tester);

      expect(find.text('Study 1 due'), findsNothing);
      expect(find.byTooltip('Delete'), findsOneWidget);
    });
  });

  testWidgets('the card editor\'s delete can be undone once it has closed', (
    tester,
  ) async {
    final db = await _seed();
    final repo = DriftStudyRepository(db);
    final container = _container(db);
    await _pump(tester, container, _workbench());

    await _rightClick(tester, find.byKey(const ValueKey('hub-card')));
    await tester.tap(find.text('Edit…'));
    await _settle(tester);
    await tester.tap(find.byTooltip('Delete'));
    await _settle(tester);
    expect((await repo.getCard('hub-card'))!.deletedAt, isNotNull);
    expect(find.byTooltip('Delete'), findsNothing);

    await _pressUndo(tester);
    expect((await repo.getCard('hub-card'))!.deletedAt, isNull);
    await _outlastToast(tester);
  });

  test('importing a backup breaks a loop it closes with the local links', () async {
    // The backup holds AWS → hub; this device has since linked hub → AWS.
    final source = await _seed(linked: false);
    await _addLink(source, _aws, _hub, minute: 1);
    final contents = await DataExportService(
      collections: _collectionsFor(source),
      settingsRepository: DriftSettingsRepository(source),
    ).buildArchiveContents();
    final zip = File('${Directory.systemTemp.path}/voyager_deck_link_loop.zip');
    await zip.writeAsBytes(generateBackupZipIsolate(contents));
    addTearDown(zip.delete);

    final target = await _seed(linked: false);
    await _addLink(target, _hub, _aws, minute: 2);
    final uploads = <String, List<Object>>{};
    await DataImportService(
      db: target,
      collections: _collectionsFor(target),
      settingsRepository: DriftSettingsRepository(target),
      pushRecords: (collection, records) async => uploads[collection] = records,
      pushSettings: (_) async {},
    ).importFromZip(zip);

    // The newer edge goes, as it would on a sync pull.
    final live = await DriftStudyRepository(target).listDeckLinks();
    expect(live.map((l) => l.id), [StudyDeckLink.idFor(_aws, _hub)]);
    final pushed = uploads[FirestoreCollections.studyDeckLinks]!;
    final last = pushed.last as StudyDeckLink;
    expect(last.id, StudyDeckLink.idFor(_hub, _aws));
    expect(last.deletedAt, isNotNull);
  });

  group('source label (§7)', () {
    Future<void> session(
      WidgetTester tester,
      Set<String> cardIds, {
      String? frame,
    }) async {
      final container = _container(await _seed());
      await _pump(
        tester,
        container,
        StudySessionPage(cardIds: cardIds, frameDeckId: frame),
      );
    }

    Finder label(String name) => find.widgetWithText(StudyCardSourceLabel, name);

    testWidgets('a linked card names its home deck', (tester) async {
      await session(tester, {'aws-card'}, frame: _hub);
      expect(label('AWS'), findsWidgets);
    });

    testWidgets('a card at home shows nothing', (tester) async {
      await session(tester, {'hub-card'}, frame: _hub);
      expect(find.byType(StudyCardSourceLabel), findsNothing);
    });

    testWidgets('studying the linked deck itself shows nothing', (
      tester,
    ) async {
      await session(tester, {'aws-card'}, frame: _aws);
      expect(find.byType(StudyCardSourceLabel), findsNothing);
    });

    testWidgets('the library-wide session shows nothing', (tester) async {
      await session(tester, {'aws-card', 'hub-card'});
      expect(find.byType(StudyCardSourceLabel), findsNothing);
    });
  });

  test('a link survives the Firestore round trip', () {
    final now = DateTime.utc(2026, 9, 1);
    final link = StudyDeckLink(
      id: StudyDeckLink.idFor(_hub, _aws),
      parentDeckId: _hub,
      childDeckId: _aws,
      enabled: false,
      createdAt: now,
      updatedAt: now,
      version: 3,
    );
    final back = mergeStudyDeckLinkFromRemote(
      studyDeckLinkToFirestore(link),
      link.id,
    );
    expect(back.parentDeckId, _hub);
    expect(back.childDeckId, _aws);
    expect(back.enabled, isFalse);
    expect(back.version, 3);
    expect(back.deletedAt, isNull);
  });
}

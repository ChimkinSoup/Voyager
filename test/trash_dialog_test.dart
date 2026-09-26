import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/utils/ids.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/data/repositories/drift_repositories.dart';
import 'package:voyager/domain/models/dream_models.dart';
import 'package:voyager/domain/models/journal_models.dart';
import 'package:voyager/features/settings/services/backup_collections.dart';
import 'package:voyager/features/trash/trash_dialog.dart';
import 'package:voyager/features/trash/trash_kinds.dart';
import 'package:voyager/features/trash/trash_service.dart';

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

void main() {
  late AppDatabase db;
  late DriftJournalRepository journals;
  late TrashService service;
  final created = DateTime.utc(2026, 9, 1);

  setUp(() async {
    db = AppDatabase.inMemory();
    journals = DriftJournalRepository(db);
    service = TrashService(
      db: db,
      collections: _collectionsFor(db),
      push: (_, _) async {},
    );
    await journals.upsertJournal(
      Journal(id: 'j', name: 'Work', createdAt: created, updatedAt: created),
    );
    await journals.upsertEntry(
      JournalEntry(
        id: 'e',
        journalId: 'j',
        title: 'Standup',
        body: 'Notes',
        entryDate: created,
        createdAt: created,
        updatedAt: created,
      ),
    );
    final at = utcNow();
    await journals.softDeleteEntriesInJournal('j', at: at);
    await journals.softDeleteJournal('j', at: at);
    await DriftDreamRepository(db).upsertEntry(
      DreamEntry(
        id: 'd',
        title: 'Flying',
        body: 'Over the sea',
        entryDate: created,
        createdAt: created,
        updatedAt: created,
        deletedAt: utcNow(),
      ),
    );
  });

  tearDown(() async => db.close());

  Future<void> openTrash(WidgetTester tester, {TrashFeature? feature}) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          trashServiceProvider.overrideWithValue(service),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showTrashDialog(context, feature: feature),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pumpAndSettle();
    // The list is read off the database outside the fake clock.
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('a page link opens it filtered to that page', (tester) async {
    await openTrash(tester, feature: TrashFeature.journal);

    expect(find.text('Journal "Work"'), findsOneWidget);
    expect(find.text('"Flying"'), findsNothing);
    expect(find.text('Empty Journal trash'), findsOneWidget);

    await tester.tap(find.text('All'));
    await tester.pumpAndSettle();

    expect(find.text('"Flying"'), findsOneWidget);
    expect(find.text('Empty trash'), findsOneWidget);
  });

  testWidgets('restore brings the row back and takes it off the list', (
    tester,
  ) async {
    await openTrash(tester, feature: TrashFeature.journal);

    await tester.tap(find.text('Restore'));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pumpAndSettle();

    final journal = await tester.runAsync(() => journals.getJournal('j'));
    final entry = await tester.runAsync(() => journals.getEntry('e'));
    expect(journal!.deletedAt, isNull);
    expect(entry!.deletedAt, isNull);
    expect(find.text('Journal "Work"'), findsNothing);
  });

  test('a row says where it came from, what went with it, and how long is '
      'left', () async {
    final item = (await service.list()).firstWhere((i) => i.id == 'j');
    final now = item.deletedAt.add(const Duration(days: 5, hours: 1));

    expect(trashItemLabel(item), 'Journal "Work"');
    expect(
      trashItemDetail(item, now),
      'Journal · 1 entry · deleted 5 days ago · 25 days left',
    );
  });
}

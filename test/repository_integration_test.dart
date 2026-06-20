import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/core/utils/ids.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/data/repositories/drift_repositories.dart';
import 'package:voyager/domain/models/analytics_models.dart';
import 'package:voyager/domain/models/enums.dart';
import 'package:voyager/domain/models/journal_models.dart';
import 'package:voyager/domain/models/todo_models.dart';

void main() {
  late AppDatabase db;
  late DriftJournalRepository journalRepo;
  late DriftTodoRepository todoRepo;
  late DriftTrackerRepository trackerRepo;

  setUp(() {
    db = AppDatabase.inMemory();
    journalRepo = DriftJournalRepository(db);
    todoRepo = DriftTodoRepository(db);
    trackerRepo = DriftTrackerRepository(db);
  });

  tearDown(() async {
    await db.close();
  });

  test('journal repository persists and lists entries', () async {
    final now = utcNow();
    final journal = Journal(
      id: newId(),
      name: 'Test',
      createdAt: now,
      updatedAt: now,
    );
    await journalRepo.upsertJournal(journal);

    final entry = JournalEntry(
      id: newId(),
      journalId: journal.id,
      title: 'Hello',
      body: 'World',
      entryDate: now,
      createdAt: now,
      updatedAt: now,
    );
    await journalRepo.upsertEntry(entry);

    final entries = await journalRepo.listEntries(journalId: journal.id);
    expect(entries, hasLength(1));
    expect(entries.first.title, 'Hello');
  });

  test('journal repository supports recent lazy loading limits', () async {
    final now = utcNow();
    final journal = Journal(
      id: newId(),
      name: 'Test',
      createdAt: now,
      updatedAt: now,
    );
    await journalRepo.upsertJournal(journal);

    for (var i = 0; i < 35; i++) {
      final createdAt = now.add(Duration(minutes: i));
      await journalRepo.upsertEntry(
        JournalEntry(
          id: newId(),
          journalId: journal.id,
          title: 'Entry $i',
          body: '',
          entryDate: createdAt,
          createdAt: createdAt,
          updatedAt: createdAt,
        ),
      );
    }

    final entries = await journalRepo.listEntries(limit: 30);
    expect(entries, hasLength(30));
    expect(entries.first.title, 'Entry 34');
    expect(entries.last.title, 'Entry 5');
  });

  test(
    'journal repository purges deleted entries after retention window',
    () async {
      final now = utcNow();
      final journal = Journal(
        id: newId(),
        name: 'Test',
        createdAt: now,
        updatedAt: now,
      );
      await journalRepo.upsertJournal(journal);
      final expired = JournalEntry(
        id: newId(),
        journalId: journal.id,
        title: 'Expired',
        body: '',
        entryDate: now,
        createdAt: now,
        updatedAt: now,
        deletedAt: now.subtract(const Duration(days: 31)),
      );
      final retained = JournalEntry(
        id: newId(),
        journalId: journal.id,
        title: 'Retained',
        body: '',
        entryDate: now,
        createdAt: now,
        updatedAt: now,
        deletedAt: now.subtract(const Duration(days: 10)),
      );

      await journalRepo.upsertEntry(expired);
      await journalRepo.upsertEntry(retained);
      await journalRepo.purgeExpiredDeleted(now);

      expect(await journalRepo.getEntry(expired.id), isNull);
      expect(await journalRepo.getEntry(retained.id), isNotNull);
    },
  );

  test('todo repository soft deletes tasks', () async {
    final now = utcNow();
    final list = TodoListModel(
      id: newId(),
      name: 'Inbox',
      createdAt: now,
      updatedAt: now,
    );
    await todoRepo.upsertList(list);
    final task = TodoTask(
      id: newId(),
      listId: list.id,
      title: 'Task',
      createdAt: now,
      updatedAt: now,
    );
    await todoRepo.upsertTask(task);
    await todoRepo.softDeleteTask(task.id);

    final tasks = await todoRepo.listTasks(list.id);
    expect(tasks, isEmpty);
  });

  test('tracker repository persists tracker values', () async {
    final now = utcNow();
    final tracker = StatisticTracker(
      id: newId(),
      name: 'Energy',
      type: TrackerType.integer,
      cadence: TrackerCadence.daily,
      integerCap: 10,
      createdAt: now,
      updatedAt: now,
    );
    await trackerRepo.upsertTracker(tracker);

    final value = TrackerValue(
      id: newId(),
      trackerId: tracker.id,
      periodStart: DateTime(now.year, now.month, now.day),
      intValue: 7,
      createdAt: now,
      updatedAt: now,
    );
    await trackerRepo.upsertValue(value);

    final trackers = await trackerRepo.listTrackers();
    final values = await trackerRepo.listValues(tracker.id);

    expect(trackers, hasLength(1));
    expect(trackers.first.name, 'Energy');
    expect(values, hasLength(1));
    expect(values.first.intValue, 7);
  });

  test('tracker repository persists ranking configs and values', () async {
    final now = utcNow();
    final config = RankingConfig(
      id: newId(),
      name: 'Weekly review',
      cadence: TrackerCadence.weekly,
      maxValue: 10,
      createdAt: now,
      updatedAt: now,
    );
    await trackerRepo.upsertRankingConfig(config);

    final value = RankingValue(
      id: newId(),
      configId: config.id,
      periodStart: DateTime(now.year, now.month, now.day),
      value: 8,
      createdAt: now,
      updatedAt: now,
    );
    await trackerRepo.upsertRankingValue(value);

    final configs = await trackerRepo.listRankingConfigs();
    final values = await trackerRepo.listRankingValues(config.id);

    expect(configs, hasLength(1));
    expect(configs.first.name, 'Weekly review');
    expect(values, hasLength(1));
    expect(values.first.value, 8);
  });
}

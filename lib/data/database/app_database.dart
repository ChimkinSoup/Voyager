import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

part 'app_database.g.dart';

class JournalsTable extends Table {
  TextColumn get id => text()();
  TextColumn get name => text()();
  BoolColumn get guidedJournaling => boolean().withDefault(const Constant(false))();
  IntColumn get promptCycleDays => integer().withDefault(const Constant(7))();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();
  DateTimeColumn get deletedAt => dateTime().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

class JournalEntriesTable extends Table {
  TextColumn get id => text()();
  TextColumn get journalId => text()();
  TextColumn get title => text()();
  TextColumn get body => text()();
  TextColumn get richBodyJson => text().nullable()();
  DateTimeColumn get entryDate => dateTime()();
  DateTimeColumn get timestamp => dateTime().nullable()();
  TextColumn get tagsJson => text().withDefault(const Constant('[]'))();
  IntColumn get mood => integer().nullable()();
  TextColumn get quoteId => text().nullable()();
  TextColumn get customQuote => text().nullable()();
  TextColumn get weatherIcon => text().nullable()();
  TextColumn get guidedPrompt => text().nullable()();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();
  DateTimeColumn get deletedAt => dateTime().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

class TodoListsTable extends Table {
  TextColumn get id => text()();
  TextColumn get name => text()();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();
  DateTimeColumn get deletedAt => dateTime().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

class TodoTasksTable extends Table {
  TextColumn get id => text()();
  TextColumn get listId => text()();
  TextColumn get title => text()();
  TextColumn get notes => text().nullable()();
  DateTimeColumn get dueDate => dateTime().nullable()();
  BoolColumn get completed => boolean().withDefault(const Constant(false))();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();
  DateTimeColumn get deletedAt => dateTime().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

class CalendarEventsTable extends Table {
  TextColumn get id => text()();
  TextColumn get title => text()();
  DateTimeColumn get start => dateTime()();
  DateTimeColumn get end => dateTime()();
  BoolColumn get isFullDay => boolean().withDefault(const Constant(true))();
  IntColumn get colorValue => integer().withDefault(const Constant(0xFF7C9EFF))();
  TextColumn get notes => text().withDefault(const Constant(''))();
  TextColumn get source => text().withDefault(const Constant('local'))();
  TextColumn get externalId => text().nullable()();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();
  DateTimeColumn get deletedAt => dateTime().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

class TrackersTable extends Table {
  TextColumn get id => text()();
  TextColumn get name => text()();
  TextColumn get type => text()();
  TextColumn get cadence => text()();
  IntColumn get colorValue => integer().withDefault(const Constant(0xFF7C9EFF))();
  BoolColumn get showOnCalendar => boolean().withDefault(const Constant(false))();
  IntColumn get integerCap => integer().nullable()();
  IntColumn get defaultInt => integer().withDefault(const Constant(0))();
  BoolColumn get defaultBool => boolean().withDefault(const Constant(false))();
  TextColumn get enumOptionsJson => text().withDefault(const Constant('[]'))();
  TextColumn get defaultEnumOption => text().nullable()();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();
  DateTimeColumn get deletedAt => dateTime().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

class TrackerValuesTable extends Table {
  TextColumn get id => text()();
  TextColumn get trackerId => text()();
  DateTimeColumn get periodStart => dateTime()();
  IntColumn get intValue => integer().nullable()();
  BoolColumn get boolValue => boolean().nullable()();
  TextColumn get enumValue => text().nullable()();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();
  DateTimeColumn get deletedAt => dateTime().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

class RankingConfigsTable extends Table {
  TextColumn get id => text()();
  TextColumn get name => text()();
  TextColumn get cadence => text()();
  IntColumn get maxValue => integer()();
  IntColumn get colorStart => integer().withDefault(const Constant(0xFF4CAF50))();
  IntColumn get colorEnd => integer().withDefault(const Constant(0xFFF44336))();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();
  DateTimeColumn get deletedAt => dateTime().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

class RankingValuesTable extends Table {
  TextColumn get id => text()();
  TextColumn get configId => text()();
  DateTimeColumn get periodStart => dateTime()();
  IntColumn get value => integer()();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();
  DateTimeColumn get deletedAt => dateTime().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

class SettingsTable extends Table {
  IntColumn get id => integer().withDefault(const Constant(1))();
  IntColumn get accentColor => integer().withDefault(const Constant(0xFF7C9EFF))();
  BoolColumn get weekStartsOnMonday => boolean().withDefault(const Constant(true))();
  BoolColumn get showQuotes => boolean().withDefault(const Constant(true))();
  TextColumn get journalHotkey => text().withDefault(const Constant('Ctrl+Shift+J'))();
  TextColumn get todoHotkey => text().withDefault(const Constant('Ctrl+Shift+T'))();
  IntColumn get rankingColorStart => integer().withDefault(const Constant(0xFF4CAF50))();
  IntColumn get rankingColorEnd => integer().withDefault(const Constant(0xFFF44336))();
  BoolColumn get timelineModeYearZero => boolean().withDefault(const Constant(true))();
  IntColumn get birthYear => integer().nullable()();
  BoolColumn get alertOnPeriodicPrompts => boolean().withDefault(const Constant(false))();
  IntColumn get alertTimeHour => integer().withDefault(const Constant(9))();
  BoolColumn get hideCompletedTasks => boolean().withDefault(const Constant(false))();

  @override
  Set<Column> get primaryKey => {id};
}

class TagColorsTable extends Table {
  TextColumn get tag => text()();
  IntColumn get colorValue => integer()();

  @override
  Set<Column> get primaryKey => {tag};
}

@DriftDatabase(tables: [
  JournalsTable,
  JournalEntriesTable,
  TodoListsTable,
  TodoTasksTable,
  CalendarEventsTable,
  TrackersTable,
  TrackerValuesTable,
  RankingConfigsTable,
  RankingValuesTable,
  SettingsTable,
  TagColorsTable,
])
class AppDatabase extends _$AppDatabase {
  AppDatabase(super.e);

  @override
  int get schemaVersion => 4;

  @override
  MigrationStrategy get migration => MigrationStrategy(
        beforeOpen: (details) async {
          if (details.wasCreated) return;
          await _backfillNullBools();
        },
        onUpgrade: (migrator, from, to) async {
          if (from < 2) {
            await migrator.addColumn(settingsTable, settingsTable.hideCompletedTasks);
          }
          if (from < 3) {
            await _backfillNullBools();
          }
          if (from < 4) {
            await migrator.addColumn(journalEntriesTable, journalEntriesTable.richBodyJson);
          }
        },
      );

  Future<void> _backfillNullBools() async {
    await customStatement(
      'UPDATE settings_table SET hide_completed_tasks = 0 WHERE hide_completed_tasks IS NULL',
    );
    await customStatement(
      'UPDATE todo_tasks_table SET completed = 0 WHERE completed IS NULL',
    );
  }

  static AppDatabase create() {
    return AppDatabase(_openConnection());
  }

  static AppDatabase inMemory() {
    return AppDatabase(NativeDatabase.memory());
  }
}

LazyDatabase _openConnection() {
  return LazyDatabase(() async {
    final dir = await getApplicationDocumentsDirectory();
    final file = File(p.join(dir.path, 'voyager.sqlite'));
    return NativeDatabase(file);
  });
}

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/sync/firestore_collections.dart';
import 'package:voyager/core/widgets/context_menu.dart';
import 'package:voyager/core/widgets/glass_button.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/data/repositories/drift_repositories.dart';
import 'package:voyager/domain/models/calendar_models.dart';
import 'package:voyager/domain/models/journal_models.dart';
import 'package:voyager/domain/models/settings_models.dart';
import 'package:voyager/domain/models/todo_models.dart';
import 'package:voyager/features/settings/services/backup_collections.dart';
import 'package:voyager/features/settings/services/color_replacement_service.dart';
import 'package:voyager/features/settings/settings_color_palette_section.dart';

const _old = 0xFF112233;
const _new = 0xFF7C9EFF;
const _other = 0xFF445566;

final _now = DateTime.utc(2026, 3, 4, 5, 6, 7);

/// Stands in for the sync layer so tests can assert what a sweep uploaded.
class RecordingUploader {
  final Map<String, List<Object>> records = {};

  Future<void> pushRecords(String collection, List<Object> pushed) async {
    (records[collection] ??= []).addAll(pushed);
  }
}

List<BackupCollection> collectionsFor(AppDatabase db) => buildBackupCollections(
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
  late DriftTodoRepository todos;
  late DriftCalendarRepository calendars;
  late DriftSettingsRepository settings;
  late RecordingUploader uploader;
  late ColorReplacementService service;

  setUp(() {
    db = AppDatabase.inMemory();
    journals = DriftJournalRepository(db);
    todos = DriftTodoRepository(db);
    calendars = DriftCalendarRepository(db);
    settings = DriftSettingsRepository(db);
    uploader = RecordingUploader();
    service = ColorReplacementService(
      db: db,
      collections: collectionsFor(db),
      pushRecords: uploader.pushRecords,
    );
  });

  tearDown(() async => db.close());

  /// One record on [_old] in four collections that store a color differently:
  /// a nullable column, a non-null one, a child of another record, and a
  /// collection keyed by an encoded id rather than a generated one.
  Future<void> seedColoredRecords() async {
    await journals.upsertJournal(
      Journal(
        id: 'journal-1',
        name: 'Field Notes',
        colorValue: _old,
        createdAt: _now,
        updatedAt: _now,
      ),
    );
    await todos.upsertList(
      TodoListModel(
        id: 'list-1',
        name: 'Errands',
        colorValue: _old,
        createdAt: _now,
        updatedAt: _now,
      ),
    );
    await calendars.upsertCalendar(
      Calendar(
        id: 'calendar-1',
        name: 'Personal',
        colorValue: _old,
        createdAt: _now,
        updatedAt: _now,
      ),
    );
    await calendars.upsertEvent(
      CalendarEvent(
        id: 'event-1',
        calendarId: 'calendar-1',
        title: 'Dentist',
        start: _now,
        end: _now.add(const Duration(hours: 1)),
        isFullDay: false,
        colorValue: _old,
        createdAt: _now,
        updatedAt: _now,
      ),
    );
    await settings.setTagColor('food', _old);
  }

  group('ColorReplacementService', () {
    test('counts every record on the color, per collection', () async {
      await seedColoredRecords();

      final usage = await service.countUsage(_old);

      expect(usage.total, 5);
      expect(usage.byCollection, {
        FirestoreCollections.journals: 1,
        FirestoreCollections.todoLists: 1,
        FirestoreCollections.calendars: 1,
        FirestoreCollections.calendarEvents: 1,
        FirestoreCollections.tagColors: 1,
      });
    });

    test('counts nothing for a color no record uses', () async {
      await seedColoredRecords();

      expect((await service.countUsage(_other)).byCollection, isEmpty);
    });

    test('rewrites every record on the color and leaves the rest', () async {
      await seedColoredRecords();
      await calendars.upsertCalendar(
        Calendar(
          id: 'calendar-2',
          name: 'Work',
          colorValue: _other,
          createdAt: _now,
          updatedAt: _now,
        ),
      );

      final replaced = await service.replace(from: _old, to: _new);

      expect(replaced.total, 5);
      expect((await journals.getJournal('journal-1'))!.colorValue, _new);
      expect((await todos.listLists()).single.colorValue, _new);
      expect((await calendars.getCalendar('calendar-1'))!.colorValue, _new);
      expect((await calendars.getEvent('event-1'))!.colorValue, _new);
      expect((await settings.getTagColors())['food'], _new);
      expect((await calendars.getCalendar('calendar-2'))!.colorValue, _other);
    });

    test('matches on the color regardless of stored alpha', () async {
      await journals.upsertJournal(
        Journal(
          id: 'journal-1',
          name: 'Field Notes',
          colorValue: 0x80112233,
          createdAt: _now,
          updatedAt: _now,
        ),
      );

      expect((await service.countUsage(_old)).total, 1);
      await service.replace(from: _old, to: _new);
      expect((await journals.getJournal('journal-1'))!.colorValue, _new);
    });

    test('leaves soft-deleted records out of the count and the sweep', () async {
      await seedColoredRecords();
      await journals.softDeleteJournal('journal-1');

      expect(
        (await service.countUsage(_old)).byCollection,
        isNot(contains(FirestoreCollections.journals)),
      );
      final replaced = await service.replace(from: _old, to: _new);
      expect(replaced.byCollection, isNot(contains(
        FirestoreCollections.journals,
      )));
      final tombstone = await journals.getJournal('journal-1');
      expect(tombstone!.colorValue, _old);
    });

    test('bumps the version so the rewrite beats the stored copy', () async {
      await seedColoredRecords();
      final before = (await calendars.getCalendar('calendar-1'))!.version;

      await service.replace(from: _old, to: _new);

      expect((await calendars.getCalendar('calendar-1'))!.version, before + 1);
    });

    test('pushes every rewritten record and nothing else', () async {
      await seedColoredRecords();

      await service.replace(from: _old, to: _new);

      expect(uploader.records.keys, unorderedEquals([
        FirestoreCollections.journals,
        FirestoreCollections.todoLists,
        FirestoreCollections.calendars,
        FirestoreCollections.calendarEvents,
        FirestoreCollections.tagColors,
      ]));
      expect(
        uploader.records[FirestoreCollections.journals]!.single,
        isA<Journal>().having((j) => j.colorValue, 'colorValue', _new),
      );
    });

    test('pushes nothing when no record uses the color', () async {
      await seedColoredRecords();

      final replaced = await service.replace(from: _other, to: _new);

      expect(replaced.total, 0);
      expect(uploader.records, isEmpty);
    });
  });

  group('replaceSettingsColor', () {
    test('keeps the replacement in the slot the old color held', () {
      const before = AppSettings(colorPalette: [_other, _old, 0xFFAABBCC]);

      final after = replaceSettingsColor(before, from: _old, to: _new);

      expect(after.colorPalette, [_other, _new, 0xFFAABBCC]);
    });

    test('merges into the earlier slot when the replacement is already in the '
        'palette', () {
      const before = AppSettings(colorPalette: [_new, _other, _old]);

      final after = replaceSettingsColor(before, from: _old, to: _new);

      expect(after.colorPalette, [_new, _other]);
    });

    test('moves every settings color that held the old one', () {
      const before = AppSettings(
        colorPalette: [_old],
        accentColor: _old,
        petalColor: _old,
        minorPetalColors: [_old, _other],
        weatherChartTempColor: _old,
        weatherChartRainColor: _other,
      );

      final after = replaceSettingsColor(before, from: _old, to: _new);

      expect(after.accentColor, _new);
      expect(after.petalColor, _new);
      expect(after.minorPetalColors, [_new, _other]);
      expect(after.weatherChartTempColor, _new);
      expect(after.weatherChartRainColor, _other);
    });

    test('keeps minor petal slots at their length so weights do not shift', () {
      const before = AppSettings(
        colorPalette: [_old],
        minorPetalColors: [_old, _new],
      );

      final after = replaceSettingsColor(before, from: _old, to: _new);

      expect(after.minorPetalColors, [_new, _new]);
    });

    test('leaves unset optional colors unset', () {
      const before = AppSettings(colorPalette: [_old]);

      final after = replaceSettingsColor(before, from: _old, to: _new);

      expect(after.weatherChartTempColor, isNull);
      expect(after.weatherChartRainColor, isNull);
    });
  });

  group('palette swatch right-click', () {
    /// Runs the whole affordance: opens the swatch's menu, types [hex], and
    /// answers the confirmation. Returns what the section saved, or null if
    /// it saved nothing.
    /// Drives the affordance on an already-pumped section: opens the first
    /// swatch's menu, types [hex], and answers the confirmation.
    Future<void> driveReplace(
      WidgetTester tester, {
      required String hex,
      required bool confirm,
      void Function(WidgetTester tester)? onConfirmShown,
    }) async {
      tester
          .widget<ContextMenuRegion>(find.byType(ContextMenuRegion).first)
          .items!
          .firstWhere((item) => item.label == 'Replace everywhere…')
          .onTap!();
      await tester.pumpAndSettle();

      await tester.enterText(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.byType(TextField),
        ),
        hex,
      );
      // The OK button is disabled until the field parses, so it has to be
      // rebuilt with the typed text before it can be tapped.
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(GlassButton, 'OK'));
      await tester.pumpAndSettle();

      onConfirmShown?.call(tester);
      await tester.tap(
        find.widgetWithText(GlassButton, confirm ? 'Replace' : 'Cancel'),
      );
      await tester.pumpAndSettle();
    }

    /// [driveReplace] against a bare section, returning what it saved.
    Future<AppSettings?> replaceFirstSwatch(
      WidgetTester tester, {
      required String hex,
      required bool confirm,
      void Function(WidgetTester tester)? onConfirmShown,
    }) async {
      AppSettings? saved;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            databaseProvider.overrideWithValue(db),
            colorReplacementServiceProvider.overrideWithValue(service),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: SettingsColorPaletteSection(
                settings: const AppSettings(colorPalette: [_old, _other]),
                onSave: (settings) async => saved = settings,
              ),
            ),
          ),
        ),
      );
      await driveReplace(
        tester,
        hex: hex,
        confirm: confirm,
        onConfirmShown: onConfirmShown,
      );
      return saved;
    }

    testWidgets('confirming moves the swatch and its records', (tester) async {
      await seedColoredRecords();

      final saved = await replaceFirstSwatch(
        tester,
        hex: '7C9EFF',
        confirm: true,
      );

      expect(saved!.colorPalette, [_new, _other]);
      expect((await journals.getJournal('journal-1'))!.colorValue, _new);
    });

    testWidgets('the confirmation says how much it would change', (
      tester,
    ) async {
      await seedColoredRecords();
      late String message;
      await replaceFirstSwatch(
        tester,
        hex: '7C9EFF',
        confirm: false,
        onConfirmShown: (tester) {
          message = tester
              .widget<Text>(
                find.descendant(
                  of: find.byType(AlertDialog),
                  matching: find.textContaining('is used by'),
                ),
              )
              .data!;
        },
      );

      expect(message, contains('5 records'));
      expect(message, contains('#112233'));
      expect(message, contains('#7c9eff'));
    });

    testWidgets('the hex field takes six hex digits and nothing else', (
      tester,
    ) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            colorReplacementServiceProvider.overrideWithValue(service),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: SettingsColorPaletteSection(
                settings: const AppSettings(colorPalette: [_old, _other]),
                onSave: (_) async {},
              ),
            ),
          ),
        ),
      );
      tester
          .widget<ContextMenuRegion>(find.byType(ContextMenuRegion).first)
          .items!
          .firstWhere((item) => item.label == 'Replace everywhere…')
          .onTap!();
      await tester.pumpAndSettle();

      final field = find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byType(TextField),
      );
      String typed() => tester.widget<TextField>(field).controller!.text;
      GlassButton ok() =>
          tester.widget<GlassButton>(find.widgetWithText(GlassButton, 'OK'));

      // Non-hex characters never land, and neither does a seventh digit.
      await tester.enterText(field, 'zz7C!9E FFq99');
      await tester.pumpAndSettle();
      expect(typed(), '7C9EFF');

      // A partial color is not an answer, so OK stays disabled until the
      // sixth digit arrives.
      await tester.enterText(field, '7C9EF');
      await tester.pumpAndSettle();
      expect(ok().onPressed, isNull);
      await tester.enterText(field, '7C9EFF');
      await tester.pumpAndSettle();
      expect(ok().onPressed, isNotNull);
    });

    testWidgets('a list already on screen repaints in the new color', (
      tester,
    ) async {
      await seedColoredRecords();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            databaseProvider.overrideWithValue(db),
            colorReplacementServiceProvider.overrideWithValue(service),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: Consumer(
                builder: (context, ref, _) => Column(
                  children: [
                    // Stands in for any page showing a colored record: the
                    // provider behind it is a `keepAlive` future, so it hands
                    // back the list it read on first build until something
                    // invalidates it.
                    Text(
                      'event: '
                      '${ref.watch(calendarEventsProvider(null)).valueOrNull?.single.colorValue}',
                    ),
                    SettingsColorPaletteSection(
                      settings: const AppSettings(
                        colorPalette: [_old, _other],
                      ),
                      onSave: (_) async {},
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('event: $_old'), findsOneWidget);

      await driveReplace(tester, hex: '7C9EFF', confirm: true);

      expect(find.text('event: $_new'), findsOneWidget);
    });

    testWidgets('cancelling changes nothing', (tester) async {
      await seedColoredRecords();

      final saved = await replaceFirstSwatch(
        tester,
        hex: '7C9EFF',
        confirm: false,
      );

      expect(saved, isNull);
      expect((await journals.getJournal('journal-1'))!.colorValue, _old);
      expect(uploader.records, isEmpty);
    });
  });

  group('settingsColorsUsing', () {
    test('names each settings color on the given one', () {
      const settings = AppSettings(
        accentColor: _old,
        petalColor: _other,
        minorPetalColors: [_other, _old],
        weatherChartRainColor: _old,
      );

      expect(settingsColorsUsing(settings, _old), [
        'the app accent color',
        'a minor petal color',
        'the weather rain line',
      ]);
    });

    test('never names the palette itself', () {
      const settings = AppSettings(
        colorPalette: [_old],
        accentColor: _other,
        petalColor: _other,
      );

      expect(settingsColorsUsing(settings, _old), isEmpty);
    });
  });
}

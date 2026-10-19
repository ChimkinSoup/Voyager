// Photo Series' reminders (PHOTO_SERIES_HLD.md §13): the fire time per
// cadence, auto-acknowledge once the period is done, the sticky and OS alert
// the engine raises, and the inbox row.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/reminders/reminder_engine.dart';
import 'package:voyager/core/reminders/reminder_os_notifier.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/data/remote/in_memory_sync.dart';
import 'package:voyager/data/repositories/drift_repositories.dart';
import 'package:voyager/domain/models/enums.dart';
import 'package:voyager/domain/models/notification_models.dart';
import 'package:voyager/domain/models/photo_series_models.dart';
import 'package:voyager/domain/photo_series/photo_series_reminders.dart';

import 'fakes/fake_weather_api_client.dart';

class _FakeOs implements ReminderOsNotifier {
  _FakeOs({this.raisesDueAlertsInApp = true});

  @override
  final bool raisesDueAlertsInApp;

  final shown = <String>[];
  final dismissed = <String>[];
  final schedules = <List<PlannedReminderAlert>>[];

  @override
  Stream<String> get taps => const Stream.empty();

  @override
  Future<void> schedule(List<PlannedReminderAlert> alerts) async =>
      schedules.add(alerts);

  @override
  Future<bool> showNow(PlannedReminderAlert alert) async {
    shown.add(alert.sourceKey);
    return true;
  }

  @override
  Future<void> dismiss(String sourceKey) async => dismissed.add(sourceKey);

  @override
  Future<String?> launchSourceKey() async => null;

  @override
  Future<ReminderPermission> permission() async => ReminderPermission.granted;

  @override
  Future<void> requestPermission() async {}

  @override
  Future<void> openSystemSettings() async {}
}

Future<void> _settle() async {
  for (var i = 0; i < 20; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

final _created = DateTime(2026, 9, 1, 12);

PhotoSeries _series({
  TrackerCadence cadence = TrackerCadence.daily,
  int minutes = 9 * 60,
  int weekday = DateTime.monday,
  int monthDay = 1,
  int month = 1,
  bool enabled = true,
  DateTime? createdAt,
}) => PhotoSeries(
  id: 's',
  name: 'Progress',
  cadence: cadence,
  reminderEnabled: enabled,
  reminderMinutes: minutes,
  reminderWeekday: weekday,
  reminderMonthDay: monthDay,
  reminderMonth: month,
  createdAt: (createdAt ?? _created).toUtc(),
  updatedAt: (createdAt ?? _created).toUtc(),
);

/// [series] with a one-photo check-in on each of [photoDays], and one with no
/// photo on each of [emptyDays].
PhotoSeriesSnapshot _snapshot(
  PhotoSeries series, {
  List<DateTime> photoDays = const [],
  List<DateTime> emptyDays = const [],
}) {
  final checkIns = <PhotoCheckIn>[];
  final images = <PhotoCheckInImage>[];
  for (final (i, day) in [...photoDays, ...emptyDays].indexed) {
    checkIns.add(
      PhotoCheckIn(
        id: 'c$i',
        seriesId: series.id,
        takenOn: day,
        createdAt: _created,
        updatedAt: _created,
      ),
    );
    if (i < photoDays.length) {
      images.add(
        PhotoCheckInImage(
          id: 'i$i',
          checkInId: 'c$i',
          angleId: 'a',
          blobId: 'b$i',
          createdAt: _created,
          updatedAt: _created,
        ),
      );
    }
  }
  return PhotoSeriesSnapshot(
    series: [series],
    checkIns: checkIns,
    images: images,
  );
}

void main() {
  // A Monday.
  final monday = DateTime(2026, 10, 19);

  group('fire time', () {
    test('daily fires every day at the reminder time', () {
      expect(photoReminderFireAt(_series(), monday), DateTime(2026, 10, 19, 9));
    });

    test('weekly fires on the reminder weekday of a Monday week', () {
      expect(
        photoReminderFireAt(
          _series(cadence: TrackerCadence.weekly, weekday: DateTime.wednesday),
          monday,
        ),
        DateTime(2026, 10, 21, 9),
      );
    });

    test('monthly clamps the day to the month', () {
      final series = _series(cadence: TrackerCadence.monthly, monthDay: 31);
      expect(
        photoReminderFireAt(series, DateTime(2026, 10)),
        DateTime(2026, 10, 31, 9),
      );
      expect(
        photoReminderFireAt(series, DateTime(2027, 2)),
        DateTime(2027, 2, 28, 9),
      );
    });

    test('yearly fires on its month and clamped day', () {
      final series = _series(
        cadence: TrackerCadence.yearly,
        month: 2,
        monthDay: 29,
        minutes: 18 * 60 + 30,
      );
      expect(
        photoReminderFireAt(series, DateTime(2027)),
        DateTime(2027, 2, 28, 18, 30),
      );
      expect(
        photoReminderFireAt(series, DateTime(2028)),
        DateTime(2028, 2, 29, 18, 30),
      );
    });
  });

  group('occurrences', () {
    test('nothing is due before the reminder time', () {
      final now = DateTime(2026, 10, 19, 8);
      expect(
        latestPhotoSeriesOccurrence(_series(), now, currentDone: false),
        isNull,
      );
      expect(
        nextPhotoSeriesFire(_series(), now)?.fireAt,
        DateTime(2026, 10, 19, 9),
      );
    });

    test('the period is due once the reminder fires, until it is done', () {
      final now = DateTime(2026, 10, 19, 13);
      expect(
        latestPhotoSeriesOccurrence(_series(), now, currentDone: false)?.key,
        '2026-10-19T09:00',
      );
      expect(
        latestPhotoSeriesOccurrence(_series(), now, currentDone: true),
        isNull,
      );
    });

    test('a done period skips its own alert', () {
      final now = DateTime(2026, 10, 19, 8);
      expect(
        nextPhotoSeriesFire(_series(), now, donePeriod: monday)?.fireAt,
        DateTime(2026, 10, 20, 9),
      );
      final weekly = _series(
        cadence: TrackerCadence.weekly,
        weekday: DateTime.friday,
      );
      expect(
        nextPhotoSeriesFire(weekly, now, donePeriod: monday)?.fireAt,
        DateTime(2026, 10, 30, 9),
      );
    });

    test('a series made after the reminder time waits for the next one', () {
      final series = _series(createdAt: DateTime(2026, 10, 19, 12));
      final now = DateTime(2026, 10, 19, 13);
      expect(
        latestPhotoSeriesOccurrence(series, now, currentDone: false),
        isNull,
      );
      expect(
        nextPhotoSeriesFire(series, now)?.fireAt,
        DateTime(2026, 10, 20, 9),
      );
    });

    test('a missed period is not carried into the next', () {
      // Due all Monday; on Tuesday before 9:00 nothing is.
      expect(
        latestPhotoSeriesOccurrence(
          _series(),
          DateTime(2026, 10, 20, 8),
          currentDone: false,
        ),
        isNull,
      );
    });

    test('a check-in without a photo does not finish the period', () {
      final series = _series();
      expect(
        photoPeriodDone(_snapshot(series, emptyDays: [monday]), series, monday),
        isFalse,
      );
      expect(
        photoPeriodDone(_snapshot(series, photoDays: [monday]), series, monday),
        isTrue,
      );
    });
  });

  group('engine', () {
    late AppDatabase db;
    late DriftReminderRepository repository;
    late DateTime now;
    final engines = <ReminderEngine>[];

    setUp(() {
      db = AppDatabase.inMemory();
      repository = DriftReminderRepository(db);
    });

    tearDown(() async {
      for (final engine in engines) {
        engine.dispose();
      }
      engines.clear();
      await db.close();
    });

    Future<ReminderEngine> engineWith(
      _FakeOs os,
      PhotoSeriesSnapshot photos,
    ) async {
      final engine = ReminderEngine(
        repository: repository,
        os: os,
        deviceId: 'desk',
        onStatesWritten: () {},
        onRulesWritten: () {},
        onLogWritten: (_) {},
        clock: () => now,
      );
      engines.add(engine);
      engine.updateInputs(
        rules: const [],
        bells: const [],
        states: const [],
        tasks: const [],
        events: const [],
        photos: photos,
        removed: false,
      );
      await _settle();
      return engine;
    }

    test(
      'a due series is stickied and alerted; a check-in clears it',
      () async {
        now = DateTime(2026, 10, 19, 13, 5);
        final series = _series();
        final os = _FakeOs();
        final engine = await engineWith(os, _snapshot(series));

        expect(engine.due.map((v) => v.sourceKey), ['photoSeries:s']);
        expect(engine.due.single.title, 'Progress');
        expect(os.shown, ['photoSeries:s']);

        engine.updateInputs(photos: _snapshot(series, photoDays: [monday]));
        await _settle();
        expect(engine.due, isEmpty);
        expect(os.dismissed, ['photoSeries:s']);
      },
    );

    test('a check-in before the reminder time cancels that alert', () async {
      now = DateTime(2026, 10, 19, 8);
      final series = _series();
      final os = _FakeOs(raisesDueAlertsInApp: false);
      final engine = await engineWith(os, _snapshot(series));
      expect(os.schedules.last.single.fireAt, DateTime(2026, 10, 19, 9));

      engine.updateInputs(photos: _snapshot(series, photoDays: [monday]));
      await _settle();
      expect(os.schedules.last.single.fireAt, DateTime(2026, 10, 20, 9));
    });

    test('a series with its reminder off is no source', () async {
      now = DateTime(2026, 10, 19, 13);
      final engine = await engineWith(
        _FakeOs(),
        _snapshot(_series(enabled: false)),
      );
      expect(engine.view('photoSeries:s'), isNull);
      expect(engine.due, isEmpty);
    });
  });

  group('inbox row', () {
    List<NotificationFeedItem> feed(PhotoSeriesSnapshot photos, DateTime now) =>
        buildNotificationFeed(
          tasks: const [],
          events: const [],
          bills: const [],
          photoSeries: photos,
          now: now,
        );

    test('shows while the period is due, scoped to the period', () {
      final items = feed(_snapshot(_series()), DateTime(2026, 10, 19, 13));
      final item = items.single;
      expect(item.type, NotificationItemType.photoSeries);
      expect(item.urgency, NotificationUrgency.semi);
      expect(item.dueAt, DateTime(2026, 10, 19, 9));
      expect(item.dismissalKey, 'photoSeries:s@2026-10-19|semi');
    });

    test('none before the reminder time, once done, or with it off', () {
      final series = _series();
      expect(feed(_snapshot(series), DateTime(2026, 10, 19, 8)), isEmpty);
      expect(
        feed(
          _snapshot(series, photoDays: [monday]),
          DateTime(2026, 10, 19, 13),
        ),
        isEmpty,
      );
      expect(
        feed(_snapshot(_series(enabled: false)), DateTime(2026, 10, 19, 13)),
        isEmpty,
      );
    });

    test('turns important on the last day of a weekly period', () {
      final weekly = _snapshot(_series(cadence: TrackerCadence.weekly));
      expect(
        feed(weekly, DateTime(2026, 10, 24, 12)).single.urgency,
        NotificationUrgency.semi,
      );
      expect(
        feed(weekly, DateTime(2026, 10, 25, 12)).single.urgency,
        NotificationUrgency.important,
      );
    });

    /// The live feed, with a series due all day, and Photos hidden or not.
    Future<List<NotificationFeedItem>> rows({required bool hidden}) async {
      final db = AppDatabase.inMemory();
      addTearDown(db.close);
      final container = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(db),
          syncRepositoryProvider.overrideWithValue(InMemorySyncRepository()),
          weatherApiClientProvider.overrideWithValue(FakeWeatherApiClient()),
        ],
      );
      addTearDown(container.dispose);
      final settings = container.read(settingsRepositoryProvider);
      await settings.saveSettings(
        (await settings.getSettings()).copyWith(
          hiddenNavPages: hidden ? ['/photo-series'] : const [],
        ),
      );
      // Fires at midnight, so it is due whenever the test runs.
      await container
          .read(photoSeriesRepositoryProvider)
          .saveAll(series: [_series(minutes: 0)]);
      return container.read(notificationFeedProvider.future);
    }

    test('the live feed carries the row', () async {
      expect((await rows(hidden: false)).map((item) => item.type), [
        NotificationItemType.photoSeries,
      ]);
    });

    test('no row while Photos is hidden from the rail', () async {
      expect(await rows(hidden: true), isEmpty);
    });
  });
}

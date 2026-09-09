import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/core/utils/ids.dart';
import 'package:voyager/domain/jobs/job_queries.dart';
import 'package:voyager/domain/models/job_models.dart';

JobApplication app({
  String? id,
  String company = 'Datadog',
  String title = 'Software Engineer',
  String status = 'Applied',
  DateTime? dateApplied,
  String? notes,
  String? applicationUrl,
  List<String> seasonIds = const [],
}) {
  final now = utcNow();
  return JobApplication(
    id: id ?? newId(),
    company: company,
    title: title,
    status: status,
    dateApplied: dateApplied ?? DateTime(2026, 8, 20),
    notes: notes,
    applicationUrl: applicationUrl,
    seasonIds: seasonIds,
    createdAt: now,
    updatedAt: now,
  );
}

JobStage stage(String name, int order) {
  final now = utcNow();
  return JobStage(
    id: newId(),
    name: name,
    sortOrder: order,
    createdAt: now,
    updatedAt: now,
  );
}

JobCompany company(String name) {
  final now = utcNow();
  return JobCompany(id: newId(), name: name, createdAt: now, updatedAt: now);
}

void main() {
  group('duplicate detection', () {
    const url = 'https://boards.greenhouse.io/acme/jobs/1';

    test('flags both rows when the posting URL matches', () {
      final a = app(id: 'a', applicationUrl: url);
      final b = app(id: 'b', applicationUrl: url);
      expect(jobDuplicateIds([a, b]), {'a', 'b'});
    });

    test('the scheme, a leading www. and a trailing slash are noise', () {
      final a = app(id: 'a', applicationUrl: 'https://www.acme.com/jobs/1/');
      final b = app(id: 'b', applicationUrl: 'HTTP://Acme.com/jobs/1');
      expect(jobDuplicateIds([a, b]), {'a', 'b'});
    });

    test('the query string is not — it often names the posting', () {
      final a = app(id: 'a', applicationUrl: 'https://acme.com/jobs?id=1');
      final b = app(id: 'b', applicationUrl: 'https://acme.com/jobs?id=2');
      expect(jobDuplicateIds([a, b]), isEmpty);
    });

    test('two roles under one name at one company are not duplicates', () {
      // The point of moving off company+title: a company posts several
      // distinct jobs under the same title, and only the link tells them
      // apart.
      final a = app(id: 'a', applicationUrl: 'https://acme.com/jobs/1');
      final b = app(id: 'b', applicationUrl: 'https://acme.com/jobs/2');
      expect(a.company, b.company);
      expect(a.title, b.title);
      expect(jobDuplicateIds([a, b]), isEmpty);
    });

    test('rows with no URL are never flagged, not even against each other', () {
      final a = app(id: 'a');
      final b = app(id: 'b');
      final c = app(id: 'c', applicationUrl: '   ');
      expect(jobDuplicateIds([a, b, c]), isEmpty);
    });

    test('a lone row is never flagged', () {
      expect(jobDuplicateIds([app(applicationUrl: url)]), isEmpty);
    });
  });

  group('search', () {
    test('matches a substring inside a word', () {
      expect(jobMatchesQuery(app(company: 'Datadog'), 'dog'), isTrue);
    });

    test('searches title, notes and status too', () {
      final application = app(
        company: 'Acme',
        title: 'Backend Intern',
        status: 'Online Assessment',
        notes: 'referred by #alex',
      );
      expect(jobMatchesQuery(application, 'intern'), isTrue);
      expect(jobMatchesQuery(application, 'assessment'), isTrue);
      expect(jobMatchesQuery(application, 'alex'), isTrue);
    });

    test('every term of a multi-token query has to match', () {
      final application = app(company: 'Datadog', title: 'Backend Intern');
      expect(jobMatchesQuery(application, 'datadog intern'), isTrue);
      expect(jobMatchesQuery(application, 'datadog frontend'), isFalse);
    });

    test('an empty or blank query matches everything', () {
      expect(jobMatchesQuery(app(), ''), isTrue);
      expect(jobMatchesQuery(app(), '   '), isTrue);
    });
  });

  group('filtering', () {
    final active = app(id: 'active');
    final archived = app(id: 'archived', seasonIds: const ['retired']);
    final running = app(id: 'running', seasonIds: const ['live']);
    final rejected = app(id: 'rejected', status: 'Rejected');
    const retiredSeasons = {'retired'};

    test('archived rows are hidden by default', () {
      final result = filterJobApplications(
        [active, archived],
        includeArchived: false,
        archivedSeasonIds: retiredSeasons,
        statuses: const {},
        query: '',
      );
      expect(result.map((a) => a.id), ['active']);
    });

    test('include-archived brings them back', () {
      final result = filterJobApplications(
        [active, archived],
        includeArchived: true,
        archivedSeasonIds: retiredSeasons,
        statuses: const {},
        query: '',
      );
      expect(result.map((a) => a.id), ['active', 'archived']);
    });

    test('an application in a season that is still running stays active', () {
      final result = filterJobApplications(
        [active, running, archived],
        includeArchived: false,
        archivedSeasonIds: retiredSeasons,
        statuses: const {},
        query: '',
      );
      expect(result.map((a) => a.id), ['active', 'running']);
    });

    test('status filter and search are ANDed', () {
      final result = filterJobApplications(
        [active, rejected],
        includeArchived: false,
        archivedSeasonIds: const {},
        statuses: const {'Rejected'},
        query: 'datadog',
      );
      expect(result.map((a) => a.id), ['rejected']);
    });
  });

  group('ordering', () {
    JobApplication row(String id, DateTime dateApplied, DateTime createdAt) =>
      JobApplication(
        id: id,
        company: id,
        title: 'SWE',
        status: 'Applied',
        dateApplied: dateApplied,
        createdAt: createdAt,
        updatedAt: createdAt,
      );

    test('a later day comes first', () {
      final older = row('older', DateTime(2026, 8, 19), DateTime(2026, 8, 19));
      final newer = row('newer', DateTime(2026, 8, 20), DateTime(2026, 8, 18));
      final rows = [older, newer]..sort(compareJobApplications);
      expect([for (final r in rows) r.id], ['newer', 'older']);
    });

    test('within one day it is the order they were entered, newest first', () {
      // `dateApplied` is date-only, so a day of bulk applying leaves every row
      // comparing equal on it. Without the `createdAt` tiebreak the order is
      // whatever the unstable sort produced — which is what read as
      // alphabetical-within-the-day.
      final day = DateTime(2026, 8, 20);
      final rows =
          [
            row('zulu', day, DateTime(2026, 8, 20, 9)),
            row('alpha', day, DateTime(2026, 8, 20, 11)),
            row('mike', day, DateTime(2026, 8, 20, 10)),
          ]..sort(compareJobApplications);
      expect([for (final r in rows) r.id], ['alpha', 'mike', 'zulu']);
    });

    test('the tiebreak does not reorder across days', () {
      final rows =
          [
            row('yesterday-late', DateTime(2026, 8, 19), DateTime(2026, 8, 25)),
            row('today-early', DateTime(2026, 8, 20), DateTime(2026, 8, 20)),
          ]..sort(compareJobApplications);
      expect([for (final r in rows) r.id], ['today-early', 'yesterday-late']);
    });
  });

  group('seasons', () {
    JobSeason season(String id, {DateTime? archivedAt}) => JobSeason(
      id: id,
      name: id,
      archivedAt: archivedAt,
      createdAt: DateTime.utc(2025),
      updatedAt: DateTime.utc(2025),
    );

    test('only retired seasons count as archiving', () {
      final seasons = [
        season('live'),
        season('retired', archivedAt: DateTime.utc(2025, 12)),
      ];
      expect(jobArchivedSeasonIds(seasons), {'retired'});
      expect(
        jobIsArchived(
          app(seasonIds: const ['live']),
          jobArchivedSeasonIds(seasons),
        ),
        isFalse,
      );
      expect(
        jobIsArchived(
          app(seasonIds: const ['retired']),
          jobArchivedSeasonIds(seasons),
        ),
        isTrue,
      );
    });

    test('an application under no season is never archived', () {
      expect(jobIsArchived(app(), const {'retired'}), isFalse);
    });

    test('one ended cycle does not archive a row still in a live one', () {
      // Archived only once every season it is filed under has been retired:
      // a row that also belongs to a running cycle is still in play.
      expect(
        jobIsArchived(
          app(seasonIds: const ['retired', 'live']),
          const {'retired'},
        ),
        isFalse,
      );
      expect(
        jobIsArchived(
          app(seasonIds: const ['retired', 'gone']),
          const {'retired', 'gone'},
        ),
        isTrue,
      );
    });

    test('a retired season is no longer offered for new applications', () {
      final seasons = [
        season('live'),
        season('retired', archivedAt: DateTime.utc(2025, 12)),
      ];
      expect(jobSelectableSeasons(seasons).map((s) => s.id), ['live']);
    });
  });

  group('status ordering', () {
    test('follows the stage order, with orphans appended', () {
      final stages = [stage('Applied', 0), stage('Interview', 1)];
      final order = jobStatusDisplayOrder(stages, [
        app(status: 'Ghosted'),
        app(status: 'Interview'),
      ]);
      expect(order, ['Applied', 'Interview', 'Ghosted']);
    });

    test('counts drop statuses nobody is on', () {
      final stages = [stage('Applied', 0), stage('Interview', 1)];
      final counts = jobStatusCounts(stages, [
        app(status: 'Applied'),
        app(status: 'Applied'),
      ]);
      expect(counts, [(status: 'Applied', count: 2)]);
    });

    test('an orphan status still counts and sorts last', () {
      final stages = [stage('Applied', 0)];
      final counts = jobStatusCounts(stages, [
        app(status: 'Ghosted'),
        app(status: 'Applied'),
      ]);
      expect(counts, [
        (status: 'Applied', count: 1),
        (status: 'Ghosted', count: 1),
      ]);
    });
  });

  group('daily counts', () {
    final now = DateTime(2026, 8, 21, 14, 30);

    test('always returns one entry per day, oldest first', () {
      final series = jobDailyCounts(const [], now: now);
      expect(series, hasLength(30));
      expect(series.first.day, DateTime(2026, 7, 23));
      expect(series.last.day, DateTime(2026, 8, 21));
      expect(series.every((entry) => entry.count == 0), isTrue);
    });

    test('buckets on dateApplied, not on when the row was made', () {
      final series = jobDailyCounts([
        app(dateApplied: DateTime(2026, 8, 21)),
        app(dateApplied: DateTime(2026, 8, 21)),
        app(dateApplied: DateTime(2026, 8, 19)),
      ], now: now);
      expect(series.last.count, 2);
      expect(series[27].count, 1);
    });

    test('applications older than the window are dropped', () {
      final series = jobDailyCounts([
        app(dateApplied: DateTime(2026, 1, 1)),
      ], now: now);
      expect(series.every((entry) => entry.count == 0), isTrue);
    });
  });

  group('company suggestions', () {
    final companies = [company('Visa'), company('US Visa'), company('Datadog')];

    test('matches anywhere in the name, case-insensitively', () {
      expect(filterJobCompanies(companies, 'visa').map((c) => c.name), [
        'Visa',
        'US Visa',
      ]);
    });

    test('prefix matches come first', () {
      expect(filterJobCompanies(companies, 'Visa').first.name, 'Visa');
    });

    test('an empty query offers only the companies already applied to', () {
      // The seeded catalogue is ~150 entries; offering it unprompted on focus
      // would bury the handful the user actually uses.
      expect(
        filterJobCompanies(companies, '', recentKeys: const ['visa']).map(
          (c) => c.name,
        ),
        ['Visa'],
      );
    });

    test('with no history an empty query offers nothing at all', () {
      expect(filterJobCompanies(companies, ''), isEmpty);
    });

    test('used companies rank ahead of the seeded catalogue', () {
      // 'US Visa' would sort last on its own — prefix matches come first —
      // but having been applied to outranks that.
      expect(
        filterJobCompanies(companies, 'visa', recentKeys: const ['us visa'])
            .map((c) => c.name),
        ['US Visa', 'Visa'],
      );
    });

    test('several used companies keep their recency order', () {
      expect(
        filterJobCompanies(
          companies,
          '',
          recentKeys: const ['visa', 'datadog'],
        ).map((c) => c.name),
        ['Visa', 'Datadog'],
      );
    });

    test('jobRecentCompanyKeys is newest-first and de-duplicated', () {
      final keys = jobRecentCompanyKeys([
        app(company: 'Datadog', dateApplied: DateTime(2026, 8, 1)),
        app(company: 'Visa', dateApplied: DateTime(2026, 8, 20)),
        app(company: 'visa ', dateApplied: DateTime(2026, 8, 10)),
      ]);
      expect(keys, ['visa', 'datadog']);
    });
  });
}

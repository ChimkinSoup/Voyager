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
  String? seasonId,
}) {
  final now = utcNow();
  return JobApplication(
    id: id ?? newId(),
    company: company,
    title: title,
    status: status,
    dateApplied: dateApplied ?? DateTime(2026, 8, 20),
    notes: notes,
    seasonId: seasonId,
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
    test('flags both rows when company and title match', () {
      final a = app(id: 'a');
      final b = app(id: 'b');
      expect(jobDuplicateIds([a, b]), {'a', 'b'});
    });

    test('company matching is case- and whitespace-insensitive', () {
      final a = app(id: 'a', company: 'Datadog');
      final b = app(id: 'b', company: '  datadog ');
      expect(jobDuplicateIds([a, b]), {'a', 'b'});
    });

    test('a different title is not a duplicate', () {
      final a = app(id: 'a', title: 'Software Engineer');
      final b = app(id: 'b', title: 'Software Engineer II');
      expect(jobDuplicateIds([a, b]), isEmpty);
    });

    test('a lone row is never flagged', () {
      expect(jobDuplicateIds([app()]), isEmpty);
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
    final archived = app(id: 'archived', seasonId: 'season-1');
    final rejected = app(id: 'rejected', status: 'Rejected');

    test('archived rows are hidden by default', () {
      final result = filterJobApplications(
        [active, archived],
        includeArchived: false,
        statuses: const {},
        query: '',
      );
      expect(result.map((a) => a.id), ['active']);
    });

    test('include-archived brings them back', () {
      final result = filterJobApplications(
        [active, archived],
        includeArchived: true,
        statuses: const {},
        query: '',
      );
      expect(result.map((a) => a.id), ['active', 'archived']);
    });

    test('status filter and search are ANDed', () {
      final result = filterJobApplications(
        [active, rejected],
        includeArchived: false,
        statuses: const {'Rejected'},
        query: 'datadog',
      );
      expect(result.map((a) => a.id), ['rejected']);
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

    test('an empty query returns everything, alphabetically', () {
      expect(filterJobCompanies(companies, '').map((c) => c.name), [
        'Datadog',
        'US Visa',
        'Visa',
      ]);
    });
  });
}

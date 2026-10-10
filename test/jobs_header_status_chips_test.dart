// BUG-183: the Jobs header's status chips sat in a horizontal scroller that a
// mouse can't move, so a status past the row's width could be neither seen
// nor filtered by. The chips that don't fit now fold into a "+N" chip whose
// menu lists each with its count and filters like the chips.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/core/theme/voyager_theme.dart';
import 'package:voyager/domain/models/job_experience_snippet.dart';
import 'package:voyager/features/jobs/jobs_header.dart';

import 'narrow_window_harness.dart' show loadRealFonts;

const _statuses = [
  (status: 'Phone Screen', count: 12),
  (status: 'Online Assessment', count: 40),
  (status: 'Onsite', count: 6),
  (status: 'Rejected', count: 241),
  (status: 'Applied', count: 2),
  (status: 'Interview', count: 1),
];

Widget _header({
  required List<({String status, int count})> statusCounts,
  required ValueChanged<String> onStatusTapped,
  Set<String> active = const {},
}) => MaterialApp(
  theme: VoyagerTheme.dark(),
  home: Scaffold(
    body: JobsHeader(
      lifetimeTotal: 304,
      statusCounts: statusCounts,
      dailyCounts: const [],
      stages: const [],
      includeArchived: false,
      onIncludeArchivedChanged: (_) {},
      activeStatuses: active,
      onStatusTapped: onStatusTapped,
      statusColors: (_) => const Color(0xFF888888),
      profileLinkedInUrl: 'https://linkedin.com/in/x',
      profileGitHubUrl: 'https://github.com/x',
      profilePortfolioUrl: 'https://x.dev',
      experienceSnippets: const [
        JobExperienceSnippet(id: 'a', name: 'Initech - QA', description: ''),
        JobExperienceSnippet(id: 'b', name: 'Acme - SWE', description: ''),
      ],
    ),
  ),
);

void _setWindow(WidgetTester tester, double width) {
  tester.view.physicalSize = Size(width, 600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

Finder _chip(String status) => find.text(status);

void main() {
  group('layoutStatusChips', () {
    test('all of them when they fit, with no "+N"', () {
      expect(
        layoutStatusChips(widths: [100, 100], budget: 206, overflowWidth: 30),
        2,
      );
    });

    test('BUG-183 the rest leave room for the "+N" chip', () {
      // Three need 312; two and the "+N" need 206 + 6 + 30.
      expect(
        layoutStatusChips(
          widths: [100, 100, 100],
          budget: 250,
          overflowWidth: 30,
        ),
        2,
      );
      expect(
        layoutStatusChips(
          widths: [100, 100, 100],
          budget: 230,
          overflowWidth: 30,
        ),
        1,
      );
    });

    test('nothing fits: only the "+N" chip', () {
      expect(
        layoutStatusChips(widths: [100, 100], budget: 60, overflowWidth: 30),
        0,
      );
    });
  });

  testWidgets(
    'BUG-183 every status is shown or behind "+N", and filters from there',
    (tester) async {
      await loadRealFonts(tester);
      _setWindow(tester, 1440);
      final tapped = <String>[];
      await tester.pumpWidget(
        _header(statusCounts: _statuses, onStatusTapped: tapped.add),
      );

      final shown = [
        for (final entry in _statuses)
          if (_chip(entry.status).evaluate().isNotEmpty) entry.status,
      ];
      final hidden = _statuses.length - shown.length;
      expect(hidden, greaterThan(0));
      // The leading ones, in order, each whole inside the row.
      expect(shown, [for (final e in _statuses.take(shown.length)) e.status]);
      final more = find.text('+$hidden');
      expect(more, findsOneWidget);
      expect(tester.takeException(), isNull);

      await tester.tap(more);
      await tester.pumpAndSettle();
      for (final entry in _statuses.skip(shown.length)) {
        expect(find.text(entry.status), findsOneWidget);
        expect(find.text('${entry.count}'), findsOneWidget);
      }

      await tester.tap(find.text('Interview'));
      await tester.pumpAndSettle();
      expect(tapped, ['Interview']);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );

  testWidgets(
    'BUG-183 a wide header shows every chip and no "+N"',
    (tester) async {
      await loadRealFonts(tester);
      _setWindow(tester, 2400);
      await tester.pumpWidget(
        _header(
          statusCounts: _statuses.take(3).toList(),
          onStatusTapped: (_) {},
        ),
      );

      for (final entry in _statuses.take(3)) {
        expect(_chip(entry.status), findsOneWidget);
      }
      expect(find.textContaining('+'), findsNothing);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );
}

// The profile copy buttons sit flush against the left of the 30-day chart.
//
// The chart is right-aligned in the header's right half. Its Align used to
// fill the whole half, so the buttons packed in before it landed at the far
// left of that half — stranded mid-row, a long way from the chart.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/features/jobs/jobs_charts.dart';
import 'package:voyager/features/jobs/jobs_header.dart';

Color _grey(String _) => const Color(0xFF888888);

void _ignoreBool(bool _) {}
void _ignoreString(String _) {}

void main() {
  testWidgets('copy buttons sit just left of the chart on a wide window', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1600, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: JobsHeader(
            lifetimeTotal: 3,
            statusCounts: [],
            dailyCounts: [],
            stages: [],
            includeArchived: false,
            onIncludeArchivedChanged: _ignoreBool,
            activeStatuses: {},
            onStatusTapped: _ignoreString,
            statusColors: _grey,
            profileLinkedInUrl: 'https://linkedin.com/in/example',
            profileGitHubUrl: 'https://github.com/example',
            profilePortfolioUrl: 'https://example.com',
          ),
        ),
      ),
    );

    final chart = tester.getRect(find.byType(JobsSparkline));
    final lastButton = tester.getRect(find.byTooltip('Copy Portfolio URL'));

    // The chart stays pinned to the header's right padding...
    expect(chart.right, 1600 - 20);
    // ...and the buttons butt up against its left edge, 12px apart.
    expect(chart.left - lastButton.right, 12);
  });
}

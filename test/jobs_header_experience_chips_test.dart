// The Jobs header's experience copy chips (JOBS_EXPERIENCE_SNIPPETS_HLD.md
// §7, §10): up to three in the user's order, the rest behind a caret menu,
// and a narrow window moves chips into that menu rather than squeezing the
// 30-day chart below its floor. Every copy writes the description exactly —
// an empty one included — and names the snippet in a toast.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/domain/models/job_experience_snippet.dart';
import 'package:voyager/features/jobs/jobs_charts.dart';
import 'package:voyager/features/jobs/jobs_header.dart';

Color _grey(String _) => const Color(0xFF888888);

void _ignoreBool(bool _) {}
void _ignoreString(String _) {}

JobExperienceSnippet _snippet(String id, String name, [String? description]) =>
    JobExperienceSnippet(
      id: id,
      name: name,
      description: description ?? 'Body of $name',
    );

Widget _header(
  List<JobExperienceSnippet> snippets, {
  bool profileLinks = false,
}) => MaterialApp(
  home: Scaffold(
    body: JobsHeader(
      lifetimeTotal: 3,
      statusCounts: const [],
      dailyCounts: const [],
      stages: const [],
      includeArchived: false,
      onIncludeArchivedChanged: _ignoreBool,
      activeStatuses: const {},
      onStatusTapped: _ignoreString,
      statusColors: _grey,
      profileLinkedInUrl: profileLinks ? 'https://linkedin.com/in/x' : null,
      profileGitHubUrl: profileLinks ? 'https://github.com/x' : null,
      profilePortfolioUrl: profileLinks ? 'https://x.dev' : null,
      experienceSnippets: snippets,
    ),
  ),
);

void _setWindow(WidgetTester tester, double width) {
  tester.view.physicalSize = Size(width, 600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

/// Records every clipboard write instead of touching the real one.
List<String> _captureClipboard(WidgetTester tester) {
  final copied = <String>[];
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    SystemChannels.platform,
    (call) async {
      if (call.method == 'Clipboard.setData') {
        copied.add((call.arguments as Map)['text'] as String);
      }
      return null;
    },
  );
  addTearDown(
    () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      null,
    ),
  );
  return copied;
}

Finder _chip(String name) => find.byTooltip('Copy $name');

void main() {
  group('layoutExperienceChips', () {
    test('everything fits at natural width', () {
      final layout = layoutExperienceChips(
        naturalWidths: [80, 100, 120],
        total: 3,
        budget: 1000,
      );
      expect(layout.visible, 3);
      // The cap, untouched: no chip needed truncating.
      expect(layout.maxChipWidth, 160);
    });

    test('never more than three, however wide the budget', () {
      final layout = layoutExperienceChips(
        naturalWidths: [80, 80, 80],
        total: 6,
        budget: 5000,
      );
      expect(layout.visible, 3);
    });

    test('long names share the space evenly once they have to truncate', () {
      final layout = layoutExperienceChips(
        naturalWidths: [200, 200, 200],
        total: 3,
        budget: 3 * 100 + 2 * 6,
      );
      expect(layout.visible, 3);
      expect(layout.maxChipWidth, 100);
    });

    test('a short name keeps its width and the long ones take the rest', () {
      final layout = layoutExperienceChips(
        naturalWidths: [60, 200, 200],
        total: 3,
        budget: 60 + 2 * 110 + 2 * 6,
      );
      expect(layout.visible, 3);
      expect(layout.maxChipWidth, 110);
    });

    test('chips that cannot show 90px spill, leaving room for the caret', () {
      final layout = layoutExperienceChips(
        naturalWidths: [200, 200, 200],
        total: 3,
        budget: 200,
      );
      // Three need 270 + gaps; two need 180 + gap + caret (34) = 220.
      expect(layout.visible, 1);
    });

    test('a name shorter than the floor only needs its own width', () {
      final layout = layoutExperienceChips(
        naturalWidths: [50, 50],
        total: 2,
        budget: 106,
      );
      expect(layout.visible, 2);
    });

    test('no room at all leaves only the caret', () {
      final layout = layoutExperienceChips(
        naturalWidths: [200],
        total: 1,
        budget: 40,
      );
      expect(layout.visible, 0);
    });
  });

  testWidgets('no snippets, no experience chrome', (tester) async {
    _setWindow(tester, 1920);
    await tester.pumpWidget(_header(const [], profileLinks: true));

    expect(find.byTooltip('More experiences'), findsNothing);
    expect(find.byTooltip('Copy an experience'), findsNothing);
    // The profile buttons still sit 12px off the chart, with no gap left
    // behind where the group would be.
    final chart = tester.getRect(find.byType(JobsSparkline));
    final lastButton = tester.getRect(find.byTooltip('Copy Portfolio URL'));
    expect(chart.left - lastButton.right, 12);
  });

  testWidgets('one to three snippets are all chips, in order, with no caret', (
    tester,
  ) async {
    _setWindow(tester, 1920);
    await tester.pumpWidget(
      _header([
        _snippet('a', 'Acme'),
        _snippet('b', 'Beta'),
      ], profileLinks: true),
    );

    final acme = tester.getRect(_chip('Acme'));
    final beta = tester.getRect(_chip('Beta'));
    expect(acme.left, lessThan(beta.left));
    expect(find.byTooltip('More experiences'), findsNothing);

    // Between the profile icons and the chart, 12px from each.
    final lastButton = tester.getRect(find.byTooltip('Copy Portfolio URL'));
    final chart = tester.getRect(find.byType(JobsSparkline));
    expect(acme.left - lastButton.right, 12);
    expect(chart.left - beta.right, 12);
  });

  testWidgets('tapping a chip copies its description and names it', (
    tester,
  ) async {
    _setWindow(tester, 1920);
    final copied = _captureClipboard(tester);
    const body = '  - Built the billing API.\n\n- Cut p99 by 40%.  \n';
    await tester.pumpWidget(_header([_snippet('a', 'Acme - SWE', body)]));

    await tester.tap(_chip('Acme - SWE'));
    await tester.pumpAndSettle();

    expect(copied, [body]);
    expect(find.text('Acme - SWE copied'), findsOneWidget);
    expect(find.byType(SnackBar), findsNothing);
  });

  testWidgets('an empty description still copies, as ""', (tester) async {
    _setWindow(tester, 1920);
    final copied = _captureClipboard(tester);
    await tester.pumpWidget(_header([_snippet('a', 'Blank', '')]));

    await tester.tap(_chip('Blank'));
    await tester.pumpAndSettle();

    expect(copied, ['']);
    expect(find.text('Blank copied'), findsOneWidget);
  });

  testWidgets('four or more: three chips, the rest behind the caret', (
    tester,
  ) async {
    _setWindow(tester, 1920);
    final copied = _captureClipboard(tester);
    await tester.pumpWidget(
      _header([
        for (final name in ['One', 'Two', 'Three', 'Four', 'Five'])
          _snippet(name, name),
      ]),
    );

    for (final name in ['One', 'Two', 'Three']) {
      expect(_chip(name), findsOneWidget);
    }
    expect(_chip('Four'), findsNothing);
    expect(_chip('Five'), findsNothing);

    await tester.tap(find.byTooltip('More experiences'));
    await tester.pumpAndSettle();
    // The menu lists exactly the ones without a chip.
    expect(find.text('Four'), findsOneWidget);
    expect(find.text('Five'), findsOneWidget);
    expect(find.text('One'), findsOneWidget); // the chip, not a menu row

    await tester.tap(find.text('Four'));
    await tester.pumpAndSettle();

    expect(copied, ['Body of Four']);
    expect(find.text('Four copied'), findsOneWidget);
  });

  testWidgets('reordering in Settings changes which snippets are chips', (
    tester,
  ) async {
    _setWindow(tester, 1920);
    final list = [
      for (final name in ['One', 'Two', 'Three', 'Four']) _snippet(name, name),
    ];
    await tester.pumpWidget(_header(list));
    expect(_chip('Four'), findsNothing);

    await tester.pumpWidget(_header([list[3], ...list.take(3)]));
    expect(_chip('Four'), findsOneWidget);
    expect(_chip('Three'), findsNothing);
    expect(
      tester.getRect(_chip('Four')).left,
      lessThan(tester.getRect(_chip('One')).left),
    );
  });

  testWidgets('a narrow window moves chips into the menu, not the chart', (
    tester,
  ) async {
    _setWindow(tester, 1280);
    const long = 'Acme Corporation - SWE';
    await tester.pumpWidget(
      _header([
        _snippet('a', '$long A'),
        _snippet('b', '$long B'),
        _snippet('c', '$long C'),
      ], profileLinks: true),
    );

    // Not all three fit at a readable width beside the icons and the chart.
    expect(_chip('$long C'), findsNothing);
    expect(find.byTooltip('More experiences'), findsOneWidget);
    for (final name in ['$long A', '$long B']) {
      expect(tester.getSize(_chip(name)).width, greaterThanOrEqualTo(90));
    }
    // And the chart is left at least its floor.
    expect(
      tester.getSize(find.byType(JobsSparkline)).width,
      greaterThanOrEqualTo(140),
    );
    expect(tester.takeException(), isNull);
  });
}

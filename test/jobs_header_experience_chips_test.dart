// The Jobs header's experience copy chips (JOBS_EXPERIENCE_SNIPPETS_HLD.md
// §7, §10): up to three in the user's order, the rest behind a caret menu,
// and a narrow window moves chips into that menu rather than squeezing the
// 30-day chart below its floor. Every copy writes the description exactly —
// an empty one included — and names the snippet in a toast.

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/core/theme/voyager_theme.dart';
import 'package:voyager/domain/models/job_experience_snippet.dart';
import 'package:voyager/features/jobs/jobs_charts.dart';
import 'package:voyager/features/jobs/jobs_header.dart';

import 'narrow_window_harness.dart' show loadRealFonts;

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
  ThemeData? theme,
}) => MaterialApp(
  theme: theme,
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
      final visible = layoutExperienceChips(
        naturalWidths: [80, 100, 120],
        total: 3,
        budget: 1000,
      );
      expect(visible, 3);
    });

    test('never more than three, however wide the budget', () {
      final visible = layoutExperienceChips(
        naturalWidths: [80, 80, 80],
        total: 6,
        budget: 5000,
      );
      expect(visible, 3);
    });

    test('a name past the cap needs only the cap', () {
      final visible = layoutExperienceChips(
        naturalWidths: [200, 200, 200],
        total: 3,
        budget: 3 * 160 + 2 * 6,
      );
      expect(visible, 3);
    });

    test(
      'BUG-184 a chip that cannot show its whole name moves to the menu',
      () {
        // The 1440px header: three chips would have been cut to ~100px each.
        final visible = layoutExperienceChips(
          naturalWidths: [107, 147, 160],
          total: 4,
          budget: 241,
        );
        // Two need 254 + gap + caret; one needs 107 + gap + caret.
        expect(visible, 1);
      },
    );

    test('no room at all leaves only the caret', () {
      final visible = layoutExperienceChips(
        naturalWidths: [200],
        total: 1,
        budget: 40,
      );
      expect(visible, 0);
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

    // Not all three fit beside the icons and the chart.
    expect(_chip('$long C'), findsNothing);
    expect(find.byTooltip('More experiences'), findsOneWidget);
    // Those that stayed are not squeezed below the cap their long names
    // reach.
    for (final name in ['$long A', '$long B']) {
      if (_chip(name).evaluate().isEmpty) continue;
      expect(tester.getSize(_chip(name)).width, 160);
    }
    // And the chart is left at least its floor.
    expect(
      tester.getSize(find.byType(JobsSparkline)).width,
      greaterThanOrEqualTo(140),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'BUG-184 at 1440px every chip shows its whole name',
    (tester) async {
      await loadRealFonts(tester);
      _setWindow(tester, 1440);
      await tester.pumpWidget(
        _header(
          [
            _snippet('a', 'Initech - QA'),
            _snippet('b', 'Acme - SWE Intern'),
            _snippet('c', 'Globex - Backend SWE'),
            _snippet('d', 'Hooli - Platform'),
          ],
          profileLinks: true,
          theme: VoyagerTheme.dark(),
        ),
      );

      expect(find.text('Initech - QA'), findsOneWidget);
      for (final element in find.byType(Text).evaluate()) {
        final text = (element.widget as Text).data;
        if (text == null || !text.contains(' - ')) continue;
        final paragraph = element.renderObject! as RenderParagraph;
        expect(paragraph.didExceedMaxLines, isFalse, reason: text);
      }
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );

  testWidgets('BUG-184 tooltips show in the header though the app hides them', (
    tester,
  ) async {
    _setWindow(tester, 1920);
    await tester.pumpWidget(
      TooltipVisibility(
        visible: false,
        child: _header([_snippet('a', 'Acme - SWE')], profileLinks: true),
      ),
    );

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    for (final (target, message) in [
      (_chip('Acme - SWE'), 'Copy Acme - SWE'),
      (find.byTooltip('Copy LinkedIn URL'), 'Copy LinkedIn URL'),
    ]) {
      await mouse.moveTo(tester.getCenter(target));
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pump(const Duration(milliseconds: 300));
      // The message itself, painted in the overlay.
      expect(find.text(message), findsOneWidget, reason: message);
      await mouse.moveTo(Offset.zero);
      await tester.pumpAndSettle();
    }
  });

  // FV-36 follow-up: at the minimum window (720 logical px, ~630 of it the
  // page beside the rail) the profile icons squeeze the chart to ~50px, and
  // "Last 30 days" wrapped onto a second line, down over the chart.
  for (final (width, expected) in [
    (630.0, '30 days'),
    (1920.0, 'Last 30 days'),
  ]) {
    testWidgets(
      'the chart label stays on one line at ${width.toInt()}px',
      (tester) async {
        await loadRealFonts(tester);
        _setWindow(tester, width);
        await tester.pumpWidget(
          _header(
            [_snippet('a', 'Initech - QA'), _snippet('b', 'Acme - SWE Intern')],
            profileLinks: true,
            theme: VoyagerTheme.dark(),
          ),
        );

        final label = find.textContaining('30 days');
        expect(label, findsOneWidget);
        final paragraph = tester.renderObject<RenderParagraph>(label);
        expect(paragraph.didExceedMaxLines, isFalse);
        final oneLine = TextPainter(
          text: TextSpan(text: 'L', style: paragraph.text.style),
          textDirection: TextDirection.ltr,
        )..layout();
        expect(paragraph.size.height, oneLine.height, reason: 'one line');
        expect(tester.widget<Text>(label).data, expected);
        expect(tester.takeException(), isNull);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.windows),
    );
  }
}

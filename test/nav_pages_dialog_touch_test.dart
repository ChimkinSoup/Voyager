// BUG-393: on a phone the Navigation pages dialog's rows started a reorder
// on any swipe, so its list couldn't be scrolled to the last pages, and the
// labels broke mid-word in the 40dp-inset dialog.

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/core/theme/voyager_theme.dart';
import 'package:voyager/domain/models/enums.dart';
import 'package:voyager/features/settings/settings_page.dart';

import 'narrow_window_harness.dart';

void main() {
  testWidgets(
    'on a phone a swipe scrolls the list, and the labels fit one line',
    (tester) async {
      tester.view.physicalSize = const Size(361, 794);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await loadRealFonts(tester);
      final (db, container) = await openHarnessContainer();
      addTearDown(() async {
        container.dispose();
        await db.close();
      });

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: VoyagerTheme.forMode(AppThemeMode.dark),
            home: const Scaffold(body: SettingsPage()),
          ),
        ),
      );
      await settle(tester);
      await tester.tap(find.widgetWithText(Tab, 'Appearance'));
      await settle(tester);
      final page = tester
          .state<ScrollableState>(
            find
                .byWidgetPredicate(
                  (widget) =>
                      widget is Scrollable &&
                      widget.axisDirection == AxisDirection.down,
                )
                .first,
          )
          .position;
      while (find.text('Navigation pages').evaluate().isEmpty &&
          page.pixels < page.maxScrollExtent) {
        page.jumpTo((page.pixels + 200).clamp(0.0, page.maxScrollExtent));
        await settle(tester);
      }
      await tester.ensureVisible(find.text('Navigation pages'));
      await settle(tester);
      await tester.tap(find.text('Navigation pages'));
      await settle(tester);

      final dialog = find.byType(AlertDialog);
      final list = find.descendant(
        of: dialog,
        matching: find.byType(Scrollable),
      );
      final position = tester.state<ScrollableState>(list.first).position;
      final firstRow = find.descendant(
        of: dialog,
        matching: find.text('Journal'),
      );
      final before = tester.getTopLeft(firstRow).dy;

      await tester.drag(firstRow, const Offset(0, -120));
      await settle(tester);

      expect(position.pixels, greaterThan(0), reason: 'the swipe scrolled');
      // And moved nothing: back at the top, Journal still leads.
      position.jumpTo(0);
      await settle(tester);
      expect(tester.getTopLeft(firstRow).dy, moreOrLessEquals(before));

      for (final label in const ['Calendar', 'Analytics', 'LeetCode']) {
        final paragraph = tester.renderObject<RenderParagraph>(
          find.descendant(of: dialog, matching: find.text(label)),
        );
        // One line, and not cut short by an ellipsis.
        final lineTops = paragraph
            .getBoxesForSelection(
              TextSelection(baseOffset: 0, extentOffset: label.length),
            )
            .map((box) => box.top)
            .toSet();
        expect(lineTops, hasLength(1), reason: label);
        expect(paragraph.didExceedMaxLines, isFalse, reason: label);
      }
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );
}

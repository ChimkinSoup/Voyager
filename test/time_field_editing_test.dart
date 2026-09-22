// Typing a time is meant to feel the same wherever a time is typed. The
// reminder editor's own popovers had been left out of that: they took raw
// text, so "8:00 PM" with the caret at the end needed three backspaces to
// lose its meridiem — one per character — while the date+time popover the
// calendar and todo panels open dropped the whole " PM" on the first press.
// Opening one was uneven too: the date+time popover came up with the time
// selected and ready to be replaced, the reminder ones came up with a bare
// caret, so the first digit typed was appended to a time the user was trying
// to overwrite.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/core/utils/time_format.dart';
import 'package:voyager/core/widgets/time_selector_popovers.dart';
import 'package:voyager/core/widgets/time_text_input_formatter.dart';

void main() {
  final eightPm = DateTime(2026, 9, 21, 20, 0);

  Future<void> pump(WidgetTester tester, Widget child) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: Center(child: child)),
      ),
    );
    await tester.pump();
  }

  /// The field's own view of itself: what it shows and where the caret sits.
  TextEditingValue valueOf(WidgetTester tester, Finder field) =>
      tester.widget<EditableText>(field).controller.value;

  /// A single backspace with the caret collapsed at [caret], the way the
  /// platform reports it — text already shortened, formatters yet to run.
  Future<void> backspace(
    WidgetTester tester,
    Finder field,
    String textAfter,
    int caret,
  ) async {
    tester
        .state<EditableTextState>(field)
        .updateEditingValue(
          TextEditingValue(
            text: textAfter,
            selection: TextSelection.collapsed(offset: caret),
          ),
        );
    await tester.pump();
  }

  group('TimeSelectorPopover (reminder time)', () {
    testWidgets('opens with the time selected so typing replaces it', (
      tester,
    ) async {
      await pump(tester, TimeSelectorPopover(initialTime: eightPm));

      final value = valueOf(tester, find.byType(EditableText));
      expect(value.text, '8:00 PM');
      expect(
        value.selection,
        const TextSelection(baseOffset: 0, extentOffset: 7),
      );
    });

    testWidgets('one backspace at the end drops the whole meridiem', (
      tester,
    ) async {
      await pump(tester, TimeSelectorPopover(initialTime: eightPm));

      final field = find.byType(EditableText);
      await backspace(tester, field, '8:00 P', 6);

      final value = valueOf(tester, field);
      expect(value.text, '8:00');
      expect(value.selection, const TextSelection.collapsed(offset: 4));
    });
  });

  group('TimeRangePopover (calendar event times)', () {
    testWidgets('opens with the start time selected', (tester) async {
      await pump(
        tester,
        TimeRangePopover(
          initialStart: eightPm,
          initialEnd: eightPm.add(const Duration(hours: 1)),
        ),
      );

      final value = valueOf(tester, find.byType(EditableText).first);
      expect(value.text, '8:00 PM');
      expect(
        value.selection,
        const TextSelection(baseOffset: 0, extentOffset: 7),
      );
    });

    testWidgets('one backspace at the end drops the whole meridiem', (
      tester,
    ) async {
      await pump(
        tester,
        TimeRangePopover(
          initialStart: eightPm,
          initialEnd: eightPm.add(const Duration(hours: 1)),
        ),
      );

      final field = find.byType(EditableText).first;
      await backspace(tester, field, '8:00 P', 6);

      expect(valueOf(tester, field).text, '8:00');
    });
  });

  group('TimeTextInputFormatter', () {
    final formatter = TimeTextInputFormatter();

    TextEditingValue format(
      String before,
      String after,
      int caret, {
      int? fromCaret,
    }) => formatter.formatEditUpdate(
      TextEditingValue(
        text: before,
        selection: TextSelection.collapsed(offset: fromCaret ?? before.length),
      ),
      TextEditingValue(
        text: after,
        selection: TextSelection.collapsed(offset: caret),
      ),
    );

    test('groups bare digits into h:mm', () {
      expect(format('80', '800', 3).text, '8:00');
      expect(format('123', '1230', 4).text, '12:30');
    });

    test('completes a lone a or p into a meridiem', () {
      expect(format('8:00', '8:00p', 5).text, '8:00 PM');
      expect(format('8:00', '8:00a', 5).text, '8:00 AM');
    });

    test('refuses an hour or minute that is out of range', () {
      expect(format('8:0', '8:0 9', 5).text, '8:09');
      expect(format('12:5', '12:59', 5).text, '12:59');
      expect(format('12:59', '12:599', 6).text, '12:59');
    });

    test('backspacing a colon takes the hour digit with it', () {
      expect(format('12:30', '1230', 2, fromCaret: 3).text, '1:30');
    });
  });

  // The three popovers each carried their own byte-identical copy of this
  // parser; they now share one, so it is worth pinning down here.
  group('parseTimeQuery', () {
    final onePm = DateTime(2026, 9, 21, 13, 0);

    test('reads the shorthands a person actually types', () {
      expect(parseTimeQuery('2p', onePm), DateTime(2026, 9, 21, 14, 0));
      expect(parseTimeQuery('1400', onePm), DateTime(2026, 9, 21, 14, 0));
      expect(parseTimeQuery('2:30 PM', onePm), DateTime(2026, 9, 21, 14, 30));
      expect(parseTimeQuery('830', onePm), DateTime(2026, 9, 21, 20, 30));
    });

    test('settles a bare hour on the reading that comes soonest', () {
      expect(parseTimeQuery('3', onePm), DateTime(2026, 9, 21, 15, 0));
      expect(
        parseTimeQuery('3', DateTime(2026, 9, 21, 16, 0)),
        // Earlier in the day, not rolled forward onto tomorrow.
        DateTime(2026, 9, 21, 3, 0),
      );
    });

    test('rejects text that is not a time', () {
      expect(parseTimeQuery('', onePm), isNull);
      expect(parseTimeQuery('pm', onePm), isNull);
      expect(parseTimeQuery('25:00', onePm), isNull);
      expect(parseTimeQuery('8:75', onePm), isNull);
    });
  });
}

// Closing a dialog hands focus back to the field it was opened from, and a
// one-line field on desktop selects all of its text when it regains focus, so
// the next keystroke replaced the draft (BUG-069). showVoyagerDialog puts the
// selection back.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/core/widgets/voyager_dialog.dart';

void main() {
  late TextEditingController first;
  late TextEditingController second;
  late FocusNode firstFocus;
  late FocusNode secondFocus;
  late BuildContext fieldContext;

  setUp(() {
    first = TextEditingController(text: 'draft text');
    second = TextEditingController(text: 'other');
    firstFocus = FocusNode();
    secondFocus = FocusNode();
  });

  tearDown(() {
    first.dispose();
    second.dispose();
    firstFocus.dispose();
    secondFocus.dispose();
  });

  /// Two fields; the first is focused with its caret at offset 10, then a
  /// dialog is opened from it.
  Future<void> openDialogFromFirst(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) {
              fieldContext = context;
              return Column(
                children: [
                  TextField(controller: first, focusNode: firstFocus),
                  TextField(controller: second, focusNode: secondFocus),
                ],
              );
            },
          ),
        ),
      ),
    );
    firstFocus.requestFocus();
    await tester.pump();
    first.selection = const TextSelection.collapsed(offset: 10);
    await tester.pump();

    unawaited(
      showVoyagerDialog<void>(
        context: fieldContext,
        builder: (_) => const AlertDialog(title: Text('A dialog')),
      ),
    );
    await tester.pumpAndSettle();
    expect(firstFocus.hasFocus, isFalse);
  }

  testWidgets(
    'closing a dialog leaves the caret where it was in the field',
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
    (tester) async {
      await openDialogFromFirst(tester);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();

      expect(firstFocus.hasFocus, isTrue);
      expect(first.selection, const TextSelection.collapsed(offset: 10));
    },
  );

  testWidgets(
    'a field focus does not return to keeps no stale selection to restore',
    (tester) async {
      await openDialogFromFirst(tester);

      // Focus goes elsewhere as the dialog closes, so it never comes back to
      // the field the dialog was opened from.
      secondFocus.requestFocus();
      Navigator.of(tester.element(find.byType(AlertDialog))).pop();
      await tester.pumpAndSettle();
      expect(secondFocus.hasFocus, isTrue);

      // Later the user puts the caret somewhere else in the first field.
      first.selection = const TextSelection.collapsed(offset: 3);
      firstFocus.requestFocus();
      await tester.pump();

      expect(first.selection, const TextSelection.collapsed(offset: 3));
    },
  );
}

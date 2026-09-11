// The editor panel's tag box and the dropdown under it: the list narrows the
// way `#` completion does in the journal body, and it never offers a tag the
// entry has just gained or keeps back one it has just lost.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/core/widgets/contextual_popover.dart';
import 'package:voyager/features/rankings/rankings_tags_field.dart';

/// Pumps the field under a host that takes every change straight back, the
/// way the edit panel does once its save lands.
Future<void> _pumpField(
  WidgetTester tester, {
  required List<String> suggestions,
  List<String> tags = const [],
}) async {
  var current = tags;
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Padding(
          padding: const EdgeInsets.all(16),
          child: StatefulBuilder(
            builder: (context, setState) => RankingTagsField(
              tags: current,
              suggestions: suggestions,
              accentColor: Colors.blue,
              onChanged: (next) => setState(() => current = next),
            ),
          ),
        ),
      ),
    ),
  );
}

Finder _offered(String tag) => find.descendant(
  of: find.byType(ContextualPopover),
  matching: find.text(tag),
);

void main() {
  testWidgets('typing narrows the list to tags that start with it', (
    tester,
  ) async {
    await _pumpField(tester, suggestions: ['test', 'arst']);

    await tester.showKeyboard(find.byType(TextField));
    await tester.pumpAndSettle();
    expect(_offered('test'), findsOneWidget);
    expect(_offered('arst'), findsOneWidget);

    // `arst` has a `t` in it, but not at the front.
    await tester.enterText(find.byType(TextField), 't');
    await tester.pumpAndSettle();
    expect(_offered('test'), findsOneWidget);
    expect(_offered('arst'), findsNothing);

    // Commit strips a leading `#`, so the filter looks past it too.
    await tester.enterText(find.byType(TextField), '#a');
    await tester.pumpAndSettle();
    expect(_offered('test'), findsNothing);
    expect(_offered('arst'), findsOneWidget);
  });

  testWidgets('the tag Enter adds leaves the list at once', (tester) async {
    await _pumpField(tester, suggestions: ['test', 'arst']);

    await tester.showKeyboard(find.byType(TextField));
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();

    // On the entry as a chip, and gone from the list without another keystroke.
    expect(find.text('test'), findsOneWidget);
    expect(_offered('test'), findsNothing);
    expect(_offered('arst'), findsOneWidget);
  });

  testWidgets('tapping a chip puts the tag back in the list', (tester) async {
    await _pumpField(tester, tags: ['test'], suggestions: ['test', 'arst']);

    await tester.showKeyboard(find.byType(TextField));
    await tester.pumpAndSettle();
    expect(_offered('test'), findsNothing);

    await tester.tap(find.text('test'));
    await tester.pumpAndSettle();
    expect(_offered('test'), findsOneWidget);
  });
}

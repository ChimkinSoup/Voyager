import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/core/vim/vim_enabled_scope.dart';
import 'package:voyager/core/widgets/labeled_text_field.dart';
import 'package:voyager/core/widgets/tag_highlighted_text_field.dart';
import 'package:voyager/core/widgets/voyager_text_field.dart';

/// Text copied from a Windows app ends its lines in `\r\n`. A one-line field
/// drops the `\n` on its own; the `\r` used to stay behind, invisible, and be
/// saved (BUG-017).
Future<String> _pasteInto(
  WidgetTester tester,
  Widget Function(TextEditingController) build,
  String pasted,
) async {
  final controller = TextEditingController();
  addTearDown(controller.dispose);
  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        home: VimEnabledScope(
          enabled: false,
          child: Scaffold(body: build(controller)),
        ),
      ),
    ),
  );
  await tester.enterText(find.byType(TextField), pasted);
  return controller.text;
}

void main() {
  testWidgets('LabeledTextField: one line keeps no carriage return', (
    tester,
  ) async {
    final text = await _pasteInto(
      tester,
      (c) => LabeledTextField(label: 'Title', controller: c),
      'L1\r\nL2',
    );
    expect(text, 'L1L2');
  });

  testWidgets('LabeledTextField: several lines keep only \\n', (tester) async {
    final text = await _pasteInto(
      tester,
      (c) => LabeledTextField(label: 'Body', controller: c, maxLines: null),
      'L1\r\nL2',
    );
    expect(text, 'L1\nL2');
  });

  testWidgets('TagHighlightedTextField: one line keeps no carriage return', (
    tester,
  ) async {
    final focusNode = FocusNode();
    addTearDown(focusNode.dispose);
    final text = await _pasteInto(
      tester,
      (c) => TagHighlightedTextField(controller: c, focusNode: focusNode),
      'L1\r\nL2',
    );
    expect(text, 'L1L2');
  });

  testWidgets('TagHighlightedTextField: several lines keep only \\n', (
    tester,
  ) async {
    final focusNode = FocusNode();
    addTearDown(focusNode.dispose);
    final text = await _pasteInto(
      tester,
      (c) => TagHighlightedTextField(
        controller: c,
        focusNode: focusNode,
        maxLines: null,
      ),
      'L1\r\nL2',
    );
    expect(text, 'L1\nL2');
  });

  testWidgets('VoyagerTextField: one line gets no line break', (tester) async {
    final text = await _pasteInto(
      tester,
      (c) => VoyagerTextField(controller: c),
      'L1\r\nL2',
    );
    expect(text, 'L1L2');
  });
}

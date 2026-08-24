import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/core/vim/vim_enabled_scope.dart';
import 'package:voyager/core/vim/vim_session.dart';
import 'package:voyager/core/widgets/labeled_text_field.dart';

/// Two Vim fields side by side, for the writes that can land after focus has
/// already moved between them.
///
/// A session resolves the field it is about to write through its host scope.
/// Resolving that from the *global* primary focus is right only while the
/// scope's own field is the focused one — and two paths run after it is not:
/// [VimSession.reset], which is called from the focus listener itself, and the
/// clipboard read behind `<C-v>`, which finishes a frame or two after the key.
/// Both used to write the source field's whole value into the destination
/// field, onChanged and all.
void main() {
  late TextEditingController a;
  late TextEditingController b;
  late FocusNode focusA;
  late FocusNode focusB;
  final List<String> changesB = [];

  setUp(() {
    a = TextEditingController(text: 'AAAA');
    b = TextEditingController(text: 'BBBB');
    focusA = FocusNode(debugLabel: 'A');
    focusB = FocusNode(debugLabel: 'B');
    changesB.clear();
    VimRegister.text = '';
    VimRegister.linewise = false;
  });

  tearDown(() {
    a.dispose();
    b.dispose();
    focusA.dispose();
    focusB.dispose();
  });

  Future<void> pumpFields(WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: VimEnabledScope(
            enabled: true,
            child: Scaffold(
              body: Column(
                children: [
                  LabeledTextField(label: 'A', controller: a, focusNode: focusA),
                  LabeledTextField(
                    label: 'B',
                    controller: b,
                    focusNode: focusB,
                    onChanged: changesB.add,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    focusA.requestFocus();
    await tester.pump();
    a.selection = const TextSelection.collapsed(offset: 0);
    await tester.pump();
  }

  Future<void> typeCommand(WidgetTester tester, String keys) async {
    for (final ch in keys.split('')) {
      await tester.sendKeyEvent(
        LogicalKeyboardKey.knownLogicalKeys.firstWhere(
          (k) => k.keyLabel.toLowerCase() == ch.toLowerCase(),
        ),
      );
      await tester.pump();
    }
  }

  testWidgets('leaving a field in Visual mode does not overwrite the next one',
      (tester) async {
    await pumpFields(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    await typeCommand(tester, 'vl');

    focusB.requestFocus();
    await tester.pump();

    expect(b.text, 'BBBB');
    expect(a.text, 'AAAA');
    // The corruption used to be persisted, because it arrived through
    // `userUpdateTextEditingValue` on the field it landed in.
    expect(changesB, isEmpty);
  });

  testWidgets('a clipboard read that resolves after a focus change is dropped',
      (tester) async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'Clipboard.getData') {
            await Future<void>.delayed(const Duration(milliseconds: 50));
            return <String, dynamic>{'text': 'PASTED'};
          }
          return null;
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null),
    );

    await pumpFields(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyV);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    focusB.requestFocus();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    expect(b.text, 'BBBB');
    expect(changesB, isEmpty);
    // Nor does it land late in the field it was typed in: by then that field
    // is back in Insert and the user has moved on.
    expect(a.text, 'AAAA');
  });
}

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/core/text/preserve_selection_on_app_resume.dart';

void main() {
  group('PreserveSelectionOnAppResume.restoreIfSelectAll', () {
    test('restores a caret when the field was select-all\'d', () {
      final controller = TextEditingController(text: '#array #dp');
      addTearDown(controller.dispose);
      const saved = TextSelection.collapsed(offset: 7);
      controller.selection = TextSelection(
        baseOffset: 0,
        extentOffset: controller.text.length,
      );

      PreserveSelectionOnAppResume.restoreIfSelectAll(controller, saved);

      expect(controller.selection, saved);
    });

    test('restores a partial range when the field was select-all\'d', () {
      final controller = TextEditingController(text: 'hello world');
      addTearDown(controller.dispose);
      const saved = TextSelection(baseOffset: 1, extentOffset: 5);
      controller.selection = TextSelection(
        baseOffset: 0,
        extentOffset: controller.text.length,
      );

      PreserveSelectionOnAppResume.restoreIfSelectAll(controller, saved);

      expect(controller.selection, saved);
    });

    test('leaves an intentional select-all alone', () {
      final controller = TextEditingController(text: 'keep me');
      addTearDown(controller.dispose);
      final selectAll = TextSelection(
        baseOffset: 0,
        extentOffset: controller.text.length,
      );
      controller.selection = selectAll;

      PreserveSelectionOnAppResume.restoreIfSelectAll(controller, selectAll);

      expect(controller.selection, selectAll);
    });

    test('does nothing when the current selection is not select-all', () {
      final controller = TextEditingController(text: 'abc');
      addTearDown(controller.dispose);
      const current = TextSelection.collapsed(offset: 2);
      controller.selection = current;

      PreserveSelectionOnAppResume.restoreIfSelectAll(
        controller,
        const TextSelection.collapsed(offset: 0),
      );

      expect(controller.selection, current);
    });

    test('clamps a saved caret that outlives a shorter text', () {
      final controller = TextEditingController(text: 'ab');
      addTearDown(controller.dispose);
      controller.selection = const TextSelection(
        baseOffset: 0,
        extentOffset: 2,
      );

      PreserveSelectionOnAppResume.restoreIfSelectAll(
        controller,
        const TextSelection.collapsed(offset: 99),
      );

      expect(controller.selection, const TextSelection.collapsed(offset: 2));
    });
  });

  group('PreserveSelectionOnAppResume widget', () {
    Future<void> setAppLifecycleState(AppLifecycleState state) async {
      final message = const StringCodec().encodeMessage(state.toString());
      await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .handlePlatformMessage('flutter/lifecycle', message, (_) {});
    }

    testWidgets(
      'Alt-Tab back keeps the caret in a single-line field',
      (tester) async {
        final controller = TextEditingController(text: '#array #hash-table');
        addTearDown(controller.dispose);
        final guard = PreserveSelectionOnAppResume()..install();
        addTearDown(guard.dispose);

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(body: TextField(controller: controller)),
          ),
        );
        await tester.tap(find.byType(TextField));
        await tester.pump();

        const caret = TextSelection.collapsed(offset: 7);
        controller.selection = caret;
        await tester.pump();
        expect(controller.selection, caret);

        await setAppLifecycleState(AppLifecycleState.inactive);
        await tester.pump();

        // Simulate the select-all that still races past Flutter's own
        // `_justResumed` guard on some desktop focus paths.
        controller.selection = TextSelection(
          baseOffset: 0,
          extentOffset: controller.text.length,
        );

        await setAppLifecycleState(AppLifecycleState.resumed);
        await tester.pump();
        // Microtask + post-frame restore.
        await tester.pump();

        expect(controller.selection, caret);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.windows),
    );

    testWidgets(
      'Tabbing into a single-line field still select-alls',
      (tester) async {
        final first = TextEditingController(text: 'first');
        final second = TextEditingController(text: 'second field');
        addTearDown(first.dispose);
        addTearDown(second.dispose);
        final guard = PreserveSelectionOnAppResume()..install();
        addTearDown(guard.dispose);

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Column(
                children: [
                  TextField(controller: first, autofocus: true),
                  TextField(controller: second),
                ],
              ),
            ),
          ),
        );
        await tester.pump();

        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump();

        expect(
          second.selection,
          TextSelection(baseOffset: 0, extentOffset: second.text.length),
        );
      },
      variant: TargetPlatformVariant.only(TargetPlatform.windows),
    );

    testWidgets(
      'multiline fields are left alone',
      (tester) async {
        final controller = TextEditingController(text: 'line one\nline two');
        addTearDown(controller.dispose);
        final guard = PreserveSelectionOnAppResume()..install();
        addTearDown(guard.dispose);

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: TextField(controller: controller, maxLines: 4),
            ),
          ),
        );
        await tester.tap(find.byType(TextField));
        await tester.pump();

        const caret = TextSelection.collapsed(offset: 5);
        controller.selection = caret;
        await tester.pump();

        await setAppLifecycleState(AppLifecycleState.inactive);
        await tester.pump();
        controller.selection = TextSelection(
          baseOffset: 0,
          extentOffset: controller.text.length,
        );
        await setAppLifecycleState(AppLifecycleState.resumed);
        await tester.pump();
        await tester.pump();

        // Guard does not track multiline fields, so the artificial select-all
        // must remain.
        expect(
          controller.selection,
          TextSelection(baseOffset: 0, extentOffset: controller.text.length),
        );
      },
      variant: TargetPlatformVariant.only(TargetPlatform.windows),
    );
  });
}

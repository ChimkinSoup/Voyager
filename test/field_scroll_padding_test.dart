import 'package:flutter/material.dart';
import 'package:flutter_code_editor/flutter_code_editor.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/core/vim/vim_enabled_scope.dart';
import 'package:voyager/core/widgets/field_scroll_padding.dart';
import 'package:voyager/core/widgets/labeled_text_field.dart';
import 'package:voyager/core/widgets/tag_highlighted_text_field.dart';
import 'package:voyager/core/widgets/voyager_text_field.dart';
import 'package:voyager/features/leetcode/leetcode_code_field.dart';

Future<void> _pumpField(WidgetTester tester, Widget field) async {
  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        home: VimEnabledScope(
          enabled: false,
          child: Scaffold(body: field),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('VoyagerTextField uses zero caret scroll padding', (tester) async {
    await _pumpField(tester, const VoyagerTextField());
    expect(
      tester.widget<TextField>(find.byType(TextField)).scrollPadding,
      kVoyagerFieldScrollPadding,
    );
  });

  testWidgets('LabeledTextField uses zero caret scroll padding', (tester) async {
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    await _pumpField(
      tester,
      LabeledTextField(label: 'Title', controller: controller),
    );
    expect(
      tester.widget<TextField>(find.byType(TextField)).scrollPadding,
      kVoyagerFieldScrollPadding,
    );
  });

  testWidgets('TagHighlightedTextField uses zero caret scroll padding',
      (tester) async {
    final controller = TextEditingController();
    final focusNode = FocusNode();
    addTearDown(controller.dispose);
    addTearDown(focusNode.dispose);
    await _pumpField(
      tester,
      TagHighlightedTextField(controller: controller, focusNode: focusNode),
    );
    expect(
      tester.widget<TextField>(find.byType(TextField)).scrollPadding,
      kVoyagerFieldScrollPadding,
    );
  });

  testWidgets('LeetCode code editor uses zero caret scroll padding',
      (tester) async {
    final controller = CodeController(text: 'x = 1');
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: VimEnabledScope(
            enabled: false,
            child: Scaffold(
              body: LeetCodeCodeInput(
                controller: controller,
                language: 'python',
                onLanguageChanged: (_) {},
              ),
            ),
          ),
        ),
      ),
    );
    // Line numbers are IgnorePointer; the editable code box is last.
    expect(
      tester.widget<TextField>(find.byType(TextField).last).scrollPadding,
      kVoyagerFieldScrollPadding,
    );
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });

  testWidgets(
    'focused VoyagerTextField at top of bouncing scroll does not jitter',
    (tester) async {
      final scrollController = ScrollController();
      addTearDown(scrollController.dispose);

      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: VimEnabledScope(
              enabled: false,
              child: Scaffold(
                body: SizedBox(
                  height: 400,
                  child: SingleChildScrollView(
                    controller: scrollController,
                    physics: const BouncingScrollPhysics(
                      decelerationRate: ScrollDecelerationRate.fast,
                      parent: RangeMaintainingScrollPhysics(),
                    ),
                    child: const Column(
                      children: [
                        VoyagerTextField(
                          autofocus: true,
                          decoration: InputDecoration(labelText: 'Title'),
                        ),
                        SizedBox(height: 2000),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.tap(find.byType(TextField));
      await tester.pump();

      expect(scrollController.offset, 0);

      for (var i = 0; i < 12; i++) {
        await tester.pump(const Duration(milliseconds: 50));
        expect(
          scrollController.offset,
          0,
          reason: 'scroll offset jittered to ${scrollController.offset} on frame $i',
        );
      }
    },
  );
}

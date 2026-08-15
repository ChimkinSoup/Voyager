import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/core/vim/vim_enabled_scope.dart';
import 'package:voyager/core/widgets/labeled_text_field.dart';
import 'package:voyager/core/widgets/selection_highlight_layer.dart';
import 'package:voyager/core/widgets/tag_highlighted_text_field.dart';
import 'package:voyager/core/widgets/voyager_text_field.dart';
import 'package:voyager/features/leetcode/leetcode_code_field.dart';

/// [SelectionHighlightLayer] only replaces Flutter's highlight on fields that
/// can show what is wrong with it — a paragraph that wraps or breaks. A
/// single-line field has exactly one line, so its widest line *is* the line
/// being selected and there is no row below to leave a seam against; it keeps
/// the native highlight, and the two must not both paint.
void main() {
  late TextEditingController controller;
  late FocusNode focusNode;

  setUp(() {
    controller = TextEditingController(text: 'first line\nsecond line');
    focusNode = FocusNode();
  });

  tearDown(() {
    controller.dispose();
    focusNode.dispose();
  });

  Future<void> pump(WidgetTester tester, Widget field) async {
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: VimEnabledScope(
            enabled: false,
            child: Scaffold(
              body: SizedBox(width: 400, height: 300, child: field),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byType(TextField));
    await tester.pump();
  }

  /// The selection colour the real [TextField] resolves, after any
  /// [TextSelectionTheme] the wrapper installs over it.
  Color? fieldSelectionColor(WidgetTester tester) {
    return TextSelectionTheme.of(
      tester.element(find.byType(TextField).first),
    ).selectionColor;
  }

  group('multi-line fields paint their own selection', () {
    testWidgets('TagHighlightedTextField', (tester) async {
      await pump(
        tester,
        TagHighlightedTextField(
          controller: controller,
          focusNode: focusNode,
          maxLines: null,
        ),
      );
      expect(find.byType(SelectionHighlightLayer), findsOneWidget);
      expect(fieldSelectionColor(tester), Colors.transparent);
    });

    testWidgets('VoyagerTextField', (tester) async {
      await pump(
        tester,
        VoyagerTextField(controller: controller, maxLines: null),
      );
      expect(find.byType(SelectionHighlightLayer), findsOneWidget);
      expect(fieldSelectionColor(tester), Colors.transparent);
    });

    testWidgets('LabeledTextField', (tester) async {
      await pump(
        tester,
        LabeledTextField(
          label: 'Body',
          controller: controller,
          maxLines: null,
        ),
      );
      expect(find.byType(SelectionHighlightLayer), findsOneWidget);
      expect(fieldSelectionColor(tester), Colors.transparent);
    });
  });

  group('single-line fields keep Flutter\'s selection', () {
    testWidgets('TagHighlightedTextField', (tester) async {
      await pump(
        tester,
        TagHighlightedTextField(
          controller: controller,
          focusNode: focusNode,
        ),
      );
      expect(find.byType(SelectionHighlightLayer), findsNothing);
      expect(fieldSelectionColor(tester), isNot(Colors.transparent));
    });

    testWidgets('VoyagerTextField', (tester) async {
      await pump(tester, VoyagerTextField(controller: controller));
      expect(find.byType(SelectionHighlightLayer), findsNothing);
      expect(fieldSelectionColor(tester), isNot(Colors.transparent));
    });

    testWidgets('LabeledTextField', (tester) async {
      await pump(
        tester,
        LabeledTextField(label: 'Name', controller: controller),
      );
      expect(find.byType(SelectionHighlightLayer), findsNothing);
      expect(fieldSelectionColor(tester), isNot(Colors.transparent));
    });
  });

  testWidgets('a field without a controller is left alone', (tester) async {
    await pump(tester, const VoyagerTextField(maxLines: null));
    expect(find.byType(SelectionHighlightLayer), findsNothing);
    expect(fieldSelectionColor(tester), isNot(Colors.transparent));
  });

  testWidgets('LeetCodeCodeView paints its own selection', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: LeetCodeCodeView(
            code: 'a\n\nb',
            language: 'python',
          ),
        ),
      ),
    );
    await tester.tap(find.byType(TextField).last);
    await tester.pump();

    expect(find.byType(SelectionHighlightLayer), findsOneWidget);
    expect(
      TextSelectionTheme.of(
        tester.element(find.byType(TextField).last),
      ).selectionColor,
      Colors.transparent,
    );
  });
}

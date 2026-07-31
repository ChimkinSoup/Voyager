import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/spellcheck/voyager_spell_check_service.dart';
import 'package:voyager/core/widgets/spell_check_squiggle_layer.dart';

/// Collects (text, hasSquiggle) for each leaf in the rendered [TextSpan]
/// tree, so tests can assert on what's actually painted without reaching
/// into the widget's private cache fields.
List<(String, bool)> _leafSpans(WidgetTester tester) {
  final richText = tester.widget<RichText>(find.byType(RichText).first);
  final root = richText.text as TextSpan;
  final out = <(String, bool)>[];
  void visit(TextSpan span) {
    if (span.text != null && span.text!.isNotEmpty) {
      final hasSquiggle = span.style?.decorationStyle == TextDecorationStyle.wavy;
      out.add((span.text!, hasSquiggle));
    }
    for (final child in span.children ?? const []) {
      visit(child as TextSpan);
    }
  }

  visit(root);
  return out;
}

bool _wordHasSquiggle(WidgetTester tester, String word) {
  final combined = _leafSpans(tester);
  for (final (text, squiggle) in combined) {
    if (text.contains(word) && squiggle) return true;
  }
  return false;
}

void main() {
  Future<void> pumpLayer(
    WidgetTester tester, {
    required VoyagerSpellCheckService service,
    required TextEditingController controller,
    required FocusNode focusNode,
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [voyagerSpellCheckServiceProvider.overrideWithValue(service)],
        child: MaterialApp(
          home: Scaffold(
            body: SpellCheckSquiggleLayer(
              controller: controller,
              focusNode: focusNode,
              style: const TextStyle(fontSize: 16),
            ),
          ),
        ),
      ),
    );
  }

  void typeChar(TextEditingController controller, String ch) {
    final newText = controller.text + ch;
    controller.value = TextEditingValue(
      text: newText,
      selection: TextSelection.collapsed(offset: newText.length),
    );
  }

  testWidgets('hides the squiggle for a word while it is still being typed, '
      'then shows it once finished', (tester) async {
    final service = VoyagerSpellCheckService()..updateDictionary({'hello'});
    final controller = TextEditingController();
    final focusNode = FocusNode();
    addTearDown(controller.dispose);
    addTearDown(focusNode.dispose);

    await pumpLayer(tester, service: service, controller: controller, focusNode: focusNode);

    for (final ch in 'xqz'.split('')) {
      typeChar(controller, ch);
      await tester.pump();
      expect(
        _wordHasSquiggle(tester, 'xqz'),
        isFalse,
        reason: 'still typing "${controller.text}" — nothing should be flagged yet',
      );
    }

    typeChar(controller, ' ');
    await tester.pump();
    expect(_wordHasSquiggle(tester, 'xqz'), isTrue);
  });

  testWidgets('does not flag a correctly spelled word', (tester) async {
    final service = VoyagerSpellCheckService()..updateDictionary({'hello', 'world'});
    final controller = TextEditingController();
    final focusNode = FocusNode();
    addTearDown(controller.dispose);
    addTearDown(focusNode.dispose);

    await pumpLayer(tester, service: service, controller: controller, focusNode: focusNode);

    for (final ch in 'hello world'.split('')) {
      typeChar(controller, ch);
      await tester.pump();
    }
    expect(_wordHasSquiggle(tester, 'hello'), isFalse);
    expect(_wordHasSquiggle(tester, 'world'), isFalse);
  });

  testWidgets('an edit earlier in the text does not disturb a later flagged word', (tester) async {
    final service = VoyagerSpellCheckService()..updateDictionary({'cat', 'dog'});
    final controller = TextEditingController(text: 'cat dog qqzzxx');
    final focusNode = FocusNode();
    addTearDown(controller.dispose);
    addTearDown(focusNode.dispose);

    await pumpLayer(tester, service: service, controller: controller, focusNode: focusNode);
    await tester.pump();
    expect(_wordHasSquiggle(tester, 'qqzzxx'), isTrue);

    // Insert extra text at the very start, shifting "qqzzxx" to the right —
    // exercises the widget's own incremental-cache offset-shifting path.
    controller.value = const TextEditingValue(
      text: 'extra cat dog qqzzxx',
      selection: TextSelection.collapsed(offset: 5),
    );
    await tester.pump();
    expect(_wordHasSquiggle(tester, 'qqzzxx'), isTrue);
    expect(_wordHasSquiggle(tester, 'cat'), isFalse);
    expect(_wordHasSquiggle(tester, 'dog'), isFalse);
  });

  testWidgets('a swap to unrelated text (reused controller) is fully rechecked', (tester) async {
    final service = VoyagerSpellCheckService()..updateDictionary({'hello'});
    final controller = TextEditingController(
      text: 'hello there this is entry one with plenty of words in it',
    );
    final focusNode = FocusNode();
    addTearDown(controller.dispose);
    addTearDown(focusNode.dispose);

    await pumpLayer(tester, service: service, controller: controller, focusNode: focusNode);
    await tester.pump();

    controller.value = const TextEditingValue(
      text: 'a completely different entry with its own unrelated qqzzxx word',
      selection: TextSelection.collapsed(offset: 0),
    );
    await tester.pump();
    expect(_wordHasSquiggle(tester, 'qqzzxx'), isTrue);
    expect(_wordHasSquiggle(tester, 'unrelated'), isTrue);
  });

  testWidgets('picks up a dictionary change on the next real edit via the generation check', (tester) async {
    final service = VoyagerSpellCheckService()..updateDictionary({'hello'});
    final controller = TextEditingController(text: 'hello voyager');
    final focusNode = FocusNode();
    addTearDown(controller.dispose);
    addTearDown(focusNode.dispose);

    await pumpLayer(tester, service: service, controller: controller, focusNode: focusNode);
    await tester.pump();
    expect(_wordHasSquiggle(tester, 'voyager'), isTrue);

    service.updateCustomWords({'voyager'});

    // A real subsequent edit — the generation mismatch should force a full
    // recheck rather than incrementally extending the now-stale cached spans.
    typeChar(controller, '!');
    await tester.pump();
    expect(_wordHasSquiggle(tester, 'voyager'), isFalse);
  });
}

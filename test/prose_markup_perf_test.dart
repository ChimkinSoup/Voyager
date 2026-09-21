import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/core/text/prose_markup.dart';
import 'package:voyager/core/widgets/tag_highlighted_text_field.dart';

/// EMPHASIS_FORMATTING.md §12's performance risk: a field and the five layers
/// stacked around it all lay out the same paragraph, and re-scanning a long
/// journal entry once per layer per keystroke is what the one-entry cache in
/// `ProseEditingController` exists to prevent.
///
/// Counted rather than timed. Wall clock on this machine swings by more than
/// the effect being measured, and the number of parses is the thing the cache
/// actually controls.
void main() {
  /// A body of the size the journal really reaches, with markers throughout so
  /// no early-out in the parser can be doing the work.
  final body = List.generate(
    120,
    (i) =>
        'Paragraph $i with **bold** and *slant* and a #tag-$i in it, '
        'plus `code` and \$x_$i\$ to make the zones do something.',
  ).join('\n\n');

  testWidgets('a keystroke parses the entry once, not once per layer', (
    tester,
  ) async {
    final controller = TextEditingController(text: body);
    final focusNode = FocusNode();
    addTearDown(controller.dispose);
    addTearDown(focusNode.dispose);

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: TagHighlightedTextField(
              controller: controller,
              focusNode: focusNode,
              maxLines: null,
              hintText: 'Body',
            ),
          ),
        ),
      ),
    );
    focusNode.requestFocus();
    await tester.pumpAndSettle();

    proseParseCount = 0;
    controller.value = TextEditingValue(
      text: '$body!',
      selection: TextSelection.collapsed(offset: body.length + 1),
    );
    await tester.pump();

    // One for the new text. The layers that run on the debounced copy ask for
    // the *old* string in the same frame, which the one-entry cache cannot
    // hold at the same time — so two is the honest ceiling, and six (one per
    // consumer) is the regression this guards against.
    expect(proseParseCount, lessThanOrEqualTo(2));
  });

  test('a long entry parses in one pass over it', () {
    // Not a timing assertion — a shape one. Everything the parser records is
    // bounded by the markers actually in the text, so a quadratic scan would
    // show up here as a run that never finishes rather than as a slow number.
    final markup = ProseMarkup.parse(body);
    expect(markup.spans, hasLength(240)); // one bold and one italic per line
    expect(markup.zones, hasLength(360)); // tag, code and math per line
    expect(markup.text, body);
  });
}

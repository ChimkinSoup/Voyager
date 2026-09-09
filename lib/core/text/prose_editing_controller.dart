import 'package:flutter/material.dart';
import 'package:voyager/core/text/prose_markup.dart';
import 'package:voyager/core/text/prose_text_span.dart';
import 'package:voyager/core/text/styled_runs.dart';

/// The controller a prose field hands its [TextField] and its overlay layers,
/// wrapping the plain one the caller owns.
///
/// Emphasis has to be rendered by the field itself: bold is wider than
/// regular, so painting it in a layer above the text would leave the real
/// glyphs unmoved underneath (EMPHASIS_FORMATTING.md §5.2). The only hook for
/// that is [TextEditingController.buildTextSpan] — which lives on the
/// controller, not the widget.
///
/// Rather than push a new controller type out to the ~50 call sites that build
/// these fields, this one *proxies* the caller's: [value] reads and writes
/// straight through, so there is still exactly one source of truth, and
/// everything the caller does with its own controller — autosave listeners,
/// tag completion rewrites, Vim's edits — keeps working untouched. The field
/// wraps whatever it is given, which is also what makes emphasis
/// automatic: §1 asks for it always on in eligible fields, and an opt-in
/// controller type at the call site would instead make a forgotten import a
/// silently unformatted field.
class ProseEditingController extends TextEditingController {
  ProseEditingController({required this.source, required this.focusNode}) {
    source.addListener(_forward);
    // Reveal is a function of the caret, and an unfocused field has none — so
    // blurring has to repaint the markers away. Notifying here rather than
    // rebuilding the field means the overlay layers, which listen to this
    // controller and not to the focus node, come along too.
    focusNode.addListener(_forward);
  }

  /// The controller the caller owns. Never disposed here.
  final TextEditingController source;

  final FocusNode focusNode;

  ProseEmphasisTheme _emphasis = const ProseEmphasisTheme.metrics();

  /// The field's own palette, reassigned on every build. Deliberately not a
  /// notifying setter: the [TextField] reading it is rebuilt by the same build
  /// that sets it.
  set emphasis(ProseEmphasisTheme theme) => _emphasis = theme;

  (String, ProseMarkup)? _recent;
  (String, ProseMarkup)? _older;

  @override
  TextEditingValue get value => source.value;

  @override
  set value(TextEditingValue newValue) => source.value = newValue;

  void _forward() => notifyListeners();

  @override
  void dispose() {
    source.removeListener(_forward);
    focusNode.removeListener(_forward);
    super.dispose();
  }

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    assert(
      !value.composing.isValid || !withComposing || value.isComposingRangeValid,
    );
    final composing = value.composing;
    final showComposing =
        withComposing && value.isComposingRangeValid && !composing.isCollapsed;
    return _span(
      value.text,
      style ?? const TextStyle(),
      _emphasis,
      showComposing
          ? [
              (
                start: composing.start,
                end: composing.end,
                style: const TextStyle(decoration: TextDecoration.underline),
              ),
            ]
          : const [],
    );
  }

  /// The paragraph an overlay layer has to lay out against to line up with the
  /// field, glyph for glyph.
  ///
  /// Takes [text] rather than reading it here because not every layer is
  /// looking at the current value — the `#tag` pills work from a debounced
  /// copy. Reveal is always resolved against the *live* caret, so a layer
  /// running a beat behind on the text is still internally consistent.
  TextSpan overlaySpan(
    String text,
    TextStyle base, {
    List<StyledRange> extra = const [],
  }) => _span(text, base, const ProseEmphasisTheme.metrics(), extra);

  TextSpan _span(
    String text,
    TextStyle base,
    ProseEmphasisTheme theme,
    List<StyledRange> extra,
  ) {
    final markup = _markupFor(text);
    return buildProseSpan(
      markup: markup,
      base: base,
      revealed: focusNode.hasFocus
          ? markup.revealedBy(value.selection)
          : const {},
      theme: theme,
      extra: extra,
    );
  }

  /// Two-entry parse cache. The field and the five layers around it all ask
  /// for the same string within a frame, and re-scanning a long journal entry
  /// once per layer per keystroke is the cost §12 warns about.
  ///
  /// Two entries and not one because they do not *all* ask for the same
  /// string: the `#tag` pills work from a debounced copy, so one frame asks
  /// for the new text, then the old, then the new again — which a single slot
  /// thrashes on, re-scanning the whole entry each time.
  ProseMarkup _markupFor(String text) {
    final recent = _recent;
    if (recent != null && recent.$1 == text) return recent.$2;
    final older = _older;
    if (older != null && older.$1 == text) {
      _older = recent;
      _recent = older;
      return older.$2;
    }
    final parsed = ProseMarkup.parse(text);
    _older = recent;
    _recent = (text, parsed);
    return parsed;
  }
}

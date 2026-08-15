import 'package:flutter/material.dart';
import 'package:flutter_math_fork/flutter_math.dart';
import 'package:voyager/core/widgets/search_highlight_text.dart';

/// Renders card text where `$...$` segments are LaTeX source, e.g.
/// `Solve for x: $x^{2} + 1 = 0$`. Rendering only happens here, at display
/// time — the raw `$...$` source is what's stored and what the editor shows,
/// per STUDY.md ("this doesn't mean LIVE latex").
class StudyRichText extends StatelessWidget {
  const StudyRichText(
    this.text, {
    super.key,
    this.style,
    this.textAlign = TextAlign.start,
    this.keywords = const [],
    this.maxLines,
    this.overflow,
  });

  final String text;
  final TextStyle? style;
  final TextAlign textAlign;

  /// Line cap and overflow handling, forwarded to the underlying text. Set by
  /// callers that render card text into a fixed box, like the deck grid's
  /// tiles.
  final int? maxLines;
  final TextOverflow? overflow;

  /// Search terms to emphasise. Only the prose between `$...$` segments can
  /// carry a highlight — the math renders as widgets, not spans, so a term
  /// that only occurs inside LaTeX source shows up unmarked.
  final List<String> keywords;

  static final _mathPattern = RegExp(r'\$([^$]+)\$');

  @override
  Widget build(BuildContext context) {
    final effectiveStyle = style ?? DefaultTextStyle.of(context).style;
    final matches = _mathPattern.allMatches(text).toList();
    if (matches.isEmpty) {
      return keywordHighlightedText(
        text,
        style: effectiveStyle,
        keywords: keywords,
        textAlign: textAlign,
        maxLines: maxLines,
        overflow: overflow,
      );
    }

    final spans = <InlineSpan>[];
    var cursor = 0;
    for (final match in matches) {
      if (match.start > cursor) {
        spans.addAll(
          keywordSpans(
            text.substring(cursor, match.start),
            effectiveStyle,
            keywords,
          ),
        );
      }
      final tex = match.group(1)!;
      spans.add(
        WidgetSpan(
          alignment: PlaceholderAlignment.middle,
          // Math doesn't line-break: a wide equation lays out at its natural
          // width and overflows whatever box it lands in — loudest in the
          // workbench's miniature tiles. Scaling it down keeps the whole
          // equation on screen instead of striping the tile.
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: Math.tex(
              tex,
              mathStyle: MathStyle.text,
              textStyle: effectiveStyle,
              onErrorFallback: (_) => Text('\$$tex\$', style: effectiveStyle),
            ),
          ),
        ),
      );
      cursor = match.end;
    }
    if (cursor < text.length) {
      spans.addAll(
        keywordSpans(text.substring(cursor), effectiveStyle, keywords),
      );
    }

    return Text.rich(
      TextSpan(style: effectiveStyle, children: spans),
      textAlign: textAlign,
      maxLines: maxLines,
      overflow: overflow ?? TextOverflow.clip,
    );
  }
}

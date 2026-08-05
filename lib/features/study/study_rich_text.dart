import 'package:flutter/material.dart';
import 'package:flutter_math_fork/flutter_math.dart';

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
  });

  final String text;
  final TextStyle? style;
  final TextAlign textAlign;

  static final _mathPattern = RegExp(r'\$([^$]+)\$');

  @override
  Widget build(BuildContext context) {
    final effectiveStyle = style ?? DefaultTextStyle.of(context).style;
    final matches = _mathPattern.allMatches(text).toList();
    if (matches.isEmpty) {
      return Text(text, style: effectiveStyle, textAlign: textAlign);
    }

    final spans = <InlineSpan>[];
    var cursor = 0;
    for (final match in matches) {
      if (match.start > cursor) {
        spans.add(TextSpan(text: text.substring(cursor, match.start)));
      }
      final tex = match.group(1)!;
      spans.add(
        WidgetSpan(
          alignment: PlaceholderAlignment.middle,
          child: Math.tex(
            tex,
            mathStyle: MathStyle.text,
            textStyle: effectiveStyle,
            onErrorFallback: (_) => Text('\$$tex\$', style: effectiveStyle),
          ),
        ),
      );
      cursor = match.end;
    }
    if (cursor < text.length) {
      spans.add(TextSpan(text: text.substring(cursor)));
    }

    return Text.rich(
      TextSpan(style: effectiveStyle, children: spans),
      textAlign: textAlign,
    );
  }
}

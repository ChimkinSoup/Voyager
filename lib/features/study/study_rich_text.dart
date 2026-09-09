import 'package:flutter/material.dart';
import 'package:flutter_math_fork/flutter_math.dart';
import 'package:voyager/core/text/prose_markup.dart';
import 'package:voyager/core/text/prose_text_span.dart';
import 'package:voyager/core/widgets/prose_highlight_underlay.dart';
import 'package:voyager/core/widgets/search_highlight_text.dart';

/// The `![[media:…]]` tokens study cards used to embed images with.
///
/// Nothing writes them any more — images live in the card's front/back
/// gallery (STUDY_IMAGES.md) — but cards authored before that change still
/// carry them in their stored text, so every study surface strips them out
/// on the way to the screen. The trailing newline goes with the token: it was
/// added when the token was inserted, on the assumption the image would be a
/// block of its own.
final _legacyMediaTokenPattern = RegExp(
  r'!\[\[media:[A-Za-z0-9_-]+(?:\|\d+)?\]\]\n?',
);

/// [text] with any legacy embed tokens removed. The images they used to point
/// at are shown by the card's gallery instead.
String stripStudyMediaTokens(String text) =>
    text.contains('![[') ? text.replaceAll(_legacyMediaTokenPattern, '') : text;

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

  @override
  Widget build(BuildContext context) {
    final effectiveStyle = style ?? DefaultTextStyle.of(context).style;
    final source = stripStudyMediaTokens(text);
    // Parsed on the whole card, not on the prose between the equations: the
    // parser's own `$…$` exclusion is what keeps `*` inside math literal, and
    // a `**` pair either side of an equation still applies (§4.3).
    final scheme = Theme.of(context).colorScheme;
    final emphasisTheme = ProseEmphasisTheme.of(scheme, scheme.primary);
    final emphasis = proseReadRanges(source, emphasisTheme);
    // The equations come from the parser rather than a regex of this file's
    // own, so the two can never disagree about where math is. §2.3 fixes the
    // priority as LaTeX, then inline code, then tags, and the zone scanner
    // implements it positionally; a local `\$([^$]+)\$` knows nothing about
    // backticks, so `` `a$b` and $x$ `` had the parser seeing a code span and
    // one equation while this rendered `$b … $x` as an equation — emphasis
    // ranges and math slices computed against different boundaries, layered
    // onto each other wrongly. It also keeps the `$` flanking rule (§6.2, an
    // unpaired `$` is a price) in one place.
    final matches = [
      for (final zone in ProseMarkup.zonesOf(source))
        if (zone.kind == ProseZoneKind.latex) zone,
    ];
    if (matches.isEmpty) {
      return keywordHighlightedText(
        source,
        style: effectiveStyle,
        keywords: keywords,
        textAlign: textAlign,
        maxLines: maxLines,
        overflow: overflow,
        emphasis: emphasis,
        highlightFill: emphasisTheme.highlightColor,
      );
    }

    final spans = <InlineSpan>[];
    var cursor = 0;
    for (final match in matches) {
      // A zone spans the delimiters; the LaTeX source is what sits between.
      final tex = source.substring(match.start + 1, match.end - 1);
      if (match.start > cursor) {
        spans.addAll(
          keywordSpans(
            source.substring(cursor, match.start),
            effectiveStyle,
            keywords,
            emphasis: emphasis,
            offset: cursor,
          ),
        );
      }
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
    if (cursor < source.length) {
      spans.addAll(
        keywordSpans(
          source.substring(cursor),
          effectiveStyle,
          keywords,
          emphasis: emphasis,
          offset: cursor,
        ),
      );
    }

    // `==highlight==` comes back marked, not filled — see
    // [kProseHighlightMark]. The underlay reads the boxes off the paragraph
    // the child laid out, so the equations' `WidgetSpan`s are already placed.
    return ProseHighlightUnderlay(
      color: emphasisTheme.highlightColor!,
      child: Text.rich(
        TextSpan(style: effectiveStyle, children: spans),
        textAlign: textAlign,
        maxLines: maxLines,
        overflow: overflow ?? TextOverflow.clip,
      ),
    );
  }
}

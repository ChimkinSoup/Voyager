import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:voyager/core/text/prose_markup.dart';
import 'package:voyager/core/text/prose_text_span.dart';
import 'package:voyager/core/text/styled_runs.dart';
import 'package:voyager/core/widgets/prose_highlight_underlay.dart';
import 'package:voyager/core/utils/journal_tags.dart';

/// A match-centred window into [text], for a one- or two-line result blurb.
///
/// Without this a blurb is just the opening words, so an entry that matched on
/// something a thousand characters down shows nothing explaining why it's in
/// the list. When a keyword hits, the window starts [leadIn] characters ahead
/// of it (snapped forward to a word boundary) and is marked with a leading `…`.
///
/// The hit sits near the *start* of the window on purpose: callers clip these
/// with `maxLines`, and a match centred in a long window would be clipped away
/// again. Whitespace is collapsed so both visible lines carry text — a body
/// that opens with a short date line would otherwise spend one of them on it.
///
/// The tail is capped at [maxLength] but left un-marked: it's far longer than
/// two lines can show, so the caller's `TextOverflow.ellipsis` is what the
/// reader actually sees, and a `…` here would double up with it.
String searchSnippet(
  String text, {
  List<String> keywords = const [],
  int leadIn = 30,
  int maxLength = 400,
}) {
  final collapsed = text.replaceAll(RegExp(r'\s+'), ' ').trim();
  final needles = _normalizedKeywords(keywords);

  var start = 0;
  if (needles.isNotEmpty) {
    final hit = _nextPatternIndex(collapsed.toLowerCase(), needles, 0);
    if (hit != null && hit > leadIn) {
      start = hit - leadIn;
      final space = collapsed.indexOf(' ', start);
      if (space >= 0 && space + 1 <= hit) start = space + 1;
    }
  }

  final end = math.min(collapsed.length, start + maxLength);
  // Emphasis is resolved against the whole of [collapsed] — which is still the
  // whole document, only respaced — so a pair the window cut through loses its
  // orphaned delimiter rather than showing the reader a raw `**` (§5.3).
  final window = proseSlice(collapsed, start, end);
  return start == 0 ? window : '…$window';
}

/// Rich text for search results with tag pills, keyword emphasis and stored
/// formatting markers rendered (EMPHASIS_FORMATTING.md §10).
///
/// [emphasis] is parsed here rather than by the caller because this is the
/// only place that knows the whole string: the tag pills split it up, and a
/// `**` pair wrapping a tag has one delimiter on each side of the split.
Widget searchHighlightedText(
  String text, {
  required TextStyle style,
  List<String> keywords = const [],
  int? maxLines,
  TextOverflow? overflow,
  int Function(String tag)? tagColorFor,
  ProseEmphasisTheme? emphasisTheme,
  required Brightness brightness,
}) {
  // Required rather than defaulted: a tag pill painted in the dark palette on
  // a light surface is close to invisible, and a default would have made that
  // the quiet outcome at every call site that forgot.
  final colorFor =
      tagColorFor ?? (tag) => resolveTagColor(colorForTag(tag), brightness);

  if (text.isEmpty) {
    return Text('', style: style, maxLines: maxLines, overflow: overflow);
  }

  final emphasis = emphasisTheme == null
      ? const <StyledRange>[]
      : proseReadRanges(text, emphasisTheme);
  // `==highlight==` leaves a mark, not a fill — see [kProseHighlightMark].
  final highlightFill = emphasisTheme?.highlightColor;

  final spans = <InlineSpan>[];
  var cursor = 0;
  for (final match in journalTagPattern.allMatches(text)) {
    if (match.start > cursor) {
      spans.addAll(
        keywordSpans(
          text.substring(cursor, match.start),
          style,
          keywords,
          emphasis: emphasis,
          offset: cursor,
        ),
      );
    }
    final tagName = match.group(1)!;
    final tagText = match.group(0)!;
    final tagColor = Color(colorFor(tagName));
    spans.add(
      WidgetSpan(
        alignment: PlaceholderAlignment.baseline,
        baseline: TextBaseline.alphabetic,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 1),
          decoration: BoxDecoration(
            color: tagColor.withValues(alpha: 0.3),
            borderRadius: BorderRadius.circular(8),
          ),
          // Keywords apply inside the pill too. Without this a plain keyword
          // that only occurs in a tag name (`proj` against `#project-alpha`)
          // matched the entry but emphasised nothing, so the result read as a
          // false positive.
          child: _withHighlightFill(
            highlightFill,
            Text.rich(
              TextSpan(
                children: keywordSpans(
                  tagText,
                  style,
                  keywords,
                  emphasis: emphasis,
                  offset: match.start,
                ),
              ),
            ),
          ),
        ),
      ),
    );
    cursor = match.end;
  }
  if (cursor < text.length) {
    spans.addAll(
      keywordSpans(
        text.substring(cursor),
        style,
        keywords,
        emphasis: emphasis,
        offset: cursor,
      ),
    );
  }

  if (spans.isEmpty) {
    return Text(
      text,
      style: style,
      maxLines: maxLines,
      overflow: overflow,
    );
  }

  return _withHighlightFill(
    highlightFill,
    Text.rich(TextSpan(children: spans), maxLines: maxLines, overflow: overflow),
  );
}

/// [paragraph] under the fill for its `==highlight==` runs, when the surface
/// renders emphasis at all.
Widget _withHighlightFill(Color? fill, Widget paragraph) => fill == null
    ? paragraph
    : ProseHighlightUnderlay(color: fill, child: paragraph);

/// Plain search-result text with every occurrence of [keywords] emphasised.
///
/// The tag-pill-free counterpart to [searchHighlightedText], for results whose
/// text isn't journal prose — a quote or a problem title with a `#` in it is
/// just punctuation there, not a tag.
/// Pass a null [style] to inherit the ambient [DefaultTextStyle] — what a
/// `ListTile` title wants, since the tile styles its own slots and an explicit
/// style here would quietly override that. Give [highlightColor] alongside it,
/// as there's then no base colour to derive the emphasis wash from.
/// [emphasis] is opt-in for the same reason: a quote or a problem title is
/// not journal prose, and its `*` is an asterisk. Pass [highlightFill]
/// alongside it — `==highlight==` leaves a mark rather than a fill, and this
/// is the colour [ProseHighlightUnderlay] paints it in.
Widget keywordHighlightedText(
  String text, {
  TextStyle? style,
  Color? highlightColor,
  List<String> keywords = const [],
  int? maxLines,
  TextOverflow? overflow,
  TextAlign? textAlign,
  List<StyledRange> emphasis = const [],
  Color? highlightFill,
}) {
  final spans = keywordSpans(
    text,
    style,
    keywords,
    highlightColor: highlightColor,
    emphasis: emphasis,
  );
  if (spans.length == 1 && emphasis.isEmpty) {
    return Text(
      text,
      style: style,
      maxLines: maxLines,
      overflow: overflow,
      textAlign: textAlign,
    );
  }
  return _withHighlightFill(
    highlightFill,
    Text.rich(
      TextSpan(children: spans),
      maxLines: maxLines,
      overflow: overflow,
      textAlign: textAlign,
    ),
  );
}

/// Splits [text] so that each run matching one of [keywords] carries the
/// search emphasis and everything else keeps [style].
///
/// Normalises [keywords] itself rather than trusting callers to pass them
/// pre-folded — it's reached from several search surfaces, and a stray
/// uppercase needle would silently match nothing.
///
/// [emphasis] carries the formatting of the *whole* document this slice came
/// from, in document offsets, with [offset] saying where the slice starts in
/// it — see [applyStyledRanges].
List<TextSpan> keywordSpans(
  String text,
  TextStyle? style,
  List<String> keywords, {
  Color? highlightColor,
  List<StyledRange> emphasis = const [],
  int offset = 0,
}) {
  final needles = _normalizedKeywords(keywords);
  if (needles.isEmpty || text.isEmpty) {
    return applyStyledRanges([
      TextSpan(text: text, style: style),
    ], emphasis, offset);
  }

  final patterns = <String>[
    if (needles.length > 1) needles.join(' '),
    ...needles,
  ]..sort((a, b) => b.length.compareTo(a.length));

  final spans = <TextSpan>[];
  var index = 0;
  final lower = text.toLowerCase();

  TextStyle highlightedStyle() => (style ?? const TextStyle()).copyWith(
    backgroundColor: highlightColor ?? style?.color?.withValues(alpha: 0.18),
    fontWeight: FontWeight.w600,
  );

  while (index < text.length) {
    int? hitAt;
    int? hitLen;
    for (final pattern in patterns) {
      if (pattern.isEmpty) continue;
      if (lower.startsWith(pattern, index)) {
        hitAt = index;
        hitLen = pattern.length;
        break;
      }
    }

    if (hitAt == null) {
      final next = _nextPatternIndex(lower, patterns, index);
      if (next == null) {
        spans.add(TextSpan(text: text.substring(index), style: style));
        break;
      }
      spans.add(TextSpan(text: text.substring(index, next), style: style));
      index = next;
      continue;
    }

    spans.add(
      TextSpan(
        text: text.substring(hitAt, hitAt + hitLen!),
        style: highlightedStyle(),
      ),
    );
    index = hitAt + hitLen;
  }

  return applyStyledRanges(
    spans.isEmpty ? [TextSpan(text: text, style: style)] : spans,
    emphasis,
    offset,
  );
}

List<String> _normalizedKeywords(List<String> keywords) => keywords
    .map((k) => k.trim().toLowerCase())
    .where((k) => k.isNotEmpty)
    .toList();

int? _nextPatternIndex(String lower, List<String> patterns, int from) {
  int? best;
  for (final pattern in patterns) {
    if (pattern.isEmpty) continue;
    final i = lower.indexOf(pattern, from);
    if (i >= 0 && (best == null || i < best)) best = i;
  }
  return best;
}

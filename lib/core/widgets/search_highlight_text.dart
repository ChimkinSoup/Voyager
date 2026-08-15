import 'dart:math' as math;

import 'package:flutter/material.dart';
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
  final window = collapsed.substring(start, end);
  return start == 0 ? window : '…$window';
}

/// Rich text for search results with tag pills and keyword emphasis.
Widget searchHighlightedText(
  String text, {
  required TextStyle style,
  List<String> keywords = const [],
  int? maxLines,
  TextOverflow? overflow,
  int Function(String tag)? tagColorFor,
}) {
  final colorFor = tagColorFor ?? colorForTag;

  if (text.isEmpty) {
    return Text('', style: style, maxLines: maxLines, overflow: overflow);
  }

  final spans = <InlineSpan>[];
  var cursor = 0;
  for (final match in journalTagPattern.allMatches(text)) {
    if (match.start > cursor) {
      spans.addAll(
        keywordSpans(text.substring(cursor, match.start), style, keywords),
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
          child: Text(tagText, style: style),
        ),
      ),
    );
    cursor = match.end;
  }
  if (cursor < text.length) {
    spans.addAll(keywordSpans(text.substring(cursor), style, keywords));
  }

  if (spans.isEmpty) {
    return Text(
      text,
      style: style,
      maxLines: maxLines,
      overflow: overflow,
    );
  }

  return Text.rich(
    TextSpan(children: spans),
    maxLines: maxLines,
    overflow: overflow,
  );
}

/// Plain search-result text with every occurrence of [keywords] emphasised.
///
/// The tag-pill-free counterpart to [searchHighlightedText], for results whose
/// text isn't journal prose — a quote or a problem title with a `#` in it is
/// just punctuation there, not a tag.
/// Pass a null [style] to inherit the ambient [DefaultTextStyle] — what a
/// `ListTile` title wants, since the tile styles its own slots and an explicit
/// style here would quietly override that. Give [highlightColor] alongside it,
/// as there's then no base colour to derive the emphasis wash from.
Widget keywordHighlightedText(
  String text, {
  TextStyle? style,
  Color? highlightColor,
  List<String> keywords = const [],
  int? maxLines,
  TextOverflow? overflow,
  TextAlign? textAlign,
}) {
  final spans = keywordSpans(
    text,
    style,
    keywords,
    highlightColor: highlightColor,
  );
  if (spans.length == 1) {
    return Text(
      text,
      style: style,
      maxLines: maxLines,
      overflow: overflow,
      textAlign: textAlign,
    );
  }
  return Text.rich(
    TextSpan(children: spans),
    maxLines: maxLines,
    overflow: overflow,
    textAlign: textAlign,
  );
}

/// Splits [text] so that each run matching one of [keywords] carries the
/// search emphasis and everything else keeps [style].
///
/// Normalises [keywords] itself rather than trusting callers to pass them
/// pre-folded — it's reached from several search surfaces, and a stray
/// uppercase needle would silently match nothing.
List<TextSpan> keywordSpans(
  String text,
  TextStyle? style,
  List<String> keywords, {
  Color? highlightColor,
}) {
  final needles = _normalizedKeywords(keywords);
  if (needles.isEmpty || text.isEmpty) {
    return [TextSpan(text: text, style: style)];
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

  return spans.isEmpty ? [TextSpan(text: text, style: style)] : spans;
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

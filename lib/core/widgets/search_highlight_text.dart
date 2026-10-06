import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:voyager/core/text/prose_markup.dart';
import 'package:voyager/core/text/prose_text_span.dart';
import 'package:voyager/core/text/search_fold.dart';
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
///
/// [fold] finds the hit the way the Search page matches: on [searchFold]ed
/// text with paired delimiters left out, so `foobar` lands on `foo**bar**`
/// (BUG-089) and `cafe` on `café` (BUG-090).
String searchSnippet(
  String text, {
  List<String> keywords = const [],
  int leadIn = 30,
  int maxLength = 400,
  bool fold = false,
}) {
  final collapsed = text.replaceAll(RegExp(r'\s+'), ' ').trim();
  final needles = _normalizedKeywords(keywords, fold: fold);

  var start = 0;
  if (needles.isNotEmpty) {
    var hit = _nextHit(collapsed.toLowerCase(), needles, 0)?.index;
    // The mapped fold costs two body-length lists, so it only runs when the
    // plain search missed and folding could find something it can't.
    if (fold && hit == null && _foldCanDiffer(collapsed)) {
      final folded = searchFoldMapped(
        collapsed,
        skip: proseDelimiterOffsets(collapsed),
      );
      final found = _nextHit(folded.text, needles, 0);
      if (found != null) hit = folded.starts[found.index];
    }
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
  bool fold = false,
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
  // With [fold], the delimiters the emphasis hides, so a keyword is matched
  // against what the reader sees: `foobar` across `foo**bar**` (BUG-089).
  final hidden = !fold || emphasisTheme == null || keywords.isEmpty
      ? const <int>{}
      : _hiddenOffsets(text);
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
          hidden: hidden,
          fold: fold,
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
                  hidden: hidden,
                  fold: fold,
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
        hidden: hidden,
        fold: fold,
      ),
    );
  }

  if (spans.isEmpty) {
    return Text(text, style: style, maxLines: maxLines, overflow: overflow);
  }

  return _withHighlightFill(
    highlightFill,
    Text.rich(
      TextSpan(children: spans),
      maxLines: maxLines,
      overflow: overflow,
    ),
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
/// it — see [applyStyledRanges]. [hidden] holds the delimiters that emphasis
/// hides, in the same offsets; [fold] matching skips them.
///
/// [fold] matches on [searchFold]ed text, so `cafe` emphasises `café` — the
/// Search page's matching. Elsewhere it stays case folding only, since those
/// filters don't fold accents and a highlight they never matched would read
/// as a hit.
List<TextSpan> keywordSpans(
  String text,
  TextStyle? style,
  List<String> keywords, {
  Color? highlightColor,
  List<StyledRange> emphasis = const [],
  int offset = 0,
  Set<int> hidden = const {},
  bool fold = false,
}) {
  final needles = _normalizedKeywords(keywords, fold: fold);
  if (needles.isEmpty || text.isEmpty) {
    return applyStyledRanges(
      [TextSpan(text: text, style: style)],
      emphasis,
      offset,
    );
  }

  final patterns = <String>[
    if (needles.length > 1) needles.join(' '),
    ...needles,
  ]..sort((a, b) => b.length.compareTo(a.length));

  final spans = <TextSpan>[];
  final mapped = fold
      ? searchFoldMapped(text, skip: hidden, skipBase: offset)
      : null;
  final haystack = mapped?.text ?? text.toLowerCase();
  int startOf(int k) => mapped?.starts[k] ?? math.min(k, text.length);
  int endOf(int k) => mapped?.ends[k] ?? math.min(k + 1, text.length);

  TextStyle highlightedStyle() => (style ?? const TextStyle()).copyWith(
    backgroundColor: highlightColor ?? style?.color?.withValues(alpha: 0.18),
    fontWeight: FontWeight.w600,
  );

  var cursor = 0;
  var at = 0;
  while (true) {
    final hit = _nextHit(haystack, patterns, at);
    if (hit == null) break;
    at = hit.index + hit.length;
    // Back in [text]: a folded match can span hidden delimiters and dropped
    // accents, and one source letter can fold to two (`ß`), so a match may
    // begin inside the letter the last one ended on.
    final start = math.max(startOf(hit.index), cursor);
    final end = endOf(at - 1);
    if (end <= start) continue;
    if (start > cursor) {
      spans.add(TextSpan(text: text.substring(cursor, start), style: style));
    }
    spans.add(
      TextSpan(text: text.substring(start, end), style: highlightedStyle()),
    );
    cursor = end;
  }
  if (cursor < text.length) {
    spans.add(TextSpan(text: text.substring(cursor), style: style));
  }

  return applyStyledRanges(
    spans.isEmpty ? [TextSpan(text: text, style: style)] : spans,
    emphasis,
    offset,
  );
}

List<String> _normalizedKeywords(List<String> keywords, {required bool fold}) =>
    keywords
        .map((k) => fold ? searchFold(k.trim()) : k.trim().toLowerCase())
        .where((k) => k.isNotEmpty)
        .toList();

/// Whether [searchFold] or a hidden delimiter could make a match the plain
/// lowercase search misses: anything non-ASCII, or a delimiter character.
bool _foldCanDiffer(String text) {
  for (var i = 0; i < text.length; i++) {
    final unit = text.codeUnitAt(i);
    if (unit >= 0x80 || unit == 0x2A || unit == 0x5F || unit == 0x3D) {
      return true;
    }
  }
  return false;
}

/// [proseDelimiterOffsets], cached the way [proseReadRanges] caches its
/// ranges: the Search page rebuilds every visible row per keystroke, and each
/// row would otherwise re-parse its title and snippet.
Set<int> _hiddenOffsets(String text) {
  final hit = _hiddenOffsetsCache[text];
  if (hit != null) return hit;
  if (_hiddenOffsetsCache.length >= _hiddenOffsetsCacheLimit) {
    _hiddenOffsetsCache.clear();
  }
  return _hiddenOffsetsCache[text] = proseDelimiterOffsets(text);
}

final _hiddenOffsetsCache = <String, Set<int>>{};
const _hiddenOffsetsCacheLimit = 256;

/// The earliest occurrence of any of [patterns] in [folded] at or after
/// [from], taking the longest pattern when several start there.
({int index, int length})? _nextHit(
  String folded,
  List<String> patterns,
  int from,
) {
  int? best;
  var bestLength = 0;
  for (final pattern in patterns) {
    if (pattern.isEmpty) continue;
    final i = folded.indexOf(pattern, from);
    if (i < 0) continue;
    if (best == null ||
        i < best ||
        (i == best && pattern.length > bestLength)) {
      best = i;
      bestLength = pattern.length;
    }
  }
  return best == null ? null : (index: best, length: bestLength);
}

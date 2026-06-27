import 'package:flutter/material.dart';
import 'package:voyager/core/utils/journal_tags.dart';

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
  final lowerKeywords = keywords
      .map((k) => k.trim().toLowerCase())
      .where((k) => k.isNotEmpty)
      .toList();

  if (text.isEmpty) {
    return Text('', style: style, maxLines: maxLines, overflow: overflow);
  }

  final spans = <InlineSpan>[];
  var cursor = 0;
  for (final match in journalTagPattern.allMatches(text)) {
    if (match.start > cursor) {
      spans.addAll(
        _keywordSpans(
          text.substring(cursor, match.start),
          style,
          lowerKeywords,
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
          child: Text(tagText, style: style),
        ),
      ),
    );
    cursor = match.end;
  }
  if (cursor < text.length) {
    spans.addAll(_keywordSpans(text.substring(cursor), style, lowerKeywords));
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

List<TextSpan> _keywordSpans(
  String text,
  TextStyle style,
  List<String> keywords,
) {
  if (keywords.isEmpty || text.isEmpty) {
    return [TextSpan(text: text, style: style)];
  }

  final patterns = <String>[
    if (keywords.length > 1) keywords.join(' '),
    ...keywords,
  ]..sort((a, b) => b.length.compareTo(a.length));

  final spans = <TextSpan>[];
  var index = 0;
  final lower = text.toLowerCase();

  TextStyle highlightedStyle() => style.copyWith(
    backgroundColor: style.color?.withValues(alpha: 0.18),
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

int? _nextPatternIndex(String lower, List<String> patterns, int from) {
  int? best;
  for (final pattern in patterns) {
    if (pattern.isEmpty) continue;
    final i = lower.indexOf(pattern, from);
    if (i >= 0 && (best == null || i < best)) best = i;
  }
  return best;
}

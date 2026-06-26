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

  final spans = <TextSpan>[];
  var index = 0;
  final lower = text.toLowerCase();

  while (index < text.length) {
    int? hitAt;
    int? hitLen;
    for (final keyword in keywords) {
      if (lower.startsWith(keyword, index)) {
        hitAt = index;
        hitLen = keyword.length;
        break;
      }
    }

    if (hitAt == null) {
      final next = _nextKeywordIndex(lower, keywords, index);
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
        style: style.copyWith(
          backgroundColor: style.color?.withValues(alpha: 0.18),
          fontWeight: FontWeight.w600,
        ),
      ),
    );
    index = hitAt + hitLen;
  }

  return spans.isEmpty ? [TextSpan(text: text, style: style)] : spans;
}

int? _nextKeywordIndex(String lower, List<String> keywords, int from) {
  int? best;
  for (final keyword in keywords) {
    final i = lower.indexOf(keyword, from);
    if (i >= 0 && (best == null || i < best)) best = i;
  }
  return best;
}

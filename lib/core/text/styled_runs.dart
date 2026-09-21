import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:voyager/core/text/prose_highlight_paint.dart';

/// A style applied over one range of a paragraph.
typedef StyledRange = ({int start, int end, TextStyle style});

/// Builds the spans for [text] with [ranges] restyled, leaving everything
/// else on [base].
///
/// [ranges] must be sorted and non-overlapping — every caller derives them
/// from a scan of the same string, so that is free to arrange and much
/// cheaper than a general interval merge.
TextSpan buildStyledRuns(
  String text,
  TextStyle base,
  List<StyledRange> ranges,
) {
  if (ranges.isEmpty) return TextSpan(text: text, style: base);
  final children = <InlineSpan>[];
  var cursor = 0;
  for (final range in ranges) {
    final start = range.start.clamp(0, text.length);
    final end = range.end.clamp(start, text.length);
    if (start > cursor) {
      children.add(TextSpan(text: text.substring(cursor, start), style: base));
    }
    if (end > start) {
      children.add(
        TextSpan(
          text: text.substring(start, end),
          style: base.merge(range.style),
        ),
      );
    }
    cursor = math.max(cursor, end);
  }
  if (cursor < text.length) {
    children.add(TextSpan(text: text.substring(cursor), style: base));
  }
  return TextSpan(style: base, children: children);
}

/// [spans] — contiguous, in document order, the first starting at [offset] of
/// the document — with [ranges] merged in on top.
///
/// For the read surfaces that already build their own spans from a scan of
/// their own (search keywords, LeetCode's syntax tokens) and need emphasis
/// laid over the result. [ranges] is in *document* offsets, sorted and
/// non-overlapping, so one parse of the whole text serves every slice — which
/// is the point: a `**` pair straddling a tag pill or a `$…$` is invisible to
/// anything that parses the slices separately.
List<TextSpan> applyStyledRanges(
  List<TextSpan> spans,
  List<StyledRange> ranges,
  int offset,
) {
  if (ranges.isEmpty) return spans;
  final out = <TextSpan>[];
  var at = offset;
  var next = 0;
  for (final span in spans) {
    final text = span.text;
    if (text == null || text.isEmpty) {
      out.add(span);
      continue;
    }
    final end = at + text.length;
    var cursor = 0;
    while (cursor < text.length) {
      while (next < ranges.length && ranges[next].end <= at + cursor) {
        next++;
      }
      if (next >= ranges.length || ranges[next].start >= end) {
        out.add(TextSpan(text: text.substring(cursor), style: span.style));
        break;
      }
      final range = ranges[next];
      final start = math.max(range.start - at, cursor);
      if (start > cursor) {
        out.add(
          TextSpan(text: text.substring(cursor, start), style: span.style),
        );
        cursor = start;
      }
      final stop = math.min(range.end - at, text.length);
      final merged = (span.style ?? const TextStyle()).merge(range.style);
      final wash = span.style?.backgroundColor;
      out.add(
        wash != null && range.style.backgroundColor == kProseHighlightMark
            // Both want the one background slot. A search keyword's wash is
            // real ink; the prose mark is transparent and exists only for
            // `ProseHighlightUnderlay` to find, so it loses — but the run has
            // to still read as *inside* the highlight, or the fill splits
            // around every keyword and rounds each fragment's corners. Hence
            // the nesting: the mark stays on the parent, where
            // [proseHighlightRanges] reads it, and the wash paints from the
            // child. Merged flat, a keyword inside a `==…==` lost its wash
            // entirely and was repainted in the accent fill — a search hit
            // with nothing marked.
            ? TextSpan(
                style: merged.copyWith(backgroundColor: kProseHighlightMark),
                children: [
                  TextSpan(
                    text: text.substring(cursor, stop),
                    style: TextStyle(backgroundColor: wash),
                  ),
                ],
              )
            : TextSpan(text: text.substring(cursor, stop), style: merged),
      );
      cursor = stop;
    }
    at = end;
  }
  return out;
}

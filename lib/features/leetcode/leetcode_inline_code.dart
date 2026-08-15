import 'package:flutter/material.dart';
import 'package:highlight/highlight_core.dart' show Highlight, Node;
import 'package:voyager/core/constants/leetcode_constants.dart';
import 'package:voyager/core/theme/app_fonts.dart';
import 'package:voyager/core/utils/journal_tags.dart';
import 'package:voyager/core/widgets/search_highlight_text.dart';
import 'package:voyager/features/leetcode/leetcode_code_field.dart';

/// A backtick-delimited run inside a piece of prose, as offsets into the
/// *rendered* text — the delimiters are gone by the time these are used.
class InlineCodeRange {
  const InlineCodeRange(this.start, this.end);

  final int start;
  final int end;

  @override
  bool operator ==(Object other) =>
      other is InlineCodeRange && other.start == start && other.end == end;

  @override
  int get hashCode => Object.hash(start, end);

  @override
  String toString() => 'InlineCodeRange($start, $end)';
}

/// Prose with its `` `inline code` `` delimiters stripped and their positions
/// recorded.
class ParsedInlineCode {
  const ParsedInlineCode(this.text, this.codeRanges);

  /// What the reader sees: [text] with every matched backtick pair removed.
  final String text;
  final List<InlineCodeRange> codeRanges;

  bool get hasCode => codeRanges.isNotEmpty;
}

/// Splits prose on `` `code` `` pairs.
///
/// A run opens at a backtick and closes at the next one *on the same line*.
/// The line limit is what keeps a stray backtick — the apostrophe people
/// reach for when they mean `'`, or the leftover edge of a snippet a search
/// snippet cut in half — from swallowing the rest of the card as code. An
/// unmatched backtick, and an empty ` `` ` pair, stay literal text.
ParsedInlineCode parseInlineCode(String source) {
  if (!source.contains('`')) return ParsedInlineCode(source, const []);

  final buffer = StringBuffer();
  final ranges = <InlineCodeRange>[];
  // How much of [buffer] is written, i.e. the next offset in the rendered text.
  var rendered = 0;
  var cursor = 0;

  while (cursor < source.length) {
    final open = source.indexOf('`', cursor);
    if (open < 0) {
      buffer.write(source.substring(cursor));
      break;
    }

    final newline = source.indexOf('\n', open + 1);
    final lineEnd = newline < 0 ? source.length : newline;
    final close = source.indexOf('`', open + 1);

    // No partner before the line ends, or nothing between the two: the
    // backtick is just a character. Resume *after* it so the one that failed
    // to close this run can still open the next.
    if (close < 0 || close >= lineEnd || close == open + 1) {
      buffer.write(source.substring(cursor, open + 1));
      rendered += open + 1 - cursor;
      cursor = open + 1;
      continue;
    }

    buffer.write(source.substring(cursor, open));
    rendered += open - cursor;

    final code = source.substring(open + 1, close);
    buffer.write(code);
    ranges.add(InlineCodeRange(rendered, rendered + code.length));
    rendered += code.length;
    cursor = close + 1;
  }

  return ParsedInlineCode(buffer.toString(), ranges);
}

/// Grammars are registered on first use rather than up front — a card only
/// ever tokenizes its own problem's language, and most decks are one language.
final _highlight = Highlight();
final _registeredLanguages = <String>{};

/// The stored `codeLanguage` reduced to a key [leetCodeHighlightMode] knows,
/// so an unrecognised value can't register Python's grammar under its name.
String _languageKey(String language) =>
    leetCodeCodeLanguages.contains(language) ? language : 'python';

/// Class names per snippet, memoized. The deck's grid rebuilds a tile on every
/// scroll frame and each rebuild would otherwise re-parse the same handful of
/// snippets; the answer only depends on the source and the grammar, so it is
/// cached across rebuilds and thrown away wholesale once it grows.
final _tokenCache = <String, List<(String, String?)>>{};
const _tokenCacheLimit = 512;

/// Splits [code] into styled tokens using [language]'s grammar.
///
/// Returns a single unstyled token when the grammar produces anything other
/// than [code] verbatim: the chip's painted background is positioned from the
/// prose's own offsets, so text that doesn't round-trip would misalign it.
List<(String, TextStyle?)> _tokenize(
  String code,
  String language,
  Map<String, TextStyle> styles,
) {
  final key = _languageKey(language);
  final cached = _tokenCache['$key $code'];
  if (cached != null) {
    return [
      for (final (text, className) in cached)
        (text, className == null ? null : styles[className]),
    ];
  }

  if (_registeredLanguages.add(key)) {
    _highlight.registerLanguage(key, leetCodeHighlightMode(key));
  }

  // Class names, not resolved styles: the cache outlives a light/dark switch,
  // and the palette is looked up fresh on the way out.
  final tokens = <(String, String?)>[];
  void walk(List<Node> nodes, String? inherited) {
    for (final node in nodes) {
      final className = node.className ?? inherited;
      final value = node.value;
      if (value != null) tokens.add((value, className));
      final children = node.children;
      if (children != null) walk(children, className);
    }
  }

  walk(_highlight.parse(code, language: key).nodes ?? const [], null);

  final length = tokens.fold(0, (sum, token) => sum + token.$1.length);
  final result = length == code.length ? tokens : [(code, null)];

  if (_tokenCache.length >= _tokenCacheLimit) _tokenCache.clear();
  _tokenCache['$key $code'] = result;
  return [
    for (final (text, className) in result)
      (text, className == null ? null : styles[className]),
  ];
}

/// A rounded fill painted behind a range of the paragraph.
class _Chip {
  const _Chip({
    required this.start,
    required this.end,
    required this.color,
    required this.radius,
    required this.padding,
  });

  final int start;
  final int end;
  final Color color;
  final double radius;

  /// How far the fill spreads past the glyphs, horizontally and vertically.
  final Offset padding;
}

/// Prose from a LeetCode problem, with `` `inline code` `` set in the code
/// font, tokenized in the code block's own palette, and sat on a rounded
/// translucent chip.
///
/// The chip is painted rather than built from a `WidgetSpan` pill (the way
/// [searchHighlightedText] builds its tag pills) for one reason: a widget is
/// an unbreakable box, so a snippet wider than the card would run off the edge
/// instead of wrapping. Painting behind the paragraph — the pattern
/// `SelectionHighlightLayer` and `VimTextOverlay` already use here — lets the
/// text wrap normally and gives every line of a wrapped run its own chip.
///
/// [CustomPaint] hands the painter the child's size, so the [TextPainter]
/// below lays the identical span tree out at the identical width and every box
/// it reports lands on the real glyphs.
class LeetCodeProseText extends StatelessWidget {
  const LeetCodeProseText(
    this.text, {
    super.key,
    required this.style,
    required this.language,
    this.keywords = const [],
    this.tagPills = false,
    this.maxLines,
    this.overflow,
    this.textAlign,
  });

  final String text;

  /// The prose style. Inline code keeps its size, colour and leading and
  /// changes only family — [AppFonts.monoFamily] shares the body font's
  /// vertical metrics, so a chip mid-sentence doesn't shift the line.
  final TextStyle? style;

  /// The problem's `codeLanguage`, used to tokenize the snippets.
  final String language;

  /// Search terms to emphasise, as [keywordSpans] does elsewhere.
  final List<String> keywords;

  /// Whether `#tag` runs get the tag pill [searchHighlightedText] gives them.
  /// On for the deck's tiles, which already show them; off for the full card,
  /// which never has.
  final bool tagPills;

  final int? maxLines;
  final TextOverflow? overflow;
  final TextAlign? textAlign;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Resolved rather than left to inherit: the painter lays out its own copy
    // of the paragraph, and a span that fell back to the ambient
    // [DefaultTextStyle] would be measured against a different one here.
    final prose = DefaultTextStyle.of(context).style.merge(style);
    final parsed = parseInlineCode(text);

    if (!parsed.hasCode && !tagPills) {
      return Text.rich(
        TextSpan(children: keywordSpans(parsed.text, prose, keywords)),
        maxLines: maxLines,
        overflow: overflow,
        textAlign: textAlign,
      );
    }

    final codeStyle = prose.copyWith(fontFamily: AppFonts.monoFamily);
    final syntax = leetCodeSyntaxStyles(theme.brightness);
    final chipColor = theme.colorScheme.onSurface.withValues(alpha: 0.10);

    final spans = <InlineSpan>[];
    final chips = <_Chip>[];
    var cursor = 0;

    for (final range in parsed.codeRanges) {
      if (range.start > cursor) {
        spans.addAll(
          _proseSpans(parsed.text, cursor, range.start, prose, chips),
        );
      }
      final code = parsed.text.substring(range.start, range.end);
      for (final (token, tokenStyle) in _tokenize(code, language, syntax)) {
        spans.addAll(
          keywordSpans(token, codeStyle.merge(tokenStyle), keywords),
        );
      }
      chips.add(
        _Chip(
          start: range.start,
          end: range.end,
          color: chipColor,
          radius: 4,
          padding: const Offset(2.5, 1),
        ),
      );
      cursor = range.end;
    }
    if (cursor < parsed.text.length) {
      spans.addAll(
        _proseSpans(parsed.text, cursor, parsed.text.length, prose, chips),
      );
    }

    final span = TextSpan(children: spans);
    final paragraph = Text.rich(
      span,
      maxLines: maxLines,
      overflow: overflow,
      textAlign: textAlign,
    );
    if (chips.isEmpty) return paragraph;

    return CustomPaint(
      painter: _ChipPainter(
        span: span,
        chips: chips,
        textAlign: textAlign ?? TextAlign.start,
        textDirection: Directionality.of(context),
        textScaler: MediaQuery.textScalerOf(context),
        textHeightBehavior: DefaultTextHeightBehavior.maybeOf(context),
        maxLines: maxLines,
        ellipsis: overflow == TextOverflow.ellipsis ? '…' : null,
      ),
      child: paragraph,
    );
  }

  /// Spans for `[start, end)` of the prose, adding a chip for each `#tag` in
  /// it when [tagPills] is on. Tags are chips here rather than the
  /// `WidgetSpan` pills of [searchHighlightedText] so they wrap and measure
  /// like the rest of the paragraph — the painter cannot lay out a widget.
  List<InlineSpan> _proseSpans(
    String text,
    int start,
    int end,
    TextStyle prose,
    List<_Chip> chips,
  ) {
    final slice = text.substring(start, end);
    if (!tagPills) return keywordSpans(slice, prose, keywords);

    final spans = <InlineSpan>[];
    var cursor = 0;
    for (final match in journalTagPattern.allMatches(slice)) {
      if (match.start > cursor) {
        spans.addAll(
          keywordSpans(slice.substring(cursor, match.start), prose, keywords),
        );
      }
      spans.addAll(
        keywordSpans(match.group(0)!, prose, keywords),
      );
      chips.add(
        _Chip(
          start: start + match.start,
          end: start + match.end,
          color: Color(colorForTag(match.group(1)!)).withValues(alpha: 0.3),
          radius: 8,
          padding: const Offset(3, 1),
        ),
      );
      cursor = match.end;
    }
    if (cursor < slice.length) {
      spans.addAll(keywordSpans(slice.substring(cursor), prose, keywords));
    }
    return spans;
  }
}

class _ChipPainter extends CustomPainter {
  const _ChipPainter({
    required this.span,
    required this.chips,
    required this.textAlign,
    required this.textDirection,
    required this.textScaler,
    required this.textHeightBehavior,
    required this.maxLines,
    required this.ellipsis,
  });

  final TextSpan span;
  final List<_Chip> chips;
  final TextAlign textAlign;
  final TextDirection textDirection;
  final TextScaler textScaler;
  final TextHeightBehavior? textHeightBehavior;
  final int? maxLines;
  final String? ellipsis;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final painter = TextPainter(
      text: span,
      textAlign: textAlign,
      textDirection: textDirection,
      textScaler: textScaler,
      textHeightBehavior: textHeightBehavior,
      maxLines: maxLines,
      ellipsis: ellipsis,
    )..layout(maxWidth: size.width);

    // A clipped paragraph still reports boxes for the text it dropped, and a
    // chip drawn for a run the reader cannot see would sit on the card as a
    // stray smudge.
    canvas.save();
    canvas.clipRect(Offset.zero & size);
    for (final chip in chips) {
      final paint = Paint()..color = chip.color;
      for (final rect in _lineRects(painter, chip)) {
        canvas.drawRRect(
          RRect.fromRectAndRadius(rect, Radius.circular(chip.radius)),
          paint,
        );
      }
    }
    canvas.restore();
    painter.dispose();
  }

  /// One rect per line the chip's range covers.
  ///
  /// [TextPainter.getBoxesForSelection] returns a box per style run, so a
  /// tokenized snippet comes back as several abutting boxes — drawn
  /// individually they leave pale seams where the translucent fills meet at
  /// the edges. Merging by line gives one fill per line instead, and is also
  /// what lets a wrapped snippet get a chip on each of its lines.
  Iterable<Rect> _lineRects(TextPainter painter, _Chip chip) {
    final boxes = painter.getBoxesForSelection(
      TextSelection(baseOffset: chip.start, extentOffset: chip.end),
    );
    final lines = <double, Rect>{};
    for (final box in boxes) {
      final rect = box.toRect();
      if (rect.isEmpty) continue;
      // Boxes on one line share a top to within rounding; key on it so runs
      // of different token styles merge but wrapped lines stay apart.
      final key = (rect.top * 4).roundToDouble();
      final merged = lines[key];
      lines[key] = merged == null ? rect : merged.expandToInclude(rect);
    }
    return lines.values.map(
      (rect) => Rect.fromLTRB(
        rect.left - chip.padding.dx,
        rect.top - chip.padding.dy,
        rect.right + chip.padding.dx,
        rect.bottom + chip.padding.dy,
      ),
    );
  }

  @override
  bool shouldRepaint(covariant _ChipPainter old) =>
      old.span != span ||
      old.chips != chips ||
      old.textAlign != textAlign ||
      old.textDirection != textDirection ||
      old.textScaler != textScaler ||
      old.maxLines != maxLines ||
      old.ellipsis != ellipsis;
}

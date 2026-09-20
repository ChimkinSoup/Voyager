import 'package:flutter/material.dart';
import 'package:highlight/highlight_core.dart' show Highlight, Node;
import 'package:voyager/core/constants/leetcode_constants.dart';
import 'package:voyager/core/theme/app_fonts.dart';
import 'package:voyager/features/leetcode/leetcode_code_field.dart';
import 'package:voyager/features/leetcode/leetcode_inline_code.dart';

/// A tab's stored `languageKey` reduced to one this build can actually
/// highlight, or null.
///
/// A key the build no longer offers reads as "no language" rather than
/// erroring or being rewritten — the record is left exactly as it is, in case
/// the grammar comes back (§8).
String? cheatLanguageKey(String? languageKey) =>
    languageKey != null && leetCodeCodeLanguages.contains(languageKey)
    ? languageKey
    : null;

final _highlight = Highlight();
final _registered = <String>{};

/// One command, monospace, syntax-highlighted against [languageKey] and with
/// any run matching [keywords] marked.
///
/// Wraps rather than ellipsises: a long command is still the whole command,
/// and Copy takes all of it either way (§8).
class LeetCodeCheatCommandText extends StatelessWidget {
  const LeetCodeCheatCommandText(
    this.command, {
    super.key,
    required this.languageKey,
    required this.style,
    this.keywords = const [],
  });

  final String command;

  /// Null renders plain mono — what a tab with no language, or with one this
  /// build no longer offers, gets.
  final String? languageKey;

  final TextStyle style;

  /// Search terms to mark, as the rest of the app's search surfaces do.
  final List<String> keywords;

  @override
  Widget build(BuildContext context) {
    final mono = style.copyWith(fontFamily: AppFonts.monoFamily);
    if (command.isEmpty) return Text('', style: mono);

    final syntax = leetCodeSyntaxStyles(Theme.of(context).brightness);
    final spans = cheatCommandSpans(
      command,
      languageKey: languageKey,
      base: mono,
      syntax: syntax,
      keywords: keywords,
      highlightColor: Theme.of(
        context,
      ).colorScheme.primary.withValues(alpha: 0.22),
    );
    return Text.rich(TextSpan(children: spans));
  }
}

/// [command] split into spans that carry both its syntax colours and the
/// search emphasis.
///
/// The two are composed over the *whole* string rather than one inside the
/// other: tokenizing first and marking inside each token would miss a needle
/// that straddles a token boundary — searching `new Array` against
/// `new ArrayList<>()`, whose grammar splits it at the space — and marking
/// first would hand the tokenizer text it can no longer parse.
@visibleForTesting
List<TextSpan> cheatCommandSpans(
  String command, {
  required String? languageKey,
  required TextStyle base,
  required Map<String, TextStyle> syntax,
  List<String> keywords = const [],
  Color? highlightColor,
}) {
  final tokens = _tokenizeCommand(command, languageKey, syntax);
  final marked = _matchRanges(command, keywords);
  if (marked.isEmpty) {
    return [
      for (final (text, style) in tokens)
        TextSpan(text: text, style: base.merge(style)),
    ];
  }

  final emphasis = base.copyWith(
    backgroundColor: highlightColor,
    fontWeight: FontWeight.w600,
  );

  // Walk the string once, cutting at every boundary either set introduces, so
  // a token that is half-matched becomes two spans with the same colour and
  // different backgrounds.
  final spans = <TextSpan>[];
  var at = 0;
  for (final (text, style) in tokens) {
    final tokenEnd = at + text.length;
    var cursor = at;
    while (cursor < tokenEnd) {
      final range = _rangeAt(marked, cursor);
      final next = range != null
          ? (range.end < tokenEnd ? range.end : tokenEnd)
          : _nextRangeStart(marked, cursor, tokenEnd);
      spans.add(
        TextSpan(
          text: command.substring(cursor, next),
          style: range != null ? emphasis.merge(style) : base.merge(style),
        ),
      );
      cursor = next;
    }
    at = tokenEnd;
  }
  return spans;
}

/// Tokens as `(text, style)`, in order, covering [command] exactly.
///
/// Falls back to one unstyled token when the grammar does not reproduce
/// [command] verbatim — the same guard `leetcode_inline_code.dart` keeps, for
/// the same reason: offsets computed here have to land on the real glyphs.
List<(String, TextStyle?)> _tokenizeCommand(
  String command,
  String? languageKey,
  Map<String, TextStyle> syntax,
) {
  final key = cheatLanguageKey(languageKey);
  if (key == null) return [(command, null)];

  if (_registered.add(key)) {
    _highlight.registerLanguage(key, leetCodeHighlightMode(key));
  }

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

  walk(_highlight.parse(command, language: key).nodes ?? const [], null);

  final length = tokens.fold(0, (sum, token) => sum + token.$1.length);
  if (length != command.length) return [(command, null)];
  return [
    for (final (text, className) in tokens)
      (text, className == null ? null : syntax[className]),
  ];
}

/// Half-open `[start, end)` ranges of [text] matching any of [keywords],
/// merged where they overlap and in ascending order.
List<({int start, int end})> _matchRanges(String text, List<String> keywords) {
  final needles = [
    for (final keyword in keywords)
      if (keyword.trim().isNotEmpty) keyword.trim().toLowerCase(),
  ];
  if (needles.isEmpty) return const [];

  final lower = text.toLowerCase();
  final found = <({int start, int end})>[];
  for (final needle in needles) {
    var from = 0;
    while (true) {
      final at = lower.indexOf(needle, from);
      if (at < 0) break;
      found.add((start: at, end: at + needle.length));
      from = at + 1;
    }
  }
  if (found.isEmpty) return const [];

  found.sort((a, b) => a.start.compareTo(b.start));
  final merged = <({int start, int end})>[found.first];
  for (final range in found.skip(1)) {
    final last = merged.last;
    if (range.start <= last.end) {
      if (range.end > last.end) {
        merged[merged.length - 1] = (start: last.start, end: range.end);
      }
    } else {
      merged.add(range);
    }
  }
  return merged;
}

({int start, int end})? _rangeAt(List<({int start, int end})> ranges, int at) {
  for (final range in ranges) {
    if (at >= range.start && at < range.end) return range;
  }
  return null;
}

int _nextRangeStart(List<({int start, int end})> ranges, int from, int limit) {
  for (final range in ranges) {
    if (range.start > from && range.start < limit) return range.start;
  }
  return limit;
}

/// A prose run and a fenced code block, as a description splits into them.
class CheatDescriptionPart {
  const CheatDescriptionPart.prose(this.text)
    : isCode = false,
      fenceLanguage = null;
  const CheatDescriptionPart.code(this.text, {this.fenceLanguage})
    : isCode = true;

  final String text;
  final bool isCode;

  /// The word after the opening fence, when there was one. Null falls back to
  /// the tab's own language.
  final String? fenceLanguage;
}

/// Splits a description into prose and triple-backtick fenced blocks.
///
/// An **unclosed** fence stays literal text to the end of that description —
/// it never bleeds into the next entry, because each description is parsed on
/// its own (§8).
List<CheatDescriptionPart> parseCheatDescription(String description) {
  if (!description.contains('```')) {
    return [CheatDescriptionPart.prose(description)];
  }

  final parts = <CheatDescriptionPart>[];
  final lines = description.split('\n');
  final buffer = <String>[];
  var fenceAt = -1;
  String? fenceLanguage;

  void flushProse() {
    if (buffer.isEmpty) return;
    parts.add(CheatDescriptionPart.prose(buffer.join('\n')));
    buffer.clear();
  }

  for (var i = 0; i < lines.length; i++) {
    final line = lines[i];
    if (!line.trimLeft().startsWith('```')) {
      buffer.add(line);
      continue;
    }
    if (fenceAt < 0) {
      // Remember where the fence opened: if it never closes, everything from
      // here has to go back as the literal text it is.
      flushProse();
      fenceAt = i;
      final info = line.trimLeft().substring(3).trim();
      fenceLanguage = info.isEmpty ? null : info;
      continue;
    }
    parts.add(
      CheatDescriptionPart.code(
        buffer.join('\n'),
        fenceLanguage: fenceLanguage,
      ),
    );
    buffer.clear();
    fenceAt = -1;
    fenceLanguage = null;
  }

  if (fenceAt >= 0) {
    // Unclosed: put the fence line itself back and render the rest as prose.
    parts.add(
      CheatDescriptionPart.prose([lines[fenceAt], ...buffer].join('\n')),
    );
  } else {
    flushProse();
  }
  return parts;
}

/// A description rendered the way Viewing mode shows it: proportional prose
/// with `` `inline code` `` set in the code font, and fenced blocks as
/// highlighted snippets.
class LeetCodeCheatDescription extends StatelessWidget {
  const LeetCodeCheatDescription(
    this.description, {
    super.key,
    required this.languageKey,
    required this.style,
    this.keywords = const [],
  });

  final String description;
  final String? languageKey;
  final TextStyle style;
  final List<String> keywords;

  @override
  Widget build(BuildContext context) {
    final parts = parseCheatDescription(description);
    final children = <Widget>[];
    for (final part in parts) {
      final text = part.isCode ? part.text : part.text.trim();
      if (text.isEmpty) continue;
      if (children.isNotEmpty) children.add(const SizedBox(height: 8));
      if (part.isCode) {
        children.add(
          LeetCodeCodeView(
            code: text,
            // A fence's own info string wins over the tab's language, so a
            // Python snippet pasted into a Java tab still reads as Python.
            language:
                cheatLanguageKey(part.fenceLanguage) ??
                cheatLanguageKey(languageKey) ??
                '',
          ),
        );
      } else {
        children.add(
          LeetCodeProseText(
            text,
            style: style,
            language: cheatLanguageKey(languageKey),
            keywords: keywords,
          ),
        );
      }
    }
    if (children.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: children,
    );
  }
}

export 'package:voyager/domain/models/enums.dart' show SnippetExpandKey;

/// One text-expansion shortcut: type [trigger], get [replacement].
///
/// Modelled on Obsidian's Latex Suite (see `SNIPPET.md`), minus the parts that
/// only make sense in a maths editor: triggers are plain strings, never regex,
/// and the only flags are the two that mean something in prose — [autoExpand]
/// (their `A`) and [wordBoundary] (their `w`).
///
/// Triggers are unique across the whole list. That is enforced where snippets
/// are written (the settings dialog) rather than here, so a record that arrives
/// from an older device with a duplicate trigger still parses; the lookup index
/// simply prefers the longest match and would never reach the second one.
class Snippet {
  const Snippet({
    required this.id,
    required this.trigger,
    required this.replacement,
    this.autoExpand = false,
    this.wordBoundary = false,
  });

  /// Stable identity for list edits and sync. Not derived from [trigger]: the
  /// user renaming a trigger has to stay the same row.
  final String id;

  /// Plain text. Matched as a suffix of what sits before the caret.
  ///
  /// A trigger whose last character is outside the BMP (most emoji) cannot
  /// auto-expand — the auto path only recognises one code unit of growth as a
  /// typed character — but still expands with the expand key. See SNIPPET.md
  /// §3.1.
  final String trigger;

  /// May contain `$0`, `$1`, … tabstops — see [parseSnippetReplacement].
  final String replacement;

  /// Latex Suite's `A`: expand the instant the trigger is complete, with no
  /// expand key. Note the chronology this implies — a one-character auto
  /// trigger fires before a longer trigger sharing its prefix can ever be
  /// typed.
  final bool autoExpand;

  /// Latex Suite's `w`: only expand when the trigger is preceded *and*
  /// followed by a word delimiter (start/end of the field count). See
  /// [isSnippetWordDelimiter].
  final bool wordBoundary;

  Snippet copyWith({
    String? trigger,
    String? replacement,
    bool? autoExpand,
    bool? wordBoundary,
  }) {
    return Snippet(
      id: id,
      trigger: trigger ?? this.trigger,
      replacement: replacement ?? this.replacement,
      autoExpand: autoExpand ?? this.autoExpand,
      wordBoundary: wordBoundary ?? this.wordBoundary,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'trigger': trigger,
    'replacement': replacement,
    'autoExpand': autoExpand,
    'wordBoundary': wordBoundary,
  };

  /// Null for anything that isn't a usable record — a non-map entry, or one
  /// with no id or an empty trigger. Sync and import both feed this untrusted
  /// data, and one bad row must not take the rest of the list with it.
  static Snippet? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['id'];
    final trigger = raw['trigger'];
    if (id is! String || id.isEmpty) return null;
    if (trigger is! String || trigger.isEmpty) return null;
    return Snippet(
      id: id,
      trigger: trigger,
      replacement: raw['replacement'] is String
          ? raw['replacement'] as String
          : '',
      autoExpand: raw['autoExpand'] == true,
      wordBoundary: raw['wordBoundary'] == true,
    );
  }

  static List<Snippet> listFromJson(Object? raw) {
    if (raw is! List) return const [];
    final out = <Snippet>[];
    for (final entry in raw) {
      final snippet = Snippet.fromJson(entry);
      if (snippet != null) out.add(snippet);
    }
    return out;
  }

  @override
  bool operator ==(Object other) =>
      other is Snippet &&
      other.id == id &&
      other.trigger == trigger &&
      other.replacement == replacement &&
      other.autoExpand == autoExpand &&
      other.wordBoundary == wordBoundary;

  @override
  int get hashCode =>
      Object.hash(id, trigger, replacement, autoExpand, wordBoundary);
}

/// One `$n` in a parsed replacement.
class SnippetTabstop {
  const SnippetTabstop({required this.index, required this.offset});

  /// The `n` in `$n`. Decides visit order, ascending.
  final int index;

  /// Character offset into [ParsedSnippet.text] where the caret lands.
  final int offset;

  @override
  bool operator ==(Object other) =>
      other is SnippetTabstop && other.index == index && other.offset == offset;

  @override
  int get hashCode => Object.hash(index, offset);

  @override
  String toString() => 'SnippetTabstop($index @ $offset)';
}

/// A replacement with its `$n` markers stripped out and recorded.
class ParsedSnippet {
  const ParsedSnippet({required this.text, required this.tabstops});

  /// The literal text to insert.
  final String text;

  /// Tabstops in visit order — ascending by [SnippetTabstop.index], so `$0`
  /// comes first however late in the string it appears. Empty for a plain
  /// replacement, which expands without opening a session at all.
  final List<SnippetTabstop> tabstops;
}

/// Splits [replacement] into literal text plus tabstop positions, following
/// Latex Suite's `$` rules.
///
/// - `$` then one or more digits is a tabstop (`$0`, `$1`, `$10`).
/// - `$` anywhere else is a literal `$`. That is what makes Latex Suite's
///   inline-maths idiom `$$0$` parse as `$`, tabstop 0, `$` rather than as an
///   escape.
/// - `\$` is a literal `$` even when digits follow, which is the only way to
///   write a `$0` that must survive as characters. Deliberately *not* `$$`,
///   which the idiom above already spends.
///
/// A repeated index (`$1 … $1`) keeps the first and drops the rest: mirrored
/// tabstops are a v2 feature, and silently expanding to two carets would be a
/// worse answer than one.
ParsedSnippet parseSnippetReplacement(String replacement) {
  final text = StringBuffer();
  final tabstops = <SnippetTabstop>[];
  final seen = <int>{};
  var length = 0;
  var i = 0;

  while (i < replacement.length) {
    final unit = replacement.codeUnitAt(i);

    if (unit == _kBackslash &&
        i + 1 < replacement.length &&
        replacement.codeUnitAt(i + 1) == _kDollar) {
      text.write(r'$');
      length++;
      i += 2;
      continue;
    }

    if (unit == _kDollar) {
      var digits = i + 1;
      while (digits < replacement.length &&
          _isDigit(replacement.codeUnitAt(digits))) {
        digits++;
      }
      if (digits > i + 1) {
        final index = int.parse(replacement.substring(i + 1, digits));
        if (seen.add(index)) {
          tabstops.add(SnippetTabstop(index: index, offset: length));
        }
        i = digits;
        continue;
      }
    }

    text.writeCharCode(unit);
    length++;
    i++;
  }

  tabstops.sort((a, b) => a.index.compareTo(b.index));
  return ParsedSnippet(text: text.toString(), tabstops: tabstops);
}

/// Whether [replacement] uses `${…}` — placeholder syntax Latex Suite supports
/// and this version does not. Surfaced as a warning in the settings editor so a
/// snippet copied from a Latex Suite config doesn't silently expand wrong.
bool snippetUsesPlaceholders(String replacement) {
  for (var i = 0; i + 1 < replacement.length; i++) {
    if (replacement.codeUnitAt(i) == _kBackslash) {
      i++;
      continue;
    }
    if (replacement.codeUnitAt(i) == _kDollar &&
        replacement.codeUnitAt(i + 1) == _kOpenBrace) {
      return true;
    }
  }
  return false;
}

/// Whether the character at [index] of [text] ends a word, in the sense
/// [Snippet.wordBoundary] means.
///
/// The complement of `\w`: letters, digits and `_` are word characters, and
/// everything else — whitespace, punctuation, symbols — is a delimiter. Out of
/// range counts as a delimiter, which is how the start and end of a field
/// satisfy the gate.
bool isSnippetWordDelimiter(String text, int index) {
  if (index < 0 || index >= text.length) return true;
  return !_isWordCodeUnit(text.codeUnitAt(index));
}

const int _kDollar = 0x24;
const int _kBackslash = 0x5C;
const int _kOpenBrace = 0x7B;
const int _kUnderscore = 0x5F;

bool _isDigit(int unit) => unit >= 0x30 && unit <= 0x39;

/// ASCII inline, anything above it deferred to [_unicodeWord].
///
/// This runs on the hot path — once per candidate trigger character on every
/// keystroke — and the overwhelming majority of characters typed into these
/// fields are ASCII, so the branchy comparisons are worth avoiding a regex for.
bool _isWordCodeUnit(int unit) {
  if (unit < 0x80) {
    return (unit >= 0x61 && unit <= 0x7A) || // a-z
        (unit >= 0x41 && unit <= 0x5A) || // A-Z
        _isDigit(unit) ||
        unit == _kUnderscore;
  }
  return _unicodeWord.hasMatch(String.fromCharCode(unit));
}

/// Letters and digits outside ASCII — accented Latin, Greek, CJK — so a
/// word-boundary snippet behaves the same in a non-English note.
final RegExp _unicodeWord = RegExp(r'[\p{L}\p{N}]', unicode: true);

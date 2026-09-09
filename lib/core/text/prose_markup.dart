import 'package:flutter/widgets.dart';
import 'package:voyager/core/utils/journal_tags.dart';

/// The four inline styles Voyager prose can carry (EMPHASIS_FORMATTING.md §2).
enum EmphasisKind { bold, italic, underline, highlight }

/// Why a stretch of text is opaque to emphasis parsing.
enum ProseZoneKind {
  /// `$...$` study LaTeX, where `*` is multiplication (§4.3).
  latex,

  /// `` `inline code` ``, and everything after an unclosed backtick (§4.2).
  inlineCode,

  /// A `#tag` body. Outer wrappers still apply to the tag; it is only the
  /// characters *inside* the tag that can't open or close a span (§4.4).
  tag,
}

/// [closed] is false only for the tail an unclosed backtick opens: emphasis
/// treats it exactly like a real code span (§4.2), but the spellcheck
/// tokenizer does not, since one stray backtick would otherwise take the
/// squiggles off the whole rest of a long entry.
typedef ProseZone = ({int start, int end, ProseZoneKind kind, bool closed});

/// One matched delimiter pair, on offsets into the *stored* string.
///
/// [start] is the first character of the opening delimiter and [end] one past
/// the last character of the closing one, so the `**bold**` in `a **bold** b`
/// is `start: 2, end: 10` with a [delimiterLength] of 2. Nothing here is ever
/// expressed in rendered offsets: hiding a delimiter is a paint decision made
/// later, and stored indices have to stay the ones Vim, undo and sync see.
@immutable
class EmphasisSpan {
  const EmphasisSpan({
    required this.start,
    required this.end,
    required this.kind,
    required this.delimiterLength,
  });

  final int start;
  final int end;
  final EmphasisKind kind;
  final int delimiterLength;

  int get contentStart => start + delimiterLength;
  int get contentEnd => end - delimiterLength;

  @override
  bool operator ==(Object other) =>
      other is EmphasisSpan &&
      other.start == start &&
      other.end == end &&
      other.kind == kind &&
      other.delimiterLength == delimiterLength;

  @override
  int get hashCode => Object.hash(start, end, kind, delimiterLength);

  @override
  String toString() => 'EmphasisSpan($kind, $start..$end, d$delimiterLength)';
}

/// A parsed piece of prose: where emphasis applies, and where it is forbidden.
///
/// One parser serves every surface — the editing controller, the overlay
/// layers stacked around a field, and the read-mode display widgets — so a
/// journal entry can never wrap differently depending on who laid it out.
@immutable
class ProseMarkup {
  const ProseMarkup._(this.text, this.zones, this.spans);

  static const empty = ProseMarkup._('', <ProseZone>[], <EmphasisSpan>[]);

  final String text;

  /// Exclusion zones, sorted by [ProseZone.start] ascending.
  ///
  /// Non-overlapping with one exception: the open-ended zone an *unclosed*
  /// backtick leaves runs to the end of the document, and the `#tag` and
  /// `$…$` zones below it are nested inside it rather than skipped, because
  /// [tokenizeWords] drops that one zone and still needs the other two. Every
  /// consumer either stops at the first zone covering an offset ([inZone]) or
  /// jumps to its end ([_scanRuns], which therefore stops at the tail), so the
  /// nesting is inert to all of them.
  final List<ProseZone> zones;

  /// Matched spans in pre-order — sorted by [EmphasisSpan.start] ascending and
  /// [EmphasisSpan.end] descending, so a span's descendants are exactly the
  /// entries that follow it while their start is below its [contentEnd]. The
  /// list is a properly nested forest: spans never partially overlap.
  final List<EmphasisSpan> spans;

  bool get hasEmphasis => spans.isNotEmpty;

  /// Just the exclusion zones, for the callers that never look at emphasis —
  /// the spellcheck tokenizer and autocorrect's own gates (§6).
  ///
  /// Cached two deep on the string, the same way `ProseEditingController`
  /// caches a whole parse: the squiggle layer and the autocorrect gate ask for
  /// the same document on the same keystroke, and this scans all of it (§12).
  static List<ProseZone> zonesOf(String source) {
    if (source.isEmpty) return const [];
    if (_zoneRecent?.$1 == source) return _zoneRecent!.$2;
    final older = _zoneOlder;
    if (older != null && older.$1 == source) {
      _zoneOlder = _zoneRecent;
      _zoneRecent = older;
      return older.$2;
    }
    final zones = _scanZones(source);
    _zoneOlder = _zoneRecent;
    _zoneRecent = (source, zones);
    return zones;
  }

  static ProseMarkup parse(String source) {
    assert(() {
      proseParseCount++;
      return true;
    }());
    if (source.isEmpty) return empty;
    final zones = zonesOf(source);
    if (!source.contains('*') &&
        !source.contains('_') &&
        !source.contains('=')) {
      return ProseMarkup._(source, zones, const []);
    }
    return ProseMarkup._(source, zones, _matchSpans(source, zones));
  }

  /// The spans whose delimiters [selection] reveals: every span the caret sits
  /// inside, or that the selection touches at all (§3.1).
  ///
  /// Containment is inclusive at both ends, so arrowing onto a span's edge
  /// shows its markers rather than making the user press once more to get
  /// inside them. Ancestors come along for free — a caret inside a nested span
  /// is by definition inside everything wrapping it.
  Set<EmphasisSpan> revealedBy(TextSelection selection) {
    if (spans.isEmpty || !selection.isValid) return const {};
    final start = selection.start;
    final end = selection.end;
    return {
      for (final span in spans)
        if (start <= span.end && end >= span.start) span,
    };
  }

  /// Whether [offset] falls inside an exclusion zone of [kind] — of any kind
  /// when [kind] is null.
  bool inZone(int offset, {ProseZoneKind? kind}) {
    for (final zone in zones) {
      if (zone.start > offset) break;
      if (offset < zone.end && (kind == null || zone.kind == kind)) return true;
    }
    return false;
  }
}

/// The `[start, end)` slice of [source], with any delimiter the cut left
/// without its partner removed.
///
/// §5.3 says a read surface must parse the whole document, because a pair
/// straddling a boundary loses one delimiter. Previews and search snippets are
/// the surfaces that cannot: what they display *is* a derived string —
/// `firstSentencePreview` truncates, `searchSnippet` opens a window at the
/// first hit — and parsing anything but what is displayed would put every
/// offset out. So the pairs are resolved here against the whole of [source],
/// and only the half-pairs the window kept are dropped. A cut through
/// `**bold**` shows the reader `bold`, not `**bold`.
///
/// Deliberately not a scan for anything that *looks* like a delimiter: a `2*3`
/// or a `_config` the author typed never paired in the first place and is left
/// exactly as it is, in the preview as in the entry.
String proseSlice(String source, int start, int end) {
  final from = start.clamp(0, source.length);
  final to = end.clamp(from, source.length);
  // Nothing was cut off, or there is nothing that could have paired.
  if ((from == 0 && to == source.length) ||
      (!source.contains('*') &&
          !source.contains('_') &&
          !source.contains('='))) {
    return source.substring(from, to);
  }

  final drop = <int>{};
  for (final span in ProseMarkup.parse(source).spans) {
    // Whole delimiters: a cut through the middle of a `**` keeps neither.
    final keptOpen = span.start >= from && span.contentStart <= to;
    final keptClose = span.contentEnd >= from && span.end <= to;
    if (keptOpen && keptClose) continue;
    for (var i = span.start; i < span.contentStart; i++) {
      drop.add(i);
    }
    for (var i = span.contentEnd; i < span.end; i++) {
      drop.add(i);
    }
  }
  if (drop.isEmpty) return source.substring(from, to);

  final buffer = StringBuffer();
  for (var i = from; i < to; i++) {
    if (!drop.contains(i)) buffer.writeCharCode(source.codeUnitAt(i));
  }
  return buffer.toString();
}

/// How many times [ProseMarkup.parse] has been called, counted in debug builds
/// only.
///
/// §12 names re-parsing a long entry once per layer per keystroke as the
/// performance risk of this feature, and `ProseEditingController`'s one-entry
/// cache is what stops it. Nothing else can observe whether that cache is
/// working, so the perf test counts through here.
@visibleForTesting
int proseParseCount = 0;

(String, List<ProseZone>)? _zoneRecent;
(String, List<ProseZone>)? _zoneOlder;

const int _asterisk = 0x2A;
const int _underscore = 0x5F;
const int _equals = 0x3D;
const int _dollar = 0x24;
const int _backtick = 0x60;
const int _hash = 0x23;

/// Letters, digits and `_` — what `__` may not sit in the middle of.
final _wordChar = RegExp(r'[\p{L}\p{N}_]', unicode: true);

bool _isWordCharAt(String text, int index) =>
    index >= 0 && index < text.length && _wordChar.hasMatch(text[index]);

bool _isSpaceAt(String text, int index) {
  if (index < 0 || index >= text.length) return false;
  final unit = text.codeUnitAt(index);
  if (unit == 0x20 || unit == 0x0A || unit == 0x09 || unit == 0x0D) {
    return true;
  }
  // A non-breaking or typographic space is whitespace to the reader, and
  // flanking is a rule about what the reader sees (§2.3). U+00A0 arrives
  // from a Word paste, an OS compose key or another device; read as text it
  // lets a `**` closer preceded by one bold a trailing space, and italicises
  // a `*` flanked by them where an ordinary `2 * 3` is correctly left alone.
  return unit == 0xA0 ||
      unit == 0x202F ||
      unit == 0x3000 ||
      (unit >= 0x2000 && unit <= 0x200A);
}

/// LaTeX first, then inline code, then tags (§2.3) — an outer zone swallows
/// whatever punctuation an inner one would have matched on.
List<ProseZone> _scanZones(String source) {
  final zones = <ProseZone>[];
  final length = source.length;
  var i = 0;
  while (i < length) {
    final unit = source.codeUnitAt(i);
    if (unit == _dollar) {
      final newline = source.indexOf('\n', i + 1);
      final lineEnd = newline < 0 ? length : newline;
      final close = source.indexOf(r'$', i + 1);
      // An empty `$$` is not math, and neither is `$5 for lunch and $10`: an
      // opener may not be followed by a space and a closer may not be preceded
      // by one, exactly as an emphasis run is flanked (§2.3), and a pair has
      // to close on its own line the way an inline-code pair does (§4.2).
      // An unpaired `$` is a price, not the start of an equation (§6.2) — and
      // since these zones gate the spellcheck tokenizer and autocorrect (§6.1),
      // two prices in one entry used to take the dictionary and the corrector
      // off everything between them, across paragraphs, with nothing to see.
      if (close > i + 1 &&
          close < lineEnd &&
          !_isSpaceAt(source, i + 1) &&
          !_isSpaceAt(source, close - 1)) {
        zones.add((
          start: i,
          end: close + 1,
          kind: ProseZoneKind.latex,
          closed: true,
        ));
        i = close + 1;
        continue;
      }
    } else if (unit == _backtick) {
      final newline = source.indexOf('\n', i + 1);
      final lineEnd = newline < 0 ? length : newline;
      final close = source.indexOf('`', i + 1);
      if (close >= 0 && close < lineEnd && close != i + 1) {
        zones.add((
          start: i,
          end: close + 1,
          kind: ProseZoneKind.inlineCode,
          closed: true,
        ));
        i = close + 1;
        continue;
      }
      // No partner before the line ends. [parseInlineCode] leaves the backtick
      // literal and reads on; emphasis instead stops for the rest of the
      // document (§4.2), matching what `insideInlineCode` already does to
      // autocorrect — one stray backtick means the author is mid-thought about
      // code, and guessing at markup below it is worse than doing nothing.
      zones.add((
        start: i,
        end: length,
        kind: ProseZoneKind.inlineCode,
        closed: false,
      ));
      // The tail is opaque to emphasis, but [tokenizeWords] drops this zone
      // (§6.1) and still needs the `#tag` and `$…$` zones inside it — so the
      // scan carries on rather than returning, or one stray backtick puts red
      // waves under every tag name in the rest of a long entry. The zones it
      // goes on to add are nested in this one; every consumer either stops at
      // the first zone that covers an offset or skips to its end, so the
      // overlap is inert.
      i++;
      continue;
    } else if (unit == _hash) {
      final tag = journalTagPattern.matchAsPrefix(source, i);
      if (tag != null) {
        // `\w` includes `_`, so the pattern swallows a closing `__` into the
        // tag body — leaving `__#tag__`'s opener with nothing to pair with,
        // and letting tag completion's `replaceRange` delete the delimiter.
        // A run of two or more underscores is where the tag stops; a single
        // `_` stays inside it, so `#tag_name` is one tag (§4.4).
        var end = i + 1;
        while (end < tag.end) {
          if (source.codeUnitAt(end) == _underscore &&
              end + 1 < tag.end &&
              source.codeUnitAt(end + 1) == _underscore) {
            break;
          }
          end++;
        }
        if (end > i + 1) {
          zones.add((
            start: i,
            end: end,
            kind: ProseZoneKind.tag,
            closed: true,
          ));
        }
        i = end;
        continue;
      }
    }
    i++;
  }
  return zones;
}

/// A maximal run of one delimiter character, outside every exclusion zone.
class _Run {
  _Run({
    required this.position,
    required this.length,
    required this.unit,
    required this.canOpen,
    required this.canClose,
  });

  final int position;
  final int length;
  final int unit;
  final bool canOpen;
  final bool canClose;

  /// Characters taken off the left of the run by pairs it has closed, and off
  /// the right by pairs it has opened. Both draw on the same run, so a run
  /// acting as closer and then opener can't spend the same character twice.
  int closed = 0;
  int opened = 0;

  int get available => length - closed - opened;
}

List<_Run> _scanRuns(String source, List<ProseZone> zones) {
  final runs = <_Run>[];
  final length = source.length;
  var zone = 0;
  var i = 0;
  while (i < length) {
    while (zone < zones.length && zones[zone].end <= i) {
      zone++;
    }
    if (zone < zones.length && i >= zones[zone].start) {
      i = zones[zone].end;
      continue;
    }
    final unit = source.codeUnitAt(i);
    if (unit != _asterisk && unit != _underscore && unit != _equals) {
      i++;
      continue;
    }
    // A run stops at the next zone as well as at a different character: `**`
    // straddling the start of a `$…$` is one delimiter and one literal.
    final limit = zone < zones.length ? zones[zone].start : length;
    var end = i + 1;
    while (end < limit && source.codeUnitAt(end) == unit) {
      end++;
    }

    // Flanking, simplified from CommonMark to whitespace only: an opener may
    // not be followed by a space, a closer may not be preceded by one. That is
    // what keeps `2 * 3` three tokens (§11) — and, with no extra rule needed,
    // what keeps a line-start `* ` bullet a bullet (§2.4), since the space
    // after the marker is exactly what stops it opening.
    var canOpen = end < length && !_isSpaceAt(source, end);
    var canClose = i > 0 && !_isSpaceAt(source, i - 1);
    if (unit == _underscore) {
      // `__` additionally has to sit at a word edge, or `snake_case__names`
      // and `a__b__c` would come out underlined.
      canOpen = canOpen && !_isWordCharAt(source, i - 1);
      canClose = canClose && !_isWordCharAt(source, end);
    }

    runs.add(
      _Run(
        position: i,
        length: end - i,
        unit: unit,
        canOpen: canOpen,
        canClose: canClose,
      ),
    );
    i = end;
  }
  return runs;
}

EmphasisKind _kindFor(int unit, int width) => switch (unit) {
  _asterisk => width == 2 ? EmphasisKind.bold : EmphasisKind.italic,
  _underscore => EmphasisKind.underline,
  _ => EmphasisKind.highlight,
};

List<EmphasisSpan> _matchSpans(String source, List<ProseZone> zones) {
  final runs = _scanRuns(source, zones);
  if (runs.isEmpty) return const [];

  final spans = <EmphasisSpan>[];
  final openers = <_Run>[];

  for (final run in runs) {
    if (run.canClose) {
      // `__` and `==` have no one-character form, so an opener with a single
      // character left is not a candidate for them: it has to be skipped over
      // rather than end the search, or one stray `_` inside a `__…__` pair
      // takes the enclosing pair — and every pair around it — down with it.
      final needed = run.unit == _asterisk ? 1 : 2;
      while (run.available >= needed) {
        var index = openers.length - 1;
        while (index >= 0 &&
            (openers[index].unit != run.unit ||
                openers[index].available < needed)) {
          index--;
        }
        if (index < 0) break;
        final opener = openers[index];
        // `**` before `*` (§2.3): two characters are spent as bold whenever
        // both sides can afford them, so `**` is never split into two italics.
        // `__` and `==` have no one-character form at all.
        final width = run.unit == _asterisk
            ? (run.available >= 2 && opener.available >= 2 ? 2 : 1)
            : 2;

        // Everything opened after the matched opener can never close now
        // without crossing this pair. Dropping those is what keeps the result
        // a properly nested forest rather than a pile of overlapping ranges —
        // `*a ==b* c==` gives italic `a ==b` and a literal tail (§2.2).
        openers.removeRange(index + 1, openers.length);

        final start = opener.position + opener.length - opener.opened - width;
        final end = run.position + run.closed + width;
        spans.add(
          EmphasisSpan(
            start: start,
            end: end,
            kind: _kindFor(run.unit, width),
            delimiterLength: width,
          ),
        );
        opener.opened += width;
        run.closed += width;
        if (opener.available == 0) openers.removeAt(index);
      }
    }
    if (run.canOpen && run.available > 0) openers.add(run);
  }

  spans.sort((a, b) => a.start != b.start ? a.start - b.start : b.end - a.end);
  return spans;
}

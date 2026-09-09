/// Rich clipboard HTML, rewritten as Voyager's plain-text markers
/// (EMPHASIS_FORMATTING.md §7).
///
/// Deliberately not a general HTML parser. It walks tags, keeps the four
/// styles Voyager has markers for, turns the block-level ones into newlines
/// and drops everything else — a table becomes its cells' text, a link becomes
/// its label. §7 is explicit that no marker is invented for a style the syntax
/// cannot express, so colour, size and strikethrough all arrive as plain text
/// rather than as an approximation of themselves.
library;

const _boldTags = {'b', 'strong'};
const _italicTags = {'i', 'em'};
const _underlineTags = {'u', 'ins'};
const _highlightTags = {'mark'};

/// Tags whose content is not prose at all. Word and Google Docs both ship a
/// `<style>` block ahead of the body, and pasting a stylesheet into a journal
/// entry is the most visible way this could go wrong.
const _skippedTags = {'style', 'script', 'head', 'title'};

/// Tags that end the line they are on.
const _blockTags = {
  'p',
  'div',
  'br',
  'li',
  'tr',
  'h1',
  'h2',
  'h3',
  'h4',
  'h5',
  'h6',
  'blockquote',
  'pre',
};

/// One open element, and the markers it is owed.
class _Open {
  _Open(this.tag, this.markers);

  final String tag;
  final List<String> markers;

  /// Whether the opening markers have actually been written yet. They wait for
  /// the element's first non-space character, so `<b> x</b>` comes out as
  /// ` **x**` and not as `** x**` — which the flanking rule (§2.3) would leave
  /// literal. An element that never gets one closes without writing anything.
  bool flushed = false;

  /// Where this element's own text starts in the output chunks.
  int contentFrom = 0;

  /// The output chunks holding each marker actually written for this element —
  /// the opener, and the closer once it is written. A marker missing from here
  /// was refused at the opening edge and gets no partner.
  final slots = <String, List<int>>{};
}

/// Letters, digits and `_`, matching the parser's own word-character class:
/// what a `__` may not sit against (§2.3).
final _wordEdge = RegExp(r'[\p{L}\p{N}_]', unicode: true);

/// Whether [marker] can still be a delimiter around [content].
///
/// There is no escape syntax in v1, so a marker cannot survive its own
/// delimiter inside the run it wraps: `<b>2*3</b>` written out as `**2*3**`
/// comes back as two *italics* and a stray asterisk, and `<mark>a==b</mark>`
/// as a highlight over `a` followed by a literal `b==`. Pasting the run plain
/// is §7's own rule — do not invent markers for a style the syntax cannot
/// express — applied to a marker the content itself takes away again.
///
/// A lone `_` or `=` is harmless: the parser skips an opener too short for the
/// run closing it, so `__hello _world__` still underlines. A lone `*` is not,
/// since one asterisk is itself an italic delimiter and splits a `**` pair.
bool _markerSurvives(String marker, String content) =>
    marker == '*' || marker == '**'
    ? !content.contains('*')
    : !content.contains(marker);

/// [html] as marked-up plain text, or `''` when it holds no text at all.
String htmlToProseMarkers(String html) {
  // Assembled as a list of chunks rather than a [StringBuffer] because a
  // marker already written may still have to be withdrawn, and neither test
  // can be made at the moment the opener goes down: a `__` is forbidden
  // against a word character at *either* edge (§2.3), and no marker survives
  // its own delimiter turning up in the text it wraps (§7). Both answers are
  // still in the future there.
  final parts = <String>[];
  final markerSlots = <int>{};
  final open = <_Open>[];
  // Closers written but not yet vindicated — only a `__` can still be taken
  // back by what follows it.
  final pendingClosers = <(_Open, String)>[];
  var wrote = false;
  var pendingSpace = false;
  var pendingBreaks = 0;

  void emit(String chunk) {
    if (chunk.isEmpty) return;
    parts.add(chunk);
    wrote = true;
  }

  void emitMarker(String marker) {
    markerSlots.add(parts.length);
    parts.add(marker);
    wrote = true;
  }

  /// The last character actually standing in the output. Withdrawn markers
  /// leave empty chunks behind, and the parser never sees those.
  String lastWritten() {
    for (var i = parts.length - 1; i >= 0; i--) {
      if (parts[i].isNotEmpty) return parts[i].substring(parts[i].length - 1);
    }
    return '';
  }

  void withdraw(_Open element, String marker) {
    for (final slot in element.slots.remove(marker) ?? const <int>[]) {
      parts[slot] = '';
    }
  }

  /// Settles every pending `__` closer against [next], the character that
  /// actually lands to its right.
  void resolveClosers(String next) {
    if (pendingClosers.isEmpty) return;
    if (_wordEdge.hasMatch(next)) {
      for (final (element, marker) in pendingClosers) {
        withdraw(element, marker);
      }
    }
    pendingClosers.clear();
  }

  void flushGap() {
    if (pendingBreaks > 0) {
      emit('\n' * pendingBreaks);
      pendingClosers.clear();
    } else if (pendingSpace) {
      emit(' ');
      pendingClosers.clear();
    }
    pendingBreaks = 0;
    pendingSpace = false;
  }

  void flushOpeners() {
    for (final element in open) {
      if (element.flushed) continue;
      element.flushed = true;
      for (final marker in element.markers) {
        // A `__` against a word character pastes as four literal underscores,
        // and Word and Google Docs both emit underlined runs abutting their
        // neighbours with no space at all (`text-decoration: underline` on a
        // bare `<span>`). Losing the underline is strictly better (§7).
        if (marker == '__' && _wordEdge.hasMatch(lastWritten())) continue;
        element.slots[marker] = [parts.length];
        emitMarker(marker);
      }
      element.contentFrom = parts.length;
    }
  }

  void writeText(String text) {
    for (var i = 0; i < text.length; i++) {
      final ch = text[i];
      // HTML collapses runs of whitespace, and a marker must not land against
      // one, so the gap is held until something is written on the far side.
      if (ch == ' ' || ch == '\t' || ch == '\n' || ch == '\r') {
        if (wrote || pendingBreaks > 0) pendingSpace = true;
        continue;
      }
      flushGap();
      final at = parts.length;
      flushOpeners();
      // What lands to the right of a pending `__` closer is the first marker
      // an element opening here writes, if any, and otherwise this character.
      resolveClosers(at < parts.length ? parts[at] : ch);
      emit(ch);
    }
  }

  void close(String tag) {
    final at = open.lastIndexWhere((element) => element.tag == tag);
    if (at < 0) return;
    // Everything still open inside it closes with it: `<b><i>x</b></i>`, which
    // browsers do emit, has to come out properly nested either way.
    for (var i = open.length - 1; i >= at; i--) {
      final element = open.removeAt(i);
      if (!element.flushed) continue;
      // The element's own text, without the markers a nested element wrote: an
      // inner italic's `*` must not make its parent withdraw a good `**`.
      final content = [
        for (var slot = element.contentFrom; slot < parts.length; slot++)
          if (!markerSlots.contains(slot)) parts[slot],
      ].join();
      for (final marker in element.markers.reversed) {
        if (!element.slots.containsKey(marker)) continue;
        if (!_markerSurvives(marker, content)) {
          withdraw(element, marker);
          continue;
        }
        element.slots[marker]!.add(parts.length);
        emitMarker(marker);
        if (marker == '__') pendingClosers.add((element, marker));
      }
    }
  }

  var i = 0;
  var skipDepth = 0;
  String? skipTag;

  while (i < html.length) {
    final lt = html.indexOf('<', i);
    if (lt < 0) {
      if (skipDepth == 0) writeText(_decodeEntities(html.substring(i)));
      break;
    }
    if (lt > i && skipDepth == 0) {
      writeText(_decodeEntities(html.substring(i, lt)));
    }
    final gt = html.indexOf('>', lt + 1);
    if (gt < 0) break;
    final raw = html.substring(lt + 1, gt);
    i = gt + 1;

    // Comments and declarations carry no text and no formatting —
    // `<!--[if gte mso 9]>` is most of a Word clipboard.
    if (raw.startsWith('!') || raw.startsWith('?')) continue;

    final closing = raw.startsWith('/');
    final body = closing ? raw.substring(1) : raw;
    final tag = _tagName(body);
    if (tag.isEmpty) continue;

    if (skipDepth > 0) {
      if (closing && tag == skipTag) skipDepth--;
      continue;
    }
    if (!closing && _skippedTags.contains(tag)) {
      skipDepth = 1;
      skipTag = tag;
      continue;
    }

    if (_blockTags.contains(tag)) {
      // A single line break between blocks, and none before the first.
      if (wrote) pendingBreaks = 1;
      pendingSpace = false;
    }

    if (closing) {
      close(tag);
      continue;
    }

    final own = _markerFor(tag);
    final markers = <String>[
      ?own,
      ..._markersFromStyle(_stylesOf(body), skip: own),
    ];
    if (markers.isEmpty || body.endsWith('/') || tag == 'br') continue;
    open.add(_Open(tag, markers));
  }

  // An unclosed `<b>` at the end of the fragment still has to balance, or the
  // paste leaves a literal `**` behind (§2.2) — routed through [close] so it
  // meets the same survival rules as every element that closed itself.
  while (open.isNotEmpty) {
    close(open.last.tag);
  }
  return parts.join();
}

/// The marker pair for a tag, or null when it carries no formatting.
String? _markerFor(String tag) {
  if (_boldTags.contains(tag)) return '**';
  if (_italicTags.contains(tag)) return '*';
  if (_underlineTags.contains(tag)) return '__';
  if (_highlightTags.contains(tag)) return '==';
  return null;
}

String _tagName(String body) {
  var end = 0;
  while (end < body.length && !_isTagNameBreak(body.codeUnitAt(end))) {
    end++;
  }
  return body.substring(0, end).toLowerCase();
}

bool _isTagNameBreak(int unit) =>
    unit == 0x20 ||
    unit == 0x09 ||
    unit == 0x0A ||
    unit == 0x0D ||
    unit == 0x2F;

/// The `style="…"` declarations on a tag, lowercased.
///
/// Google Docs ships no `<b>` at all — every run is a `<span>` with an inline
/// `font-weight` — so without this the one source §11 names by name would
/// paste as flat text.
String _stylesOf(String body) {
  final at = body.toLowerCase().indexOf('style=');
  if (at < 0) return '';
  final start = at + 'style='.length;
  if (start >= body.length) return '';
  final quote = body[start];
  if (quote != '"' && quote != "'") return '';
  final end = body.indexOf(quote, start + 1);
  if (end < 0) return '';
  return body.substring(start + 1, end).toLowerCase();
}

List<String> _markersFromStyle(String style, {String? skip}) {
  if (style.isEmpty) return const [];
  final markers = <String>[];
  final weight = _declaration(style, 'font-weight');
  if (weight == 'bold' ||
      weight == 'bolder' ||
      (weight != null && (int.tryParse(weight) ?? 0) >= 600)) {
    markers.add('**');
  }
  if (_declaration(style, 'font-style') == 'italic') markers.add('*');
  final decoration = _declaration(style, 'text-decoration');
  if (decoration != null && decoration.contains('underline')) markers.add('__');
  return [
    for (final marker in markers)
      if (marker != skip) marker,
  ];
}

String? _declaration(String style, String property) {
  for (final part in style.split(';')) {
    final colon = part.indexOf(':');
    if (colon < 0) continue;
    if (part.substring(0, colon).trim() != property) continue;
    return part.substring(colon + 1).trim();
  }
  return null;
}

const _namedEntities = {
  'amp': '&',
  'lt': '<',
  'gt': '>',
  'quot': '"',
  'apos': "'",
  'nbsp': ' ',
  'ndash': '–',
  'mdash': '—',
  'hellip': '…',
  'lsquo': '‘',
  'rsquo': '’',
  'ldquo': '“',
  'rdquo': '”',
};

String _decodeEntities(String text) {
  if (!text.contains('&')) return text;
  return text.replaceAllMapped(RegExp(r'&(#x?[0-9a-fA-F]+|\w+);'), (match) {
    final body = match.group(1)!;
    if (body.startsWith('#')) {
      final hex = body.length > 1 && (body[1] == 'x' || body[1] == 'X');
      final code = int.tryParse(
        hex ? body.substring(2) : body.substring(1),
        radix: hex ? 16 : 10,
      );
      if (code == null || code < 0 || code > 0x10FFFF) return match.group(0)!;
      return String.fromCharCode(code);
    }
    return _namedEntities[body.toLowerCase()] ?? match.group(0)!;
  });
}

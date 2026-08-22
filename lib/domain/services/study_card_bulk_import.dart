/// One successfully parsed front/back pair from a bulk paste.
class StudyBulkImportCard {
  const StudyBulkImportCard({
    required this.front,
    required this.back,
    required this.lineNumber,
  });

  final String front;
  final String back;

  /// 1-based line number in the original paste (blank lines counted).
  final int lineNumber;
}

/// A non-blank line that could not become a card.
class StudyBulkImportSkippedLine {
  const StudyBulkImportSkippedLine({
    required this.lineNumber,
    required this.rawLine,
    required this.reason,
  });

  final int lineNumber;
  final String rawLine;
  final String reason;
}

/// Result of parsing pipe-separated study card text.
class StudyBulkImportParseResult {
  const StudyBulkImportParseResult({
    required this.cards,
    required this.skipped,
  });

  final List<StudyBulkImportCard> cards;
  final List<StudyBulkImportSkippedLine> skipped;
}

/// Parses bulk study-card paste text.
///
/// Rules:
/// - Newlines separate cards (`\r\n` / `\n`).
/// - Blank / whitespace-only lines are ignored (not reported as skipped).
/// - First unescaped `|` splits front from back; later pipes stay in the back.
/// - `\|` is a literal `|` and does not split.
/// - Front and back are trimmed; empty either side → skipped.
StudyBulkImportParseResult parseStudyBulkImportText(String text) {
  final normalized = text.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
  final lines = normalized.split('\n');
  final cards = <StudyBulkImportCard>[];
  final skipped = <StudyBulkImportSkippedLine>[];

  for (var i = 0; i < lines.length; i++) {
    final rawLine = lines[i];
    final lineNumber = i + 1;
    if (rawLine.trim().isEmpty) continue;

    final split = _splitFrontBack(rawLine);
    if (split == null) {
      skipped.add(
        StudyBulkImportSkippedLine(
          lineNumber: lineNumber,
          rawLine: rawLine,
          reason: 'Missing | separator',
        ),
      );
      continue;
    }

    final front = split.$1.trim();
    final back = split.$2.trim();
    if (front.isEmpty || back.isEmpty) {
      skipped.add(
        StudyBulkImportSkippedLine(
          lineNumber: lineNumber,
          rawLine: rawLine,
          reason: front.isEmpty && back.isEmpty
              ? 'Empty front and back'
              : front.isEmpty
                  ? 'Empty front'
                  : 'Empty back',
        ),
      );
      continue;
    }

    cards.add(
      StudyBulkImportCard(front: front, back: back, lineNumber: lineNumber),
    );
  }

  return StudyBulkImportParseResult(cards: cards, skipped: skipped);
}

/// Returns `(front, back)` with escapes already resolved, or `null` if no
/// unescaped `|` was found.
(String, String)? _splitFrontBack(String line) {
  final front = StringBuffer();
  final back = StringBuffer();
  var inBack = false;

  for (var i = 0; i < line.length; i++) {
    final ch = line[i];
    if (ch == r'\' && i + 1 < line.length && line[i + 1] == '|') {
      (inBack ? back : front).write('|');
      i++;
      continue;
    }
    if (ch == '|' && !inBack) {
      inBack = true;
      continue;
    }
    (inBack ? back : front).write(ch);
  }

  if (!inBack) return null;
  return (front.toString(), back.toString());
}

import 'package:voyager/features/leetcode/leetcode_cheat_providers.dart';

/// The cheat sheet as markdown, header-form, ready to paste into an editor and
/// print (§6).
///
/// Header form rather than a table because descriptions are multi-line and can
/// carry fenced code, which a table would have to flatten into `<br>` soup.
///
/// Empty sections are skipped, and a tab left with no surviving section is
/// skipped with them — a heading with nothing under it is noise in the pasted
/// document, not information.
///
/// Returns an empty string when there is nothing to say, which the caller
/// turns into a `Nothing to export` toast rather than putting blank text on
/// the clipboard.
///
/// Accepted wart: a description whose line begins with `#` reads as a heading
/// in the pasted document. The field is markdown by contract, so that is the
/// user's own text doing what it says.
String leetCodeCheatSheetMarkdown(
  LeetCodeCheatSheetData data, {

  /// Restricts the export to one tab. Null exports every tab.
  String? tabId,
}) {
  final buffer = StringBuffer();

  for (final tab in data.tabs) {
    if (tabId != null && tab.id != tabId) continue;

    final sections = [
      for (final section in data.sectionsOf(tab.id))
        if (data.entriesOf(section.id).isNotEmpty) section,
    ];
    if (sections.isEmpty) continue;

    if (buffer.isNotEmpty) buffer.write('\n');
    buffer.write('# ${tab.name}\n');

    for (final section in sections) {
      buffer.write('\n## ${section.name}\n');
      for (final entry in data.entriesOf(section.id)) {
        final complexity = entry.complexity;
        // The command is fenced in backticks so `<>` and `_` survive the paste
        // as text rather than as markup.
        buffer.write('\n### `${entry.command}`');
        if (complexity != null && complexity.isNotEmpty) {
          buffer.write(' — $complexity');
        }
        buffer.write('\n');
        final description = entry.description.trim();
        // Emitted verbatim: it is already markdown-ish, so inline backticks
        // and fenced blocks pass straight through.
        if (description.isNotEmpty) buffer.write('\n$description\n');
      }
    }
  }

  return buffer.toString();
}

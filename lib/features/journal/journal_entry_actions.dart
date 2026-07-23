import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/utils/time_format.dart';
import 'package:voyager/core/widgets/journal_color_flag.dart';
import 'package:voyager/domain/models/journal_models.dart';

/// Shared right-click actions for a journal entry, so the journal list and the
/// search results surface identical options ("Statistics", "Change Journal",
/// "Delete").

/// Shows the read-only "Entry Statistics" dialog for [entry] — word/character
/// counts, sentence/paragraph counts, reading time and mood.
void showJournalEntryStatisticsDialog(
  BuildContext context,
  WidgetRef ref,
  JournalEntry entry,
) {
  final words = ref.read(analyticsServiceProvider).countWords(entry.body);
  final chars = entry.body.length;
  final readingTimeMin = (words / 200).ceil();
  final sentences = entry.body.trim().isEmpty
      ? 0
      : entry.body
          .split(RegExp(r'[.!?]+(?:\s+|$)'))
          .where((s) => s.trim().isNotEmpty)
          .length;
  final paragraphs = entry.body.trim().isEmpty
      ? 0
      : entry.body
          .split(RegExp(r'\n\s*\n'))
          .where((p) => p.trim().isNotEmpty)
          .length;

  final formattedDate = DateFormat.yMMMMd().format(entry.entryDate.toLocal());
  final formattedTime = formatTime12Hour(entry.entryDate.toLocal());

  showDialog<void>(
    context: context,
    builder: (ctx) {
      final theme = Theme.of(ctx);
      return AlertDialog(
        title: Row(
          children: [
            Icon(
              PhosphorIconsRegular.chartBar,
              color: theme.colorScheme.primary,
            ),
            const SizedBox(width: 12),
            const Text('Entry Statistics'),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              entry.title.isEmpty ? 'Untitled Entry' : entry.title,
              style: theme.textTheme.titleMedium
                  ?.copyWith(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 4),
            Text(
              '$formattedDate at $formattedTime',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
              ),
            ),
            const SizedBox(height: 16),
            _statRow(ctx, 'Word count', '$words'),
            _statRow(ctx, 'Character count', '$chars'),
            _statRow(ctx, 'Sentences', '$sentences'),
            _statRow(ctx, 'Paragraphs', '$paragraphs'),
            _statRow(ctx, 'Reading time', '$readingTimeMin min'),
            if (entry.mood != null)
              _statRow(ctx, 'Mood value', '${entry.mood}/10'),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Close'),
          ),
        ],
      );
    },
  );
}

Widget _statRow(BuildContext context, String label, String value) {
  final theme = Theme.of(context);
  return Padding(
    padding: const EdgeInsets.symmetric(vertical: 4.0),
    child: Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(label, style: theme.textTheme.bodyMedium),
        Text(
          value,
          style: theme.textTheme.bodyMedium?.copyWith(
            fontWeight: FontWeight.bold,
            color: theme.colorScheme.primary,
          ),
        ),
      ],
    ),
  );
}

/// Shows the "Move to Journal" picker and returns the chosen journal id, or
/// null when dismissed. The entry's [currentJournalId] gets a trailing check.
Future<String?> showMoveToJournalDialog(
  BuildContext context, {
  required List<Journal> journals,
  required String currentJournalId,
}) {
  final accent = Theme.of(context).colorScheme.primary.toARGB32();
  return showDialog<String>(
    context: context,
    builder: (ctx) {
      return AlertDialog(
        title: const Text('Move to Journal'),
        content: SizedBox(
          width: 300,
          child: ListView.builder(
            shrinkWrap: true,
            itemCount: journals.length,
            itemBuilder: (context, index) {
              final journal = journals[index];
              return ListTile(
                leading: JournalBookmarkFlag(
                  colorValue: journal.colorValue ?? accent,
                  size: 16,
                ),
                title: Text(journal.name),
                trailing: journal.id == currentJournalId
                    ? const Icon(Icons.check)
                    : null,
                onTap: () => Navigator.of(context).pop(journal.id),
              );
            },
          ),
        ),
      );
    },
  );
}

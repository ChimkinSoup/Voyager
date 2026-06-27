import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/constants/journal_constants.dart';
import 'package:voyager/core/utils/ids.dart';
import 'package:voyager/core/widgets/confirm_dialog.dart';
import 'package:voyager/core/widgets/labeled_text_field.dart';
import 'package:voyager/core/widgets/palette_color_picker.dart';
import 'package:voyager/domain/models/journal_models.dart';

Future<String?> promptJournalName(
  BuildContext context,
  String title, {
  String? initial,
}) async {
  final controller = TextEditingController(text: initial ?? '');
  return showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: LabeledTextField(
        label: title,
        controller: controller,
        autofocus: true,
        onSubmitted: (_) => Navigator.pop(context, controller.text),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, controller.text),
          child: const Text('OK'),
        ),
      ],
    ),
  );
}

Future<void> renameJournalList(
  BuildContext context,
  WidgetRef ref,
  Journal journal,
) async {
  final name = await promptJournalName(
    context,
    'Rename journal',
    initial: journal.name,
  );
  if (name == null || name.trim().isEmpty || name.trim() == journal.name) {
    return;
  }
  final updated = journal.copyWith(name: name.trim());
  await ref.read(journalRepositoryProvider).upsertJournal(updated);
  ref.read(remoteSyncServiceProvider).pushJournal(updated);
  ref.invalidate(journalsProvider);
}

Future<void> changeJournalListColor(
  BuildContext context,
  WidgetRef ref,
  Journal journal,
  List<Journal> allJournals,
) async {
  final color = await pickPaletteColorWithRef(
    ref,
    context,
    current: journal.colorValue,
    usedColors: allJournals
        .where((item) => item.id != journal.id && item.colorValue != null)
        .map((item) => item.colorValue!)
        .toSet(),
  );
  if (color == null) return;
  final updated = journal.copyWith(colorValue: color);
  await ref.read(journalRepositoryProvider).upsertJournal(updated);
  ref.read(remoteSyncServiceProvider).pushJournal(updated);
  ref.invalidate(journalsProvider);
}

Future<bool> deleteJournalList(
  BuildContext context,
  WidgetRef ref, {
  required Journal journal,
  required List<Journal> allJournals,
  required int entryCount,
}) async {
  if (journal.id == legacyJournalId) return false;

  final choice = await showDeleteContainerDialog(
    context,
    title: 'Delete "${journal.name}"?',
    message: entryCount == 0
        ? 'This journal has no entries and will be removed.'
        : 'This journal has $entryCount entries. Move them to the default "Journal", or delete everything.',
    deleteAllLabel: 'Yes (delete all entries)',
  );
  if (choice == DeleteContainerChoice.cancel) return false;

  final repo = ref.read(journalRepositoryProvider);
  final remoteSync = ref.read(remoteSyncServiceProvider);

  if (choice == DeleteContainerChoice.deleteAll && entryCount > 0) {
    final entries = await repo.listEntries(journalId: journal.id);
    await repo.softDeleteEntriesInJournal(journal.id);
    final now = utcNow();
    for (final entry in entries) {
      remoteSync.pushJournalEntryNow(entry.copyWith(deletedAt: now));
    }
  } else if (choice == DeleteContainerChoice.moveToDefault && entryCount > 0) {
    final fallback = allJournals.firstWhere(
      (item) => item.id == legacyJournalId,
      orElse: () {
        final now = utcNow();
        return Journal(
          id: legacyJournalId,
          name: 'Journal',
          colorValue: Theme.of(context).colorScheme.primary.toARGB32(),
          createdAt: now,
          updatedAt: now,
        );
      },
    );
    if (!allJournals.any((item) => item.id == legacyJournalId)) {
      await repo.upsertJournal(fallback);
      remoteSync.pushJournal(fallback);
    }
    final entries = await repo.listEntries(journalId: journal.id);
    await repo.reassignEntriesJournal(journal.id, legacyJournalId);
    for (final entry in entries) {
      remoteSync.pushJournalEntryNow(
        entry.copyWith(journalId: legacyJournalId),
      );
    }
  }

  await repo.softDeleteJournal(journal.id);
  await remoteSync.pushJournalById(journal.id);
  ref.invalidate(journalEntriesProvider);
  ref.invalidate(journalListEntriesProvider);
  ref.invalidate(journalsProvider);
  return true;
}

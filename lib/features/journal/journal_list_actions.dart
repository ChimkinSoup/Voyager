import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/constants/journal_constants.dart';
import 'package:voyager/core/sync/remote_sync_service.dart';
import 'package:voyager/core/utils/ids.dart';
import 'package:voyager/core/widgets/confirm_dialog.dart';
import 'package:voyager/core/widgets/create_name_color_dialog.dart';
import 'package:voyager/core/widgets/enter_to_submit_scope.dart';
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
    builder: (context) => EnterToSubmitScope(
      onSubmit: () => Navigator.pop(context, controller.text),
      child: AlertDialog(
      title: Text(title),
      content: LabeledTextField(
        label: title,
        controller: controller,
        autofocus: true,
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
  await ref.read(journalsProvider.future);
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
  await ref.read(journalsProvider.future);
}

Future<Journal?> createJournalList(
  BuildContext context,
  WidgetRef ref,
) async {
  final allJournals = ref.read(journalsProvider).valueOrNull ?? [];
  final palette = ref.read(colorPaletteProvider);
  final defaultColor = Theme.of(context).colorScheme.primary.toARGB32();
  final assigner = paletteFromItems(
    allJournals.map((j) => j.colorValue),
    palette,
  );
  final result = await showCreateNameColorDialog(
    context,
    title: 'New journal',
    palette: palette,
    initialColor: assigner.nextColor(),
    usedColors: allJournals
        .where((j) => j.colorValue != null)
        .map((j) => j.colorValue!)
        .toSet(),
  );
  if (result == null) return null;

  final now = utcNow();
  final repo = ref.read(journalRepositoryProvider);
  final remoteSync = ref.read(remoteSyncServiceProvider);
  final created = Journal(
    id: newId(),
    name: result.name,
    colorValue: result.color,
    createdAt: now,
    updatedAt: now,
  );

  if (allJournals.isEmpty) {
    final legacy = Journal(
      id: legacyJournalId,
      name: 'Journal',
      colorValue: defaultColor,
      createdAt: now,
      updatedAt: now,
    );
    await repo.upsertJournal(legacy);
    remoteSync.pushJournal(legacy);
  }

  await repo.upsertJournal(created);
  remoteSync.pushJournal(created);
  ref.invalidate(journalEntriesProvider);
  ref.invalidate(journalListEntriesProvider);
  ref.invalidate(journalEntryCountsProvider);
  ref.invalidate(journalsProvider);
  return created;
}

void _invalidateJournalDeleteProviders(WidgetRef ref, String journalId) {
  ref.invalidate(journalEntriesProvider);
  ref.invalidate(journalListEntriesProvider);
  ref.invalidate(journalListEntriesProvider(journalId));
  ref.invalidate(journalEntryCountsProvider);
  ref.invalidate(journalsProvider);
}

Future<void> _syncJournalDeleteRemote({
  required RemoteSyncService remoteSync,
  required Journal journal,
  required DeleteContainerChoice choice,
  required int entryCount,
  required List<JournalEntry> entriesBeforeDelete,
  Journal? fallbackJournalToPush,
}) async {
  if (fallbackJournalToPush != null) {
    remoteSync.pushJournal(fallbackJournalToPush);
  }

  if (choice == DeleteContainerChoice.deleteAll && entryCount > 0) {
    final now = utcNow();
    for (final entry in entriesBeforeDelete) {
      remoteSync.pushJournalEntryNow(entry.copyWith(deletedAt: now));
    }
  } else if (choice == DeleteContainerChoice.moveToDefault && entryCount > 0) {
    for (final entry in entriesBeforeDelete) {
      remoteSync.pushJournalEntryNow(
        entry.copyWith(journalId: legacyJournalId),
      );
    }
  }

  await remoteSync.pushJournalById(journal.id);
}

/// Deletes a journal locally first (fast), updates providers, then syncs remotely.
///
/// [onConfirmed] runs immediately after the user confirms, before local I/O.
Future<bool> deleteJournalList(
  BuildContext context,
  WidgetRef ref, {
  required Journal journal,
  required List<Journal> allJournals,
  required int entryCount,
  VoidCallback? onConfirmed,
  VoidCallback? onLocalDeleteFailed,
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

  onConfirmed?.call();

  final repo = ref.read(journalRepositoryProvider);
  final remoteSync = ref.read(remoteSyncServiceProvider);
  Journal? fallbackJournalToPush;
  var entriesBeforeDelete = const <JournalEntry>[];

  try {
    if (entryCount > 0) {
      entriesBeforeDelete = await repo.listEntries(journalId: journal.id);
    }

    if (choice == DeleteContainerChoice.deleteAll && entryCount > 0) {
      await repo.softDeleteEntriesInJournal(journal.id);
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
        fallbackJournalToPush = fallback;
      }
      await repo.reassignEntriesJournal(journal.id, legacyJournalId);
    }

    await repo.softDeleteJournal(journal.id);
  } catch (error, stackTrace) {
    onLocalDeleteFailed?.call();
    FlutterError.reportError(
      FlutterErrorDetails(
        exception: error,
        stack: stackTrace,
        library: 'journal_list_actions',
        context: ErrorDescription('while deleting journal locally'),
      ),
    );
    return false;
  }

  _invalidateJournalDeleteProviders(ref, journal.id);

  unawaited(
    _syncJournalDeleteRemote(
      remoteSync: remoteSync,
      journal: journal,
      choice: choice,
      entryCount: entryCount,
      entriesBeforeDelete: entriesBeforeDelete,
      fallbackJournalToPush: fallbackJournalToPush,
    ).catchError((Object error, StackTrace stackTrace) {
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: error,
          stack: stackTrace,
          library: 'journal_list_actions',
          context: ErrorDescription('while syncing journal delete remotely'),
        ),
      );
    }),
  );

  return true;
}

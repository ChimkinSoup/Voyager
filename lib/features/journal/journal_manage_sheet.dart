import 'package:flutter/material.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/constants/journal_constants.dart';
import 'package:voyager/core/utils/ids.dart';
import 'package:voyager/core/widgets/confirm_dialog.dart';
import 'package:voyager/core/widgets/create_name_color_dialog.dart';
import 'package:voyager/core/widgets/palette_color_picker.dart';
import 'package:voyager/core/widgets/voyager_menu_catalog.dart';
import 'package:voyager/domain/models/journal_models.dart';

Future<String?> showJournalManageSheet(
  BuildContext context,
  WidgetRef ref,
) async {
  final createdId = await showDialog<String?>(
    context: context,
    builder: (context) => const _JournalManageDialog(),
  );
  ref.invalidate(journalsProvider);
  ref.invalidate(journalEntriesProvider);
  return createdId;
}

class _JournalManageDialog extends ConsumerStatefulWidget {
  const _JournalManageDialog();

  @override
  ConsumerState<_JournalManageDialog> createState() =>
      _JournalManageDialogState();
}

class _JournalManageDialogState extends ConsumerState<_JournalManageDialog> {
  var _loading = true;
  List<Journal> _journals = [];
  Map<String, int> _entryCounts = {};
  String? _createdJournalId;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    setState(() => _loading = true);
    final repo = ref.read(journalRepositoryProvider);
    final journals = await repo.listJournals();
    final entries = await repo.listEntries();
    final counts = <String, int>{};
    for (final journal in journals) {
      counts[journal.id] = entries
          .where((e) => e.journalId == journal.id)
          .length;
    }
    counts[legacyJournalId] = entries
        .where((e) => e.journalId == legacyJournalId)
        .length;
    if (!mounted) return;
    setState(() {
      _journals = journals;
      _entryCounts = counts;
      _loading = false;
    });
  }

  Future<void> _createJournal() async {
    final palette = ref.read(colorPaletteProvider);
    final defaultJournalColor = Theme.of(
      context,
    ).colorScheme.primary.toARGB32();
    final assigner = paletteFromItems(
      _journals.map((j) => j.colorValue),
      palette,
    );
    final initialColor = assigner.nextColor();
    final result = await showCreateNameColorDialog(
      context,
      title: 'New journal',
      palette: palette,
      initialColor: initialColor,
      usedColors: _journals
          .where((j) => j.colorValue != null)
          .map((j) => j.colorValue!)
          .toSet(),
    );
    if (result == null) return;

    final repo = ref.read(journalRepositoryProvider);
    final remoteSync = ref.read(remoteSyncServiceProvider);
    final now = utcNow();
    final trimmed = result.name;

    if (_journals.isEmpty) {
      final legacy = Journal(
        id: legacyJournalId,
        name: 'Journal',
        colorValue: defaultJournalColor,
        createdAt: now,
        updatedAt: now,
      );
      final named = Journal(
        id: newId(),
        name: trimmed,
        colorValue: result.color,
        createdAt: now,
        updatedAt: now,
      );
      await repo.upsertJournal(legacy);
      remoteSync.pushJournal(legacy);

      final entries = await repo.listEntries();
      for (final entry in entries) {
        if (entry.journalId == legacyJournalId ||
            !_journals.any((j) => j.id == entry.journalId)) {
          final migrated = entry.copyWith(journalId: legacy.id);
          await repo.upsertEntry(migrated);
          remoteSync.pushJournalEntry(migrated);
        }
      }
      await repo.upsertJournal(named);
      remoteSync.pushJournal(named);
      _createdJournalId = named.id;
    } else {
      final journal = Journal(
        id: newId(),
        name: trimmed,
        colorValue: result.color,
        createdAt: now,
        updatedAt: now,
      );
      await repo.upsertJournal(journal);
      remoteSync.pushJournal(journal);
      _createdJournalId = journal.id;
    }
    await _reload();
  }

  Future<void> _renameJournal(Journal journal) async {
    final name = await _promptName('Rename journal', initial: journal.name);
    if (name == null || name.trim().isEmpty || name.trim() == journal.name) {
      return;
    }
    final updated = journal.copyWith(name: name.trim());
    await ref.read(journalRepositoryProvider).upsertJournal(updated);
    ref.read(remoteSyncServiceProvider).pushJournal(updated);
    await _reload();
  }

  Future<void> _pickColor(Journal journal) async {
    final color = await pickPaletteColorWithRef(
      ref,
      context,
      current: journal.colorValue,
      usedColors: _journals
          .where((item) => item.id != journal.id && item.colorValue != null)
          .map((item) => item.colorValue!)
          .toSet(),
    );
    if (color == null) return;
    final updated = journal.copyWith(colorValue: color);
    await ref.read(journalRepositoryProvider).upsertJournal(updated);
    ref.read(remoteSyncServiceProvider).pushJournal(updated);
    await _reload();
  }

  Future<void> _deleteJournal(Journal journal) async {
    if (journal.id == legacyJournalId) return;
    final count = _entryCounts[journal.id] ?? 0;
    final confirmed = await showConfirmDialog(
      context,
      title: 'Delete "${journal.name}"?',
      message: count == 0
          ? 'This journal has no entries and will be removed.'
          : 'This journal has $count entries. They will be kept under the default journal.',
    );
    if (!confirmed) return;

    final repo = ref.read(journalRepositoryProvider);
    final remoteSync = ref.read(remoteSyncServiceProvider);
    if (count > 0) {
      final fallback = _journals.firstWhere(
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
      if (!_journals.any((item) => item.id == legacyJournalId)) {
        await repo.upsertJournal(fallback);
        remoteSync.pushJournal(fallback);
      }
      final entries = await repo.listEntries(journalId: journal.id);
      await repo.reassignEntriesJournal(journal.id, legacyJournalId);
      for (final entry in entries) {
        final migrated = entry.copyWith(journalId: legacyJournalId);
        remoteSync.pushJournalEntry(migrated);
      }
    }
    await repo.softDeleteJournal(journal.id);
    await remoteSync.pushJournalById(journal.id);
    await _reload();
  }

  Future<String?> _promptName(String title, {String? initial}) async {
    final controller = TextEditingController(text: initial ?? '');
    return showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: InputDecoration(labelText: title),
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

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Manage journals'),
      content: SizedBox(
        width: 480,
        child: _loading
            ? const SizedBox(
                height: 120,
                child: Center(child: CircularProgressIndicator()),
              )
            : Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (_journals.isEmpty)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: Text(
                        'No journals yet. Creating your first journal will also keep existing entries in a journal named "Journal".',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                  Flexible(
                    child: ListView.separated(
                      shrinkWrap: true,
                      itemCount: _journals.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 8),
                      itemBuilder: (context, index) {
                        final journal = _journals[index];
                        final count = _entryCounts[journal.id] ?? 0;
                        return ListTile(
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14),
                          ),
                          tileColor: Theme.of(context).colorScheme.surface,
                          leading: CircleAvatar(
                            backgroundColor: Color(
                              journal.colorValue ?? 0xFF7C9EFF,
                            ),
                          ),
                          title: Text(journal.name),
                          subtitle: Text(
                            '$count ${count == 1 ? 'entry' : 'entries'}',
                          ),
                          trailing: PopupMenuButton<VoyagerMenuCatalogEntry>(
                            onSelected: (action) async {
                              switch (action) {
                                case VoyagerMenuCatalogEntry.rename:
                                  await _renameJournal(journal);
                                case VoyagerMenuCatalogEntry.changeColor:
                                  await _pickColor(journal);
                                case VoyagerMenuCatalogEntry.delete:
                                  await _deleteJournal(journal);
                                default:
                                  break;
                              }
                            },
                            itemBuilder: (context) => buildCatalogMenu(
                              context,
                              from: journal.id == legacyJournalId
                                  ? entityManageMenuEntries.where(
                                      (entry) =>
                                          entry !=
                                          VoyagerMenuCatalogEntry.delete,
                                    )
                                  : entityManageMenuEntries,
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ],
              ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, _createdJournalId),
          child: const Text('Close'),
        ),
        FilledButton.icon(
          onPressed: _createJournal,
          icon: const Icon(PhosphorIconsRegular.plus),
          label: const Text('New journal'),
        ),
      ],
    );
  }
}

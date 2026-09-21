import 'package:flutter/material.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/constants/journal_constants.dart';
import 'package:voyager/core/widgets/glass_button.dart';
import 'package:voyager/core/widgets/voyager_dialog.dart';
import 'package:voyager/core/widgets/voyager_menu_catalog.dart';
import 'package:voyager/domain/models/journal_models.dart';
import 'package:voyager/features/journal/journal_list_actions.dart';
import 'package:voyager/features/journal/journal_settings_dialog.dart';

/// Create, rename, recolour, configure and delete journals — everything the
/// switcher's nested ⋮ used to carry, in one dialog behind the header gear.
///
/// Returns the id of a journal created here, so the page can open into it.
Future<String?> showJournalManageSheet(
  BuildContext context,
  WidgetRef ref,
) async {
  final createdId = await showVoyagerDialog<String?>(
    context: context,
    builder: (context) => const _JournalManageDialog(),
  );
  ref.invalidate(journalsProvider);
  ref.invalidate(journalEntryCountsProvider);
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
  Map<String, int> _counts = {};
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
    final counts = <String, int>{};
    for (final journal in journals) {
      final entries = await repo.listEntries(journalId: journal.id);
      counts[journal.id] = entries.length;
    }
    if (!mounted) return;
    setState(() {
      _journals = journals;
      _counts = counts;
      _loading = false;
    });
  }

  Future<void> _createJournal() async {
    final created = await createJournalList(context, ref);
    if (created == null || !mounted) return;
    _createdJournalId = created.id;
    await _reload();
  }

  Future<void> _renameJournal(Journal journal) async {
    await renameJournalList(context, ref, journal);
    if (!mounted) return;
    await _reload();
  }

  Future<void> _pickColor(Journal journal) async {
    await changeJournalListColor(context, ref, journal, _journals);
    if (!mounted) return;
    await _reload();
  }

  Future<void> _openSettings(Journal journal) async {
    await showJournalSettingsDialog(context, ref, journal);
    if (!mounted) return;
    await _reload();
  }

  Future<void> _deleteJournal(Journal journal) async {
    final deleted = await deleteJournalList(
      context,
      ref,
      journal: journal,
      allJournals: _journals,
      entryCount: _counts[journal.id] ?? 0,
    );
    if (!deleted || !mounted) return;
    await _reload();
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
            : ListView.separated(
                shrinkWrap: true,
                itemCount: _journals.length,
                separatorBuilder: (_, _) => const SizedBox(height: 8),
                itemBuilder: (context, index) {
                  final journal = _journals[index];
                  final count = _counts[journal.id] ?? 0;
                  return ListTile(
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                    tileColor: Theme.of(context).colorScheme.surface,
                    leading: CircleAvatar(
                      backgroundColor: Color(
                        journal.colorValue ??
                            Theme.of(context).colorScheme.primary.toARGB32(),
                      ),
                    ),
                    title: Text(journal.name),
                    subtitle: Text(count == 1 ? '1 entry' : '$count entries'),
                    trailing: PopupMenuButton<VoyagerMenuCatalogEntry>(
                      onSelected: (action) async {
                        switch (action) {
                          case VoyagerMenuCatalogEntry.rename:
                            await _renameJournal(journal);
                          case VoyagerMenuCatalogEntry.changeColor:
                            await _pickColor(journal);
                          case VoyagerMenuCatalogEntry.settings:
                            await _openSettings(journal);
                          case VoyagerMenuCatalogEntry.delete:
                            await _deleteJournal(journal);
                          default:
                            break;
                        }
                      },
                      itemBuilder: (context) => buildCatalogMenu(
                        context,
                        from: journal.id == legacyJournalId
                            ? defaultConfigurableManageMenuEntries
                            : configurableManageMenuEntries,
                      ),
                    ),
                  );
                },
              ),
      ),
      actions: [
        GlassButton(
          dense: true,
          onPressed: () => Navigator.pop(context, _createdJournalId),
          label: 'Close',
        ),
        GlassButton(
          dense: true,
          onPressed: _createJournal,
          icon: const Icon(PhosphorIconsRegular.plus),
          label: 'New journal',
        ),
      ],
    );
  }
}

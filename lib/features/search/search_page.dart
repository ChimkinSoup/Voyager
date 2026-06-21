import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/utils/journal_tags.dart';
import 'package:voyager/core/widgets/keep_alive_scroll.dart';
import 'package:voyager/core/widgets/labeled_text_field.dart';
import 'package:voyager/domain/models/journal_models.dart';
import 'package:voyager/features/shell/shell_page_storage_keys.dart';

class SearchPage extends ConsumerStatefulWidget {
  const SearchPage({super.key});

  @override
  ConsumerState<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends ConsumerState<SearchPage> {
  final _queryController = TextEditingController();

  @override
  void dispose() {
    _queryController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final entriesAsync = ref.watch(journalEntriesProvider);
    final search = ref.watch(searchServiceProvider);

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          LabeledTextField(
            label: 'Search keywords or #tag',
            controller: _queryController,
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 16),
          Expanded(
            child: entriesAsync.when(
              data: (entries) {
                final parsedQuery = _parseSearchQuery(_queryController.text);
                final results = search.searchEntries(
                  entries: entries,
                  query: parsedQuery.keywords,
                  tagFilter: parsedQuery.tag == null
                      ? null
                      : [parsedQuery.tag!],
                );
                return KeepAliveScrollList(
                  storageKey: ShellPageStorageKeys.searchResults,
                  itemCount: results.length,
                  itemBuilder: (_, i) {
                    final entry = results[i];
                    return ListTile(
                      title: Text(
                        entry.title.isEmpty ? 'Untitled' : entry.title,
                      ),
                      subtitle: Text(
                        entry.body,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      onTap: () async {
                        await showDialog<void>(
                          context: context,
                          builder: (context) => _SearchEntryDialog(
                            entry: entry,
                            onSaved: () {
                              ref.invalidate(journalEntriesProvider);
                            },
                          ),
                        );
                      },
                    );
                  },
                );
              },
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (e, _) => Center(child: Text('$e')),
            ),
          ),
        ],
      ),
    );
  }
}

({String? tag, String keywords}) _parseSearchQuery(String rawQuery) {
  final parts = rawQuery.trim().split(RegExp(r'\s+'));
  String? tag;
  final keywords = <String>[];
  for (final part in parts) {
    if (part.isEmpty) continue;
    if (tag == null && part.startsWith('#') && part.length > 1) {
      tag = part.substring(1);
    } else {
      keywords.add(part);
    }
  }
  return (tag: tag, keywords: keywords.join(' '));
}

class _SearchEntryDialog extends ConsumerStatefulWidget {
  const _SearchEntryDialog({required this.entry, required this.onSaved});

  final JournalEntry entry;
  final VoidCallback onSaved;

  @override
  ConsumerState<_SearchEntryDialog> createState() => _SearchEntryDialogState();
}

class _SearchEntryDialogState extends ConsumerState<_SearchEntryDialog> {
  late final TextEditingController _titleController;
  late final TextEditingController _bodyController;

  @override
  void initState() {
    super.initState();
    _titleController = TextEditingController(text: widget.entry.title);
    _bodyController = TextEditingController(text: widget.entry.body);
  }

  @override
  void dispose() {
    _titleController.dispose();
    _bodyController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final body = _bodyController.text.trimRight();
    final updated = widget.entry.copyWith(
      title: _titleController.text.trim(),
      body: body,
      tags: extractTags(body),
    );
    await ref.read(journalRepositoryProvider).upsertEntry(updated);
    ref.read(remoteSyncServiceProvider).pushJournalEntryNow(updated);
    widget.onSaved();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Journal entry'),
      content: SizedBox(
        width: 640,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            LabeledTextField(label: 'Title', controller: _titleController),
            const SizedBox(height: 12),
            SizedBox(
              height: 320,
              child: LabeledTextField(
                label: 'Body',
                controller: _bodyController,
                expands: true,
                keyboardType: TextInputType.multiline,
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Close'),
        ),
        FilledButton(
          onPressed: () async {
            await _save();
            if (context.mounted) Navigator.pop(context);
          },
          child: const Text('Save'),
        ),
      ],
    );
  }
}


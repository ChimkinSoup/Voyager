import 'package:flutter/material.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/widgets/keep_alive_scroll.dart';
import 'package:voyager/core/widgets/labeled_text_field.dart';
import 'package:voyager/features/shell/shell_page_storage_keys.dart';

class SearchPage extends ConsumerStatefulWidget {
  const SearchPage({super.key});

  @override
  ConsumerState<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends ConsumerState<SearchPage> {
  final _queryController = TextEditingController();
  var _tagOnly = false;

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
            label: _tagOnly ? 'Tag filter' : 'Search keywords',
            controller: _queryController,
            onChanged: (_) => setState(() {}),
          ),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              onPressed: () => setState(() => _tagOnly = !_tagOnly),
              icon: Icon(_tagOnly ? PhosphorIconsRegular.tag : PhosphorIconsRegular.textT),
              label: Text(_tagOnly ? 'Tag mode' : 'Keyword mode'),
            ),
          ),
          const SizedBox(height: 16),
          Expanded(
            child: entriesAsync.when(
              data: (entries) {
                final results = search.searchEntries(
                  entries: entries,
                  query: _queryController.text,
                  tagFilter: _tagOnly && _queryController.text.isNotEmpty
                      ? [_queryController.text.replaceAll('#', '')]
                      : null,
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

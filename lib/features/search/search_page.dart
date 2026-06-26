import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/icons/voyager_icons.dart';
import 'package:voyager/core/theme/voyager_menu_theme.dart';
import 'package:voyager/core/utils/journal_tags.dart';
import 'package:voyager/core/utils/time_format.dart';
import 'package:voyager/core/widgets/datetime_picker_dialog.dart';
import 'package:voyager/core/widgets/journal_color_flag.dart';
import 'package:voyager/core/widgets/keep_alive_scroll.dart';
import 'package:voyager/core/widgets/labeled_text_field.dart';
import 'package:voyager/core/widgets/tag_highlighted_text_field.dart';
import 'package:voyager/core/widgets/voyager_menu_catalog.dart';
import 'package:voyager/core/widgets/voyager_popup_menu_item.dart';
import 'package:voyager/core/widgets/weather_icon.dart';
import 'package:voyager/domain/models/journal_models.dart';
import 'package:voyager/features/shell/shell_page_storage_keys.dart';

class SearchPage extends ConsumerStatefulWidget {
  const SearchPage({super.key});

  @override
  ConsumerState<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends ConsumerState<SearchPage> {
  final _queryController = TextEditingController();
  final _queryFocusNode = FocusNode();

  @override
  void dispose() {
    _queryController.dispose();
    _queryFocusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final entriesAsync = ref.watch(journalEntriesProvider);
    final journalsAsync = ref.watch(journalsProvider);
    final search = ref.watch(searchServiceProvider);

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          TagHighlightedTextField(
            controller: _queryController,
            focusNode: _queryFocusNode,
            hintText: 'Search keywords or #tag',
            tagColorFor: colorForTag,
            decoration: const InputDecoration(
              labelText: 'Search keywords or #tag',
            ),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 16),
          Expanded(
            child: entriesAsync.when(
              data: (entries) => journalsAsync.when(
                data: (journals) {
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
                              journals: journals,
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
                loading: () =>
                    const Center(child: CircularProgressIndicator()),
                error: (e, _) => Center(child: Text('$e')),
              ),
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
  const _SearchEntryDialog({
    required this.entry,
    required this.journals,
    required this.onSaved,
  });

  final JournalEntry entry;
  final List<Journal> journals;
  final VoidCallback onSaved;

  @override
  ConsumerState<_SearchEntryDialog> createState() => _SearchEntryDialogState();
}

class _SearchEntryDialogState extends ConsumerState<_SearchEntryDialog> {
  late final TextEditingController _titleController;
  late final TextEditingController _bodyController;
  late final FocusNode _bodyFocusNode;
  late int? _mood;
  late String _weatherIcon;

  @override
  void initState() {
    super.initState();
    _titleController = TextEditingController(text: widget.entry.title);
    _bodyController = TextEditingController(text: widget.entry.body);
    _bodyFocusNode = FocusNode();
    _mood = widget.entry.mood;
    _weatherIcon = widget.entry.weatherIcon ?? 'sunny';
  }

  @override
  void dispose() {
    _titleController.dispose();
    _bodyController.dispose();
    _bodyFocusNode.dispose();
    super.dispose();
  }

  Journal? get _journal {
    for (final journal in widget.journals) {
      if (journal.id == widget.entry.journalId) return journal;
    }
    return null;
  }

  Color get _accentColor => Color(
    _journal?.colorValue ?? Theme.of(context).colorScheme.primary.toARGB32(),
  );

  Future<void> _save() async {
    final body = _bodyController.text.trimRight();
    final updated = widget.entry.copyWith(
      title: _titleController.text.trim(),
      body: body,
      tags: extractTags(body),
      mood: _mood,
      weatherIcon: _weatherIcon,
    );
    await ref.read(journalRepositoryProvider).upsertEntry(updated);
    ref.read(remoteSyncServiceProvider).pushJournalEntryNow(updated);
    widget.onSaved();
  }

  Future<void> _changeEntryDate() async {
    final picked = await showDateTimePickerDialog(
      context,
      initialDateTime: widget.entry.entryDate.toLocal(),
    );
    if (picked == null || !mounted) return;
    final updated = widget.entry.copyWith(entryDate: picked.toUtc());
    await ref.read(journalRepositoryProvider).upsertEntry(updated);
    ref.read(remoteSyncServiceProvider).pushJournalEntryNow(updated);
    widget.onSaved();
    if (mounted) Navigator.pop(context);
  }

  Future<void> _moveToJournal(String journalId) async {
    if (journalId == widget.entry.journalId) return;
    final updated = widget.entry.copyWith(journalId: journalId);
    await ref.read(journalRepositoryProvider).upsertEntry(updated);
    ref.read(remoteSyncServiceProvider).pushJournalEntryNow(updated);
    widget.onSaved();
    if (mounted) Navigator.pop(context);
  }

  String _entryDateTimeLabel(BuildContext context) {
    final local = widget.entry.entryDate.toLocal();
    final materialLocalizations = MaterialLocalizations.of(context);
    return '${materialLocalizations.formatShortDate(local)} ${formatTime12Hour(local)}';
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Journal entry'),
      content: SizedBox(
        width: 640,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Stack(
                clipBehavior: Clip.none,
                children: [
                  LabeledTextField(
                    label: 'Title',
                    controller: _titleController,
                    textInputAction: TextInputAction.next,
                    onSubmitted: (_) => _bodyFocusNode.requestFocus(),
                  ),
                  Positioned(
                    top: 0,
                    right: 0,
                    child: JournalTitleCornerFlag(
                      colorValue: _accentColor.toARGB32(),
                      onSelected: _moveToJournal,
                      menuEntries: (_) => [
                        for (var i = 0; i < widget.journals.length; i++)
                          VoyagerPopupMenuItem<String>(
                            value: widget.journals[i].id,
                            position: VoyagerMenuTheme.positionFor(
                              i,
                              widget.journals.length,
                            ),
                            child: Row(
                              children: [
                                JournalBookmarkFlag(
                                  colorValue:
                                      widget.journals[i].colorValue ??
                                      _accentColor.toARGB32(),
                                  size: 12,
                                ),
                                const SizedBox(width: 8),
                                Expanded(child: Text(widget.journals[i].name)),
                              ],
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Text('Mood', style: TextStyle(color: _accentColor)),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Slider(
                      value: (_mood ?? 5).toDouble(),
                      min: 1,
                      max: 10,
                      divisions: 9,
                      activeColor: _accentColor,
                      onChanged: (value) =>
                          setState(() => _mood = value.round()),
                    ),
                  ),
                  PopupMenuButton<VoyagerMenuCatalogEntry>(
                    icon: Icon(
                      weatherIconData(_weatherIcon),
                      color: _accentColor,
                    ),
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(
                      minWidth: 40,
                      minHeight: 40,
                    ),
                    onSelected: (entry) =>
                        setState(() => _weatherIcon = entry.weatherIconValue!),
                    itemBuilder: (context) => buildCatalogMenu(
                      context,
                      from: weatherMenuEntries,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Flexible(
                    child: OutlinedButton.icon(
                      onPressed: _changeEntryDate,
                      icon: Icon(
                        VoyagerIcons.calendar,
                        size: 18,
                        color: _accentColor,
                      ),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: _accentColor,
                        side: BorderSide(
                          color: _accentColor.withValues(alpha: 0.7),
                        ),
                      ),
                      label: Text(
                        _entryDateTimeLabel(context),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              SizedBox(
                height: 320,
                child: TagHighlightedTextField(
                  controller: _bodyController,
                  focusNode: _bodyFocusNode,
                  expands: true,
                  keyboardType: TextInputType.multiline,
                  tagColorFor: colorForTag,
                  decoration: const InputDecoration(
                    labelText: 'Body',
                    alignLabelWithHint: true,
                  ),
                ),
              ),
            ],
          ),
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

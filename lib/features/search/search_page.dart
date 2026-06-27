import 'dart:math' as math;

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
import 'package:voyager/core/widgets/mood_gradient_slider.dart';
import 'package:voyager/core/widgets/search_highlight_text.dart';
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
    final theme = Theme.of(context);
    final settings = ref.watch(settingsProvider).valueOrNull;
    final accentColor = Color(
      settings?.accentColor ?? theme.colorScheme.primary.toARGB32(),
    );

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          TagHighlightedTextField(
            controller: _queryController,
            focusNode: _queryFocusNode,
            cursorColor: accentColor,
            hintText: 'Search keywords or #tag',
            onChanged: (_) => setState(() {}),
            decoration: const InputDecoration(
              filled: false,
              border: InputBorder.none,
              enabledBorder: InputBorder.none,
              focusedBorder: InputBorder.none,
            ),
          ),
          const SizedBox(height: 16),
          Expanded(
            child: entriesAsync.when(
              skipLoadingOnReload: true,
              data: (entries) => journalsAsync.when(
                skipLoadingOnReload: true,
                data: (journals) {
                  final parsedQuery = _parseSearchQuery(_queryController.text);
                  final results = search.searchEntries(
                    entries: entries,
                    query: parsedQuery.keywords,
                    tagFilter: parsedQuery.tag == null
                        ? null
                        : [parsedQuery.tag!],
                  );
                  final keywords = parsedQuery.keywords
                      .split(RegExp(r'\s+'))
                      .where((k) => k.isNotEmpty)
                      .toList();
                  return KeepAliveScrollList(
                    storageKey: ShellPageStorageKeys.searchResults,
                    itemCount: results.length,
                    itemBuilder: (_, i) {
                      final entry = results[i];
                      final bodyStyle = theme.textTheme.bodyMedium!;
                      return ListTile(
                        title: searchHighlightedText(
                          entry.title.isEmpty ? 'Untitled' : entry.title,
                          style: bodyStyle.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                          keywords: keywords,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: searchHighlightedText(
                          entry.body,
                          style: bodyStyle,
                          keywords: keywords,
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
  late JournalEntry _entry;
  late int? _mood;
  late String _weatherIcon;

  @override
  void initState() {
    super.initState();
    _entry = widget.entry;
    _titleController = TextEditingController(text: _entry.title);
    _bodyController = TextEditingController(text: _entry.body);
    _bodyFocusNode = FocusNode();
    _mood = _entry.mood;
    _weatherIcon = _entry.weatherIcon ?? 'sunny';
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
      if (journal.id == _entry.journalId) return journal;
    }
    return null;
  }

  Color get _accentColor => Color(
    _journal?.colorValue ?? Theme.of(context).colorScheme.primary.toARGB32(),
  );

  Future<void> _save() async {
    final body = _bodyController.text.trimRight();
    final updated = _entry.copyWith(
      title: _titleController.text.trim(),
      body: body,
      tags: extractTags(body),
      mood: _mood,
      weatherIcon: _weatherIcon,
    );
    await ref.read(journalRepositoryProvider).upsertEntry(updated);
    ref.read(remoteSyncServiceProvider).pushJournalEntryNow(updated);
    if (mounted) setState(() => _entry = updated);
    widget.onSaved();
  }

  Future<void> _changeEntryDate() async {
    final picked = await showDateTimePickerDialog(
      context,
      initialDateTime: _entry.entryDate.toLocal(),
    );
    if (picked == null || !mounted) return;
    final updated = _entry.copyWith(entryDate: picked.toUtc());
    await ref.read(journalRepositoryProvider).upsertEntry(updated);
    ref.read(remoteSyncServiceProvider).pushJournalEntryNow(updated);
    if (!mounted) return;
    setState(() => _entry = updated);
    widget.onSaved();
  }

  Future<void> _moveToJournal(String journalId) async {
    if (journalId == _entry.journalId) return;
    final updated = _entry.copyWith(journalId: journalId);
    await ref.read(journalRepositoryProvider).upsertEntry(updated);
    ref.read(remoteSyncServiceProvider).pushJournalEntryNow(updated);
    if (!mounted) return;
    setState(() => _entry = updated);
    widget.onSaved();
  }

  String _entryDateTimeLabel(BuildContext context) {
    final local = _entry.entryDate.toLocal();
    final materialLocalizations = MaterialLocalizations.of(context);
    return '${materialLocalizations.formatShortDate(local)} ${formatTime12Hour(local)}';
  }

  @override
  Widget build(BuildContext context) {
    final dialogWidth = math.min(
      920.0,
      MediaQuery.sizeOf(context).width - 48,
    );

    return AlertDialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
      title: const Text('Journal entry'),
      content: SizedBox(
        width: dialogWidth,
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
                    accentColor: _accentColor,
                    contentPadding: const EdgeInsets.fromLTRB(16, 16, 56, 16),
                    onSubmitted: (_) => _bodyFocusNode.requestFocus(),
                  ),
                  Positioned(
                    top: 0,
                    right: 10,
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
                    child: MoodGradientSlider(
                      value: _mood ?? 5,
                      accent: _accentColor,
                      onChanged: (value) => setState(() => _mood = value),
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
                height: 480,
                child: TagHighlightedTextField(
                  controller: _bodyController,
                  focusNode: _bodyFocusNode,
                  cursorColor: _accentColor,
                  expands: true,
                  hintText: 'Start writing...',
                  decoration: const InputDecoration(
                    filled: false,
                    border: InputBorder.none,
                    enabledBorder: InputBorder.none,
                    focusedBorder: InputBorder.none,
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
          style: FilledButton.styleFrom(backgroundColor: _accentColor),
          child: const Text('Save'),
        ),
      ],
    );
  }
}

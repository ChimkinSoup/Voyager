import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/icons/voyager_icons.dart';
import 'package:voyager/core/utils/ids.dart';
import 'package:voyager/core/widgets/confirm_dialog.dart';
import 'package:voyager/core/widgets/context_menu.dart';
import 'package:voyager/features/journal/journal_entry_actions.dart';
import 'package:voyager/core/theme/voyager_menu_theme.dart';
import 'package:voyager/core/utils/journal_tags.dart';
import 'package:voyager/core/utils/time_format.dart';
import 'package:intl/intl.dart';
import 'package:voyager/core/widgets/contextual_popover.dart';
import 'package:voyager/core/widgets/date_selector_popover.dart';
import 'package:voyager/core/widgets/datetime_selector_popover.dart';
import 'package:voyager/core/widgets/time_selector_popovers.dart';
import 'package:voyager/core/widgets/datetime_picker_dialog.dart';
import 'package:voyager/core/widgets/journal_color_flag.dart';
import 'package:voyager/core/widgets/selector_pill.dart';
import 'package:voyager/core/widgets/enter_to_submit_scope.dart';
import 'package:voyager/core/widgets/glass_button.dart';
import 'package:voyager/core/widgets/keep_alive_scroll.dart';
import 'package:voyager/core/widgets/labeled_text_field.dart';
import 'package:voyager/core/widgets/mood_gradient_slider.dart';
import 'package:voyager/core/widgets/search_highlight_text.dart';
import 'package:voyager/core/widgets/tag_highlighted_text_field.dart';
import 'package:voyager/core/widgets/voyager_dialog.dart';
import 'package:voyager/core/widgets/voyager_menu_catalog.dart';
import 'package:voyager/core/widgets/voyager_popup_menu_item.dart';
import 'package:voyager/core/widgets/weather_icon.dart';
import 'package:voyager/domain/models/journal_models.dart';
import 'package:voyager/core/sync/remote_sync_service.dart';
import 'package:voyager/core/sync/journal_write_coordinator.dart';
import 'package:voyager/domain/repositories/repositories.dart';
import 'package:voyager/features/search/search_entry_save_helper.dart';
import 'package:voyager/features/shell/shell_page_storage_keys.dart';
import 'package:voyager/core/sync/pending_flush_registry.dart';
import 'package:voyager/core/tags/tag_suggestions.dart';
import 'package:voyager/core/widgets/voyager_scroll_view.dart';

class SearchPage extends ConsumerStatefulWidget {
  const SearchPage({super.key});

  @override
  ConsumerState<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends ConsumerState<SearchPage> {
  final _queryController = TextEditingController();
  final _queryFocusNode = FocusNode();

  final Map<String, JournalEntry> _localUpdates = {};

  /// Entries deleted from the search results this session, hidden immediately
  /// so the list doesn't wait for the provider to refresh.
  final Set<String> _deletedIds = {};

  @override
  void dispose() {
    _queryController.dispose();
    _queryFocusNode.dispose();
    super.dispose();
  }

  void _invalidateEntryCaches() {
    ref.invalidate(journalEntriesProvider);
    ref.invalidate(journalListEntriesProvider);
    ref.invalidate(journalEntryCountsProvider);
  }

  Future<void> _deleteEntry(JournalEntry entry) async {
    final confirmed = await showConfirmDialog(
      context,
      title: 'Delete entry?',
      message: 'This entry will be moved to trash.',
    );
    if (!confirmed || !mounted) return;
    await ref.read(journalRepositoryProvider).softDeleteEntry(entry.id);
    ref
        .read(remoteSyncServiceProvider)
        .pushJournalEntryNow(entry.copyWith(deletedAt: utcNow()));
    if (!mounted) return;
    setState(() {
      _deletedIds.add(entry.id);
      _localUpdates.remove(entry.id);
    });
    _invalidateEntryCaches();
  }

  Future<void> _changeEntryJournal(
    JournalEntry entry,
    List<Journal> journals,
  ) async {
    final targetJournalId = await showMoveToJournalDialog(
      context,
      journals: journals,
      currentJournalId: entry.journalId,
    );
    if (targetJournalId == null ||
        targetJournalId == entry.journalId ||
        !mounted) {
      return;
    }
    final repo = ref.read(journalRepositoryProvider);
    final existing = await repo.getEntry(entry.id);
    if (existing == null || !mounted) return;
    final updated = existing.copyWith(journalId: targetJournalId);
    await repo.upsertEntry(updated);
    ref.read(remoteSyncServiceProvider).pushJournalEntryNow(updated);
    if (!mounted) return;
    setState(() => _localUpdates[updated.id] = updated);
    _invalidateEntryCaches();
  }

  @override
  Widget build(BuildContext context) {
    final entriesAsync = ref.watch(
      journalListEntriesProvider(allJournalEntriesScope),
    );
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
            // Search only ever looks at journal entries (see
            // SearchService.searchEntries), so it completes against theirs.
            tagScope: TagScope.journal,
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
                  final mergedEntries = entries
                      .where((e) => !_deletedIds.contains(e.id))
                      .map((e) {
                        final local = _localUpdates[e.id];
                        if (local != null) {
                          if (local.version > e.version) return local;
                          if (local.version == e.version &&
                              !local.updatedAt.isBefore(e.updatedAt))
                            return local;
                        }
                        return e;
                      })
                      .toList();
                  final parsedQuery = _parseSearchQuery(_queryController.text);
                  final results = search.searchEntries(
                    entries: mergedEntries,
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
                      return ContextMenuRegion(
                        items: [
                          ContextMenuItem(
                            label: 'Statistics',
                            icon: PhosphorIconsRegular.chartBar,
                            onTap: () => showJournalEntryStatisticsDialog(
                              context,
                              ref,
                              entry,
                            ),
                          ),
                          ContextMenuItem(
                            label: 'Change Journal',
                            icon: PhosphorIconsRegular.folder,
                            onTap: () => _changeEntryJournal(entry, journals),
                          ),
                          ContextMenuItem(
                            label: 'Delete',
                            icon: PhosphorIconsRegular.trash,
                            isDestructive: true,
                            onTap: () => _deleteEntry(entry),
                          ),
                        ],
                        child: ListTile(
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
                            searchSnippet(entry.body, keywords: keywords),
                            style: bodyStyle,
                            keywords: keywords,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                          onTap: () async {
                            await showVoyagerDialog<void>(
                              context: context,
                              builder: (context) => _SearchEntryDialog(
                                entry: entry,
                                journals: journals,
                                onSaved: (updatedEntry) {
                                  if (mounted) {
                                    setState(() {
                                      _localUpdates[updatedEntry.id] =
                                          updatedEntry;
                                    });
                                    ref.invalidate(journalEntriesProvider);
                                    ref.invalidate(journalListEntriesProvider);
                                    ref.invalidate(journalEntryCountsProvider);
                                  }
                                },
                              ),
                            );
                          },
                        ),
                      );
                    },
                  );
                },
                loading: () => const Center(child: CircularProgressIndicator()),
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
  final void Function(JournalEntry) onSaved;

  @override
  ConsumerState<_SearchEntryDialog> createState() => _SearchEntryDialogState();
}

class _SearchEntryDialogState extends ConsumerState<_SearchEntryDialog> {
  late final TextEditingController _titleController;
  late final TextEditingController _bodyController;
  late final FocusNode _titleFocusNode;
  late final FocusNode _bodyFocusNode;
  late JournalEntry _entry;
  late int? _mood;
  late String _weatherIcon;
  bool _isSaved = false;

  late final Future<void> Function() _lifecycleFlushCallback;

  @override
  void initState() {
    super.initState();
    _lifecycleFlushCallback = _lifecycleFlush;
    PendingFlushRegistry.instance.register(_lifecycleFlushCallback);
    _entry = widget.entry;
    _titleController = TextEditingController(text: _entry.title);
    _bodyController = TextEditingController(text: _entry.body);

    _titleFocusNode = FocusNode();
    _titleFocusNode.onKeyEvent = (node, event) {
      if (event is! KeyDownEvent) return KeyEventResult.ignored;
      if (event.logicalKey == LogicalKeyboardKey.tab &&
          !HardwareKeyboard.instance.isShiftPressed) {
        _bodyFocusNode.requestFocus();
        return KeyEventResult.handled;
      }
      // Enter commits from the title too, not just the body — Tab is what
      // moves between the two fields.
      if (event.logicalKey == LogicalKeyboardKey.enter &&
          !HardwareKeyboard.instance.isShiftPressed) {
        _saveAndClose();
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    };

    // _handleBodyKey is installed by TagHighlightedTextField (see its
    // onKeyEvent param) rather than assigned here: the tag completion popup
    // owns focusNode.onKeyEvent so it can take Enter while it's open, and
    // chains through to this handler otherwise.
    _bodyFocusNode = FocusNode();

    _mood = _entry.mood ?? kDefaultMood;
    _weatherIcon = _entry.weatherIcon ?? 'sunny';
  }

  KeyEventResult _handleBodyKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    if (event.logicalKey == LogicalKeyboardKey.enter &&
        !HardwareKeyboard.instance.isShiftPressed) {
      _saveAndClose();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  JournalWriteCoordinator? _coordinator;
  RemoteSyncService? _remoteSync;
  JournalRepository? _journalRepository;

  bool _isDatePickerOpen = false;

  @override
  void dispose() {
    PendingFlushRegistry.instance.unregister(_lifecycleFlushCallback);
    if (!_isSaved) {
      unawaited(_save());
    }
    _titleController.dispose();
    _bodyController.dispose();
    _titleFocusNode.dispose();
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
    _isSaved = true;
    final title = _titleController.text.trim();
    final body = _bodyController.text.trimRight();

    // Use cached references to avoid calling ref.read() during dispose()
    final helper = SearchEntrySaveHelper(
      coordinator: _coordinator ?? ref.read(journalWriteCoordinatorProvider),
      remoteSync: _remoteSync ?? ref.read(remoteSyncServiceProvider),
      journalRepository:
          _journalRepository ?? ref.read(journalRepositoryProvider),
    );
    final updated = await helper.saveEntry(
      baseline: _entry,
      title: title,
      body: body,
      mood: _mood,
      weatherIcon: _weatherIcon,
      journalId: _entry.journalId,
    );
    if (updated != null) {
      if (mounted) setState(() => _entry = updated);
      widget.onSaved(updated);
    }
  }

  Future<void> _lifecycleFlush() async {
    await _save();
  }

  /// Closes first, then saves: the popup disappearing is the user's
  /// confirmation that Enter landed, so it must not wait on the write.
  void _saveAndClose() {
    unawaited(_save());
    if (mounted) Navigator.pop(context);
  }

  Future<void> _changeEntryDateAndTime(BuildContext buttonContext) async {
    final journal = widget.journals.cast<Journal?>().firstWhere(
      (j) => j?.id == _entry.journalId,
      orElse: () => null,
    );
    final accentColor = Color(
      journal?.colorValue ?? Theme.of(context).colorScheme.primary.toARGB32(),
    );

    setState(() => _isDatePickerOpen = true);
    final pickedDt = await showContextualPopover<DateTime>(
      context: context,
      buttonContext: buttonContext,
      width: 500,
      height: 380,
      accentColor: accentColor,
      builder: (ctx) => DateTimeSelectorPopover(
        initialDateTime: _entry.entryDate.toLocal(),
        accentColor: accentColor,
      ),
    );
    if (mounted) setState(() => _isDatePickerOpen = false);
    if (pickedDt == null) return;

    // Update locally immediately for snappy responsiveness
    final updatedImmediate = _entry.copyWith(entryDate: pickedDt.toUtc());
    if (mounted) {
      setState(() => _entry = updatedImmediate);
      widget.onSaved(updatedImmediate);
    }

    final helper = SearchEntrySaveHelper(
      coordinator: ref.read(journalWriteCoordinatorProvider),
      remoteSync: ref.read(remoteSyncServiceProvider),
      journalRepository: ref.read(journalRepositoryProvider),
    );
    final updated = await helper.saveEntry(
      baseline: _entry,
      title: _titleController.text.trim(),
      body: _bodyController.text.trimRight(),
      mood: _mood,
      weatherIcon: _weatherIcon,
      journalId: _entry.journalId,
      entryDate: pickedDt.toUtc(),
    );
    if (updated != null) {
      if (mounted) setState(() => _entry = updated);
      widget.onSaved(updated);
    }
  }

  Future<void> _moveToJournal(String journalId) async {
    if (journalId == _entry.journalId) return;
    final helper = SearchEntrySaveHelper(
      coordinator: ref.read(journalWriteCoordinatorProvider),
      remoteSync: ref.read(remoteSyncServiceProvider),
      journalRepository: ref.read(journalRepositoryProvider),
    );
    final updated = await helper.saveEntry(
      baseline: _entry,
      title: _titleController.text.trim(),
      body: _bodyController.text.trimRight(),
      mood: _mood,
      weatherIcon: _weatherIcon,
      journalId: journalId,
    );
    if (updated != null) {
      if (mounted) setState(() => _entry = updated);
      widget.onSaved(updated);
    }
  }

  @override
  Widget build(BuildContext context) {
    _coordinator = ref.watch(journalWriteCoordinatorProvider);
    _remoteSync = ref.watch(remoteSyncServiceProvider);
    _journalRepository = ref.watch(journalRepositoryProvider);

    final dialogWidth = math.min(920.0, MediaQuery.sizeOf(context).width - 48);

    return EnterToSubmitScope(
      onSubmit: () async {
        if (context.mounted) Navigator.pop(context);
      },
      child: AlertDialog(
        insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
        title: const Text('Journal entry'),
        content: SizedBox(
          width: dialogWidth,
          child: VoyagerScrollView(
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
                      focusNode: _titleFocusNode,
                      textInputAction: TextInputAction.done,
                      accentColor: _accentColor,
                      contentPadding: const EdgeInsets.fromLTRB(16, 16, 40, 16),
                      onSubmitted: (_) => _saveAndClose(),
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
                                  Expanded(
                                    child: Text(widget.journals[i].name),
                                  ),
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
                        value: _mood,
                        accent: _accentColor,
                        onChanged: (value) => setState(() => _mood = value),
                      ),
                    ),
                    const SizedBox(width: 12),
                    PopupMenuButton<VoyagerMenuCatalogEntry>(
                      tooltip: 'Weather',
                      icon: Icon(
                        weatherIconData(_weatherIcon),
                        color: _accentColor,
                      ),
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(
                        minWidth: 40,
                        minHeight: 40,
                      ),
                      onSelected: (entry) => setState(
                        () => _weatherIcon = entry.weatherIconValue!,
                      ),
                      itemBuilder: (context) =>
                          buildCatalogMenu(context, from: weatherMenuEntries),
                    ),
                    const SizedBox(width: 8),
                    Builder(
                      builder: (ctx) {
                        final label =
                            '${DateFormat.yMMMd().format(_entry.entryDate.toLocal())} at ${formatTime12Hour(_entry.entryDate.toLocal())}';
                        return SelectorPill(
                          dense: false,
                          ellipsize: false,
                          isActive: _isDatePickerOpen,
                          label: label,
                          accentColor: _accentColor,
                          onTap: () => _changeEntryDateAndTime(ctx),
                        );
                      },
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                SizedBox(
                  height: 480,
                  child: TagHighlightedTextField(
                    controller: _bodyController,
                    focusNode: _bodyFocusNode,
                    tagScope: TagScope.journal,
                    onKeyEvent: _handleBodyKey,
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
          GlassButton(
            onPressed: () => Navigator.pop(context),
            label: 'Close',
            dense: true,
          ),
          GlassButton(
            onPressed: () {
              unawaited(_save());
              if (context.mounted) Navigator.pop(context);
            },
            label: 'Save',
            color: _accentColor,
            dense: true,
          ),
        ],
      ),
    );
  }
}

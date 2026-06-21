import 'dart:async';

import 'package:flutter/material.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/constants/app_constants.dart';
import 'package:voyager/core/icons/voyager_icons.dart';
import 'package:voyager/core/theme/voyager_menu_theme.dart';
import 'package:voyager/core/theme/voyager_spacing.dart';
import 'package:voyager/core/widgets/voyager_popup_menu_item.dart';
import 'package:voyager/core/utils/ids.dart';
import 'package:voyager/core/utils/time_format.dart';
import 'package:voyager/core/widgets/datetime_picker_dialog.dart';
import 'package:voyager/core/widgets/keep_alive_scroll.dart';
import 'package:voyager/core/widgets/labeled_text_field.dart';
import 'package:voyager/core/widgets/rounded_dropdown.dart';
import 'package:voyager/domain/models/journal_models.dart';
import 'package:voyager/domain/models/settings_models.dart';
import 'package:voyager/domain/repositories/repositories.dart';
import 'package:voyager/core/widgets/journal_color_flag.dart';
import 'package:voyager/core/widgets/weather_icon.dart';
import 'package:voyager/features/journal/journal_manage_sheet.dart';
import 'package:voyager/features/shell/shell_page_storage_keys.dart';

class JournalPage extends ConsumerStatefulWidget {
  const JournalPage({super.key});

  @override
  ConsumerState<JournalPage> createState() => _JournalPageState();
}

class _JournalPageState extends ConsumerState<JournalPage> {
  static const _allJournals = '__all__';

  String _journalFilter = _allJournals;
  String? _lastViewedJournalId;
  String? _selectedEntryId;
  JournalEntry? _selectedEntry;
  final _titleController = TextEditingController();
  final _entryBodyDrafts = <String, String>{};
  Timer? _metadataSaveTimer;
  var _metadataDirty = false;
  var _suppressAutoSelect = false;
  int? _mood;
  String? _weatherIcon;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(_restoreLastViewedJournal());
    });
  }

  @override
  void dispose() {
    _metadataSaveTimer?.cancel();
    _titleController.dispose();
    super.dispose();
  }

  Future<void> _ensureDefaultJournal() async {
    // Entries can exist before any journal container is created.
  }

  String _journalIdForNewEntry(List<Journal> journals) {
    if (_journalFilter != _allJournals) return _journalFilter;

    if (_lastViewedJournalId != null &&
        journals.any((j) => j.id == _lastViewedJournalId)) {
      return _lastViewedJournalId!;
    }

    final selectedJournalId = _selectedEntry?.journalId;
    if (selectedJournalId != null &&
        journals.any((j) => j.id == selectedJournalId)) {
      return selectedJournalId;
    }

    return journals.first.id;
  }

  Future<void> _restoreLastViewedJournal() async {
    if (!mounted) return;
    final settingsRepo = ref.read(settingsRepositoryProvider);
    final journalRepo = ref.read(journalRepositoryProvider);

    final settings = await settingsRepo.getSettings();
    final savedId = settings.lastViewedJournalId;
    if (savedId == null || !mounted) return;

    final journals = await journalRepo.listJournals();
    if (!mounted) return;
    if (journals.any((j) => j.id == savedId)) {
      setState(() => _lastViewedJournalId = savedId);
    }
  }

  Future<void> _persistLastViewedJournal(
    String journalId,
    SettingsRepository settingsRepo,
  ) async {
    final settings = await settingsRepo.getSettings();
    if (settings.lastViewedJournalId == journalId) return;
    await settingsRepo.saveSettings(
      settings.copyWith(lastViewedJournalId: journalId),
    );
  }

  Future<void> _rememberViewedJournal(String journalId) async {
    if (!mounted) return;
    final journalRepo = ref.read(journalRepositoryProvider);
    final settingsRepo = ref.read(settingsRepositoryProvider);

    final journals = await journalRepo.listJournals();
    if (!journals.any((j) => j.id == journalId)) return;
    if (_lastViewedJournalId == journalId) return;
    if (!mounted) return;
    setState(() => _lastViewedJournalId = journalId);
    await _persistLastViewedJournal(journalId, settingsRepo);
  }

  Future<void> _createJournal() async {
    final createdId = await showJournalManageSheet(context, ref);
    if (createdId != null && mounted) {
      setState(() => _journalFilter = createdId);
      await _rememberViewedJournal(createdId);
    }
  }

  Future<void> _createEntry() async {
    await _ensureDefaultJournal();
    final journals = await ref.read(journalRepositoryProvider).listJournals();
    if (journals.isEmpty) return;

    final journalId = _journalIdForNewEntry(journals);
    final now = utcNow();
    final settings = await ref.read(settingsRepositoryProvider).getSettings();
    Quote? assignedQuote;
    if (settings.showQuotes) {
      await ref.read(quotesLoadedProvider.future);
      final quoteBank = ref.read(quoteBankProvider);
      assignedQuote = quoteBank.nextQuote();
    }

    final weather =
        await ref.read(weatherServiceProvider).refreshIfNeeded() ??
        ref.read(weatherServiceProvider).readCachedSnapshot(settings);

    final entry = JournalEntry(
      id: newId(),
      journalId: journalId,
      title: '',
      body: '',
      entryDate: now,
      timestamp: now,
      quoteId: assignedQuote?.id,
      customQuote: assignedQuote?.text,
      weatherIcon: weather?.icon,
      createdAt: now,
      updatedAt: now,
    );
    await ref.read(journalRepositoryProvider).upsertEntry(entry);
    ref.read(remoteSyncServiceProvider).pushJournalEntry(entry);
    _suppressAutoSelect = true;
    _loadEntry(entry);
    ref.invalidate(journalEntriesProvider);
  }

  void _loadEntry(JournalEntry entry) {
    if (_selectedEntryId != null && _selectedEntryId != entry.id) {
      _metadataSaveTimer?.cancel();
      if (_metadataDirty) {
        unawaited(_saveMetadata(refreshList: true));
      }
    }
    final displayEntry = _entryWithDraftBody(entry);
    setState(() {
      _selectedEntryId = displayEntry.id;
      _selectedEntry = displayEntry;
      _titleController.text = displayEntry.title;
      _mood = displayEntry.mood;
      _weatherIcon = displayEntry.weatherIcon ?? 'sunny';
      _metadataDirty = false;
    });
    unawaited(_rememberViewedJournal(displayEntry.journalId));
  }

  void _updateBodyDraft(String entryId, String body) {
    _entryBodyDrafts[entryId] = body;
  }

  JournalEntry _entryWithDraftBody(JournalEntry entry) {
    final draftBody = _entryBodyDrafts[entry.id];
    if (draftBody == null) return entry;
    return JournalEntry(
      id: entry.id,
      journalId: entry.journalId,
      title: entry.title,
      body: draftBody,
      entryDate: entry.entryDate,
      richBodyJson: entry.richBodyJson,
      timestamp: entry.timestamp,
      tags: entry.tags,
      mood: entry.mood,
      quoteId: entry.quoteId,
      customQuote: entry.customQuote,
      weatherIcon: entry.weatherIcon,
      guidedPrompt: entry.guidedPrompt,
      createdAt: entry.createdAt,
      updatedAt: entry.updatedAt,
      deletedAt: entry.deletedAt,
    );
  }

  Future<void> _saveMetadata({bool refreshList = false}) async {
    final entryId = _selectedEntryId;
    if (entryId == null) return;
    final title = _titleController.text;
    final mood = _mood;
    final weatherIcon = _weatherIcon;

    final repo = ref.read(journalRepositoryProvider);
    final existing = await repo.getEntry(entryId);
    if (existing == null) return;
    if (existing.title == title &&
        existing.mood == mood &&
        existing.weatherIcon == weatherIcon) {
      if (_selectedEntryId != entryId) return;
      _metadataDirty = false;
      return;
    }

    final updated = existing.copyWith(
      title: title,
      mood: mood,
      weatherIcon: weatherIcon,
    );
    await repo.upsertEntry(updated);
    if (_selectedEntryId == updated.id) {
      _selectedEntry = updated;
      _metadataDirty = false;
    }
    ref.read(remoteSyncServiceProvider).pushJournalEntry(updated);
    if (refreshList) ref.invalidate(journalEntriesProvider);
  }

  void _scheduleMetadataSave({bool refreshList = false}) {
    _metadataDirty = true;
    _metadataSaveTimer?.cancel();
    _metadataSaveTimer = Timer(const Duration(milliseconds: 500), () {
      unawaited(_saveMetadata(refreshList: refreshList));
    });
  }

  Future<void> _changeEntryDate() async {
    final entry = _selectedEntry;
    if (entry == null) return;

    _metadataSaveTimer?.cancel();
    await _saveMetadata();
    if (!mounted) return;

    final nextLocal = await showDateTimePickerDialog(
      context,
      initialDateTime: entry.entryDate.toLocal(),
    );
    if (nextLocal == null) return;
    if (!mounted) return;

    final repo = ref.read(journalRepositoryProvider);
    final existing = await repo.getEntry(entry.id);
    if (existing == null) return;

    final updated = existing.copyWith(entryDate: nextLocal.toUtc());
    await repo.upsertEntry(updated);
    ref.read(remoteSyncServiceProvider).pushJournalEntry(updated);
    if (!mounted) return;
    setState(() => _selectedEntry = updated);
    ref.invalidate(journalEntriesProvider);
  }

  String _entryDateTimeLabel(BuildContext context, DateTime dateTime) {
    final local = dateTime.toLocal();
    final materialLocalizations = MaterialLocalizations.of(context);
    final date = materialLocalizations.formatShortDate(local);
    final time = formatTime12Hour(local);
    return '$date $time';
  }

  Future<void> _deleteEntry() async {
    final entry = _selectedEntry;
    if (entry == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete entry?'),
        content: const Text('This entry will be moved to trash.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await ref.read(journalRepositoryProvider).softDeleteEntry(entry.id);
    ref.read(remoteSyncServiceProvider).pushJournalEntry(
      entry.copyWith(deletedAt: utcNow()),
    );
    setState(() {
      _selectedEntryId = null;
      _selectedEntry = null;
      _titleController.clear();
    });
    ref.invalidate(journalEntriesProvider);
  }

  Future<void> _moveEntryToJournal(String journalId) async {
    final entry = _selectedEntry;
    if (entry == null || entry.journalId == journalId) return;
    final repo = ref.read(journalRepositoryProvider);
    final existing = await repo.getEntry(entry.id);
    if (existing == null) return;
    final updated = existing.copyWith(journalId: journalId);
    await repo.upsertEntry(updated);
    ref.read(remoteSyncServiceProvider).pushJournalEntry(updated);
    if (!mounted) return;
    setState(() => _selectedEntry = updated);
    ref.invalidate(journalEntriesProvider);
  }

  int _journalFlagColor(Journal journal) =>
      journal.colorValue ??
      Theme.of(context).colorScheme.primary.toARGB32();

  Widget? _journalFlagForEntry(JournalEntry entry, List<Journal> journals) {
    final journal = journals.cast<Journal?>().firstWhere(
      (j) => j!.id == entry.journalId,
      orElse: () => null,
    );
    final color = journal != null
        ? _journalFlagColor(journal)
        : Theme.of(context).colorScheme.primary.toARGB32();
    return JournalTitleCornerFlag(
      colorValue: color,
      onSelected: _moveEntryToJournal,
      menuEntries: (_) => [
        for (var i = 0; i < journals.length; i++)
          VoyagerPopupMenuItem<String>(
            value: journals[i].id,
            position: VoyagerMenuTheme.positionFor(i, journals.length),
            child: Row(
              children: [
                ColorCornerFlag(
                  colorValue: _journalFlagColor(journals[i]),
                  size: 12,
                  richColor: true,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    journals[i].name,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (journals[i].id == entry.journalId)
                  Icon(
                    PhosphorIconsRegular.check,
                    size: 18,
                    color: Theme.of(context).colorScheme.primary,
                  ),
              ],
            ),
          ),
      ],
    );
  }

  IconData _weatherData(String? icon) => weatherIconData(icon);

  @override
  Widget build(BuildContext context) {
    final journalsAsync = ref.watch(journalsProvider);
    final entriesAsync = ref.watch(journalEntriesProvider);
    final settings = ref.watch(settingsProvider).value;

    return journalsAsync.when(
      data: (journals) => entriesAsync.when(
        data: (entries) {
          final filtered = _journalFilter == _allJournals
              ? entries
              : entries.where((e) => e.journalId == _journalFilter).toList();
          final selectedVisible = filtered.any(
            (entry) => entry.id == _selectedEntryId,
          );
          if (!selectedVisible && filtered.isNotEmpty && !_suppressAutoSelect) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted && _selectedEntryId != filtered.first.id) {
                _loadEntry(filtered.first);
              }
            });
          }
          if (selectedVisible) {
            _suppressAutoSelect = false;
          }

          return LayoutBuilder(
            builder: (context, constraints) {
              final sidebarWidth = (constraints.maxWidth * 0.22).clamp(
                200.0,
                320.0,
              );
              return Row(
                children: [
                  SizedBox(
                    width: sidebarWidth,
                    child: Column(
                      children: [
                        Padding(
                          padding: const EdgeInsets.all(12),
                          child: Row(
                            children: [
                              Expanded(
                                child: RoundedDropdown<String>(
                                  value:
                                      journals.any(
                                            (j) => j.id == _journalFilter,
                                          ) ||
                                          _journalFilter == _allJournals
                                      ? _journalFilter
                                      : (journals.isNotEmpty
                                            ? journals.first.id
                                            : _allJournals),
                                  items: [
                                    if (journals.length > 1)
                                      const RoundedDropdownItem(
                                        value: _allJournals,
                                        label: 'All journals',
                                      ),
                                    ...journals.map(
                                      (j) => RoundedDropdownItem(
                                        value: j.id,
                                        label: j.name,
                                      ),
                                    ),
                                  ],
                                  onChanged: journals.isEmpty
                                      ? null
                                      : (v) => setState(() {
                                          _journalFilter = v;
                                          if (v != _allJournals) {
                                            unawaited(_rememberViewedJournal(v));
                                          }
                                        }),
                                ),
                              ),
                              IconButton(
                                tooltip: 'Manage journals',
                                onPressed: _createJournal,
                                icon: const Icon(
                                  VoyagerIcons.manage,
                                ),
                              ),
                            ],
                          ),
                        ),
                        Expanded(
                          child: KeepAliveScrollList(
                            storageKey: ShellPageStorageKeys.journalEntryList,
                            itemCount: filtered.length,
                            itemBuilder: (_, i) {
                              final entry = filtered[i];
                              final local = entry.entryDate.toLocal();
                              final dateLabel = MaterialLocalizations.of(
                                context,
                              ).formatShortDate(local);
                              final timeLabel = formatTime12Hour(local);
                              final preview = firstSentencePreview(entry.body);
                              return Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: VoyagerSpacing.sm,
                                  vertical: VoyagerSpacing.xxs,
                                ),
                                child: ListTile(
                                  dense: true,
                                  visualDensity: const VisualDensity(
                                    vertical: VoyagerSpacing
                                        .compactListVerticalDensity,
                                  ),
                                  contentPadding: const EdgeInsets.symmetric(
                                    horizontal: VoyagerSpacing.md,
                                    vertical: VoyagerSpacing.xs,
                                  ),
                                  selected: entry.id == _selectedEntryId,
                                  title: Text(
                                    entry.title.isEmpty
                                        ? 'Untitled'
                                        : entry.title,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: Theme.of(
                                      context,
                                    ).textTheme.titleSmall,
                                  ),
                                  subtitle: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      if (preview.isNotEmpty)
                                        Text(
                                          preview,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: Theme.of(
                                            context,
                                          ).textTheme.bodySmall?.copyWith(
                                            color: Theme.of(context)
                                                .colorScheme
                                                .onSurface
                                                .withValues(alpha: 0.78),
                                          ),
                                        ),
                                      Text(
                                        '$dateLabel · $timeLabel',
                                        style: Theme.of(context)
                                            .textTheme
                                            .labelSmall
                                            ?.copyWith(
                                              color: Theme.of(context)
                                                  .colorScheme
                                                  .onSurface
                                                  .withValues(alpha: 0.65),
                                            ),
                                      ),
                                    ],
                                  ),
                                  onTap: () => _loadEntry(entry),
                                ),
                              );
                            },
                          ),
                        ),
                        Padding(
                          padding: const EdgeInsets.all(12),
                          child: MouseRegion(
                            cursor: SystemMouseCursors.click,
                            child: FilledButton(
                              onPressed: _createEntry,
                              child: const Text('New entry'),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const VerticalDivider(width: 24),
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(24, 40, 24, 24),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Padding(
                            padding: const EdgeInsets.only(top: 8, bottom: 12),
                            child: Stack(
                              clipBehavior: Clip.none,
                              alignment: Alignment.centerRight,
                              children: [
                                LabeledTextField(
                                  label: 'Title',
                                  controller: _titleController,
                                  contentPadding: const EdgeInsets.fromLTRB(
                                    16,
                                    16,
                                    36,
                                    16,
                                  ),
                                  onChanged: (_) {
                                    _metadataDirty = true;
                                    _scheduleMetadataSave(refreshList: true);
                                  },
                                ),
                                if (_selectedEntry != null)
                                  Positioned(
                                    top: 0,
                                    right: 0,
                                    child: _journalFlagForEntry(
                                      _selectedEntry!,
                                      journals,
                                    )!,
                                  ),
                              ],
                            ),
                          ),
                          if (_selectedEntryId != null) ...[
                            Row(
                              children: [
                                const Text('Mood'),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: _MoodGradientSlider(
                                    value: _mood ?? 5,
                                    accent: Theme.of(
                                      context,
                                    ).colorScheme.primary,
                                    onChanged: (value) {
                                      setState(() {
                                        _mood = value;
                                        _metadataDirty = true;
                                      });
                                      _scheduleMetadataSave(refreshList: true);
                                    },
                                  ),
                                ),
                                const SizedBox(width: 12),
                                PopupMenuButton<String>(
                                  icon: Icon(_weatherData(_weatherIcon)),
                                  padding: EdgeInsets.zero,
                                  constraints: const BoxConstraints(
                                    minWidth: 40,
                                    minHeight: 40,
                                  ),
                                  onSelected: (v) {
                                    setState(() {
                                      _weatherIcon = v;
                                      _metadataDirty = true;
                                    });
                                    _saveMetadata(refreshList: true);
                                  },
                                  itemBuilder: (_) =>
                                      voyagerPopupMenuEntries<String>([
                                        (
                                          value: 'sunny',
                                          child: Text('Sunny'),
                                        ),
                                        (
                                          value: 'cloudy',
                                          child: Text('Cloudy'),
                                        ),
                                        (
                                          value: 'rain',
                                          child: Text('Rain'),
                                        ),
                                        (
                                          value: 'snow',
                                          child: Text('Snow'),
                                        ),
                                      ]),
                                ),
                                const SizedBox(width: 8),
                                Flexible(
                                  child: OutlinedButton.icon(
                                    onPressed: _changeEntryDate,
                                    icon: const Icon(
                                      VoyagerIcons.calendar,
                                      size: 18,
                                    ),
                                    label: Text(
                                      _entryDateTimeLabel(
                                        context,
                                        _selectedEntry!.entryDate,
                                      ),
                                      overflow: TextOverflow.ellipsis,
                                      maxLines: 1,
                                    ),
                                  ),
                                ),
                                IconButton(
                                  tooltip: 'Delete entry',
                                  onPressed: _deleteEntry,
                                  icon: const Icon(PhosphorIconsRegular.trash),
                                  visualDensity: VisualDensity.compact,
                                ),
                              ],
                            ),
                            const SizedBox(height: 12),
                          ],
                          Expanded(
                            child: _PlainJournalEditor(
                              entry: _selectedEntry,
                              onDraftChanged: _updateBodyDraft,
                            ),
                          ),
                          if (settings?.showQuotes == true &&
                              _selectedEntry != null)
                            _EntryQuote(quote: _selectedEntry!.customQuote),
                        ],
                      ),
                    ),
                  ),
                ],
              );
            },
          );
        },
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('$e')),
      ),
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text('$e')),
    );
  }
}

class _PlainJournalEditor extends ConsumerStatefulWidget {
  const _PlainJournalEditor({
    required this.entry,
    required this.onDraftChanged,
  });

  final JournalEntry? entry;
  final void Function(String entryId, String body) onDraftChanged;

  @override
  ConsumerState<_PlainJournalEditor> createState() =>
      _PlainJournalEditorState();
}

class _EntryQuote extends StatelessWidget {
  const _EntryQuote({required this.quote});

  final String? quote;

  @override
  Widget build(BuildContext context) {
    final text = quote;
    if (text == null || text.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: Align(
        alignment: Alignment.centerRight,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 320),
          child: Text(
            text,
            textAlign: TextAlign.right,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              fontStyle: FontStyle.italic,
              color: Theme.of(
                context,
              ).colorScheme.onSurface.withValues(alpha: 0.6),
            ),
          ),
        ),
      ),
    );
  }
}

class _PlainJournalEditorState extends ConsumerState<_PlainJournalEditor> {
  late final TextEditingController _controller;
  late FocusNode _focusNode;
  Timer? _saveTimer;
  Timer? _tagTimer;
  var _tags = const <String>[];
  var _lastText = '';
  String? _lastPersistedEntryId;
  var _lastPersistedText = '';
  var _dirty = false;
  var _applyingListShortcut = false;
  var _editorFocused = false;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.entry?.body ?? '');
    _focusNode = FocusNode()..addListener(_handleFocusChanged);
    _lastText = _controller.text;
    _lastPersistedEntryId = widget.entry?.id;
    _lastPersistedText = _controller.text.trimRight();
    _tags = widget.entry?.tags ?? extractTags(_controller.text);
  }

  @override
  void didUpdateWidget(covariant _PlainJournalEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.entry?.id == widget.entry?.id) return;
    unawaited(_persistDraft(oldWidget.entry, refreshList: true));
    _saveTimer?.cancel();
    _tagTimer?.cancel();
    _controller.text = widget.entry?.body ?? '';
    _lastText = _controller.text;
    _lastPersistedEntryId = widget.entry?.id;
    _lastPersistedText = _controller.text.trimRight();
    _dirty = false;
    _tags = widget.entry?.tags ?? extractTags(_controller.text);
  }

  @override
  void dispose() {
    _saveTimer?.cancel();
    _tagTimer?.cancel();
    unawaited(_persistDraft(widget.entry, refreshList: false));
    _focusNode.removeListener(_handleFocusChanged);
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _handleFocusChanged() {
    if (!mounted) return;
    setState(() => _editorFocused = _focusNode.hasFocus);
  }

  Future<void> _persistDraft(
    JournalEntry? entry, {
    required bool refreshList,
  }) async {
    if (entry == null) return;
    final plainBody = _controller.text.trimRight();
    if (!_dirty &&
        _lastPersistedEntryId == entry.id &&
        plainBody == _lastPersistedText) {
      return;
    }
    final tags = extractTags(plainBody);

    final repo = ref.read(journalRepositoryProvider);
    final settingsRepo = ref.read(settingsRepositoryProvider);
    final existing = await repo.getEntry(entry.id);
    if (existing == null) return;

    final colors = await settingsRepo.getTagColors();
    for (final tag in tags) {
      if (!colors.containsKey(tag)) {
        await settingsRepo.setTagColor(tag, colorForTag(tag));
      }
    }

    final updated = existing.copyWith(
      body: plainBody,
      richBodyJson: null,
      tags: tags,
    );
    await repo.upsertEntry(updated);
    _lastPersistedEntryId = entry.id;
    _lastPersistedText = plainBody;
    if (mounted &&
        widget.entry?.id == entry.id &&
        _controller.text.trimRight() == plainBody) {
      _dirty = false;
    }
    ref.read(remoteSyncServiceProvider).pushJournalEntryNow(updated);
    if (refreshList) ref.invalidate(journalEntriesProvider);
  }

  void _handleChanged(String value) {
    if (!_applyingListShortcut) {
      _applyListContinuation();
    }

    _lastText = _controller.text;
    final entryId = widget.entry?.id;
    if (entryId != null) {
      widget.onDraftChanged(entryId, _controller.text);
    }
    _dirty = true;
    _saveTimer?.cancel();
    _saveTimer = Timer(
      Duration(seconds: syncDebounceSeconds),
      () => unawaited(_persistDraft(widget.entry, refreshList: true)),
    );

    _tagTimer?.cancel();
    _tagTimer = Timer(const Duration(milliseconds: 250), () {
      if (!mounted) return;
      final nextTags = extractTags(_controller.text);
      if (_sameTags(_tags, nextTags)) return;
      setState(() => _tags = nextTags);
    });
  }

  void _applyListContinuation() {
    final text = _controller.text;
    final selection = _controller.selection;
    if (!selection.isCollapsed || selection.baseOffset <= 0) return;
    if (text.length != _lastText.length + 1) return;

    final newlineOffset = selection.baseOffset - 1;
    if (newlineOffset < 0 ||
        newlineOffset >= text.length ||
        text[newlineOffset] != '\n') {
      return;
    }

    final previousLineStart = text.lastIndexOf('\n', newlineOffset - 1) + 1;
    final previousLine = text.substring(previousLineStart, newlineOffset);
    final bulletMatch = RegExp(r'^(\s*)-\s+(.*)$').firstMatch(previousLine);
    final numberMatch = RegExp(
      r'^(\s*)(\d+)\.\s+(.*)$',
    ).firstMatch(previousLine);
    if (bulletMatch == null && numberMatch == null) return;

    final indent = bulletMatch?.group(1) ?? numberMatch?.group(1) ?? '';
    final content = bulletMatch?.group(2) ?? numberMatch?.group(3) ?? '';
    final nextNumber = (int.tryParse(numberMatch?.group(2) ?? '') ?? 0) + 1;
    final insert = content.isEmpty
        ? ''
        : bulletMatch != null
        ? '$indent- '
        : '$indent$nextNumber. ';
    final replacementStart = content.isEmpty
        ? previousLineStart
        : selection.baseOffset;
    final replacementEnd = selection.baseOffset;
    final nextText = text.replaceRange(
      replacementStart,
      replacementEnd,
      insert,
    );
    final nextOffset = replacementStart + insert.length;

    _applyingListShortcut = true;
    _controller.value = TextEditingValue(
      text: nextText,
      selection: TextSelection.collapsed(offset: nextOffset),
    );
    _applyingListShortcut = false;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final fillColor =
        theme.inputDecorationTheme.fillColor ?? theme.colorScheme.surface;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 120),
      curve: Curves.easeOut,
      decoration: BoxDecoration(
        color: fillColor,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: _editorFocused
              ? theme.colorScheme.primary.withValues(alpha: 0.95)
              : theme.dividerColor,
          width: _editorFocused ? 1.8 : 1,
        ),
        boxShadow: [
          if (_editorFocused)
            BoxShadow(
              color: theme.colorScheme.primary.withValues(alpha: 0.14),
              blurRadius: 14,
              spreadRadius: 1,
            ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_tags.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
              child: Wrap(
                spacing: 8,
                runSpacing: 4,
                children: [
                  for (final tag in _tags)
                    Chip(
                      label: Text('#$tag'),
                      backgroundColor: Color(
                        colorForTag(tag),
                      ).withValues(alpha: 0.3),
                    ),
                ],
              ),
            ),
          Expanded(
            child: TextField(
              controller: _controller,
              focusNode: _focusNode,
              expands: true,
              maxLines: null,
              minLines: null,
              textAlignVertical: TextAlignVertical.top,
              keyboardType: TextInputType.multiline,
              onChanged: _handleChanged,
              decoration: const InputDecoration(
                hintText: 'Start writing...',
                filled: false,
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
                contentPadding: EdgeInsets.all(16),
              ),
            ),
          ),
        ],
      ),
    );
  }

  bool _sameTags(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

class _MoodGradientSlider extends StatelessWidget {
  const _MoodGradientSlider({
    required this.value,
    required this.accent,
    required this.onChanged,
  });

  final int value;
  final Color accent;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    return SliderTheme(
      data: SliderTheme.of(context).copyWith(
        trackHeight: 8,
        activeTrackColor: Colors.transparent,
        inactiveTrackColor: Colors.transparent,
        overlayColor: accent.withValues(alpha: 0.16),
        thumbColor: accent,
        trackShape: _GradientSliderTrackShape(
          gradient: LinearGradient(colors: [Colors.white, accent]),
          inactiveColor: Theme.of(context).colorScheme.surface,
        ),
      ),
      child: Slider(
        min: 1,
        max: 10,
        divisions: 9,
        label: '$value',
        value: value.toDouble(),
        onChanged: (next) => onChanged(next.round()),
      ),
    );
  }
}

class _GradientSliderTrackShape extends SliderTrackShape
    with BaseSliderTrackShape {
  const _GradientSliderTrackShape({
    required this.gradient,
    required this.inactiveColor,
  });

  final LinearGradient gradient;
  final Color inactiveColor;

  @override
  Rect getPreferredRect({
    required RenderBox parentBox,
    Offset offset = Offset.zero,
    required SliderThemeData sliderTheme,
    bool isEnabled = false,
    bool isDiscrete = false,
  }) {
    final trackHeight = sliderTheme.trackHeight ?? 4;
    final trackLeft = offset.dx;
    final trackTop = offset.dy + (parentBox.size.height - trackHeight) / 2;
    final trackWidth = parentBox.size.width;
    return Rect.fromLTWH(trackLeft, trackTop, trackWidth, trackHeight);
  }

  @override
  void paint(
    PaintingContext context,
    Offset offset, {
    required RenderBox parentBox,
    required SliderThemeData sliderTheme,
    required Animation<double> enableAnimation,
    required TextDirection textDirection,
    required Offset thumbCenter,
    Offset? secondaryOffset,
    bool isEnabled = false,
    bool isDiscrete = false,
  }) {
    final rect = getPreferredRect(
      parentBox: parentBox,
      offset: offset,
      sliderTheme: sliderTheme,
      isEnabled: isEnabled,
      isDiscrete: isDiscrete,
    );
    final radius = Radius.circular(rect.height / 2);
    final inactivePaint = Paint()..color = inactiveColor;
    context.canvas.drawRRect(
      RRect.fromRectAndRadius(rect, radius),
      inactivePaint,
    );

    final activeRect = Rect.fromLTRB(
      rect.left,
      rect.top,
      thumbCenter.dx.clamp(rect.left, rect.right),
      rect.bottom,
    );
    if (activeRect.width <= 0) return;
    final activePaint = Paint()..shader = gradient.createShader(rect);
    context.canvas.drawRRect(
      RRect.fromRectAndRadius(activeRect, radius),
      activePaint,
    );
  }
}

List<String> extractTags(String body) {
  final matches = RegExp(r'#(\w+)').allMatches(body);
  return matches.map((m) => m.group(1)!).toSet().toList();
}

int colorForTag(String tag) => 0xFF000000 | (tag.hashCode.abs() & 0xFFFFFF);

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/constants/journal_constants.dart';
import 'package:voyager/core/icons/voyager_icons.dart';
import 'package:voyager/core/sync/firestore_collections.dart';
import 'package:voyager/core/sync/remote_sync_service.dart';
import 'package:voyager/core/theme/voyager_menu_theme.dart';
import 'package:voyager/core/theme/voyager_spacing.dart';
import 'package:voyager/core/widgets/confirm_dialog.dart';
import 'package:voyager/core/widgets/voyager_menu_catalog.dart';
import 'package:voyager/core/widgets/voyager_popup_menu_item.dart';
import 'package:voyager/core/utils/ids.dart';
import 'package:voyager/core/utils/journal_tags.dart';
import 'package:voyager/core/utils/time_format.dart';
import 'package:voyager/core/widgets/tag_highlighted_text_field.dart';
import 'package:voyager/core/widgets/datetime_picker_dialog.dart';
import 'package:voyager/core/widgets/keep_alive_scroll.dart';
import 'package:voyager/core/widgets/labeled_text_field.dart';
import 'package:voyager/core/widgets/mood_gradient_slider.dart';
import 'package:voyager/core/widgets/resizable_pane_divider.dart';
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
  static const _localSaveDebounce = Duration(milliseconds: 400);

  String _journalFilter = _allJournals;
  String? _lastViewedJournalId;
  Journal? _pendingJournal;
  final _pendingEntries = <String, JournalEntry>{};
  final _pendingEntryIds = <String>[];
  final _entryListScrollController = ScrollController();
  String? _selectedEntryId;
  JournalEntry? _selectedEntry;
  final _titleController = TextEditingController();
  final _titleFocusNode = FocusNode();
  final _bodyFocusNode = FocusNode();
  final _listTitlePreview = ValueNotifier<String>('');
  final _listBodyPreview = ValueNotifier<String>('');
  final _entryBodyDrafts = <String, String>{};
  Timer? _metadataSaveTimer;
  var _metadataDirty = false;
  var _suppressAutoSelect = false;
  int? _mood;
  String? _weatherIcon;
  RemoteSyncService? _remoteSync;
  double? _entryListWidth;
  double? _entryListDragStartWidth;
  DateTime? _lastEntryCreatedAt;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final settingsRepo = ref.read(settingsRepositoryProvider);
      final journalRepo = ref.read(journalRepositoryProvider);
      unawaited(_restoreJournalPreferences(settingsRepo, journalRepo));
    });
  }

  @override
  void dispose() {
    _metadataSaveTimer?.cancel();
    _listTitlePreview.dispose();
    _listBodyPreview.dispose();
    final entryId = _selectedEntryId;
    final remoteSync = _remoteSync;
    if (entryId != null && remoteSync != null) {
      unawaited(
        remoteSync.flushDocument(FirestoreCollections.journalEntries, entryId),
      );
    }
    _titleController.dispose();
    _titleFocusNode.dispose();
    _bodyFocusNode.dispose();
    _entryListScrollController.dispose();
    super.dispose();
  }

  void _invalidateJournalEntriesIfMounted() {
    if (!mounted) return;
    ref.invalidate(journalEntriesProvider);
    ref.invalidate(journalListEntriesProvider);
  }

  String _entryListScope(List<Journal>? journals) {
    if (_journalFilter == _allJournals) return allJournalEntriesScope;
    if (journals != null &&
        !journals.any((journal) => journal.id == _journalFilter)) {
      return allJournalEntriesScope;
    }
    return _journalFilter;
  }

  Future<void> _ensureDefaultJournal() async {
    final repo = ref.read(journalRepositoryProvider);
    final journals = await repo.listJournals();
    if (journals.any((journal) => journal.id == legacyJournalId)) return;

    final now = utcNow();
    final settings = await ref.read(settingsRepositoryProvider).getSettings();
    final defaultJournal = Journal(
      id: legacyJournalId,
      name: 'Journal',
      colorValue: settings.accentColor,
      createdAt: now,
      updatedAt: now,
    );
    await repo.upsertJournal(defaultJournal);
    ref.read(remoteSyncServiceProvider).pushJournal(defaultJournal);
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

  Future<void> _restoreJournalPreferences(
    SettingsRepository settingsRepo,
    JournalRepository journalRepo,
  ) async {
    final settings = await settingsRepo.getSettings();
    if (!mounted) return;

    final savedId = settings.lastViewedJournalId;
    String? restoredJournalId;
    if (savedId != null) {
      final journals = await journalRepo.listJournals();
      if (!mounted) return;
      if (journals.any((j) => j.id == savedId)) {
        restoredJournalId = savedId;
      }
    }

    setState(() {
      if (restoredJournalId != null) {
        _lastViewedJournalId = restoredJournalId;
        _journalFilter = restoredJournalId;
      }
      _entryListWidth = settings.journalEntryListWidth;
    });
  }

  Future<void> _persistEntryListWidth(double? width) async {
    final settingsRepo = ref.read(settingsRepositoryProvider);
    final settings = await settingsRepo.getSettings();
    if (settings.journalEntryListWidth == width) return;
    await settingsRepo.saveSettings(
      width == null
          ? settings.copyWith(clearJournalEntryListWidth: true)
          : settings.copyWith(journalEntryListWidth: width),
    );
  }

  void _resetEntryListWidth() {
    setState(() => _entryListWidth = null);
    unawaited(_persistEntryListWidth(null));
  }

  void _onEntryListDragStart(double totalWidth) {
    _entryListDragStartWidth =
        _entryListWidth ?? JournalEntryListLayout.defaultListWidth(totalWidth);
  }

  void _onEntryListDragUpdate(double totalDelta, double totalWidth) {
    final startWidth = _entryListDragStartWidth;
    if (startWidth == null) return;
    setState(
      () => _entryListWidth = JournalEntryListLayout.clampListWidth(
        startWidth + totalDelta,
        totalWidth,
      ),
    );
  }

  void _onEntryListDragEnd() {
    final width = _entryListWidth;
    _entryListDragStartWidth = null;
    unawaited(_persistEntryListWidth(width));
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
    final created = await showJournalManageSheet(context, ref);
    if (created != null && mounted) {
      setState(() {
        _pendingJournal = created;
        _journalFilter = created.id;
        _selectedEntryId = null;
        _selectedEntry = null;
      });
      unawaited(_rememberViewedJournal(created.id));
    }
  }

  void _reconcilePendingJournal(List<Journal> journals) {
    final pending = _pendingJournal;
    if (pending == null) return;
    if (!journals.any((journal) => journal.id == pending.id)) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      setState(() => _pendingJournal = null);
    });
  }

  DateTime _nextEntryTimestamp() {
    final now = utcNow();
    final last = _lastEntryCreatedAt;
    final next = last != null && !now.isAfter(last)
        ? last.add(const Duration(milliseconds: 1))
        : now;
    _lastEntryCreatedAt = next;
    return next;
  }

  void _registerPendingEntry(JournalEntry entry) {
    _pendingEntries[entry.id] = entry;
    _pendingEntryIds.remove(entry.id);
    _pendingEntryIds.insert(0, entry.id);
  }

  void _removePendingEntry(String id) {
    _pendingEntries.remove(id);
    _pendingEntryIds.remove(id);
  }

  void _writeEntryListScrollStorage(double offset) {
    if (!mounted) return;
    PageStorage.of(context).writeState(
      context,
      offset,
      identifier: ShellPageStorageKeys.journalEntryList,
    );
  }

  List<JournalEntry> _buildDisplayEntries(List<JournalEntry> entries) {
    final persisted = sortJournalEntriesNewestFirst(
      entries.where((entry) => !_pendingEntries.containsKey(entry.id)),
    );
    final pending = [
      for (final id in _pendingEntryIds)
        if (_pendingEntries.containsKey(id)) _pendingEntries[id]!,
    ];
    return [...pending, ...persisted];
  }

  void _scrollEntryListToTop() {
    if (!_entryListScrollController.hasClients) return;
    _entryListScrollController.jumpTo(0);
  }

  Future<void> _createEntry() async {
    if (!mounted) return;

    final journals = ref.read(journalsProvider).value;
    if (journals == null) {
      await _createEntryWhenReady();
      return;
    }
    _createEntryOptimistic(journals);
  }

  Future<void> _createEntryWhenReady() async {
    await _ensureDefaultJournal();
    if (!mounted) return;
    final journals = await ref.read(journalRepositoryProvider).listJournals();
    if (!mounted || journals.isEmpty) return;
    _createEntryOptimistic(journals);
  }

  void _createEntryOptimistic(List<Journal> journals) {
    if (!mounted) return;

    final settings =
        ref.read(settingsProvider).value ?? const AppSettings();
    final weatherService = ref.read(weatherServiceProvider);
    final weather = weatherService.readCachedSnapshot(settings);
    final journalId = journals.isEmpty
        ? legacyJournalId
        : _journalIdForNewEntry(journals);
    if (journals.isEmpty) {
      unawaited(_ensureDefaultJournal());
    }
    final now = _nextEntryTimestamp();

    final entry = JournalEntry(
      id: newId(),
      journalId: journalId,
      title: '',
      body: '',
      entryDate: now,
      timestamp: now,
      weatherIcon: weather?.icon,
      createdAt: now,
      updatedAt: now,
    );

    _registerPendingEntry(entry);
    _suppressAutoSelect = true;
    _writeEntryListScrollStorage(0);
    _loadEntry(entry);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _writeEntryListScrollStorage(0);
      _scrollEntryListToTop();
      _bodyFocusNode.requestFocus();
    });

    unawaited(_finalizeNewEntry(entry, settings));
  }

  Future<void> _finalizeNewEntry(
    JournalEntry entry,
    AppSettings settings,
  ) async {
    final journalRepo = ref.read(journalRepositoryProvider);
    final remoteSync = ref.read(remoteSyncServiceProvider);
    final weatherService = ref.read(weatherServiceProvider);

    Quote? assignedQuote;
    if (settings.showQuotes) {
      await ref.read(quotesLoadedProvider.future);
      if (!mounted) return;
      assignedQuote = ref.read(quoteBankProvider).nextQuote();
    }

    final weather =
        await weatherService.refreshIfNeeded() ??
        weatherService.readCachedSnapshot(settings);
    if (!mounted) return;

    final finalized = entry.copyWith(
      quoteId: assignedQuote?.id,
      customQuote: assignedQuote?.text,
      weatherIcon: weather?.icon ?? entry.weatherIcon,
    );

    await journalRepo.upsertEntry(finalized);
    remoteSync.pushJournalEntryNow(finalized);
    if (!mounted) return;

    if (_pendingEntries.containsKey(finalized.id)) {
      _pendingEntries[finalized.id] = finalized;
    }
    if (_selectedEntryId == finalized.id) {
      setState(() => _selectedEntry = finalized);
    }
  }

  void _loadEntry(JournalEntry entry) {
    if (_selectedEntryId != null && _selectedEntryId != entry.id) {
      final previousEntryId = _selectedEntryId!;
      final remoteSync = ref.read(remoteSyncServiceProvider);
      _metadataSaveTimer?.cancel();
      if (_metadataDirty) {
        unawaited(
          _saveMetadata(refreshList: true).then(
            (_) => remoteSync.flushDocument(
              FirestoreCollections.journalEntries,
              previousEntryId,
            ),
          ),
        );
      } else {
        unawaited(
          remoteSync.flushDocument(
            FirestoreCollections.journalEntries,
            previousEntryId,
          ),
        );
      }
    }
    final displayEntry = _entryWithDraftBody(entry);
    final draftBody = _entryBodyDrafts[displayEntry.id] ?? displayEntry.body;
    _listTitlePreview.value = displayEntry.title;
    _listBodyPreview.value = draftBody;
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
    if (entryId == _selectedEntryId) {
      _listBodyPreview.value = body;
    }
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
    final entry = _selectedEntry;
    if (entryId == null || entry == null || entry.id != entryId) return;

    final title = _titleController.text;
    final mood = _mood;
    final weatherIcon = _weatherIcon;

    if (entry.title == title &&
        entry.mood == mood &&
        entry.weatherIcon == weatherIcon) {
      _metadataDirty = false;
      return;
    }

    final updated = entry.copyWith(
      title: title,
      mood: mood,
      weatherIcon: weatherIcon,
    );

    final repo = ref.read(journalRepositoryProvider);
    await ref
        .read(remoteSyncServiceProvider)
        .saveJournalEntryThenScheduleUpload(
          entryId: entryId,
          saveLocal: () async {
            await repo.upsertEntry(updated);
            if (_selectedEntryId == entryId && mounted) {
              _selectedEntry = updated;
              _metadataDirty = false;
            }
          },
        );
    if (refreshList) _invalidateJournalEntriesIfMounted();
  }

  void _scheduleMetadataSave() {
    _metadataSaveTimer?.cancel();
    _metadataSaveTimer = Timer(_localSaveDebounce, () {
      unawaited(_saveMetadata());
    });
  }

  Future<void> _flushMetadataSave({bool refreshList = false}) {
    _metadataSaveTimer?.cancel();
    return _saveMetadata(refreshList: refreshList);
  }

  void _submitTitleAndFocusBody() {
    _metadataDirty = true;
    unawaited(_flushMetadataSave());
    _bodyFocusNode.requestFocus();
  }

  Future<void> _changeEntryDate() async {
    final entry = _selectedEntry;
    if (entry == null) return;

    _metadataSaveTimer?.cancel();
    await _flushMetadataSave();
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
    ref.read(remoteSyncServiceProvider).pushJournalEntryNow(updated);
    if (!mounted) return;
    setState(() => _selectedEntry = updated);
    _invalidateJournalEntriesIfMounted();
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
    setState(() {
      _selectedEntryId = null;
      _selectedEntry = null;
      _titleController.clear();
      _journalFilter = _allJournals;
    });
    _removePendingEntry(entry.id);
    _invalidateJournalEntriesIfMounted();
  }

  Future<void> _editQuote() async {
    final entry = _selectedEntry;
    if (entry == null) return;
    final controller = TextEditingController(text: entry.customQuote ?? '');
    final quote = await showDialog<String?>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Edit quote'),
        content: SizedBox(
          width: 560,
          child: TextField(
            controller: controller,
            autofocus: true,
            minLines: 5,
            maxLines: 12,
            decoration: const InputDecoration(labelText: 'Quote'),
            onSubmitted: (_) => Navigator.pop(context, controller.text),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (quote == null) return;
    final updated = entry.copyWith(customQuote: quote.trim());
    await ref.read(journalRepositoryProvider).upsertEntry(updated);
    ref.read(remoteSyncServiceProvider).pushJournalEntryNow(updated);
    if (!mounted) return;
    setState(() => _selectedEntry = updated);
    _invalidateJournalEntriesIfMounted();
  }

  Future<void> _moveEntryToJournal(String journalId) async {
    final entry = _selectedEntry;
    if (entry == null || entry.journalId == journalId) return;
    final repo = ref.read(journalRepositoryProvider);
    final existing = await repo.getEntry(entry.id);
    if (existing == null) return;
    final updated = existing.copyWith(journalId: journalId);
    await repo.upsertEntry(updated);
    ref.read(remoteSyncServiceProvider).pushJournalEntryNow(updated);
    if (!mounted) return;
    setState(() => _selectedEntry = updated);
    _invalidateJournalEntriesIfMounted();
  }

  int _journalFlagColor(Journal journal) =>
      journal.colorValue ?? Theme.of(context).colorScheme.primary.toARGB32();

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
                JournalBookmarkFlag(
                  colorValue: _journalFlagColor(journals[i]),
                  size: 12,
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
    _remoteSync = ref.read(remoteSyncServiceProvider);
    final journalsAsync = ref.watch(journalsProvider);
    final entryListScope = _entryListScope(journalsAsync.valueOrNull);
    final entriesAsync = ref.watch(journalListEntriesProvider(entryListScope));
    final settings = ref.watch(settingsProvider).value;

    return journalsAsync.when(
        skipLoadingOnReload: true,
        data: (journals) => entriesAsync.when(
        skipLoadingOnReload: true,
        data: (entries) {
          _reconcilePendingJournal(journals);
          final displayEntries = _buildDisplayEntries(entries);
          final displayJournals = _pendingJournal != null &&
                  !journals.any((j) => j.id == _pendingJournal!.id)
              ? [...journals, _pendingJournal!]
              : journals;
          final journalFilter =
              _journalFilter == _allJournals ||
                  displayJournals.any((j) => j.id == _journalFilter)
              ? _journalFilter
              : _allJournals;
          if (journalFilter != _journalFilter) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (!mounted) return;
              setState(() => _journalFilter = _allJournals);
            });
          }
          final filtered = entryListScope == allJournalEntriesScope
              ? displayEntries
              : displayEntries
                  .where((e) => e.journalId == entryListScope)
                  .toList();
          final accentJournal = _selectedEntry == null
              ? null
              : displayJournals.cast<Journal?>().firstWhere(
                  (j) => j!.id == _selectedEntry!.journalId,
                  orElse: () => null,
                );
          final accentColor = Color(
            accentJournal != null
                ? _journalFlagColor(accentJournal)
                : Theme.of(context).colorScheme.primary.toARGB32(),
          );
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
          if (selectedVisible &&
              (_selectedEntryId == null ||
                  !_pendingEntries.containsKey(_selectedEntryId))) {
            _suppressAutoSelect = false;
          }

          return LayoutBuilder(
            builder: (context, constraints) {
              final totalWidth = constraints.maxWidth;
              final storedListWidth =
                  _entryListWidth ??
                  JournalEntryListLayout.defaultListWidth(totalWidth);
              final listWidth = JournalEntryListLayout.clampListWidth(
                storedListWidth,
                totalWidth,
              );
              return Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SizedBox(
                    width: listWidth,
                    child: Column(
                      children: [
                        Padding(
                          padding: const EdgeInsets.all(12),
                          child: Row(
                            children: [
                              Expanded(
                                child: RoundedDropdown<String>(
                                  value: journalFilter,
                                  labelColor: journalFilter == _allJournals
                                      ? null
                                      : Color(
                                          _journalFlagColor(
                                            displayJournals.firstWhere(
                                              (j) => j.id == journalFilter,
                                            ),
                                          ),
                                        ),
                                  items: [
                                    if (displayJournals.length > 1)
                                      const RoundedDropdownItem(
                                        value: _allJournals,
                                        label: 'All journals',
                                      ),
                                    ...displayJournals.map(
                                      (j) => RoundedDropdownItem(
                                        value: j.id,
                                        label: j.name,
                                        leading: JournalBookmarkFlag(
                                          colorValue: _journalFlagColor(j),
                                          size: 12,
                                        ),
                                      ),
                                    ),
                                  ],
                                  onChanged: displayJournals.isEmpty
                                      ? null
                                      : (v) => setState(() {
                                          _journalFilter = v;
                                          if (v != _allJournals) {
                                            unawaited(
                                              _rememberViewedJournal(v),
                                            );
                                          }
                                        }),
                                ),
                              ),
                              IconButton(
                                tooltip: 'Manage journals',
                                onPressed: _createJournal,
                                icon: const Icon(VoyagerIcons.manage),
                              ),
                            ],
                          ),
                        ),
                        Expanded(
                          child: KeepAliveScrollList(
                            storageKey: ShellPageStorageKeys.journalEntryList,
                            controller: _entryListScrollController,
                            itemCount: filtered.length,
                            itemBuilder: (_, i) {
                              final entry = filtered[i];
                              final isSelected = entry.id == _selectedEntryId;
                              return KeyedSubtree(
                                key: ValueKey(entry.id),
                                child: _JournalEntryListTile(
                                  entry: entry,
                                  isSelected: isSelected,
                                  titlePreview: _listTitlePreview,
                                  bodyPreview: _listBodyPreview,
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
                  ResizablePaneDivider(
                    onDragStart: () => _onEntryListDragStart(totalWidth),
                    onDragUpdate: (totalDelta) =>
                        _onEntryListDragUpdate(totalDelta, totalWidth),
                    onDragEnd: _onEntryListDragEnd,
                    onDoubleTapReset: _resetEntryListWidth,
                  ),
                  Expanded(
                    child: Padding(
                      padding: JournalEntryListLayout.editorPadding,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Padding(
                            padding: const EdgeInsets.only(top: 8, bottom: 12),
                            child: Stack(
                              clipBehavior: Clip.none,
                              alignment: Alignment.centerRight,
                              children: [
                                Focus(
                                  onKeyEvent: (node, event) {
                                    if (event is! KeyDownEvent) {
                                      return KeyEventResult.ignored;
                                    }
                                    if (event.logicalKey ==
                                            LogicalKeyboardKey.tab &&
                                        !HardwareKeyboard
                                            .instance
                                            .isShiftPressed) {
                                      _submitTitleAndFocusBody();
                                      return KeyEventResult.handled;
                                    }
                                    return KeyEventResult.ignored;
                                  },
                                  child: LabeledTextField(
                                    label: 'Title',
                                    showLabel: false,
                                    controller: _titleController,
                                    focusNode: _titleFocusNode,
                                    textInputAction: TextInputAction.next,
                                    accentColor: accentColor,
                                    contentPadding: const EdgeInsets.fromLTRB(
                                      16,
                                      16,
                                      56,
                                      16,
                                    ),
                                    onChanged: (value) {
                                      _metadataDirty = true;
                                      _listTitlePreview.value = value;
                                      _scheduleMetadataSave();
                                    },
                                    onSubmitted: (_) =>
                                        _submitTitleAndFocusBody(),
                                  ),
                                ),
                                if (_selectedEntry != null)
                                  Positioned(
                                    top: 0,
                                    right: 10,
                                    child: _journalFlagForEntry(
                                      _selectedEntry!,
                                      displayJournals,
                                    )!,
                                  ),
                              ],
                            ),
                          ),
                          if (_selectedEntryId != null) ...[
                            Row(
                              children: [
                                Text(
                                  'Mood',
                                  style: TextStyle(color: accentColor),
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: MoodGradientSlider(
                                    value: _mood ?? 5,
                                    accent: accentColor,
                                    onChanged: (value) {
                                      setState(() {
                                        _mood = value;
                                        _metadataDirty = true;
                                      });
                                      _scheduleMetadataSave();
                                    },
                                  ),
                                ),
                                const SizedBox(width: 12),
                                PopupMenuButton<VoyagerMenuCatalogEntry>(
                                  icon: Icon(
                                    _weatherData(_weatherIcon),
                                    color: accentColor,
                                  ),
                                  padding: EdgeInsets.zero,
                                  constraints: const BoxConstraints(
                                    minWidth: 40,
                                    minHeight: 40,
                                  ),
                                  onSelected: (entry) {
                                    setState(() {
                                      _weatherIcon = entry.weatherIconValue;
                                      _metadataDirty = true;
                                    });
                                    _scheduleMetadataSave();
                                  },
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
                                      color: accentColor,
                                    ),
                                    style: OutlinedButton.styleFrom(
                                      foregroundColor: accentColor,
                                      side: BorderSide(
                                        color: accentColor.withValues(
                                          alpha: 0.7,
                                        ),
                                      ),
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
                                const SizedBox(width: 8),
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
                              focusNode: _bodyFocusNode,
                              accentColor: accentColor,
                              onDraftChanged: _updateBodyDraft,
                              onEntryPersisted: (updated) =>
                                  setState(() => _selectedEntry = updated),
                            ),
                          ),
                          if (settings?.showQuotes == true &&
                              _selectedEntry != null)
                            _EntryQuote(
                              quote: _selectedEntry!.customQuote,
                              onTap: _editQuote,
                            ),
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
    required this.focusNode,
    required this.onDraftChanged,
    required this.accentColor,
    this.onEntryPersisted,
  });

  final JournalEntry? entry;
  final FocusNode focusNode;
  final Color accentColor;
  final void Function(String entryId, String body) onDraftChanged;
  final ValueChanged<JournalEntry>? onEntryPersisted;

  @override
  ConsumerState<_PlainJournalEditor> createState() =>
      _PlainJournalEditorState();
}

class _EntryQuote extends StatelessWidget {
  const _EntryQuote({required this.quote, required this.onTap});

  final String? quote;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final text = quote;
    if (text == null || text.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: Align(
        alignment: Alignment.centerRight,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(12),
          child: Padding(
            padding: const EdgeInsets.all(8),
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
        ),
      ),
    );
  }
}

class _PlainJournalEditorState extends ConsumerState<_PlainJournalEditor> {
  static const _localSaveDebounce = Duration(milliseconds: 400);

  late final TextEditingController _controller;
  Timer? _tagTimer;
  Timer? _persistDraftTimer;
  var _tags = const <String>[];
  var _lastText = '';
  String? _lastPersistedEntryId;
  var _lastPersistedText = '';
  var _dirty = false;
  var _applyingListShortcut = false;
  var _editorFocused = false;
  RemoteSyncService? _remoteSync;
  JournalRepository? _journalRepo;
  SettingsRepository? _settingsRepo;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.entry?.body ?? '');
    widget.focusNode.addListener(_handleFocusChanged);
    _lastText = _controller.text;
    _lastPersistedEntryId = widget.entry?.id;
    _lastPersistedText = _controller.text.trimRight();
    _tags = widget.entry?.tags ?? extractTags(_controller.text);
    final entry = widget.entry;
    if (entry != null) {
      ref
          .read(remoteSyncServiceProvider)
          .setDocumentEditing(
            collection: FirestoreCollections.journalEntries,
            documentId: entry.id,
            isEditing: widget.focusNode.hasFocus,
          );
    }
  }

  @override
  void didUpdateWidget(covariant _PlainJournalEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.entry?.id == widget.entry?.id) return;
    final oldEntry = oldWidget.entry;
    final remoteSync = ref.read(remoteSyncServiceProvider);
    unawaited(
      _flushPersistDraft(oldEntry, refreshList: true).then((_) async {
        if (oldEntry != null) {
          await remoteSync.flushDocument(
            FirestoreCollections.journalEntries,
            oldEntry.id,
          );
        }
      }),
    );
    _setEditingFlag(oldWidget.entry, false);
    _tagTimer?.cancel();
    _persistDraftTimer?.cancel();
    _controller.text = widget.entry?.body ?? '';
    _lastText = _controller.text;
    _lastPersistedEntryId = widget.entry?.id;
    _lastPersistedText = _controller.text.trimRight();
    _dirty = false;
    _tags = widget.entry?.tags ?? extractTags(_controller.text);
    _setEditingFlag(widget.entry, widget.focusNode.hasFocus);
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _tagTimer?.cancel();
    _persistDraftTimer?.cancel();
    final entry = widget.entry;
    final remoteSync = _remoteSync;
    if (entry != null && remoteSync != null) {
      remoteSync.setDocumentEditing(
        collection: FirestoreCollections.journalEntries,
        documentId: entry.id,
        isEditing: false,
      );
    }
    unawaited(
      _flushPersistDraft(entry, refreshList: false).then((_) async {
        if (entry != null && remoteSync != null) {
          await remoteSync.flushDocument(
            FirestoreCollections.journalEntries,
            entry.id,
          );
        }
      }),
    );
    widget.focusNode.removeListener(_handleFocusChanged);
    _controller.dispose();
    super.dispose();
  }

  void _handleFocusChanged() {
    if (!mounted) return;
    _setEditingFlag(widget.entry, widget.focusNode.hasFocus);
    setState(() => _editorFocused = widget.focusNode.hasFocus);
  }

  void _setEditingFlag(JournalEntry? entry, bool isEditing) {
    if (entry == null) return;
    final remoteSync = _remoteSync;
    if (remoteSync == null) return;
    remoteSync.setDocumentEditing(
      collection: FirestoreCollections.journalEntries,
      documentId: entry.id,
      isEditing: isEditing,
    );
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

    final repo = _journalRepo;
    final remoteSync = _remoteSync;
    if (repo == null || remoteSync == null) return;

    await remoteSync.saveJournalEntryThenScheduleUpload(
      entryId: entry.id,
      saveLocal: () async {
        final base = widget.entry;
        if (base == null || base.id != entry.id) return;
        final body = _controller.text.trimRight();
        final tags = extractTags(body);
        final updated = base.copyWith(body: body, tags: tags);
        await repo.upsertEntry(updated);
        _lastPersistedEntryId = entry.id;
        _lastPersistedText = body;
        if (mounted &&
            widget.entry?.id == entry.id &&
            _controller.text.trimRight() == body) {
          _dirty = false;
          widget.onEntryPersisted?.call(updated);
        }
      },
    );
    if (refreshList && mounted) {
      ref.invalidate(journalEntriesProvider);
      ref.invalidate(journalListEntriesProvider);
    }
  }

  void _schedulePersistDraft() {
    _persistDraftTimer?.cancel();
    _persistDraftTimer = Timer(_localSaveDebounce, () {
      unawaited(_persistDraft(widget.entry, refreshList: false));
    });
  }

  Future<void> _flushPersistDraft(
    JournalEntry? entry, {
    required bool refreshList,
  }) {
    _persistDraftTimer?.cancel();
    return _persistDraft(entry, refreshList: refreshList);
  }

  Future<void> _persistTagColors(List<String> tags) async {
    final settingsRepo = _settingsRepo;
    if (settingsRepo == null) return;
    final colors = await settingsRepo.getTagColors();
    for (final tag in tags) {
      if (!colors.containsKey(tag)) {
        await settingsRepo.setTagColor(tag, colorForTag(tag));
      }
    }
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
    _schedulePersistDraft();

    _tagTimer?.cancel();
    _tagTimer = Timer(const Duration(milliseconds: 250), () {
      if (!mounted) return;
      final nextTags = extractTags(_controller.text);
      if (_sameTags(_tags, nextTags)) return;
      _tags = nextTags;
      unawaited(_persistTagColors(nextTags));
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
    _remoteSync = ref.read(remoteSyncServiceProvider);
    _journalRepo = ref.read(journalRepositoryProvider);
    _settingsRepo = ref.read(settingsRepositoryProvider);

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
              ? widget.accentColor.withValues(alpha: 0.95)
              : theme.dividerColor,
          width: 1.8,
        ),
        boxShadow: [
          if (_editorFocused)
            BoxShadow(
              color: widget.accentColor.withValues(alpha: 0.14),
              blurRadius: 14,
              spreadRadius: 1,
            ),
        ],
      ),
      child: TagHighlightedTextField(
        controller: _controller,
        focusNode: widget.focusNode,
        expands: true,
        keyboardType: TextInputType.multiline,
        onChanged: _handleChanged,
        hintText: 'Start writing...',
        decoration: const InputDecoration(
          filled: false,
          border: InputBorder.none,
          enabledBorder: InputBorder.none,
          focusedBorder: InputBorder.none,
        ),
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

class _JournalEntryListTile extends StatelessWidget {
  const _JournalEntryListTile({
    required this.entry,
    required this.isSelected,
    required this.titlePreview,
    required this.bodyPreview,
    required this.onTap,
  });

  final JournalEntry entry;
  final bool isSelected;
  final ValueNotifier<String> titlePreview;
  final ValueNotifier<String> bodyPreview;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final local = entry.entryDate.toLocal();
    final dateLabel = MaterialLocalizations.of(context).formatShortDate(local);
    final timeLabel = formatTime12Hour(local);
    final titleStyle = Theme.of(context).textTheme.titleSmall;
    final previewStyle = Theme.of(context).textTheme.bodySmall?.copyWith(
      color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.78),
    );
    final dateStyle = Theme.of(context).textTheme.labelSmall?.copyWith(
      color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.65),
    );

    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: VoyagerSpacing.sm,
        vertical: VoyagerSpacing.xxs,
      ),
      child: ListTile(
        dense: true,
        visualDensity: const VisualDensity(
          vertical: VoyagerSpacing.compactListVerticalDensity,
        ),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: VoyagerSpacing.md,
          vertical: VoyagerSpacing.xs,
        ),
        selected: isSelected,
        title: isSelected
            ? ValueListenableBuilder<String>(
                valueListenable: titlePreview,
                builder: (context, title, _) {
                  return Text(
                    title.isEmpty ? 'Untitled' : title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: titleStyle,
                  );
                },
              )
            : Text(
                entry.title.isEmpty ? 'Untitled' : entry.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: titleStyle,
              ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (isSelected)
              ValueListenableBuilder<String>(
                valueListenable: bodyPreview,
                builder: (context, body, _) {
                  final preview = firstSentencePreview(body);
                  if (preview.isEmpty) return const SizedBox.shrink();
                  return Text(
                    preview,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: previewStyle,
                  );
                },
              )
            else ...[
              Builder(
                builder: (context) {
                  final preview = firstSentencePreview(entry.body);
                  if (preview.isEmpty) return const SizedBox.shrink();
                  return Text(
                    preview,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: previewStyle,
                  );
                },
              ),
            ],
            Text('$dateLabel · $timeLabel', style: dateStyle),
          ],
        ),
        onTap: onTap,
      ),
    );
  }
}


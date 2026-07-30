import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/sync/firestore_collections.dart';
import 'package:voyager/core/sync/journal_write_coordinator.dart';
import 'package:voyager/core/sync/pending_flush_registry.dart';
import 'package:voyager/core/sync/pending_text_merge.dart';
import 'package:voyager/core/sync/remote_sync_service.dart';
import 'package:voyager/core/sync/text_delta_injector.dart';
import 'package:voyager/core/text/list_text_editing.dart';
import 'package:voyager/core/theme/voyager_list_item_surface.dart';
import 'package:voyager/core/theme/voyager_spacing.dart';
import 'package:voyager/core/utils/ids.dart';
import 'package:voyager/core/utils/journal_tags.dart';
import 'package:voyager/core/utils/time_format.dart';
import 'package:voyager/core/widgets/resizable_pane_divider.dart';
import 'package:voyager/core/widgets/tag_highlighted_text_field.dart';
import 'package:voyager/domain/models/dream_models.dart';
import 'package:voyager/domain/models/journal_models.dart' show firstSentencePreview;
import 'package:voyager/domain/repositories/repositories.dart';
import 'package:voyager/features/dream_journal/dream_branch_painter.dart';
import 'package:voyager/features/dream_journal/dream_sticky_note.dart';

/// Layout math for the 35/65 split pane, mirroring
/// [JournalEntryListLayout]'s shape but tuned for Dream Journal's default
/// proportions.
class DreamSplitLayout {
  DreamSplitLayout._();

  static const dividerWidth = 12.0;
  static const minListWidth = 240.0;
  static const maxListWidth = 620.0;
  static const minEditorWidth = 380.0;

  static double defaultListWidth(double totalWidth) {
    return (totalWidth * 0.35).clamp(minListWidth, 480.0);
  }

  static double clampListWidth(double width, double totalWidth) {
    final maxAllowed = (totalWidth - minEditorWidth - dividerWidth).clamp(
      minListWidth,
      maxListWidth,
    );
    return width.clamp(minListWidth, maxAllowed);
  }

  static const editorPadding = EdgeInsets.fromLTRB(28, 40, 28, 24);
}

class DreamJournalPage extends ConsumerStatefulWidget {
  const DreamJournalPage({super.key});

  @override
  ConsumerState<DreamJournalPage> createState() => _DreamJournalPageState();
}

class _DreamJournalPageState extends ConsumerState<DreamJournalPage> {
  static const _localSaveDebounce = Duration(milliseconds: 400);

  String? _selectedEntryId;
  DreamEntry? _selectedEntry;
  final _titleController = TextEditingController();
  final _titleFocusNode = FocusNode();
  final _bodyFocusNode = FocusNode();
  final _bodyEditorKey = GlobalKey<_DreamBodyEditorState>();
  final _notesController = TextEditingController();
  final _notesFocusNode = FocusNode();
  var _lastNotesText = '';
  final _listTitlePreview = ValueNotifier<String>('');
  final _listBodyPreview = ValueNotifier<String>('');
  Timer? _saveTimer;
  Timer? _notesSaveTimer;
  double? _splitWidth;
  double? _dragStartWidth;
  var _appliedSavedWidth = false;
  late final Future<void> Function() _lifecycleFlushCallback;

  @override
  void initState() {
    super.initState();
    _lifecycleFlushCallback = _lifecycleFlush;
    PendingFlushRegistry.instance.register(_lifecycleFlushCallback);
    _titleFocusNode.addListener(_handleTitleFocusChanged);
    _notesFocusNode.onKeyEvent = _handleNotesKey;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(ref.read(allDreamEntriesProvider.future));
    });
  }

  Future<void> _lifecycleFlush() async {
    await _flushActiveEdits();
    await _flushNotes();
  }

  void _handleTitleFocusChanged() {
    if (!_titleFocusNode.hasFocus) {
      unawaited(_flushActiveEdits());
    }
  }

  @override
  void dispose() {
    PendingFlushRegistry.instance.unregister(_lifecycleFlushCallback);
    _titleFocusNode.removeListener(_handleTitleFocusChanged);
    _saveTimer?.cancel();
    _notesSaveTimer?.cancel();
    _titleController.dispose();
    _titleFocusNode.dispose();
    _bodyFocusNode.dispose();
    _notesController.dispose();
    _notesFocusNode.dispose();
    _listTitlePreview.dispose();
    _listBodyPreview.dispose();
    super.dispose();
  }

  DreamWriteCoordinator? _coordinatorOrNull() =>
      mounted ? ref.read(dreamWriteCoordinatorProvider) : null;
  DreamRepository? _repoOrNull() =>
      mounted ? ref.read(dreamRepositoryProvider) : null;
  RemoteSyncService? _syncOrNull() =>
      mounted ? ref.read(remoteSyncServiceProvider) : null;

  void _scheduleBodySave() {
    _saveTimer?.cancel();
    _saveTimer = Timer(_localSaveDebounce, () {
      unawaited(_saveDraft(bumpVersion: false));
    });
  }

  Future<void> _saveDraft({required bool bumpVersion}) async {
    final entry = _selectedEntry;
    if (entry == null) return;
    final body = _bodyEditorKey.currentState?.currentBodyText ?? entry.body;
    await _persistEntryEdits(
      entry: entry,
      title: _titleController.text,
      body: body,
      bumpVersion: bumpVersion,
    );
  }

  Future<void> _persistEntryEdits({
    required DreamEntry entry,
    required String title,
    required String body,
    bool bumpVersion = false,
  }) async {
    final tags = extractTags(body);
    final coordinator = _coordinatorOrNull();
    final repo = _repoOrNull();
    if (coordinator == null || repo == null) return;

    final stored = await repo.getEntry(entry.id);
    final baseline = stored ?? entry;
    if (baseline.title == title &&
        baseline.body == body &&
        _sameTags(baseline.tags, tags)) {
      return;
    }

    try {
      await coordinator.saveEntry(
        entryId: entry.id,
        bumpVersion: bumpVersion,
        applyDelta: (base) => base.copyWith(
          title: title,
          body: body,
          tags: tags,
          bumpVersion: false,
        ),
        onSuccess: (updated) {
          if (_selectedEntryId == entry.id) {
            _listTitlePreview.value = updated.title;
            _listBodyPreview.value = updated.body;
            if (mounted) setState(() => _selectedEntry = updated);
          }
          if (mounted) ref.invalidate(allDreamEntriesProvider);
        },
      );
    } catch (error, stackTrace) {
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: error,
          stack: stackTrace,
          library: 'DreamJournalPage',
          context: ErrorDescription('while persisting dream entry edits'),
        ),
      );
    }
  }

  Future<void> _flushActiveEdits() async {
    _saveTimer?.cancel();
    final entryId = _selectedEntryId;
    final entry = _selectedEntry;
    if (entryId == null || entry == null) return;
    final remoteSync = _syncOrNull();
    if (remoteSync == null) return;

    final currentBody = _bodyEditorKey.currentState?.currentBodyText ?? entry.body;
    final pendingApplied = await remoteSync.applyPendingDreamEntryTextMerge(
      entryId: entryId,
      currentLocalText: currentBody,
    );
    if (pendingApplied != null && mounted) {
      _bodyEditorKey.currentState?.setBodyText(pendingApplied.body);
    }

    await _persistEntryEdits(
      entry: entry,
      title: _titleController.text,
      body: _bodyEditorKey.currentState?.currentBodyText ??
          pendingApplied?.body ??
          entry.body,
      bumpVersion: true,
    );

    await remoteSync.flushDocument(FirestoreCollections.dreamEntries, entryId);
  }

  void _scheduleNotesSave() {
    _notesSaveTimer?.cancel();
    _notesSaveTimer = Timer(_localSaveDebounce, () {
      unawaited(_saveNotes(bumpVersion: false));
    });
  }

  void _handleNotesChanged(String value) {
    applyListEditing(controller: _notesController, previousText: _lastNotesText);
    _lastNotesText = _notesController.text;
    _scheduleNotesSave();
  }

  KeyEventResult _handleNotesKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    if (event.logicalKey == LogicalKeyboardKey.tab) {
      final outdent = HardwareKeyboard.instance.isShiftPressed;
      if (handleListTab(controller: _notesController, outdent: outdent)) {
        // Route through the same handler typing uses so the edit gets
        // saved and _lastNotesText stays in sync for the next keystroke.
        _handleNotesChanged(_notesController.text);
        return KeyEventResult.handled;
      }
    }
    if (event.logicalKey == LogicalKeyboardKey.backspace) {
      if (handleListBackspace(controller: _notesController)) {
        _handleNotesChanged(_notesController.text);
        return KeyEventResult.handled;
      }
    }
    return KeyEventResult.ignored;
  }

  Future<void> _saveNotes({required bool bumpVersion}) async {
    final entry = _selectedEntry;
    final coordinator = _coordinatorOrNull();
    final repo = _repoOrNull();
    if (entry == null || coordinator == null || repo == null) return;

    final notesText = _notesController.text;
    final stored = await repo.getEntry(entry.id);
    final baseline = stored ?? entry;
    if ((baseline.notes ?? '') == notesText) return;

    await coordinator.saveEntry(
      entryId: entry.id,
      bumpVersion: bumpVersion,
      applyDelta: (base) => base.copyWith(notes: notesText, bumpVersion: false),
      onSuccess: (updated) {
        if (_selectedEntryId == entry.id && mounted) {
          setState(() => _selectedEntry = updated);
        }
      },
    );
  }

  Future<void> _flushNotes() async {
    _notesSaveTimer?.cancel();
    await _saveNotes(bumpVersion: true);
  }

  bool _sameTags(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  Future<void> _selectEntry(DreamEntry entry) async {
    if (_selectedEntryId == entry.id) return;
    await _flushActiveEdits();
    await _flushNotes();
    if (!mounted) return;
    setState(() {
      _selectedEntryId = entry.id;
      _selectedEntry = entry;
      _titleController.text = entry.title;
      _notesController.text = entry.notes ?? '';
      _lastNotesText = _notesController.text;
      _listTitlePreview.value = entry.title;
      _listBodyPreview.value = entry.body;
    });
  }

  Future<void> _createEntry() async {
    final repo = _repoOrNull();
    final remoteSync = _syncOrNull();
    if (repo == null || remoteSync == null) return;
    await _flushActiveEdits();
    await _flushNotes();
    if (!mounted) return;

    final now = utcNow();
    final entry = DreamEntry(
      id: newId(),
      title: '',
      body: '',
      entryDate: now,
      createdAt: now,
      updatedAt: now,
    );
    await repo.upsertEntry(entry);
    remoteSync.pushDreamEntryNow(entry);
    ref.invalidate(allDreamEntriesProvider);
    if (!mounted) return;
    setState(() {
      _selectedEntryId = entry.id;
      _selectedEntry = entry;
      _titleController.text = '';
      _notesController.text = '';
      _lastNotesText = '';
      _listTitlePreview.value = '';
      _listBodyPreview.value = '';
    });
    _titleFocusNode.requestFocus();
  }

  void _togglePinned(bool pinned) {
    unawaited(() async {
      final settingsRepo = ref.read(settingsRepositoryProvider);
      final settings = await settingsRepo.getSettings();
      await settingsRepo.saveSettings(
        settings.copyWith(dreamNotesPinned: pinned),
      );
      ref.invalidate(settingsProvider);
    }());
  }

  Future<void> _persistSplitWidth(double? width) async {
    final settingsRepo = ref.read(settingsRepositoryProvider);
    final settings = await settingsRepo.getSettings();
    if (settings.dreamSplitWidth == width) return;
    await settingsRepo.saveSettings(
      width == null
          ? settings.copyWith(clearDreamSplitWidth: true)
          : settings.copyWith(dreamSplitWidth: width),
    );
    ref.invalidate(settingsProvider);
  }

  @override
  Widget build(BuildContext context) {
    final entriesAsync = ref.watch(allDreamEntriesProvider);
    final settings = ref.watch(settingsProvider).valueOrNull;
    if (!_appliedSavedWidth && settings != null) {
      _splitWidth = settings.dreamSplitWidth;
      _appliedSavedWidth = true;
    }
    final notesPinned = settings?.dreamNotesPinned ?? false;
    final accent = Theme.of(context).colorScheme.primary;
    final petalColor = Color(settings?.petalColor ?? 0xFFE6A4B4);
    final minorPetalColors = (settings?.minorPetalColors ?? const <int>[])
        .map(Color.new)
        .toList();

    return Stack(
      children: [
        Positioned.fill(
          child: DreamBranchOverlay(
            color: petalColor,
            minorColors: minorPetalColors,
          ),
        ),
        entriesAsync.when(
          data: (entries) {
            final sorted = sortDreamEntriesNewestFirst(entries);
            if (_selectedEntryId == null && sorted.isNotEmpty) {
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (mounted && _selectedEntryId == null) {
                  unawaited(_selectEntry(sorted.first));
                }
              });
            }
            return LayoutBuilder(
              builder: (context, constraints) {
                final totalWidth = constraints.maxWidth;
                final listWidth = DreamSplitLayout.clampListWidth(
                  _splitWidth ?? DreamSplitLayout.defaultListWidth(totalWidth),
                  totalWidth,
                );
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    SizedBox(width: listWidth, child: _buildEntryList(sorted)),
                    ResizablePaneDivider(
                      onDragStart: () {
                        _dragStartWidth = _splitWidth ??
                            DreamSplitLayout.defaultListWidth(totalWidth);
                      },
                      onDragUpdate: (totalDelta) {
                        final start = _dragStartWidth ??
                            DreamSplitLayout.defaultListWidth(totalWidth);
                        setState(() {
                          _splitWidth = DreamSplitLayout.clampListWidth(
                            start + totalDelta,
                            totalWidth,
                          );
                        });
                      },
                      onDragEnd: () {
                        unawaited(_persistSplitWidth(_splitWidth));
                      },
                      onDoubleTapReset: () {
                        setState(() => _splitWidth = null);
                        unawaited(_persistSplitWidth(null));
                      },
                    ),
                    Expanded(
                      child: _buildEditorArea(
                        accent: accent,
                        notesPinned: notesPinned,
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
      ],
    );
  }

  Widget _buildEntryList(List<DreamEntry> entries) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Row(
            children: [
              Text(
                'Dreams',
                style: Theme.of(
                  context,
                ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
              ),
              const Spacer(),
              IconButton(
                tooltip: 'New dream entry',
                icon: const Icon(PhosphorIconsRegular.plus),
                onPressed: () => unawaited(_createEntry()),
              ),
            ],
          ),
        ),
        Expanded(
          child: entries.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      'No dreams logged yet.',
                      style: Theme.of(context).textTheme.bodyMedium,
                      textAlign: TextAlign.center,
                    ),
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.only(bottom: 16),
                  itemCount: entries.length,
                  itemBuilder: (context, index) {
                    final entry = entries[index];
                    return _DreamEntryListTile(
                      entry: entry,
                      isSelected: entry.id == _selectedEntryId,
                      titlePreview: _listTitlePreview,
                      bodyPreview: _listBodyPreview,
                      onTap: () => unawaited(_selectEntry(entry)),
                    );
                  },
                ),
        ),
      ],
    );
  }

  Widget _buildEditorArea({required Color accent, required bool notesPinned}) {
    final entry = _selectedEntry;
    if (entry == null) {
      return Center(
        child: Text(
          'Select or create a dream to begin.',
          style: Theme.of(context).textTheme.bodyMedium,
        ),
      );
    }

    final editorColumn = Padding(
      padding: DreamSplitLayout.editorPadding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: _titleController,
            focusNode: _titleFocusNode,
            style: Theme.of(context).textTheme.headlineSmall,
            decoration: const InputDecoration(
              border: InputBorder.none,
              hintText: 'Untitled dream',
            ),
            onChanged: (_) => _scheduleBodySave(),
          ),
          const SizedBox(height: 12),
          Expanded(
            child: _DreamBodyEditor(
              key: _bodyEditorKey,
              entry: entry,
              focusNode: _bodyFocusNode,
              accentColor: accent,
              onScheduleBodySave: _scheduleBodySave,
            ),
          ),
        ],
      ),
    );

    return Stack(
      children: [
        Column(
          children: [
            Expanded(child: editorColumn),
            AnimatedSize(
              duration: const Duration(milliseconds: 320),
              curve: Curves.easeOutCubic,
              child: notesPinned
                  ? DreamNotesDockedPanel(
                      key: const ValueKey('docked'),
                      controller: _notesController,
                      focusNode: _notesFocusNode,
                      onChanged: _handleNotesChanged,
                      onUnpin: () => _togglePinned(false),
                    )
                  : const SizedBox(width: double.infinity, height: 0),
            ),
          ],
        ),
        if (!notesPinned)
          DreamStickyNote(
            controller: _notesController,
            focusNode: _notesFocusNode,
            accentColor: accent,
            onChanged: _handleNotesChanged,
            onPin: () => _togglePinned(true),
          ),
      ],
    );
  }
}

class _DreamEntryListTile extends StatelessWidget {
  const _DreamEntryListTile({
    required this.entry,
    required this.isSelected,
    required this.titlePreview,
    required this.bodyPreview,
    required this.onTap,
  });

  final DreamEntry entry;
  final bool isSelected;
  final ValueNotifier<String> titlePreview;
  final ValueNotifier<String> bodyPreview;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final local = entry.entryDate.toLocal();
    final dateLabel = MaterialLocalizations.of(context).formatShortDate(local);
    final timeLabel = formatTime12Hour(local);
    final theme = Theme.of(context);
    final titleStyle = theme.textTheme.titleSmall;
    final previewStyle = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurface.withValues(alpha: 0.78),
    );
    final dateStyle = theme.textTheme.labelSmall?.copyWith(
      color: theme.colorScheme.onSurface.withValues(alpha: 0.65),
    );
    // A faint border flags entries with only a title and no detailed log yet.
    final isDraft = entry.body.trim().isEmpty;

    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: VoyagerSpacing.sm,
        vertical: VoyagerSpacing.xxs,
      ),
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          border: isDraft
              ? Border.all(
                  color: theme.colorScheme.outline.withValues(alpha: 0.35),
                )
              : null,
        ),
        child: ListTile(
          dense: true,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          visualDensity: const VisualDensity(
            vertical: VoyagerSpacing.compactListVerticalDensity,
          ),
          contentPadding: const EdgeInsets.symmetric(
            horizontal: VoyagerSpacing.md,
            vertical: VoyagerSpacing.xs,
          ),
          tileColor: VoyagerListItemSurface.restingColor(context),
          selectedTileColor: VoyagerListItemSurface.selectedColor(context),
          selected: isSelected,
          title: isSelected
              ? ValueListenableBuilder<String>(
                  valueListenable: titlePreview,
                  builder: (context, title, _) => Text(
                    title.isEmpty ? 'Untitled' : title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: titleStyle,
                  ),
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
              else
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
              Text('$dateLabel · $timeLabel', style: dateStyle),
            ],
          ),
          onTap: onTap,
        ),
      ),
    );
  }
}

class _DreamBodyEditor extends ConsumerStatefulWidget {
  const _DreamBodyEditor({
    super.key,
    required this.entry,
    required this.focusNode,
    required this.accentColor,
    required this.onScheduleBodySave,
  });

  final DreamEntry entry;
  final FocusNode focusNode;
  final Color accentColor;
  final VoidCallback onScheduleBodySave;

  @override
  ConsumerState<_DreamBodyEditor> createState() => _DreamBodyEditorState();
}

class _DreamBodyEditorState extends ConsumerState<_DreamBodyEditor> {
  late final TextEditingController _controller;
  var _lastText = '';
  RemoteSyncService? _remoteSync;
  PendingTextMergeListener? _pendingTextMergeListener;

  String get currentBodyText => _controller.text;

  void setBodyText(String body) {
    _controller.text = body;
    _lastText = body;
  }

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.entry.body);
    _lastText = _controller.text;
    widget.focusNode.addListener(_handleFocusChanged);
    widget.focusNode.onKeyEvent = _handleKey;
    final remoteSync = ref.read(remoteSyncServiceProvider);
    _remoteSync = remoteSync;
    remoteSync.prepareEditingSession(
      collection: FirestoreCollections.dreamEntries,
      documentId: widget.entry.id,
      initialText: _controller.text,
    );
    remoteSync.setDocumentEditing(
      collection: FirestoreCollections.dreamEntries,
      documentId: widget.entry.id,
      isEditing: widget.focusNode.hasFocus,
    );
    _pendingTextMergeListener = _handlePendingTextMerge;
    remoteSync.addPendingTextMergeListener(
      collection: FirestoreCollections.dreamEntries,
      documentId: widget.entry.id,
      listener: _pendingTextMergeListener!,
    );
  }

  void _handlePendingTextMerge(PendingTextMergeEvent event) {
    if (!mounted || widget.entry.id != event.documentId) return;
    if (!widget.focusNode.hasFocus) return;

    final before = _controller.text;
    final merged = TextDeltaInjector.injectRemoteDelta(
      localText: before,
      oldRemoteText: event.previousRemoteText,
      newRemoteText: event.remoteText,
    );
    if (merged == before) return;

    final selection = _controller.selection;
    _controller.value = TextEditingValue(
      text: merged,
      selection: TextSelection.collapsed(
        offset: TextDeltaInjector.adjustedSelection(
          selection: selection.baseOffset,
          before: before,
          after: merged,
        ),
      ),
    );
    _lastText = merged;
    widget.onScheduleBodySave();
    if (mounted) setState(() {});
  }

  @override
  void didUpdateWidget(covariant _DreamBodyEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.entry.id == widget.entry.id) return;

    final remoteSync = _remoteSync;
    if (remoteSync != null) {
      if (_pendingTextMergeListener != null) {
        remoteSync.removePendingTextMergeListener(
          collection: FirestoreCollections.dreamEntries,
          documentId: oldWidget.entry.id,
          listener: _pendingTextMergeListener!,
        );
      }
      remoteSync.setDocumentEditing(
        collection: FirestoreCollections.dreamEntries,
        documentId: oldWidget.entry.id,
        isEditing: false,
      );
    }

    _controller.text = widget.entry.body;
    _lastText = _controller.text;

    if (remoteSync != null) {
      _pendingTextMergeListener = _handlePendingTextMerge;
      remoteSync.addPendingTextMergeListener(
        collection: FirestoreCollections.dreamEntries,
        documentId: widget.entry.id,
        listener: _pendingTextMergeListener!,
      );
      remoteSync.prepareEditingSession(
        collection: FirestoreCollections.dreamEntries,
        documentId: widget.entry.id,
        initialText: _controller.text,
      );
      remoteSync.setDocumentEditing(
        collection: FirestoreCollections.dreamEntries,
        documentId: widget.entry.id,
        isEditing: widget.focusNode.hasFocus,
      );
    }
    setState(() {});
  }

  @override
  void dispose() {
    final remoteSync = _remoteSync;
    if (remoteSync != null) {
      if (_pendingTextMergeListener != null) {
        remoteSync.removePendingTextMergeListener(
          collection: FirestoreCollections.dreamEntries,
          documentId: widget.entry.id,
          listener: _pendingTextMergeListener!,
        );
      }
      remoteSync.setDocumentEditing(
        collection: FirestoreCollections.dreamEntries,
        documentId: widget.entry.id,
        isEditing: false,
      );
    }
    widget.focusNode.removeListener(_handleFocusChanged);
    widget.focusNode.onKeyEvent = null;
    _controller.dispose();
    super.dispose();
  }

  void _handleFocusChanged() {
    final remoteSync = _remoteSync;
    if (remoteSync == null) return;
    remoteSync.setDocumentEditing(
      collection: FirestoreCollections.dreamEntries,
      documentId: widget.entry.id,
      isEditing: widget.focusNode.hasFocus,
    );
  }

  void _handleChanged(String value) {
    applyListEditing(controller: _controller, previousText: _lastText);

    final before = _lastText;
    _lastText = _controller.text;
    _remoteSync?.recordDreamTextChange(
      entryId: widget.entry.id,
      before: before,
      after: _controller.text,
    );
    widget.onScheduleBodySave();
  }

  KeyEventResult _handleKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    if (event.logicalKey == LogicalKeyboardKey.tab) {
      final outdent = HardwareKeyboard.instance.isShiftPressed;
      if (handleListTab(controller: _controller, outdent: outdent)) {
        // Tab/Backspace mutate the controller directly, bypassing
        // TextField.onChanged — route through the same handler typing uses
        // so the edit gets saved and the CRDT character-op session (which
        // assumes `before` always matches its actual current text) doesn't
        // silently desync.
        _handleChanged(_controller.text);
        return KeyEventResult.handled;
      }
    }
    if (event.logicalKey == LogicalKeyboardKey.backspace) {
      if (handleListBackspace(controller: _controller)) {
        _handleChanged(_controller.text);
        return KeyEventResult.handled;
      }
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    return TagHighlightedTextField(
      controller: _controller,
      focusNode: widget.focusNode,
      expands: true,
      keyboardType: TextInputType.multiline,
      cursorColor: widget.accentColor,
      onChanged: _handleChanged,
      hintText: 'Describe your dream... use #tags to mark themes',
      decoration: const InputDecoration(
        filled: false,
        border: InputBorder.none,
        enabledBorder: InputBorder.none,
        focusedBorder: InputBorder.none,
      ),
    );
  }
}

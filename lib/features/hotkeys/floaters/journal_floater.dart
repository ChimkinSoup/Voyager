import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/layout/touch_target.dart';
import 'package:voyager/core/media/widgets/media_drop_target.dart';
import 'package:voyager/core/media/widgets/media_fan_stack.dart';
import 'package:voyager/core/media/widgets/media_paste_scope.dart';
import 'package:voyager/core/sync/firestore_collections.dart';
import 'package:voyager/core/sync/journal_write_coordinator.dart';
import 'package:voyager/core/sync/pending_flush_registry.dart';
import 'package:voyager/core/sync/remote_sync_service.dart';
import 'package:voyager/core/utils/ids.dart';
import 'package:voyager/core/utils/journal_tags.dart';
import 'package:voyager/core/widgets/voyager_text_field.dart';
import 'package:voyager/domain/models/journal_models.dart';
import 'package:voyager/domain/repositories/repositories.dart';
import 'package:voyager/features/hotkeys/floaters/floater_app_icon.dart';
import 'package:voyager/features/hotkeys/floaters/floater_controller.dart';
import 'package:voyager/features/hotkeys/quick_journal_entry.dart';
import 'package:voyager/features/journal/journal_entry_delete.dart';

const _saveDebounce = Duration(milliseconds: 400);

/// The journal hotkey's notepad: a plain-text mirror of today's Quick Journal
/// Entry body. With no entry yet today, it creates one only once something is
/// written, so opening it and closing it untouched leaves nothing behind.
///
/// Edits go through the same pipeline as the journal editor — a character-op
/// session for sync, debounced local saves through the write coordinator, and
/// a flush on dismiss — so the entry reads the same in the app afterwards.
class JournalFloater extends ConsumerStatefulWidget {
  const JournalFloater({super.key});

  @override
  ConsumerState<JournalFloater> createState() => _JournalFloaterState();
}

class _JournalFloaterState extends ConsumerState<JournalFloater> {
  final _controller = TextEditingController();
  final _focus = FocusNode();
  late final FloaterController _floaters;
  late final RemoteSyncService _remoteSync;
  late final JournalWriteCoordinator _coordinator;
  late final JournalRepository _repository;
  late final Future<void> Function() _flushCallback;

  late final void Function() _invalidateJournalCaches;
  late final ProviderContainer _container;

  JournalEntry? _entry;

  /// The id today's entry is created as, handed to the image targets before
  /// it exists.
  final _pendingId = newId();
  var _loaded = false;
  Future<void>? _creating;

  /// The body as last typed or merged. Saves read this rather than the
  /// controller, which is gone by the time the dispose flush gets to write.
  String _lastText = '';
  Timer? _saveTimer;
  var _deleted = false;

  @override
  void initState() {
    super.initState();
    _floaters = ref.read(floaterControllerProvider);
    _remoteSync = ref.read(remoteSyncServiceProvider);
    _coordinator = ref.read(journalWriteCoordinatorProvider);
    _repository = ref.read(journalRepositoryProvider);
    _invalidateJournalCaches = ref.read(journalEntryCacheInvalidatorProvider);
    _container = ProviderScope.containerOf(context, listen: false);
    _flushCallback = _flush;
    _floaters.registerFlush(_flushCallback);
    PendingFlushRegistry.instance.register(_flushCallback);
    unawaited(_bind());
  }

  Future<void> _bind() async {
    final entry = await findQuickJournalEntry(_container);
    if (!mounted) return;
    setState(() => _loaded = true);
    if (entry == null) {
      _focus.requestFocus();
      return;
    }
    _controller.value = TextEditingValue(
      text: entry.body,
      selection: TextSelection.collapsed(offset: entry.body.length),
    );
    _lastText = entry.body;
    quickJournalNotepadEntryId.value = entry.id;
    setState(() => _entry = entry);
    _remoteSync.setDocumentEditing(
      collection: FirestoreCollections.journalEntries,
      documentId: entry.id,
      isEditing: true,
    );
    _focus.requestFocus();
    try {
      await _remoteSync.prepareEditingSession(
        collection: FirestoreCollections.journalEntries,
        documentId: entry.id,
        initialText: entry.body,
      );
    } catch (error, stack) {
      _report(error, stack, 'while preparing the editing session');
    }
  }

  /// Creates today's entry for what has been written so far. The session is
  /// prepared before [_entry] is set, so text typed meanwhile only moves
  /// [_lastText] and lands in the one change recorded after.
  Future<void> _ensureEntry() => _creating ??= () async {
    try {
      final entry = await resolveQuickJournalEntry(_container, id: _pendingId);
      _remoteSync.setDocumentEditing(
        collection: FirestoreCollections.journalEntries,
        documentId: entry.id,
        isEditing: true,
      );
      try {
        await _remoteSync.prepareEditingSession(
          collection: FirestoreCollections.journalEntries,
          documentId: entry.id,
          initialText: entry.body,
        );
      } catch (error, stack) {
        _report(error, stack, 'while preparing the editing session');
      }
      quickJournalNotepadEntryId.value = entry.id;
      _entry = entry;
      // Today's entry was started elsewhere meanwhile: what was typed here
      // goes after its body rather than over it.
      if (entry.id != _pendingId && entry.body.isNotEmpty) {
        _lastText = '${entry.body}\n$_lastText';
        if (mounted) {
          _controller.value = TextEditingValue(
            text: _lastText,
            selection: TextSelection.collapsed(offset: _lastText.length),
          );
        }
      }
      if (mounted) setState(() {});
      _remoteSync.recordJournalTextChange(
        entryId: entry.id,
        before: entry.body,
        after: _lastText,
      );
      await _save();
    } catch (error, stack) {
      _creating = null;
      _report(error, stack, 'while creating the quick entry');
    }
  }();

  /// For the image targets: the entry an image attaches to, created first
  /// if need be. Throws when it could not be, so no image is left ownerless.
  Future<String> _entryIdForImage() async {
    await _ensureEntry();
    final entry = _entry;
    if (entry == null) throw StateError('The quick entry could not be created');
    return entry.id;
  }

  void _handleChanged(String text) {
    final entry = _entry;
    if (entry == null) {
      _lastText = text;
      if (text.trim().isNotEmpty) unawaited(_ensureEntry());
      setState(() {});
      return;
    }
    _remoteSync.recordJournalTextChange(
      entryId: entry.id,
      before: _lastText,
      after: text,
    );
    _lastText = text;
    _saveTimer?.cancel();
    _saveTimer = Timer(_saveDebounce, () => unawaited(_save()));
    // The preview line follows the body when the entry has no title.
    if (entry.title.isEmpty) setState(() {});
  }

  Future<void> _save({bool bumpVersion = false}) {
    final entry = _entry;
    if (entry == null || _deleted) return Future.value();
    final body = _lastText;
    return _coordinator
        .saveEntry(
          entryId: entry.id,
          bumpVersion: bumpVersion,
          refreshCaches: false,
          applyDelta: (base) => base.copyWith(
            body: body,
            tags: extractTags(body),
            bumpVersion: false,
          ),
          onSuccess: (saved) => _entry = saved,
        )
        .catchError(
          (Object error, StackTrace stack) =>
              _report(error, stack, 'while saving the quick entry'),
        );
  }

  /// Runs on dismiss, on replacement by another floater, and on app quit.
  Future<void> _flush() async {
    _saveTimer?.cancel();
    await _creating;
    final entry = _entry;
    if (entry == null || _deleted) return;
    var body = _lastText;
    final merged = await _remoteSync.applyPendingJournalEntryTextMerge(
      entryId: entry.id,
      currentLocalText: body,
    );
    if (merged != null) {
      body = merged.body;
      _lastText = body;
      if (mounted) _controller.text = body;
    }
    final stored = await _repository.getEntry(entry.id);
    if (stored != null && stored.body != body) {
      await _save(bumpVersion: true);
    }
    await _remoteSync.flushDocumentLocal(
      FirestoreCollections.journalEntries,
      entry.id,
    );
    // Unconditional: the debounced saves skip the cache refresh, and the
    // journal page learns the new body from it.
    _invalidateJournalCaches();
  }

  Future<void> _delete() async {
    final entry = _entry;
    if (entry == null || _deleted) return;
    _deleted = true;
    _saveTimer?.cancel();
    _remoteSync.setDocumentEditing(
      collection: FirestoreCollections.journalEntries,
      documentId: entry.id,
      isEditing: false,
    );
    final container = ProviderScope.containerOf(context, listen: false);
    try {
      await softDeleteJournalEntry(container, entry.id);
    } finally {
      container.read(journalEntryCacheInvalidatorProvider)();
    }
    await _floaters.completeWith('Quick entry deleted');
  }

  void _report(Object error, StackTrace stack, String context) {
    FlutterError.reportError(
      FlutterErrorDetails(
        exception: error,
        stack: stack,
        library: 'JournalFloater',
        context: ErrorDescription(context),
      ),
    );
  }

  @override
  void dispose() {
    _floaters.unregisterFlush(_flushCallback);
    PendingFlushRegistry.instance.unregister(_flushCallback);
    if (_entry != null || _creating != null) {
      unawaited(() async {
        // An entry still being created is finished first, so what was typed
        // before the dismiss is not lost.
        await _creating;
        final entry = _entry;
        if (entry == null) return;
        if (!_deleted) {
          _remoteSync.setDocumentEditing(
            collection: FirestoreCollections.journalEntries,
            documentId: entry.id,
            isEditing: false,
          );
        }
        // Cheap when the dismiss already flushed: the body matches disk.
        await _flush();
        if (quickJournalNotepadEntryId.value == entry.id) {
          quickJournalNotepadEntryId.value = null;
        }
      }());
    }
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  String _preview(JournalEntry? entry) {
    if (!_loaded) return 'Quick entry';
    final title = entry?.title.trim() ?? '';
    if (title.isNotEmpty) return title;
    final firstLine = _controller.text
        .split('\n')
        .map((line) => line.trim())
        .firstWhere((line) => line.isNotEmpty, orElse: () => '');
    return firstLine.isEmpty ? 'Quick entry · today' : firstLine;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent = theme.colorScheme.primary;
    final entry = _entry;
    final entryId = entry?.id ?? _pendingId;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 6, 4, 0),
          child: Row(
            children: [
              const FloaterAppIcon(PhosphorIconsRegular.notePencil, size: 18),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  _preview(entry),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelLarge,
                ),
              ),
              IconButton(
                onPressed: entry == null ? null : _delete,
                icon: const Icon(PhosphorIconsRegular.trash, size: 18),
                tooltip: 'Delete entry',
                constraints: kMinTouchTarget,
              ),
            ],
          ),
        ),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
            child: !_loaded
                ? const Center(child: CircularProgressIndicator())
                // The journal body's images (see `_withImages` in
                // journal_page.dart): this is the same entry.
                : MediaPasteScope(
                    collection: FirestoreCollections.journalEntries,
                    documentId: entryId,
                    fieldTakesBoth: true,
                    onBeforeAttach: _entryIdForImage,
                    child: MediaDropTarget(
                      collection: FirestoreCollections.journalEntries,
                      documentId: entryId,
                      onBeforeAttach: _entryIdForImage,
                      child: Stack(
                        children: [
                          Positioned.fill(
                            child: VoyagerTextField(
                              controller: _controller,
                              focusNode: _focus,
                              accentColor: accent,
                              maxLines: null,
                              expands: true,
                              keyboardType: TextInputType.multiline,
                              decoration: const InputDecoration(
                                hintText: 'Write something…',
                              ),
                              onChanged: _handleChanged,
                            ),
                          ),
                          Positioned(
                            right: 8,
                            bottom: 8,
                            child: MediaFanStack(
                              collection: FirestoreCollections.journalEntries,
                              documentId: entryId,
                              accentColor: accent,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
          ),
        ),
      ],
    );
  }
}

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/soft_delete/soft_delete_toast.dart';
import 'package:voyager/core/sync/remote_sync_service.dart';
import 'package:voyager/core/utils/ids.dart';
import 'package:voyager/domain/models/leetcode_cheat_models.dart';
import 'package:voyager/domain/repositories/repositories.dart';
import 'package:voyager/features/leetcode/leetcode_cheat_providers.dart';

/// Every write the cheat sheet makes, in one place.
///
/// Same three beats as the rest of the app: write through the repository,
/// invalidate what reads it, hand the record to the sync layer — and never
/// await the network, which Firestore holds offline for as long as the device
/// is.
class LeetCodeCheatActions {
  /// Resolves the container now, while [ref]'s widget is certainly mounted, so
  /// nothing after the first `await` depends on it staying so.
  LeetCodeCheatActions(WidgetRef ref)
    : this.detached(ProviderScope.containerOf(ref.context, listen: false));

  /// Actions that outlive the widget that asked for them — the undo a toast
  /// offers, pressed seconds after the row it deleted was unmounted, and
  /// anything flushed from a `dispose`.
  const LeetCodeCheatActions.detached(ProviderContainer container)
    : _container = container;

  final ProviderContainer _container;

  LeetCodeRepository get _repository =>
      _container.read(leetCodeRepositoryProvider);
  RemoteSyncService get _sync => _container.read(remoteSyncServiceProvider);

  void _refresh() => _container.invalidate(leetCodeCheatSheetProvider);

  // --- Tabs ----------------------------------------------------------------

  Future<LeetCodeCheatTab> createTab({
    required String name,
    String? languageKey,
  }) async {
    final tabs = await _repository.listCheatTabs();
    final now = utcNow();
    final tab = LeetCodeCheatTab(
      id: newId(),
      name: name,
      languageKey: languageKey,
      position: tabs.isEmpty
          ? kCheatPositionStep
          : tabs.last.position + kCheatPositionStep,
      createdAt: now,
      updatedAt: now,
    );
    await _repository.upsertCheatTab(tab);
    _refresh();
    _sync.pushLeetCodeCheatTab(tab);
    return tab;
  }

  /// Patched by id rather than written from the caller's snapshot: a widget's
  /// copy lags the disk by a reload at best, and writing it whole puts back
  /// whatever a pull or another field's debounce changed since.
  Future<void> renameTab(String id, String name) async {
    final existing = await _repository.getCheatTab(id);
    if (existing == null || existing.name == name) return;
    final tab = existing.copyWith(name: name);
    await _repository.upsertCheatTab(tab);
    _refresh();
    _sync.pushLeetCodeCheatTab(tab);
  }

  Future<void> setTabLanguage(String id, String? languageKey) async {
    final existing = await _repository.getCheatTab(id);
    if (existing == null || existing.languageKey == languageKey) return;
    final tab = languageKey == null
        ? existing.copyWith(clearLanguageKey: true)
        : existing.copyWith(languageKey: languageKey);
    await _repository.upsertCheatTab(tab);
    _refresh();
    _sync.pushLeetCodeCheatTab(tab);
  }

  /// Moves the tab at [oldIndex] to [newIndex] within [ordered].
  ///
  /// Writes one row, not the strip: the dropped tab takes the midpoint of its
  /// new neighbours. Tabs are few enough that they are never renormalized —
  /// the seam would have to be dropped on some fifty times.
  Future<void> reorderTabs(
    List<LeetCodeCheatTab> ordered,
    int oldIndex,
    int newIndex,
  ) async {
    final moved = _movedNeighbours(ordered, oldIndex, newIndex);
    if (moved == null) return;
    final existing = await _repository.getCheatTab(ordered[oldIndex].id);
    if (existing == null) return;
    final tab = existing.copyWith(
      position: cheatPositionBetween(
        moved.before?.position,
        moved.after?.position,
      ),
    );
    await _repository.upsertCheatTab(tab);
    _refresh();
    _sync.pushLeetCodeCheatTab(tab);
  }

  // --- Sections ------------------------------------------------------------

  Future<LeetCodeCheatSection> createSection({
    required String tabId,
    required String name,
  }) async {
    final sections = await _repository.listCheatSections(tabId: tabId);
    final now = utcNow();
    final section = LeetCodeCheatSection(
      id: newId(),
      tabId: tabId,
      name: name,
      position: sections.isEmpty
          ? kCheatPositionStep
          : sections.last.position + kCheatPositionStep,
      createdAt: now,
      updatedAt: now,
    );
    await _repository.upsertCheatSection(section);
    _refresh();
    _sync.pushLeetCodeCheatSection(section);
    return section;
  }

  Future<void> renameSection(String id, String name) async {
    final existing = await _repository.getCheatSection(id);
    if (existing == null || existing.name == name) return;
    final section = existing.copyWith(name: name);
    await _repository.upsertCheatSection(section);
    _refresh();
    _sync.pushLeetCodeCheatSection(section);
  }

  Future<void> reorderSections(
    List<LeetCodeCheatSection> ordered,
    int oldIndex,
    int newIndex,
  ) async {
    final moved = _movedNeighbours(ordered, oldIndex, newIndex);
    if (moved == null) return;
    final existing = await _repository.getCheatSection(ordered[oldIndex].id);
    if (existing == null) return;
    final section = existing.copyWith(
      position: cheatPositionBetween(
        moved.before?.position,
        moved.after?.position,
      ),
    );
    await _repository.upsertCheatSection(section);
    _refresh();
    _sync.pushLeetCodeCheatSection(section);

    // The drop may have halved the gap past what a double can still split.
    // Renumbering is a bulk write, but the user paid for it with the drag.
    final next = [...moved.result];
    next[newIndex] = section;
    if (!cheatPositionsNeedRenormalize([for (final s in next) s.position])) {
      return;
    }
    final written = await _repository.renormalizeCheatSections(next);
    _refresh();
    unawaited(_sync.pushLeetCodeCheatSectionsBatch(written));
  }

  // --- Entries -------------------------------------------------------------

  Future<LeetCodeCheatEntry> createEntry({
    required String sectionId,
    String command = '',
  }) async {
    final entries = await _repository.listCheatEntries(sectionId: sectionId);
    final now = utcNow();
    final entry = LeetCodeCheatEntry(
      id: newId(),
      sectionId: sectionId,
      command: command,
      position: entries.isEmpty
          ? kCheatPositionStep
          : entries.last.position + kCheatPositionStep,
      createdAt: now,
      updatedAt: now,
    );
    await _repository.upsertCheatEntry(entry);
    _refresh();
    _sync.pushLeetCodeCheatEntry(entry);
    return entry;
  }

  /// Saves whichever of the four fields the caller names, leaving the rest
  /// as they are on disk.
  ///
  /// [complexity] and [label] empty or whitespace store null rather than `''`:
  /// their presence in Viewing mode is the only flag the entry has, and an
  /// empty string would draw an empty badge or hold an empty column open.
  ///
  /// [complexity] keeps its interior shape, though — it is one line per line
  /// of the command, so a blank first line means "the first line has no cost"
  /// and trimming it away would slide every badge up a line.
  Future<void> saveEntry(
    String id, {
    String? command,
    String? label,
    String? description,
    String? complexity,
  }) async {
    final existing = await _repository.getCheatEntry(id);
    if (existing == null) return;
    // Trailing blank lines belong to no command line, so they go; a leading
    // one does not.
    final nextComplexity = complexity?.trimRight();
    final nextLabel = label?.trim();
    final unchanged =
        (command == null || command == existing.command) &&
        (description == null || description == existing.description) &&
        (label == null ||
            (nextLabel!.isEmpty ? null : nextLabel) == existing.label) &&
        (complexity == null ||
            (nextComplexity!.isEmpty ? null : nextComplexity) ==
                existing.complexity);
    if (unchanged) return;

    var entry = existing.copyWith(command: command, description: description);
    if (label != null) {
      entry = nextLabel!.isEmpty
          ? entry.copyWith(clearLabel: true, bumpVersion: false)
          : entry.copyWith(label: nextLabel, bumpVersion: false);
    }
    if (complexity != null) {
      entry = nextComplexity!.isEmpty
          ? entry.copyWith(clearComplexity: true, bumpVersion: false)
          : entry.copyWith(complexity: nextComplexity, bumpVersion: false);
    }
    await _repository.upsertCheatEntry(entry);
    _refresh();
    _sync.pushLeetCodeCheatEntry(entry);
  }

  Future<void> reorderEntries(
    List<LeetCodeCheatEntry> ordered,
    int oldIndex,
    int newIndex,
  ) async {
    final moved = _movedNeighbours(ordered, oldIndex, newIndex);
    if (moved == null) return;
    final existing = await _repository.getCheatEntry(ordered[oldIndex].id);
    if (existing == null) return;
    final entry = existing.copyWith(
      position: cheatPositionBetween(
        moved.before?.position,
        moved.after?.position,
      ),
    );
    await _repository.upsertCheatEntry(entry);
    _refresh();
    _sync.pushLeetCodeCheatEntry(entry);

    final next = [...moved.result];
    next[newIndex] = entry;
    if (!cheatPositionsNeedRenormalize([for (final e in next) e.position])) {
      return;
    }
    final written = await _repository.renormalizeCheatEntries(next);
    _refresh();
    unawaited(_sync.pushLeetCodeCheatEntriesBatch(written));
  }

  // --- Deletes -------------------------------------------------------------

  Future<void> deleteEntry(String id) async {
    final entry = await _repository.softDeleteCheatEntry(id);
    _refresh();
    _sync.pushLeetCodeCheatEntry(entry);
  }

  Future<void> restoreEntry(String id) async {
    final entry = await _repository.restoreCheatEntry(id);
    _refresh();
    _sync.pushLeetCodeCheatEntry(entry);
  }

  Future<void> deleteSection(String id) async {
    final result = await _repository.softDeleteCheatSection(id);
    _refresh();
    _sync.pushLeetCodeCheatSection(result.section);
    unawaited(_sync.pushLeetCodeCheatEntriesBatch(result.entries));
  }

  Future<void> restoreSection(String id) async {
    final result = await _repository.restoreCheatSection(id);
    _refresh();
    _sync.pushLeetCodeCheatSection(result.section);
    unawaited(_sync.pushLeetCodeCheatEntriesBatch(result.entries));
  }

  Future<void> deleteTab(String id) async {
    final result = await _repository.softDeleteCheatTab(id);
    _refresh();
    _sync.pushLeetCodeCheatTab(result.tab);
    unawaited(_sync.pushLeetCodeCheatSectionsBatch(result.sections));
    unawaited(_sync.pushLeetCodeCheatEntriesBatch(result.entries));
  }

  Future<void> restoreTab(String id) async {
    final result = await _repository.restoreCheatTab(id);
    _refresh();
    _sync.pushLeetCodeCheatTab(result.tab);
    unawaited(_sync.pushLeetCodeCheatSectionsBatch(result.sections));
    unawaited(_sync.pushLeetCodeCheatEntriesBatch(result.entries));
  }

  // --- Device-local state (§5.5) -------------------------------------------

  /// Remembers the tab this device is on.
  ///
  /// Both this and [setCollapsedSections] write settings columns that are
  /// deliberately absent from `settingsSyncPayload`, so `saveSettings` leaves
  /// `AppSettings.updatedAt` where it is and nothing reaches the sync layer.
  /// That is the whole mechanism: opening the sheet must not be able to
  /// overwrite a preference another device changed more recently.
  Future<void> setLastTabId(String? tabId) async {
    final repository = _container.read(settingsRepositoryProvider);
    final settings = await repository.getSettings();
    if (settings.leetCodeCheatLastTabId == tabId) return;
    await _container
        .read(settingsProvider.notifier)
        .saveSettings(
          tabId == null
              ? settings.copyWith(clearLeetCodeCheatLastTabId: true)
              : settings.copyWith(leetCodeCheatLastTabId: tabId),
        );
  }

  /// [collapsed] narrowed to sections that still exist, so ids for sections
  /// deleted elsewhere are pruned on the next write rather than accumulating.
  Future<void> setCollapsedSections(
    Set<String> collapsed, {
    required Set<String> liveSectionIds,
  }) async {
    final repository = _container.read(settingsRepositoryProvider);
    final settings = await repository.getSettings();
    final pruned = [
      for (final id in collapsed)
        if (liveSectionIds.contains(id)) id,
    ]..sort();
    final current = [...settings.leetCodeCheatCollapsedSections]..sort();
    if (pruned.length == current.length && pruned.every(current.contains)) {
      return;
    }
    await _container
        .read(settingsProvider.notifier)
        .saveSettings(
          settings.copyWith(leetCodeCheatCollapsedSections: pruned),
        );
  }
}

/// [ordered] with the item at [oldIndex] moved to [newIndex], plus the two
/// rows it lands between.
///
/// Null when the move is a no-op, so a drag that ends where it started writes
/// nothing at all.
({List<T> result, T? before, T? after})? _movedNeighbours<T>(
  List<T> ordered,
  int oldIndex,
  int newIndex,
) {
  if (oldIndex == newIndex) return null;
  if (oldIndex < 0 || oldIndex >= ordered.length) return null;
  if (newIndex < 0 || newIndex >= ordered.length) return null;
  final next = [...ordered];
  next.insert(newIndex, next.removeAt(oldIndex));
  return (
    result: next,
    before: newIndex == 0 ? null : next[newIndex - 1],
    after: newIndex == next.length - 1 ? null : next[newIndex + 1],
  );
}

/// Deletes [entry] and stands an undo offer for it.
///
/// [overlay] is resolved by the caller *before* the delete: deleting a row
/// unmounts the widget that asked for it, and the toast has to outlive that.
Future<void> deleteCheatEntryWithUndo(
  OverlayState overlay,
  ProviderContainer container, {
  required LeetCodeCheatEntry entry,
}) async {
  final actions = LeetCodeCheatActions.detached(container);
  await softDeleteWithUndo(
    overlay: overlay,
    message: deletedMessage(entry.command, fallback: 'entry'),
    delete: () => actions.deleteEntry(entry.id),
    restore: () => actions.restoreEntry(entry.id),
  );
}

/// [deleteCheatEntryWithUndo] for a section: the heading and every live entry
/// under it come back as one unit.
Future<void> deleteCheatSectionWithUndo(
  OverlayState overlay,
  ProviderContainer container, {
  required LeetCodeCheatSection section,
}) async {
  final actions = LeetCodeCheatActions.detached(container);
  await softDeleteWithUndo(
    overlay: overlay,
    message: deletedMessage(section.name, fallback: 'section'),
    delete: () => actions.deleteSection(section.id),
    restore: () => actions.restoreSection(section.id),
  );
}

/// [deleteCheatEntryWithUndo] for a tab: its sections and their entries come
/// back with it.
Future<void> deleteCheatTabWithUndo(
  OverlayState overlay,
  ProviderContainer container, {
  required LeetCodeCheatTab tab,
}) async {
  final actions = LeetCodeCheatActions.detached(container);
  await softDeleteWithUndo(
    overlay: overlay,
    message: deletedMessage(tab.name, fallback: 'tab'),
    delete: () => actions.deleteTab(tab.id),
    restore: () => actions.restoreTab(tab.id),
  );
}

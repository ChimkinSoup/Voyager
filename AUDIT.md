# Study Page — Code Audit

Scope: `lib/features/study/**`, `lib/domain/models/study_models.dart`,
`lib/domain/services/study_srs_engine.dart`,
`lib/domain/services/study_card_bulk_import.dart`, the Study slice of
`lib/app/providers.dart`, and `DriftStudyRepository` in
`lib/data/repositories/drift_repositories.dart`.

19 issues. Severity is by blast radius: **Critical** = silent data loss or an
unusable screen, **High** = wrong persisted state or a crash on a reachable
path, **Medium** = a stuck or incorrect UI state a user can hit, **Low** =
cosmetic or narrow.

---

## Critical

### [Critical] Catching a closing deck blanks the Study page permanently
- **Location:** `lib/features/study/study_page.dart:86-96` (`_closeDeck`), triggered from `:51-84` (`_openDeck`)
- **Issue:** `_closeDeck` hangs its teardown off `_zoom.reverse().whenComplete(...)`. `TickerFuture`'s *primary* future completes when the ticker stops **for any reason, including cancellation** — `TickerFuture._cancel` calls `_primaryCompleter.complete()` and only errors the `orCancel` secondary. `AnimationController.forward()` and any write to `.value` both call `stop(canceled: true)` first. So both of `_openDeck`'s documented interrupt paths — `_zoom.forward()` on line 57 (re-tap the closing deck) and `_zoom.value = 0` on line 61 (tap a *different* deck mid-close) — cancel the reverse and schedule the completion callback as a microtask. That microtask runs *after* `_openDeck` has set `_openDeckId`, and nulls it back out.

  Result: the Workbench unmounts while `_zoom` is still driving forward to 1. The Hub is then rendered at `Opacity(1 - t)` with `IgnorePointer(ignoring: locked)`, where `locked` is true for `AnimationStatus.forward` (`:171-176`) — so the Hub fades to fully transparent *and* stops accepting pointers, and nothing replaces it because `_openDeckId == null` skips the Workbench branch at `:190`. The page is blank and dead apart from the FAB until the user navigates away and back. This is exactly the "Animation Clipping" edge case STUDY.md calls out.
- **Fix:** Gate the teardown on the close still being the operation in flight. A generation counter is the smallest change:

  ```dart
  int _closeGeneration = 0;

  void _closeDeck() {
    final generation = ++_closeGeneration;
    _zoom.reverse().whenComplete(() {
      // A cancelled reverse completes this future too, so re-check that the
      // close is still the operation in flight before tearing the deck down.
      if (!mounted || generation != _closeGeneration) return;
      if (_zoom.status != AnimationStatus.dismissed) return;
      setState(() {
        _openDeckId = null;
        _openDeckName = null;
      });
      ref.read(studyActiveDeckIdProvider.notifier).state = null;
    });
  }
  ```

  and bump `_closeGeneration` in `_openDeck` before `_zoom.forward()` on both interrupt branches.

### [Critical] The Hub's due count is served from a `keepAlive` provider six writers never invalidate — grading a stale card resurrects it
- **Location:** `lib/app/providers.dart:997-1000` (`studyAllCardsProvider`), read at `lib/features/study/study_page.dart:496-506`; missing invalidations at `lib/features/study/study_actions.dart:447-450` and `:518-521`, `lib/features/study/study_deck_workbench_page.dart:341-342`, `lib/features/study/study_import_text_modal.dart:114-116`, `lib/features/study/study_move_modal.dart:57-58`, `lib/features/study/study_debug_generator.dart:230-234`
- **Issue:** `studyAllCardsProvider` calls `ref.keepAlive()`, so it never recomputes unless something explicitly invalidates it. Exactly two paths do (`invalidateStudyCardsIn`, and the card editor). Every other writer invalidates `studyCardsProvider` / `studyDeckStatsProvider` / `studyStatsProvider` and forgets the flattened list.

  The count is the visible symptom: after deleting a deck of 30 due cards the Hub still reads "Study 30 due" for the rest of the session — while the `studyStatsProvider` numbers on the very next line are correct, because *that* one was invalidated. Two numbers, two sources, disagreeing on screen.

  The damage is what happens next. Pressing the button pushes `StudySessionPage(cardIds: dueIds)`, and `_syncQueue` (`study_session_page.dart:76-94`) filters that same stale list, so the queue is populated with cards that are tombstoned on disk. Grading one calls `gradeStudyCard(current, ...)`, whose `copyWith` carries `deletedAt: deletedAt ?? this.deletedAt` — and `this.deletedAt` is `null`, because the snapshot predates the delete. `upsertCard` then writes `deletedAt: Value(null)` through `insertOnConflictUpdate`, **overwriting the tombstone**. The card comes back to life orphaned inside a deleted deck, is pushed to Firestore, and a `StudyReviewLog` row is written for it.

  The mirror image is just as wrong in the other direction: cards created by the import modal and the debug generator never enter the Hub's list at all, so "Study N due" under-reports them indefinitely.
- **Fix:** Every Study writer already has a correct helper — use it. Replace the ad-hoc invalidation blocks with `invalidateStudyCardsIn(container)` / `_invalidateStudyCards(ref)` (`study_actions.dart:402-412`), which covers `studyCardsProvider`, `studyAllCardsProvider`, `studyDeckStatsProvider` and `studyStatsProvider` together. Apply at all six sites above.

  Belt-and-braces for the resurrection itself — have `_grade` re-read the card before writing, and drop it from the queue if it is gone:

  ```dart
  final current = queue.first;
  final live = await repo.getCard(current.id);
  if (live == null || live.deletedAt != null) {
    if (!mounted) return;
    setState(() {
      _queue = [...queue]..removeAt(0);
      _grading = false;
      _clearHistory();
    });
    return;
  }
  final graded = gradeStudyCard(live, grade);
  ```

---

## High

### [High] Study soft-deletes do not bump `version`, so a delete loses to any concurrent edit
- **Location:** `lib/data/repositories/drift_repositories.dart:3325-3332` (`softDeleteFolder`), `:3425-3432` (`softDeleteDeck`), `:3495-3502` (`softDeleteCard`)
- **Issue:** All three write `deletedAt` and `updatedAt` as raw column updates and leave `version` untouched. Conflict resolution is version-first (`remoteVersionWins`, `firestore_document_mapper.dart:93-101`): `updatedAt` is only consulted when the versions are *equal*.

  Failure: device A soft-deletes card C, which is at version 5 — the tombstone goes out still at version 5. Device B edited C an hour earlier, pushing version 6. On the next pull, version 6 beats version 5 outright and `mergeDeletedAtFromRemote` adopts the remote payload's absent tombstone. **The delete is silently discarded on every device and the card comes back.**

  This is not a novel judgement call — the codebase states the rule three times, and Study is the only place that breaks it. `softDeleteProblem` (`:536-547`): *"A tombstone that leaves `version` alone is the one revision on this table that has to win on `updatedAt` alone."* `softDeleteReferencesForOwner` (`:2330-2332`): *"Version-bumped, not just stamped: the tombstone has to beat the live row it replaces."* And `restoreVersionFrom` (`lib/core/soft_delete/restore_contract.dart:41-43`) computes its floor on the premise that *"every soft delete in the app bumps the row by one"* — now false for Study. (The undo path happens to survive: with the tombstone left at V, `restoreVersionFrom` returns V+1, which still outranks it. The delete-versus-edit race is where the data goes.)
- **Fix:** Read-bump-upsert, matching every sibling repository:

  ```dart
  @override
  Future<void> softDeleteCard(String id) async {
    final card = await getCard(id);
    if (card == null || card.deletedAt != null) return;
    // copyWith bumps version and stamps updatedAt; upsertCard records the
    // local save.
    await upsertCard(card.copyWith(deletedAt: utcNow()));
  }
  ```

  Same shape for `softDeleteDeck` / `softDeleteFolder` against `getDeck` / `getFolder`.

### [High] Study moves do not bump `version`, so a move loses to any concurrent edit and is invisible to a running session
- **Location:** `lib/data/repositories/drift_repositories.dart:3354-3367` (`moveFolder`), `:3435-3445` (`moveDeck`), `:3505-3515` (`moveCards`)
- **Issue:** Same root cause, different symptom. All three write `parentFolderId` / `deckId` plus `updatedAt` and leave `version` alone. The callers (`moveStudyFolder` at `study_actions.dart:125-128`, `moveStudyDeck` at `:147-151`, `_StudyMoveModalState._selectDeck` at `study_move_modal.dart:49-56`) then re-read the row and push it — at the unchanged version. Any device holding the same version with a later local revision wins the comparison, and the move is reverted everywhere.

  There is a second, purely local consequence: `refreshFromLive` (`lib/core/utils/live_snapshot.dart:25`) only adopts a live copy when `fresh.version > entry.version`. A card moved out of a deck while a Study or Cram session is running over it keeps its pre-move `deckId` in the session's held copy for the life of the session, so `_invalidateFor(card)` (`study_session_page.dart:125-130`) invalidates the *old* deck's providers and the destination deck's stats go stale.
- **Fix:** Route the moves through the model the same way:

  ```dart
  @override
  Future<void> moveCards(List<String> cardIds, String targetDeckId) async {
    for (final id in cardIds) {
      final card = await getCard(id);
      if (card == null) continue;
      // copyWith bumps version and stamps updatedAt.
      await upsertCard(card.copyWith(deckId: targetDeckId));
    }
  }
  ```

  `moveDeck` / `moveFolder` likewise, keeping `moveFolder`'s existing `wouldCreateCycle` guard ahead of the write.

### [High] The card editor writes a stale SRS snapshot over the live row
- **Location:** `lib/features/study/study_card_editor_modal.dart:113-141` (`_save`)
- **Issue:** `_save` reconstructs the card wholesale from `widget.existing` — the snapshot captured when the sheet opened — for `version`, `interval`, `ease`, `dueAt`, `reviewCount` and `createdAt`. The editor is a long-lived modal: a sync pull landing a grade from another device can revise the row while it is open. Saving a one-character typo fix then:

  1. rolls `interval` / `ease` / `dueAt` / `reviewCount` back to whatever they were when the sheet opened, discarding the remote grade locally; and
  2. writes `version: existing.version + 1`, which may be **equal to or lower than** the version already on disk. Combined with version-first resolution, the outcome of the next pull becomes a coin flip between the two revisions rather than a defined last-write-wins.

  The write is unconditional — `upsertCard` applies no version guard, which `restore_contract.dart:34-35` already notes as something callers must compensate for.
- **Fix:** Re-read at save time and merge only the fields this sheet owns. The SRS columns are not the editor's to write at all.

  ```dart
  Future<void> _save() async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      final repo = ref.read(studyRepositoryProvider);
      final now = utcNow();
      final current = widget.existing == null ? null : await repo.getCard(_cardId);
      final card = current == null
          ? StudyCard(
              id: _cardId,
              createdAt: now,
              updatedAt: now,
              deckId: widget.deckId,
              frontText: _front.text.trim(),
              backText: _back.text.trim(),
              dueAt: now,
            )
          // copyWith bumps version off the row as it stands now, and leaves
          // interval/ease/dueAt/reviewCount alone.
          : current.copyWith(
              frontText: _front.text.trim(),
              backText: _back.text.trim(),
            );
      await repo.upsertCard(card);
      _saved = true;
      ref.read(remoteSyncServiceProvider).pushStudyCard(card);
      invalidateStudyCardsIn(ProviderScope.containerOf(context, listen: false));
      if (mounted) Navigator.of(context).pop();
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }
  ```

  (This also fixes the stuck-`_saving` and orphaned-media issues below.)

### [High] Holding an arrow key auto-decides the entire cram deck
- **Location:** `lib/features/study/study_cram_page.dart:145-208` (`_handleArrowKey` / `_decide`)
- **Issue:** `_handleArrowKey` accepts `KeyRepeatEvent` (line 153) and calls `_decide` directly. `_decide` is guarded only by `_exiting`, which clears 220 ms later inside the `Future.delayed` callback (line 203). Unlike the review session — where `_grade` is gated behind `widget.showingBack`, which a grade immediately resets to false — cram has no such gate, because a decision needs no flip.

  So holding <kbd>→</kbd> passes one card every 220 ms until the deck is exhausted, unseen. The bucket history fills with a step per card and the user arrives at "All cards mastered" having reviewed nothing. Auto-repeat also outruns the exit animation, so the cards in between are never rendered.

  Same shape, lower impact, in `StudyKeyboardShortcuts` (`lib/features/study/study_keyboard_shortcuts.dart:87-92`): Space on `KeyRepeatEvent` re-enters `_flip()` every repeat tick and thrashes `_queuedFlip`.
- **Fix:** A deliberate decision is a key *press*. Take `KeyRepeatEvent` out of both handlers:

  ```dart
  // study_cram_page.dart:153 — a held arrow key is one decision, not a stream
  // of them; the exit animation is not a rate limiter.
  if (event is! KeyDownEvent) return false;
  ```

  Same at `study_keyboard_shortcuts.dart:87` — neither grading nor flipping is a repeatable action.

### [High] `_grade` calls `setState` across two awaits with no `mounted` check
- **Location:** `lib/features/study/study_session_page.dart:222-263`
- **Issue:** `_grade` awaits `repo.upsertCard(graded)` and then `repo.logReview(log)`, and calls `setState` at line 242 and `_flipController.showFront()` at line 260 with no `if (!mounted) return;` in between. Closing the session during those writes — the X button at `:353-356`, or Escape — throws `setState() called after dispose()`.

  Every sibling on this State already guards: `_resetAndAdvance` (`:159`), `_deleteAndAdvance` (`:191`), `_requeueRestoredCard` (`:210`), `_replay` (`:304`). `_grade` is the one that was missed, and it is the most frequently exercised path on the page.
- **Fix:**

  ```dart
  await repo.logReview(log);
  remoteSync.pushStudyReviewLog(log);
  if (!mounted) return;

  setState(() { ... });
  ```

  The card and the log are already durably written at that point, so bailing loses nothing.

---

## Medium

### [Medium] Bulk delete has no confirmation, no undo, and leaves the Hub's counters stale
- **Location:** `lib/features/study/study_deck_workbench_page.dart:332-345` (`_StudySelectionBar._delete`)
- **Issue:** Every other card-deletion path in the feature goes through `deleteStudyCard` (confirm dialog) or `softDeleteWithUndo` (8-second undo toast). The multi-select Delete button does neither: one tap on a 40-card selection tombstones all 40 with no prompt and no way back short of the 30-day trash.

  It is also the only deletion path that discards the media detach stamps `detachStudyCardMedia` returns, so those cards' images could not be restored even if the rows were recovered by hand — and it skips `studyAllCardsProvider` and `studyStatsProvider`, feeding the stale-count defect above.
- **Fix:** Reuse the machinery that already exists rather than a second implementation. `softDeleteStudyCard` returns exactly the `StudyCardDeletion` a restore needs:

  ```dart
  Future<void> _delete(BuildContext context, WidgetRef ref) async {
    final container = ProviderScope.containerOf(context, listen: false);
    final overlay = Overlay.of(context, rootOverlay: true);
    final ids = selected.toList();
    final confirmed = await showConfirmDialog(
      context,
      title: 'Delete ${ids.length} card${ids.length == 1 ? '' : 's'}?',
      message: 'They will be moved to trash.',
    );
    if (!confirmed) return;

    late final List<StudyCardDeletion> deletions;
    await softDeleteWithUndo(
      overlay: overlay,
      message: 'Deleted ${ids.length} card${ids.length == 1 ? '' : 's'}',
      delete: () async {
        final repo = container.read(studyRepositoryProvider);
        deletions = [
          for (final id in ids)
            if (await repo.getCard(id) case final card?)
              await softDeleteStudyCard(container, card),
        ];
      },
      restore: () async {
        for (final deletion in deletions) {
          await restoreStudyCard(container, deletion);
        }
      },
    );
    ref.read(studySelectedCardIdsProvider.notifier).state = {};
    ref.read(studyMultiSelectEnabledProvider.notifier).state = false;
  }
  ```

### [Medium] Five busy flags are never reset on failure, permanently disabling their buttons
- **Location:** `lib/features/study/study_card_editor_modal.dart:113-141` (`_saving`), `lib/features/study/study_import_text_modal.dart:90-122` (`_importing`), `lib/features/study/study_move_modal.dart:42-62` (`_moving`), `lib/features/study/study_move_destination_modal.dart:56-61` (`_moving`), `lib/features/study/study_deck_workbench_page.dart:308-330` (`_duplicate`)
- **Issue:** All follow the same shape: `setState(() => _busy = true)`, then a sequence of un-guarded `await`s against the repository, the media service and the sync layer, with the flag cleared only on the success path. A disk error, a media-service throw, or the `StateError` `moveFolder` raises on a cycle leaves the flag stuck.

  The consequences differ by sheet. In the editor and the import sheet the primary button is disabled forever and the only exit is the close button, which discards the user's typing. In `_StudyMoveDestinationModalState._moveHere` the modal never pops (line 307 is only reached after `onSelect` returns normally), leaving a dead sheet with no indication anything failed. In every case the exception escapes into the zone with nothing shown.
- **Fix:** Wrap each body in `try` / `finally`, clear the flag there, and surface the failure rather than swallowing it:

  ```dart
  setState(() => _importing = true);
  try {
    // ...writes...
    if (!mounted) return;
    Navigator.of(context).pop(outcome);
  } catch (error, stackTrace) {
    FlutterError.reportError(FlutterErrorDetails(
      exception: error, stack: stackTrace, library: 'study import'));
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Could not import.')));
    }
  } finally {
    if (mounted) setState(() => _importing = false);
  }
  ```

### [Medium] A failed save orphans the new card's images permanently
- **Location:** `lib/features/study/study_card_editor_modal.dart:131` (`_saved = true`), against `:89-106` (`dispose`)
- **Issue:** `dispose` cleans up the dangling media references of a *new* card that was never saved, guarded on `!_saved`. But `_save` sets `_saved = true` on line 131, **before** `await repo.upsertCard(card)` on line 132. If that write throws, the card row never exists, yet `_saved` is now true, so the cleanup is skipped on the way out.

  The references then point at a document id that has no row — precisely the state the `dispose` comment identifies as unrecoverable: *"a live reference keeps its asset off the retention clock forever."* The blob is never purged, and nothing in the app can reach it to delete it.
- **Fix:** Move the flag after the write it is asserting:

  ```dart
  await repo.upsertCard(card);
  // Only true once the row the references hang off actually exists.
  _saved = true;
  ref.read(remoteSyncServiceProvider).pushStudyCard(card);
  ```

### [Medium] `deleteStudyCard` reports success when the delete threw
- **Location:** `lib/features/study/study_actions.dart:365-396`
- **Issue:** The doc comment promises *"whether the card was actually deleted, so a session that was showing it knows whether to move on."* But `softDeleteWithUndo` (`lib/core/soft_delete/soft_delete_toast.dart:127-157`) catches a throwing `delete`, reports it, shows a "Could not delete" toast, and returns normally. `deleteStudyCard` then unconditionally `return true` on line 395.

  Both sessions act on that boolean. `_deleteAndAdvance` (`study_session_page.dart:181-198`) drops the card from the queue and clears the undo history; `_deleteCurrent` (`study_cram_page.dart:279-299`) removes it from `_cardsById` and all three buckets. So a failed delete makes the card vanish from the session anyway while it is still live on disk — and in cram it is gone for the rest of the run, because `_syncCards` only ever refreshes the held map *from itself* and can never re-admit a card it has lost.

  A related fragility on the same path: `late final StudyCardDeletion deletion` (line 383) is never assigned when `delete` throws. That is only safe because `softDeleteWithUndo` shows no toast in that case — an undocumented invariant this call site depends on.
- **Fix:** Have `softDeleteWithUndo` report whether the delete landed, and propagate it:

  ```dart
  // soft_delete_toast.dart
  Future<bool> softDeleteWithUndo({...}) async {
    try {
      await delete();
    } catch (error, stackTrace) {
      // ...existing toast + reportError...
      return false;
    }
    showSoftDeleteUndoToast(...);
    return true;
  }

  // study_actions.dart — return it instead of a bare `true`.
  return softDeleteWithUndo(
    overlay: overlay,
    message: deletedMessage(card.frontText, fallback: 'card'),
    delete: () async => deletion = await softDeleteStudyCard(container, card),
    restore: () async { ... },
  );
  ```

### [Medium] The deck's Study button opens a session that is already over
- **Location:** `lib/features/study/study_deck_workbench_page.dart:119-133`, against `lib/features/study/study_session_page.dart:76-94`
- **Issue:** The button is enabled on `cards.isEmpty ? null : ...` — any card at all — and hands the session the whole roster. The session then builds its queue from `widget.cardIds.contains(c.id) && !c.dueAt.isAfter(now)`. On a deck where everything is scheduled into the future that queue is empty, so the route pushes and renders `_SessionComplete` ("Session complete") on its first frame. The user taps Study on a deck of 40 cards and is told they have finished.

  Confirmed intent: the queue should stay due-only; the button is what is wrong. The header two lines up (`:110-115`) already knows the right number — it renders "40 cards · 0 due".
- **Fix:** Gate and label the button on the due count already in scope, matching the Hub's own button (`study_page.dart:510-528`), which already disables and relabels itself at zero:

  ```dart
  final due = dueAsync.valueOrNull?.due ?? 0;
  // ...
  GlassButton(
    onPressed: due == 0
        ? null
        : () => Navigator.of(context).push(MaterialPageRoute(
            builder: (_) => StudySessionPage(
              cardIds: {for (final c in cards) c.id},
            ),
          )),
    icon: const Icon(PhosphorIconsRegular.playCircle),
    label: due == 0 ? 'Nothing due' : 'Study $due due',
  ),
  ```

### [Medium] Duplicating a card discards its SRS state
- **Location:** `lib/data/repositories/drift_repositories.dart:3517-3544` (`duplicateCards`)
- **Issue:** The copy is built with `StudyCardsTableCompanion.insert`, which supplies only `id`, `deckId`, `frontText`, `backText`, `dueAt: now`, `createdAt`, `updatedAt`. `interval`, `ease` and `reviewCount` fall back to the column defaults, so a card with a 90-day interval and 14 reviews duplicates into a brand-new, immediately-due card.

  Confirmed as unintended. It is also inconsistent with `reverseStudyCard` (`study_actions.dart:198-219`), which explicitly preserves SRS state on the grounds that *"the card is still the same memory item to the scheduler."*

  Two smaller defects sit in the same method: it does not filter `deletedAt`, so a tombstoned id in the selection is duplicated back into a live card; and the copies are inserted at `version` 0 with no `_syncActivity` record per row.
- **Fix:** Carry the schedule across, and skip tombstones:

  ```dart
  for (final id in cardIds) {
    final row = await (_db.select(_db.studyCardsTable)
          ..where((t) => t.id.equals(id)))
        .getSingleOrNull();
    if (row == null || row.deletedAt != null) continue;
    final copyId = newId();
    await _db.into(_db.studyCardsTable).insert(
      StudyCardsTableCompanion.insert(
        id: copyId,
        deckId: row.deckId,
        frontText: row.frontText,
        backText: row.backText,
        // The copy is the same memory item to the scheduler — see
        // reverseStudyCard.
        interval: Value(row.interval),
        ease: Value(row.ease),
        reviewCount: Value(row.reviewCount),
        dueAt: row.dueAt,
        createdAt: now,
        updatedAt: now,
      ),
    );
    copies[id] = copyId;
  }
  ```

### [Medium] Cram's card menu permanently wipes SRS state, which cram is forbidden to touch
- **Location:** `lib/features/study/study_cram_page.dart:271-277` (`_resetAndAdvance`), wired at `:527-534`; the write is `lib/features/study/study_actions.dart:223-231` (`resetStudyCardProgress`)
- **Issue:** STUDY.md's Cramming Mode section is unconditional: *"Because these are temporary buckets, it must NOT update the SRS metadata and it should run entirely in-memory."* The page's own class doc repeats it (`:27-30`), and `StudyReviewLog`'s doc repeats it again (`study_models.dart:233-236`). But `_cramCard` hands `studyCardMenuItems` an `onResetProgress` callback, so every card in a cram run offers "Reset progress" — and that item calls `resetStudyCardProgress`, which writes `interval: 0`, `ease: 2.5`, `dueAt: now`, `reviewCount: 0` straight to disk via `upsertCard` and pushes it to Firestore.

  Three things make this worse than a plain spec deviation:

  - **It is invisible.** `_resetAndAdvance` follows the write with `_decide(false)`, so the card slides out and drops to the back of bucket 0 — pixel-identical to a normal fail. Nothing on screen indicates that a card's entire review history was just destroyed, because cram's buckets do not render SRS state at all.
  - **It is unconfirmed and un-undoable.** Deleting a card from the same menu gets a confirm dialog *and* an 8-second undo toast (`study_actions.dart:376-394`). Resetting gets neither, and there is no snapshot anywhere to restore from — unlike the review session, which at least keeps `_GradeStep.before` for its own undo stack.
  - **It syncs.** `resetStudyCardSrs` goes through `copyWith`, which bumps `version`, so the wipe wins the version comparison and propagates to every device.

  The item is legitimate in the Study session (`study_session_page.dart:390`) and on the Workbench tile (`study_deck_workbench_page.dart:258-259`), where the surface is *about* the card's schedule. Cram is the one surface that is contractually not.
- **Fix:** Do not offer the item where the mode forbids the action. Make the callback optional and drop the entry when it is absent, rather than leaving a live path into a write cram is not allowed to make:

  ```dart
  // study_actions.dart
  List<ContextMenuItem> studyCardMenuItems({
    required StudyCard card,
    required VoidCallback onEdit,
    required VoidCallback onReverse,
    // Null in cram: STUDY.md is explicit that cram must not touch persisted
    // SRS metadata, so the item is not offered there at all.
    VoidCallback? onResetProgress,
    required VoidCallback onDelete,
  }) {
    return [
      ContextMenuItem(label: 'Edit…', icon: PhosphorIconsRegular.pencilSimple, onTap: onEdit),
      ContextMenuItem(label: 'Reverse', icon: PhosphorIconsRegular.swap, onTap: onReverse),
      if (onResetProgress != null)
        ContextMenuItem(
          label: 'Reset progress',
          icon: PhosphorIconsRegular.arrowCounterClockwise,
          // Nothing to forget on a card that has never been reviewed.
          enabled: !card.isNew,
          onTap: card.isNew ? null : onResetProgress,
        ),
      ContextMenuItem(
        label: 'Delete',
        icon: PhosphorIconsRegular.trash,
        isDestructive: true,
        onTap: onDelete,
      ),
    ];
  }
  ```

  Then in `study_cram_page.dart:527-534`, drop `onResetProgress:` from the call and delete `_resetAndAdvance` (`:268-277`) — it becomes unreachable. The doc comment at `study_actions.dart:158-163` needs its last clause updated too: Reset progress is no longer a per-surface variation, it is a per-surface *omission*.

  If the item is wanted in cram after all, then STUDY.md's in-memory rule is what needs amending — but as the two stand today the code contradicts the spec, and this is the only place in the feature that does.

### [Medium] Deleting a deck of image cards re-queries every image in the library, once per card
- **Location:** `lib/app/providers.dart:1016-1050` (`studyCardImagesProvider`), driven from `lib/features/study/study_actions.dart:257-271` (`detachStudyCardMediaIn`)
- **Issue:** `studyCardImagesProvider` `ref.watch`es `mediaServiceProvider`, which is a `ChangeNotifierProvider` — so every `notifyListeners()` from the media service invalidates it and re-runs the whole body. That body is not the single query its doc claims: after one `listReferences()` it calls `service.assetsFor(...)` twice per card, and `assetsFor` (`lib/core/media/media_service.dart:228-235`) issues one sequential `getAsset` round-trip **per reference**. Cost is O(total images in the app), serially, per recompute.

  `detachStudyCardMediaIn` loops card-by-card, and each `removeReferencesForOwner` ends in `notifyListeners()`. Deleting a deck of 100 illustrated cards therefore triggers ~100 full recomputes of the library-wide image map, each one O(all images) — while four Study surfaces (`workbench:72`, `session:325`, `cram:495`, `editor:189`) watch it and rebuild.
- **Fix:** Two independent changes, either of which helps and both of which are worth making:

  1. Batch the detach so the notification fires once. Add a bulk entry point to `MediaService` that soft-deletes references for many owners and calls `notifyListeners()` after the loop, and have `detachStudyCardMediaIn` call it instead of iterating `removeReferencesForOwner`.
  2. Replace the per-reference `getAsset` loop with one batched lookup — collect the `mediaId` set for the whole map, issue a single `WHERE id IN (...)` read, then index it locally.

---

## Low

### [Low] A cram decision is applied to whichever card is current 220 ms later
- **Location:** `lib/features/study/study_cram_page.dart:166-208`
- **Issue:** `_decide` starts the exit animation, then defers the bucket move into `Future.delayed(_exitDuration, ...)`. `_applyDecision` re-reads `_current` *inside* that callback rather than capturing the card the user actually acted on. If the buckets change during those 220 ms — a sync pull dropping the card via `_syncCards` (`:113-133`), or `_returnRestoredCard` inserting at the head of bucket 0 (`:310-324`) — the decision lands on a different card, which is promoted or demoted without ever having been shown.
- **Fix:** Capture the id at decision time and pass it through:

  ```dart
  void _decide(bool passed, {double velocity = 0}) {
    final card = _current;
    if (card == null || _exiting) return;
    final decidedId = card.id;
    // ...animation...
    Future.delayed(_exitDuration, () {
      if (!mounted) return;
      // The card may have gone while it was flying out; the decision belongs
      // to the card the user swiped, not to whatever is at the head now.
      if (!_cardsById!.containsKey(decidedId)) {
        setState(() => _exiting = false);
        return;
      }
      // ...snapshot, then _applyDecision(decidedId, passed)...
    });
  }
  ```

  and change `_applyDecision` to take the id rather than reading `_current`.

### [Low] Undoing a grade leaves its review-log row, so "reviewed today" over-counts
- **Location:** `lib/features/study/study_session_page.dart:268-315` (`_replay`), rows written at `:233-240`
- **Issue:** `_grade` appends a `StudyReviewLog`; `_undo` restores the card's SRS fields but leaves the log row, because the log is append-only with no delete path through sync. A grade given, taken back, and then abandoned by leaving the session is counted forever in `countCardsReviewedToday` / `countCardsReviewedTotal` (`drift_repositories.dart:3562-3575`) with no schedule change to match it.

  Documented as a known trade-off at `:270-274`, so listed for completeness rather than as an oversight — but it is a real divergence between the Hub's headline number and what the schedule says happened.
- **Fix:** If the count is meant to be exact, the log needs a tombstone path like every other synced collection: give `StudyReviewLog` `version` / `deletedAt`, soft-delete the row in `_undo`, and re-insert (rather than write a second row) in `_redo`. If the current behaviour is preferred, no code change — but the Hub's "reviewed today" is then an activity count, not a schedule count.

### [Low] Undo briefly redisplays the grade it just took back
- **Location:** `lib/features/study/study_session_page.dart:306-314`
- **Issue:** `_replay` sets `_queue = step.queueBefore` (cards at their pre-grade version) and only *then* calls `_invalidateFor(restored)`. Riverpod serves the previous value while the refetch is in flight, so the next build runs `_syncQueue` against a card list that still holds the graded copy. `refreshFromLive` adopts it, because the graded version is strictly greater than the pre-grade snapshot's — so for one or more frames the card and `StudyGradingRow`'s interval previews show the state the user just undid, then flip back when the refetch lands.
- **Fix:** Seed the queue with the copy that was actually written rather than the stale snapshot:

  ```dart
  setState(() {
    to.add(from.removeLast());
    final base = forward ? step.queueAfter : step.queueBefore;
    // The restored copy is the newest revision there is; putting the snapshot
    // back instead lets the pre-invalidation list win the version comparison.
    _queue = [
      for (final card in base) card.id == restored.id ? restored : card,
    ];
    _showingBack = false;
    _grading = false;
  });
  ```

### [Low] Intervals just under a day render as "24h" instead of "1d"
- **Location:** `lib/domain/services/study_srs_engine.dart:138-150` (`formatStudyInterval`)
- **Issue:** The `days < 1` branch converts to minutes, and when that exceeds 60 falls through to `hours = (days * 24).round()`. For `days` in `[0.979, 1)` — reachable from a learning card graded Hard, e.g. `0.82 * 1.2 = 0.984` — the rounding yields 24 and the preview above the Hard button reads "24h". The next branch would have printed "1d".
- **Fix:** Clamp the hour bucket below the day boundary:

  ```dart
  final hours = (days * 24).round();
  if (hours >= 24) return '1d';
  return '${hours}h';
  ```

### [Low] `studyStatsProvider.pendingToday` is computed on every refresh and never rendered
- **Location:** `lib/app/providers.dart:1052-1066`, consumer at `lib/features/study/study_page.dart:489-551`
- **Issue:** `studyStatsProvider` runs `repo.countDueCards()` — a full scan of `study_cards` — on every invalidation, and `_StudyStatsHeader` never reads `stats.pendingToday`. The due number it actually shows is derived independently from `studyAllCardsProvider` at `:501-505`. Two sources for one number, one of them queried and thrown away; that divergence is what makes the Critical stale-count defect visible as two contradictory figures on the same screen.

  STUDY.md asks for "Cards pending review today" as one of the three global statistics, so the intent is that this value be the displayed one.
- **Fix:** Pick one source. The repository count is the accurate one and is already being paid for, so have the button read it:

  ```dart
  final due = stats?.pendingToday ?? 0;
  ```

  keeping `studyAllCardsProvider` for building the session's id set only. With the Critical fix applied the two agree, but collapsing them removes the class of bug entirely.

### [Low] A cram session over an emptied deck reports "All cards mastered"
- **Location:** `lib/features/study/study_cram_page.dart:142-143` (`_complete`)
- **Issue:** `_complete` is `_bucket0.isEmpty && _bucket1.isEmpty && _cardsById != null`. A deck whose cards are all deleted while cram is open — via the card menu, or a sync pull — satisfies it immediately and renders the congratulatory completion screen. The Workbench's `cards.isEmpty` guard on the Cram button covers the entry case but not the mid-session one.
- **Fix:** Distinguish "finished" from "nothing to finish":

  ```dart
  bool get _complete =>
      _cardsById != null &&
      _cardsById!.isNotEmpty &&
      _bucket0.isEmpty &&
      _bucket1.isEmpty;
  ```

  and render an empty state ("This deck has no cards left") rather than `_CramComplete` when `_cardsById` is empty.

### [Low] Deleting the open deck leaves the Workbench mounted over a dead id
- **Location:** `lib/features/study/study_deck_workbench_page.dart:63-108`, against `lib/features/study/study_actions.dart:416-451`
- **Issue:** `deleteStudyDeck` is reachable from the Hub tile's context menu while that deck's Workbench is the visible layer — the Hub stays live and hit-testable whenever `_zoom` is neither forward nor at 1 (`study_page.dart:171-176`). Nothing closes the Workbench afterwards. `studyDeckByIdProvider` then resolves to a tombstoned row, `deckAsync.valueOrNull?.name` falls back to `widget.deckNameHint`, and the page keeps rendering a full workbench — title, stats, Add card, Import — over a deck that no longer exists. Cards added there are created against a deleted `deckId`.
- **Fix:** Have the Workbench watch for its own deck disappearing and hand control back:

  ```dart
  ref.listen(studyDeckByIdProvider(deckId), (_, next) {
    final deck = next.valueOrNull;
    if (next.hasValue && (deck == null || deck.deletedAt != null)) {
      widget.onBack();
    }
  });
  ```

  Alternatively, have `deleteStudyDeck` clear `studyActiveDeckIdProvider` when the deleted id matches the open deck.

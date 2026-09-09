import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/soft_delete/soft_delete_toast.dart';
import 'package:voyager/core/sync/firestore_collections.dart';
import 'package:voyager/core/utils/ids.dart';
import 'package:voyager/core/widgets/confirm_dialog.dart';
import 'package:voyager/core/widgets/context_menu.dart';
import 'package:voyager/core/widgets/palette_color_picker.dart';
import 'package:voyager/domain/models/media_models.dart';
import 'package:voyager/domain/models/study_models.dart';
import 'package:voyager/domain/repositories/repositories.dart';
import 'package:voyager/domain/services/study_srs_engine.dart';
import 'package:voyager/features/study/study_move_destination_modal.dart';
import 'package:voyager/features/study/study_name_modal.dart';

void _invalidateStudyLibrary(WidgetRef ref) {
  ref.invalidate(studyFoldersProvider);
  ref.invalidate(studyDecksProvider);
}

Future<void> renameStudyFolder(
  BuildContext context,
  WidgetRef ref,
  StudyFolder folder,
) async {
  final name = await showStudyNameModal(
    context,
    title: 'Rename folder',
    initialValue: folder.name,
    hintText: 'Folder name',
  );
  if (name == null || name == folder.name) return;
  final updated = folder.copyWith(name: name);
  await ref.read(studyRepositoryProvider).upsertFolder(updated);
  ref.read(remoteSyncServiceProvider).pushStudyFolder(updated);
  ref.invalidate(studyFolderByIdProvider(folder.id));
  _invalidateStudyLibrary(ref);
}

Future<void> renameStudyDeck(
  BuildContext context,
  WidgetRef ref,
  StudyDeck deck,
) async {
  final name = await showStudyNameModal(
    context,
    title: 'Rename deck',
    initialValue: deck.name,
    hintText: 'Deck name',
  );
  if (name == null || name == deck.name) return;
  final updated = deck.copyWith(name: name);
  await ref.read(studyRepositoryProvider).upsertDeck(updated);
  ref.read(remoteSyncServiceProvider).pushStudyDeck(updated);
  ref.invalidate(studyDeckByIdProvider(deck.id));
  _invalidateStudyLibrary(ref);
}

Future<void> changeStudyFolderColor(
  BuildContext context,
  WidgetRef ref,
  StudyFolder folder,
  List<StudyFolder> siblingFolders,
) async {
  final color = await pickPaletteColorWithRef(
    ref,
    context,
    current: folder.colorValue,
    usedColors: siblingFolders
        .where((item) => item.id != folder.id && item.colorValue != null)
        .map((item) => item.colorValue!)
        .toSet(),
  );
  if (color == null) return;
  final updated = folder.copyWith(colorValue: color);
  await ref.read(studyRepositoryProvider).upsertFolder(updated);
  ref.read(remoteSyncServiceProvider).pushStudyFolder(updated);
  ref.invalidate(studyFolderByIdProvider(folder.id));
  _invalidateStudyLibrary(ref);
}

Future<void> changeStudyDeckColor(
  BuildContext context,
  WidgetRef ref,
  StudyDeck deck,
  List<StudyDeck> siblingDecks,
) async {
  final color = await pickPaletteColorWithRef(
    ref,
    context,
    current: deck.colorValue,
    usedColors: siblingDecks
        .where((item) => item.id != deck.id && item.colorValue != null)
        .map((item) => item.colorValue!)
        .toSet(),
  );
  if (color == null) return;
  final updated = deck.copyWith(colorValue: color);
  await ref.read(studyRepositoryProvider).upsertDeck(updated);
  ref.read(remoteSyncServiceProvider).pushStudyDeck(updated);
  ref.invalidate(studyDeckByIdProvider(deck.id));
  _invalidateStudyLibrary(ref);
}

Future<void> moveStudyFolder(
  BuildContext context,
  WidgetRef ref,
  StudyFolder folder,
) async {
  final repo = ref.read(studyRepositoryProvider);
  final descendants = await _collectFolderContents(repo, folder.id);
  final excludeIds = {folder.id, ...descendants.folders.map((f) => f.id)};

  return showStudyMoveDestinationModal(
    context,
    ref,
    title: 'Move "${folder.name}"',
    excludeFolderIds: excludeIds,
    onSelect: (destinationFolderId) async {
      if (await repo.wouldCreateCycle(folder.id, destinationFolderId)) {
        return;
      }
      await repo.moveFolder(folder.id, destinationFolderId);
      final moved = await repo.getFolder(folder.id);
      if (moved != null) {
        ref.read(remoteSyncServiceProvider).pushStudyFolder(moved);
      }
      ref.invalidate(studyFolderByIdProvider(folder.id));
      _invalidateStudyLibrary(ref);
    },
  );
}

Future<void> moveStudyDeck(
  BuildContext context,
  WidgetRef ref,
  StudyDeck deck,
) {
  return showStudyMoveDestinationModal(
    context,
    ref,
    title: 'Move "${deck.name}"',
    onSelect: (destinationFolderId) async {
      final repo = ref.read(studyRepositoryProvider);
      await repo.moveDeck(deck.id, destinationFolderId);
      final moved = await repo.getDeck(deck.id);
      if (moved != null) {
        ref.read(remoteSyncServiceProvider).pushStudyDeck(moved);
      }
      ref.invalidate(studyDeckByIdProvider(deck.id));
      _invalidateStudyLibrary(ref);
    },
  );
}

/// The right-click menu for a single card, wherever one is shown — the deck
/// grid's tile and the full-size card inside a study or cram session.
///
/// Items only; every action is the caller's, because "what happens next"
/// differs by surface: resetting from the grid leaves the tile where it is,
/// while resetting mid-session also moves the session on. Reset progress is
/// also a per-surface *omission* — see [onResetProgress].
List<ContextMenuItem> studyCardMenuItems({
  required StudyCard card,
  required VoidCallback onEdit,
  required VoidCallback onReverse,
  // Null in cram, where the item is not offered at all. STUDY.md is explicit
  // that cram "must NOT update the SRS metadata and it should run entirely
  // in-memory", and a reset is a persisted, synced, version-bumped wipe of the
  // card's whole review history — with no confirm, no undo, and no snapshot to
  // restore from. It is invisible there too: the card slides out and drops to
  // the back of bucket 0, pixel-identical to a normal fail. Legitimate on the
  // surfaces that are *about* a card's schedule; cram is the one that is not.
  VoidCallback? onResetProgress,
  required VoidCallback onDelete,
}) {
  return [
    ContextMenuItem(
      label: 'Edit…',
      icon: PhosphorIconsRegular.pencilSimple,
      onTap: onEdit,
    ),
    ContextMenuItem(
      label: 'Reverse',
      icon: PhosphorIconsRegular.swap,
      onTap: onReverse,
    ),
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

/// Swaps a card's two faces — text and images both. SRS state is deliberately
/// left alone: the card is still the same memory item to the scheduler, so its
/// interval and due date carry over to the reversed version.
Future<void> reverseStudyCard(WidgetRef ref, StudyCard card) async {
  final updated = card.copyWith(
    frontText: card.backText,
    backText: card.frontText,
  );
  await ref.read(studyRepositoryProvider).upsertCard(updated);
  ref.read(remoteSyncServiceProvider).pushStudyCard(updated);
  // A face's pictures belong to the face, not to the card: a diagram that
  // asked the question has to travel with it to the answer side.
  await ref
      .read(mediaServiceProvider)
      .swapFacets(
        collection: FirestoreCollections.studyCards,
        documentId: card.id,
        a: MediaFacet.front,
        b: MediaFacet.back,
      );
  invalidateStudyCards(ref);
}

/// Forgets how well the user knows [card] — its text is untouched. Returns
/// the reset card so a session can put the same copy back in its queue.
Future<StudyCard> resetStudyCardProgress(WidgetRef ref, StudyCard card) async {
  final reset = resetStudyCardSrs(card);
  await ref.read(studyRepositoryProvider).upsertCard(reset);
  ref.read(remoteSyncServiceProvider).pushStudyCard(reset);
  invalidateStudyCards(ref);
  ref.invalidate(studyDeckStatsProvider);
  ref.invalidate(studyStatsProvider);
  return reset;
}

/// Detaches every image on [cardIds], and reports the instant each detach
/// stamped.
///
/// Shared by all four card-deletion paths — one card, a deck's worth, a
/// folder's worth, and the workbench's multi-select — so that none of them can
/// be the one that forgets. An orphaned reference would keep its asset off the
/// retention clock forever, and the blob would never be purged.
///
/// Each card's detach calls `utcNow()` for itself and
/// [MediaService.restoreReferencesForOwner] matches that stamp exactly, so
/// there is one instant to remember per card — the card's own `deletedAt` is a
/// different `utcNow()` and would match nothing.
Future<Map<String, DateTime>> detachStudyCardMedia(
  WidgetRef ref,
  Iterable<String> cardIds,
) {
  return detachStudyCardMediaIn(
    ProviderScope.containerOf(ref.context, listen: false),
    cardIds,
  );
}

/// [detachStudyCardMedia] for a caller holding a container rather than a ref —
/// which is every delete that has to survive its own row unmounting.
Future<Map<String, DateTime>> detachStudyCardMediaIn(
  ProviderContainer container,
  Iterable<String> cardIds,
) {
  // The bulk entry point, so the media service notifies once for the whole
  // deck rather than once per card. Four Study surfaces watch
  // `studyCardImagesProvider`, whose body is O(all images in the app).
  return container
      .read(mediaServiceProvider)
      .removeReferencesForOwners(FirestoreCollections.studyCards, cardIds);
}

/// A card as it stood the instant before a delete, plus the instant its images
/// were detached at — everything [restoreStudyCard] needs.
class StudyCardDeletion {
  const StudyCardDeletion({required this.card, required this.mediaStamps});

  final StudyCard card;
  final Map<String, DateTime> mediaStamps;
}

/// Soft-deletes one card and returns what it takes to put it back.
///
/// Takes a [ProviderContainer] rather than a `WidgetRef`: the delete unmounts
/// the tile that asked for it, and the undo the toast offers is pressed
/// seconds later, by which time a `WidgetRef` would throw.
Future<StudyCardDeletion> softDeleteStudyCard(
  ProviderContainer container,
  StudyCard card,
) async {
  final repo = container.read(studyRepositoryProvider);
  // Read off disk rather than taken from `card`: the grid renders from a
  // provider that lags an in-flight save, and restoring from a stale snapshot
  // would quietly roll the last edit back with the undo.
  final snapshot = await repo.getCard(card.id) ?? card;
  await repo.softDeleteCard(card.id);
  final tombstone = await repo.getCard(card.id);
  if (tombstone != null) {
    container.read(remoteSyncServiceProvider).pushStudyCard(tombstone);
  }
  final mediaStamps = await detachStudyCardMediaIn(container, [card.id]);
  invalidateStudyCardsIn(container);
  return StudyCardDeletion(card: snapshot, mediaStamps: mediaStamps);
}

/// Undoes [softDeleteStudyCard].
///
/// The card is rebuilt field by field rather than `copyWith`'d, because
/// `copyWith` reads `deletedAt ?? this.deletedAt` and so cannot clear a
/// tombstone.
Future<void> restoreStudyCard(
  ProviderContainer container,
  StudyCardDeletion deletion,
) async {
  final card = deletion.card;
  final repository = container.read(studyRepositoryProvider);
  // The version is resolved against disk rather than against the snapshot —
  // see [restoreVersionFrom].
  final current = await repository.getCard(card.id);
  abortIfAlreadyRestored(found: current != null, deletedAt: current?.deletedAt);
  final restored = StudyCard(
    id: card.id,
    createdAt: card.createdAt,
    updatedAt: utcNow(),
    version: restoreVersionFrom(
      preDeleteVersion: card.version,
      currentVersion: current?.version,
    ),
    deckId: card.deckId,
    frontText: card.frontText,
    backText: card.backText,
    interval: card.interval,
    ease: card.ease,
    dueAt: card.dueAt,
    reviewCount: card.reviewCount,
  );
  await repository.upsertCard(restored);
  container.read(remoteSyncServiceProvider).pushStudyCard(restored);

  // The invalidation runs however the media work ended: an I/O failure
  // re-attaching the images is not the card failing to come back, and without
  // the `finally` the card sat on disk with nothing asking for it again.
  try {
    final media = container.read(mediaServiceProvider);
    for (final entry in deletion.mediaStamps.entries) {
      await media.restoreReferencesForOwner(
        FirestoreCollections.studyCards,
        entry.key,
        entry.value,
      );
    }
  } finally {
    invalidateStudyCardsIn(container);
  }
}

/// Returns whether the card was actually deleted, so a session that was
/// showing it knows whether to move on.
///
/// [onRestored] runs after the toast's Undo has put the card back, for a
/// session that took it out of its own in-memory queue and has to put it back
/// there too. It is not given the restored card: by the time it runs the
/// providers have been invalidated, and a session that cares reads the row it
/// is going to show from them.
Future<bool> deleteStudyCard(
  BuildContext context,
  WidgetRef ref,
  StudyCard card, {
  Future<void> Function()? onRestored,
}) async {
  // Captured while the caller is still mounted: deleting the card unmounts the
  // tile that asked for it, and the toast offering the undo has to outlive it.
  final container = ProviderScope.containerOf(context, listen: false);
  final overlay = Overlay.of(context, rootOverlay: true);

  final confirmed = await showConfirmDialog(
    context,
    title: 'Delete this card?',
    message: 'The card and its review history will be moved to trash.',
  );
  if (!confirmed) return false;

  late final StudyCardDeletion deletion;
  // Returned rather than a bare `true`: a delete that threw leaves the card
  // live on disk, and a session told otherwise drops it from its queue anyway —
  // permanently in cram, whose held map is only ever refreshed from itself.
  // This is also what keeps the unassigned `deletion` above safe, since
  // `restore` is only reachable once `delete` has returned normally.
  return softDeleteWithUndo(
    overlay: overlay,
    // A card has no title — its front text is what the user would recognise
    // it by, and an untitled one is rare enough to name generically.
    message: deletedMessage(card.frontText, fallback: 'card'),
    delete: () async => deletion = await softDeleteStudyCard(container, card),
    restore: () async {
      await restoreStudyCard(container, deletion);
      await onRestored?.call();
    },
  );
}

/// Both card lists: the per-deck roster the workbench reads and the flattened
/// one a Hub-wide session works from. A card changed from inside a session is
/// only visible to it through the latter. The deck and hub stats go with them,
/// since a card appearing or disappearing changes both counts.
/// Public because every Study writer has to call it: a writer that invalidates
/// only some of these leaves the Hub reading a `keepAlive`d list that predates
/// its write, and grading off that list writes a `deletedAt: null` back over a
/// tombstone.
void invalidateStudyCards(WidgetRef ref) {
  invalidateStudyCardsIn(ProviderScope.containerOf(ref.context, listen: false));
}

/// [invalidateStudyCards] for a caller holding a container rather than a ref.
void invalidateStudyCardsIn(ProviderContainer container) {
  container.invalidate(studyCardsProvider);
  container.invalidate(studyAllCardsProvider);
  container.invalidate(studyDeckStatsProvider);
  container.invalidate(studyStatsProvider);
}

/// Deletes [deck] and every card inside it (decks never leave orphaned
/// cards behind — there's no "loose card" concept per STUDY.md).
Future<void> deleteStudyDeck(
  BuildContext context,
  WidgetRef ref,
  StudyDeck deck,
) async {
  final repo = ref.read(studyRepositoryProvider);
  final cards = await repo.listCards(deck.id);
  final confirmed = await showConfirmDialog(
    context,
    title: 'Delete "${deck.name}"?',
    message: cards.isEmpty
        ? 'This deck has no cards and will be removed.'
        : 'This deck and its ${cards.length} card${cards.length == 1 ? '' : 's'} will be deleted.',
  );
  if (!confirmed) return;

  final remoteSync = ref.read(remoteSyncServiceProvider);
  for (final card in cards) {
    await repo.softDeleteCard(card.id);
  }
  await detachStudyCardMedia(ref, [for (final card in cards) card.id]);
  await repo.softDeleteDeck(deck.id);
  final deleted = await repo.getDeck(deck.id);
  if (deleted != null) remoteSync.pushStudyDeck(deleted);
  final deletedCards = <StudyCard>[];
  for (final card in cards) {
    final c = await repo.getCard(card.id);
    if (c != null) deletedCards.add(c);
  }
  await remoteSync.pushStudyCardsBatch(deletedCards);

  invalidateStudyCards(ref);
  _invalidateStudyLibrary(ref);
}

/// Recursively collects every descendant folder/deck of [folderId] (depth-first).
Future<
    ({List<StudyFolder> folders, List<StudyDeck> decks})>
    _collectFolderContents(StudyRepository repo, String folderId) async {
  final folders = <StudyFolder>[];
  final decks = <StudyDeck>[];
  final childFolders = await repo.listFolders(parentFolderId: folderId);
  final childDecks = await repo.listDecks(parentFolderId: folderId);
  decks.addAll(childDecks);
  for (final child in childFolders) {
    folders.add(child);
    final nested = await _collectFolderContents(repo, child.id);
    folders.addAll(nested.folders);
    decks.addAll(nested.decks);
  }
  return (folders: folders, decks: decks);
}

/// Deletes [folder] and everything nested inside it — subfolders, decks, and
/// their cards — mirroring how deleting a folder on a filesystem removes its
/// whole contents.
Future<void> deleteStudyFolder(
  BuildContext context,
  WidgetRef ref,
  StudyFolder folder,
) async {
  final repo = ref.read(studyRepositoryProvider);
  final contents = await _collectFolderContents(repo, folder.id);
  final itemCount = contents.folders.length + contents.decks.length;
  final confirmed = await showConfirmDialog(
    context,
    title: 'Delete "${folder.name}"?',
    message: itemCount == 0
        ? 'This folder is empty and will be removed.'
        : 'This folder and everything inside it (${contents.folders.length} subfolder${contents.folders.length == 1 ? '' : 's'}, ${contents.decks.length} deck${contents.decks.length == 1 ? '' : 's'}) will be deleted.',
  );
  if (!confirmed) return;

  final remoteSync = ref.read(remoteSyncServiceProvider);

  for (final deck in contents.decks) {
    final cards = await repo.listCards(deck.id);
    for (final card in cards) {
      await repo.softDeleteCard(card.id);
    }
    await detachStudyCardMedia(ref, [for (final card in cards) card.id]);
    await repo.softDeleteDeck(deck.id);
    final deleted = await repo.getDeck(deck.id);
    if (deleted != null) remoteSync.pushStudyDeck(deleted);
    final deletedCards = <StudyCard>[];
    for (final card in cards) {
      final c = await repo.getCard(card.id);
      if (c != null) deletedCards.add(c);
    }
    await remoteSync.pushStudyCardsBatch(deletedCards);
  }
  for (final subfolder in contents.folders.reversed) {
    await repo.softDeleteFolder(subfolder.id);
    final deleted = await repo.getFolder(subfolder.id);
    if (deleted != null) remoteSync.pushStudyFolder(deleted);
  }
  await repo.softDeleteFolder(folder.id);
  final deletedFolder = await repo.getFolder(folder.id);
  if (deletedFolder != null) remoteSync.pushStudyFolder(deletedFolder);

  invalidateStudyCards(ref);
  _invalidateStudyLibrary(ref);
}

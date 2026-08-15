import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/widgets/confirm_dialog.dart';
import 'package:voyager/core/widgets/context_menu.dart';
import 'package:voyager/core/widgets/palette_color_picker.dart';
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
/// while resetting mid-session also moves the session on.
List<ContextMenuItem> studyCardMenuItems({
  required StudyCard card,
  required VoidCallback onEdit,
  required VoidCallback onReverse,
  required VoidCallback onResetProgress,
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

/// Swaps a card's two faces. SRS state is deliberately left alone: the card
/// is still the same memory item to the scheduler, so its interval and due
/// date carry over to the reversed version.
Future<void> reverseStudyCard(WidgetRef ref, StudyCard card) async {
  final updated = card.copyWith(
    frontText: card.backText,
    backText: card.frontText,
  );
  await ref.read(studyRepositoryProvider).upsertCard(updated);
  ref.read(remoteSyncServiceProvider).pushStudyCard(updated);
  _invalidateStudyCards(ref);
}

/// Forgets how well the user knows [card] — its text is untouched. Returns
/// the reset card so a session can put the same copy back in its queue.
Future<StudyCard> resetStudyCardProgress(WidgetRef ref, StudyCard card) async {
  final reset = resetStudyCardSrs(card);
  await ref.read(studyRepositoryProvider).upsertCard(reset);
  ref.read(remoteSyncServiceProvider).pushStudyCard(reset);
  _invalidateStudyCards(ref);
  ref.invalidate(studyDeckStatsProvider);
  ref.invalidate(studyStatsProvider);
  return reset;
}

/// Returns whether the card was actually deleted, so a session that was
/// showing it knows whether to move on.
Future<bool> deleteStudyCard(
  BuildContext context,
  WidgetRef ref,
  StudyCard card,
) async {
  final confirmed = await showConfirmDialog(
    context,
    title: 'Delete this card?',
    message: 'The card and its review history will be removed.',
  );
  if (!confirmed) return false;

  final repo = ref.read(studyRepositoryProvider);
  await repo.softDeleteCard(card.id);
  final tombstone = await repo.getCard(card.id);
  if (tombstone != null) {
    ref.read(remoteSyncServiceProvider).pushStudyCard(tombstone);
  }
  _invalidateStudyCards(ref);
  ref.invalidate(studyDeckStatsProvider);
  ref.invalidate(studyStatsProvider);
  return true;
}

/// Both card lists: the per-deck roster the workbench reads and the flattened
/// one a Hub-wide session works from. A card changed from inside a session is
/// only visible to it through the latter.
void _invalidateStudyCards(WidgetRef ref) {
  ref.invalidate(studyCardsProvider);
  ref.invalidate(studyAllCardsProvider);
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
  await repo.softDeleteDeck(deck.id);
  final deleted = await repo.getDeck(deck.id);
  if (deleted != null) remoteSync.pushStudyDeck(deleted);
  final deletedCards = <StudyCard>[];
  for (final card in cards) {
    final c = await repo.getCard(card.id);
    if (c != null) deletedCards.add(c);
  }
  await remoteSync.pushStudyCardsBatch(deletedCards);

  ref.invalidate(studyCardsProvider);
  ref.invalidate(studyStatsProvider);
  ref.invalidate(studyDeckStatsProvider);
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

  ref.invalidate(studyCardsProvider);
  ref.invalidate(studyStatsProvider);
  ref.invalidate(studyDeckStatsProvider);
  _invalidateStudyLibrary(ref);
}

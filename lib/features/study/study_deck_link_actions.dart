import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/soft_delete/soft_delete_toast.dart';
import 'package:voyager/core/sync/firestore_collections.dart';
import 'package:voyager/core/utils/ids.dart';
import 'package:voyager/core/widgets/confirm_dialog.dart';
import 'package:voyager/core/widgets/voyager_toast.dart';
import 'package:voyager/domain/models/study_models.dart';
import 'package:voyager/domain/repositories/repositories.dart';
import 'package:voyager/domain/services/study_deck_graph.dart';
import 'package:voyager/features/study/study_actions.dart';

/// A graph of the links as they stand on disk rather than in the provider,
/// for the cycle check a write has to make against the latest rows.
Future<StudyDeckGraph> _graphOnDisk(StudyRepository repo) async =>
    StudyDeckGraph(
      decks: await repo.getAllDecks(includeDeleted: false),
      cards: const [],
      links: await repo.listDeckLinks(),
    );

void invalidateStudyDeckLinksIn(ProviderContainer container) {
  container.invalidate(studyDeckLinksProvider);
  container.invalidate(studyDeckStatsProvider);
}

/// Links [childDeckId] into [parentDeckId] — STUDY_DECK_LINKS_HLD.md §5.7.
///
/// Returns false when the link would close a cycle, which the picker should
/// already have kept out of reach; the check here is the one that holds.
/// Linking a pair that was unlinked before revives that row rather than
/// writing a second one — see [StudyDeckLink.idFor].
Future<bool> linkStudyDeck(
  WidgetRef ref, {
  required String parentDeckId,
  required String childDeckId,
}) async {
  final container = ProviderScope.containerOf(ref.context, listen: false);
  final repo = container.read(studyRepositoryProvider);
  if ((await _graphOnDisk(repo)).wouldCreateCycle(parentDeckId, childDeckId)) {
    return false;
  }
  final id = StudyDeckLink.idFor(parentDeckId, childDeckId);
  final existing = await repo.getDeckLink(id);
  if (existing != null && existing.deletedAt == null) return true;
  final now = utcNow();
  final link = StudyDeckLink(
    id: id,
    // A revived link counts as made now: when the sync layer breaks a cycle
    // it drops the newest edge, and this is the one the user just chose.
    createdAt: now,
    updatedAt: now,
    // One above the tombstone, so the revival beats it on every device.
    version: existing == null ? 0 : existing.version + 1,
    parentDeckId: parentDeckId,
    childDeckId: childDeckId,
  );
  await repo.upsertDeckLink(link);
  container.read(remoteSyncServiceProvider).pushStudyDeckLink(link);
  invalidateStudyDeckLinksIn(container);
  return true;
}

/// The placeholder's toggle. Off keeps the placeholder but takes the child's
/// cards out of the parent's stats and sessions (§3).
Future<void> setStudyDeckLinkEnabled(
  WidgetRef ref,
  StudyDeckLink link, {
  required bool enabled,
}) async {
  final container = ProviderScope.containerOf(ref.context, listen: false);
  final repo = container.read(studyRepositoryProvider);
  final current = await repo.getDeckLink(link.id);
  if (current == null || current.deletedAt != null) return;
  if (current.enabled == enabled) return;
  final updated = current.copyWith(enabled: enabled);
  await repo.upsertDeckLink(updated);
  container.read(remoteSyncServiceProvider).pushStudyDeckLink(updated);
  invalidateStudyDeckLinksIn(container);
}

/// Removes the membership only — the child deck and every card's SRS state
/// are untouched (§3). The toast's Undo puts the link back as it stood: its
/// toggle, and its place among the placeholders.
Future<void> unlinkStudyDeck(
  BuildContext context,
  StudyDeckLink link, {
  required String childName,
}) async {
  // Captured up front: unlinking unmounts the placeholder that asked, and the
  // toast offering the undo has to outlive it.
  final container = ProviderScope.containerOf(context, listen: false);
  final overlay = Overlay.of(context, rootOverlay: true);
  final repo = container.read(studyRepositoryProvider);
  // Assigned in `delete`, read only from `restore`, which `softDeleteWithUndo`
  // reaches only once `delete` has returned normally.
  late final StudyDeckLink before;
  await softDeleteWithUndo(
    overlay: overlay,
    message: 'Unlinked "$childName"',
    delete: () async {
      // Off disk rather than the placeholder's copy, which can lag a toggle.
      before = await repo.getDeckLink(link.id) ?? link;
      await _softDeleteLink(container, link.id);
    },
    restore: () => _restoreLink(container, overlay, before),
  );
}

/// Undoes [unlinkStudyDeck]: [before] as it stood, at a version that outranks
/// the tombstone and anything a pull landed while the offer stood.
Future<void> _restoreLink(
  ProviderContainer container,
  OverlayState overlay,
  StudyDeckLink before,
) async {
  final repo = container.read(studyRepositoryProvider);
  final current = await repo.getDeckLink(before.id);
  abortIfAlreadyRestored(found: current != null, deletedAt: current?.deletedAt);
  final graph = await _graphOnDisk(repo);
  // Either deck deleted while the offer stood: the link would be an orphan
  // nothing ever cleans up.
  if (graph.deck(before.parentDeckId) == null ||
      graph.deck(before.childDeckId) == null) {
    return;
  }
  // An undo is a new edge like any other — a link made the other way while
  // the offer stood would make this one close a loop.
  if (graph.wouldCreateCycle(before.parentDeckId, before.childDeckId)) {
    showVoyagerToastIn(
      overlay,
      message: 'Can\'t relink: that would now create a loop.',
      icon: PhosphorIconsRegular.warning,
      dwell: const Duration(seconds: 4),
    );
    return;
  }
  final restored = StudyDeckLink(
    id: before.id,
    // Its original age, so the placeholder returns to where it was.
    createdAt: before.createdAt,
    updatedAt: utcNow(),
    version: restoreVersionFrom(
      preDeleteVersion: before.version,
      currentVersion: current?.version,
    ),
    parentDeckId: before.parentDeckId,
    childDeckId: before.childDeckId,
    enabled: before.enabled,
  );
  await repo.upsertDeckLink(restored);
  container.read(remoteSyncServiceProvider).pushStudyDeckLink(restored);
  invalidateStudyDeckLinksIn(container);
}

Future<void> _softDeleteLink(
  ProviderContainer container,
  String id, {
  DateTime? at,
}) async {
  final repo = container.read(studyRepositoryProvider);
  await repo.softDeleteDeckLink(id, at: at);
  final tombstone = await repo.getDeckLink(id);
  if (tombstone != null) {
    container.read(remoteSyncServiceProvider).pushStudyDeckLink(tombstone);
  }
  invalidateStudyDeckLinksIn(container);
}

/// Tombstones every live link with an end in [deckIds], for a deck delete:
/// a link to or from a deleted deck is an orphan nothing would ever clean up.
///
/// [at] is the deck delete's own stamp, so restoring the deck from the trash
/// brings back exactly the links this delete took.
Future<void> softDeleteStudyDeckLinksTouching(
  ProviderContainer container,
  Set<String> deckIds, {
  DateTime? at,
}) async {
  final repo = container.read(studyRepositoryProvider);
  for (final link in await repo.listDeckLinks()) {
    if (deckIds.contains(link.parentDeckId) ||
        deckIds.contains(link.childDeckId)) {
      await _softDeleteLink(container, link.id, at: at);
    }
  }
}

/// The decks besides [link]'s child through which its parent's sessions
/// already reach [childCardIds] — enabled links whose effective set holds
/// them. A fork leaves each of these still bringing the originals in.
List<String> _otherRoutesInto(
  StudyDeckGraph graph,
  StudyDeckLink link,
  Set<String> childCardIds,
) => [
  if (childCardIds.isNotEmpty)
    for (final other in graph.linksFrom(link.parentDeckId))
      if (other.id != link.id &&
          other.enabled &&
          graph
              .effectiveCards(other.childDeckId)
              .any((c) => childCardIds.contains(c.id)))
        ?graph.deck(other.childDeckId)?.name,
];

/// Fork (§4.5): copies the child's *own* cards into the parent as new native
/// cards — new ids, fresh SRS — then removes the link. The child's own links
/// are not flattened in; nested composition stays the child's concern.
Future<void> forkStudyDeckLink(
  BuildContext context,
  WidgetRef ref,
  StudyDeckLink link, {
  required String parentName,
  required String childName,
}) async {
  final container = ProviderScope.containerOf(context, listen: false);
  final repo = container.read(studyRepositoryProvider);
  final sources = await repo.listCards(link.childDeckId);
  final graph = await container.read(studyDeckGraphProvider.future);
  if (!context.mounted) return;
  final count = sources.length;
  final alsoVia = [
    for (final name in _otherRoutesInto(graph, link, {
      for (final c in sources) c.id,
    }))
      '"$name"',
  ];
  final confirmed = await showConfirmDialog(
    context,
    title: 'Fork "$childName" into "$parentName"?',
    message:
        (count == 0
            ? '"$childName" has no cards of its own. The link will be removed.'
            : 'Its $count card${count == 1 ? '' : 's'} will be copied into '
                  '"$parentName" as new cards with fresh progress, and the '
                  'link will be removed. "$childName" itself is unchanged.') +
        // The copies have ids of their own, so nothing dedupes them against
        // originals that keep arriving another way.
        (alsoVia.isEmpty
            ? ''
            : '\n\n${alsoVia.join(', ')} also '
                  '${alsoVia.length == 1 ? 'brings' : 'bring'} '
                  '"$childName" into "$parentName", so its original cards '
                  'will still show up there alongside the copies.'),
    confirmLabel: 'Fork',
  );
  if (!confirmed) return;

  final media = container.read(mediaServiceProvider);
  final now = utcNow();
  final copies = <StudyCard>[];
  for (final source in sources) {
    final copy = StudyCard(
      id: newId(),
      createdAt: now,
      updatedAt: now,
      deckId: link.parentDeckId,
      frontText: source.frontText,
      backText: source.backText,
      // Baseline ease and interval come from the constructor's defaults — the
      // same fresh start a card typed into the editor gets.
      dueAt: now,
    );
    await repo.upsertCard(copy);
    // The copy points at the same blobs under its own id, as Duplicate does.
    await media.duplicateReferencesForOwner(
      collection: FirestoreCollections.studyCards,
      fromDocumentId: source.id,
      toDocumentId: copy.id,
    );
    copies.add(copy);
  }
  await container.read(remoteSyncServiceProvider).pushStudyCardsBatch(copies);
  await _softDeleteLink(container, link.id);
  invalidateStudyCardsIn(container);
}

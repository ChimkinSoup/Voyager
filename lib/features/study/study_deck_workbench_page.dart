import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/soft_delete/soft_delete_toast.dart';
import 'package:voyager/core/sync/firestore_collections.dart';
import 'package:voyager/core/widgets/confirm_dialog.dart';
import 'package:voyager/core/theme/voyager_theme.dart';
import 'package:voyager/core/widgets/glass_button.dart';
import 'package:voyager/core/widgets/voyager_text_field.dart';
import 'package:voyager/domain/models/study_models.dart';
import 'package:voyager/domain/services/study_deck_graph.dart';
import 'package:voyager/domain/services/study_srs_engine.dart';
import 'package:voyager/features/study/study_actions.dart';
import 'package:voyager/features/study/study_breadcrumb.dart';
import 'package:voyager/features/study/study_card_editor_modal.dart';
import 'package:voyager/features/study/study_card_tile.dart';
import 'package:voyager/features/study/study_cram_page.dart';
import 'package:voyager/features/study/study_deck_link_actions.dart';
import 'package:voyager/features/study/study_import_text_modal.dart';
import 'package:voyager/features/study/study_link_deck_modal.dart';
import 'package:voyager/features/study/study_linked_deck.dart';
import 'package:voyager/features/study/study_move_modal.dart';
import 'package:voyager/features/study/study_providers.dart';
import 'package:voyager/features/study/study_session_page.dart';

/// Administrative dashboard for a single deck — title/stats, Study/Cram
/// entry points, a search + import + multi-select control bar, and the
/// scrollable grid of card tiles.
class StudyDeckWorkbenchPage extends ConsumerStatefulWidget {
  const StudyDeckWorkbenchPage({
    super.key,
    required this.deckId,
    required this.folderStack,
    required this.onBack,
    required this.onJumpToRoot,
    required this.onJumpToFolder,
    required this.onOpenDeck,
    this.deckNameHint,
  });

  final String deckId;
  final List<String> folderStack;
  final VoidCallback onBack;
  final VoidCallback onJumpToRoot;
  final ValueChanged<int> onJumpToFolder;

  /// Leaves this deck for another — a linked deck's "Visit", or a name in
  /// "Included in".
  final ValueChanged<StudyDeck> onOpenDeck;
  final String? deckNameHint;

  @override
  ConsumerState<StudyDeckWorkbenchPage> createState() =>
      _StudyDeckWorkbenchPageState();
}

class _StudyDeckWorkbenchPageState
    extends ConsumerState<StudyDeckWorkbenchPage> {
  /// Cards whose face differs from the one the grid would show on its own —
  /// normally the front, or the back for a card the search only matched
  /// there. Turning cards over is a browsing gesture, not a mode: flips pile
  /// up as the user works through the grid and are only dropped when the deck
  /// closes, since this state lives and dies with the page.
  final Set<String> _flipped = {};

  @override
  Widget build(BuildContext context) {
    final deckId = widget.deckId;
    final theme = Theme.of(context);
    // The Hub stays live and hit-testable while the zoom is neither forward
    // nor at 1, so a deck can be deleted from its tile's context menu with
    // this workbench as the visible layer. Nothing else closes it, and the
    // page would go on rendering a full workbench — title, stats, Add card,
    // Import — over a tombstoned row, creating cards against a dead deckId.
    ref.listen(studyDeckByIdProvider(deckId), (_, next) {
      final deck = next.valueOrNull;
      if (next.hasValue && (deck == null || deck.deletedAt != null)) {
        widget.onBack();
      }
    });
    final deckAsync = ref.watch(studyDeckByIdProvider(deckId));
    final cardsAsync = ref.watch(studyCardsProvider(deckId));
    final dueAsync = ref.watch(studyDeckStatsProvider(deckId));
    final multiSelect = ref.watch(studyMultiSelectEnabledProvider);
    final selected = ref.watch(studySelectedCardIdsProvider);
    final query = ref.watch(studySearchQueryProvider);
    final cardImages =
        ref.watch(studyCardImagesProvider).valueOrNull ?? const {};

    final graph =
        ref.watch(studyDeckGraphProvider).valueOrNull ?? StudyDeckGraph.empty;

    final deckName = deckAsync.valueOrNull?.name ?? widget.deckNameHint ?? '';
    final cards = cardsAsync.valueOrNull ?? const <StudyCard>[];
    final effectiveIds = {for (final c in graph.effectiveCards(deckId)) c.id};
    final links = graph.linksFrom(deckId);
    final parents = graph.parentsOf(deckId)
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    // Matched as one phrase, so the tiles highlight it as one phrase too.
    final keywords = query.trim().isEmpty ? const <String>[] : [query.trim()];
    final needle = query.trim().toLowerCase();
    final filtered = needle.isEmpty
        ? cards
        : cards
              .where(
                (c) =>
                    c.frontText.toLowerCase().contains(needle) ||
                    c.backText.toLowerCase().contains(needle),
              )
              .toList();
    final ordered = sortStudyCardsByMastery(filtered);
    // Placeholders lead the grid, oldest link first; a search narrows them by
    // the linked deck's name.
    final shownLinks = [
      for (final link in links)
        if (needle.isEmpty ||
            (graph
                    .deck(link.childDeckId)
                    ?.name
                    .toLowerCase()
                    .contains(needle) ??
                false))
          link,
    ];
    final stats = dueAsync.valueOrNull;
    final due = stats?.due ?? 0;
    final linkedCount = stats == null ? 0 : stats.total - stats.own;

    return Material(
      color: Colors.transparent,
      child: SafeArea(
        child: Stack(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 16, 24, 0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  StudyBreadcrumbRow(
                    folderStack: widget.folderStack,
                    onTapRoot: widget.onJumpToRoot,
                    onTapFolder: widget.onJumpToFolder,
                    trailingLabel: deckName,
                  ),
                  const SizedBox(height: 16),
                  Text(deckName, style: theme.textTheme.headlineMedium),
                  const SizedBox(height: 4),
                  Text(
                    '${cards.length} card${cards.length == 1 ? '' : 's'}'
                    '${linkedCount > 0 ? ' · $linkedCount linked' : ''}'
                    ' · $due due',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
                    ),
                  ),
                  if (parents.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    _IncludedIn(
                      parents: parents,
                      onOpenDeck: widget.onOpenDeck,
                    ),
                  ],
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Expanded(
                        // Gated on the due count, not on the roster. The
                        // session's queue is due-only, so a deck whose cards
                        // are all scheduled into the future opened straight
                        // onto "Session complete" — tap Study on 40 cards, be
                        // told you have finished. Matches the Hub's button,
                        // which already disables and relabels itself at zero.
                        child: GlassButton(
                          onPressed: due == 0
                              ? null
                              : () => _studySession(effectiveIds),
                          icon: const Icon(PhosphorIconsRegular.playCircle),
                          label: due == 0 ? 'Nothing due' : 'Study $due due',
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: GlassButton(
                          onPressed: effectiveIds.isEmpty
                              ? null
                              : () => _cramSession(effectiveIds),
                          icon: const Icon(PhosphorIconsRegular.lightning),
                          label: 'Cram',
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Expanded(
                        child: VoyagerTextField(
                          onChanged: (v) =>
                              ref
                                      .read(studySearchQueryProvider.notifier)
                                      .state =
                                  v,
                          decoration: const InputDecoration(
                            hintText: 'Search cards',
                            prefixIcon: Icon(
                              PhosphorIconsRegular.magnifyingGlass,
                              size: 18,
                            ),
                            isDense: true,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      GlassButton(
                        dense: true,
                        tooltip: 'Import cards',
                        icon: const Icon(PhosphorIconsRegular.uploadSimple),
                        onPressed: () =>
                            showStudyImportTextModal(context, ref, deckId),
                      ),
                      const SizedBox(width: 8),
                      GlassButton(
                        dense: true,
                        tooltip: multiSelect
                            ? 'Exit selection'
                            : 'Select cards',
                        icon: const Icon(PhosphorIconsRegular.checkSquare),
                        color: multiSelect ? theme.colorScheme.primary : null,
                        onPressed: () {
                          final next = !multiSelect;
                          ref
                                  .read(
                                    studyMultiSelectEnabledProvider.notifier,
                                  )
                                  .state =
                              next;
                          if (!next) {
                            ref
                                    .read(studySelectedCardIdsProvider.notifier)
                                    .state =
                                {};
                          }
                        },
                      ),
                      const SizedBox(width: 8),
                      GlassButton(
                        dense: true,
                        tooltip: 'Link deck…',
                        icon: const Icon(PhosphorIconsRegular.link),
                        onPressed: () => showStudyLinkDeckModal(
                          context,
                          parentDeckId: deckId,
                        ),
                      ),
                      const SizedBox(width: 8),
                      GlassButton(
                        dense: true,
                        label: 'Add card',
                        icon: const Icon(PhosphorIconsRegular.plus),
                        onPressed: () => showStudyCardEditorModal(
                          context,
                          ref,
                          deckId: deckId,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Expanded(
                    child: ordered.isEmpty && shownLinks.isEmpty
                        ? Center(
                            child: Text(
                              cards.isEmpty && links.isEmpty
                                  ? 'No cards yet — tap "Add card" to create one.'
                                  : 'No cards match "$query".',
                              style: theme.textTheme.bodyMedium?.copyWith(
                                color: theme.colorScheme.onSurface.withValues(
                                  alpha: 0.5,
                                ),
                              ),
                            ),
                          )
                        : GridView.builder(
                            padding: const EdgeInsets.only(top: 8, bottom: 96),
                            gridDelegate:
                                const SliverGridDelegateWithMaxCrossAxisExtent(
                                  maxCrossAxisExtent: 180,
                                  mainAxisSpacing: 12,
                                  crossAxisSpacing: 12,
                                ),
                            itemCount: shownLinks.length + ordered.length,
                            itemBuilder: (context, index) {
                              if (index < shownLinks.length) {
                                return _linkTile(
                                  shownLinks[index],
                                  graph,
                                  deckName,
                                );
                              }
                              final card = ordered[index - shownLinks.length];
                              // A back-only search hit turns its tile around,
                              // so _flipped records the difference from that
                              // baseline rather than the face itself —
                              // otherwise flipping such a tile to the front
                              // would immediately snap it back.
                              final backOnly = studyCardMatchesBackOnly(
                                card,
                                keywords,
                              );
                              return StudyCardTile(
                                key: ValueKey(card.id),
                                card: card,
                                frontImages:
                                    cardImages[card.id]?.front ?? const [],
                                backImages:
                                    cardImages[card.id]?.back ?? const [],
                                keywords: keywords,
                                showBack:
                                    backOnly != _flipped.contains(card.id),
                                onFlipped: (showingBack) => setState(() {
                                  if (showingBack == backOnly) {
                                    _flipped.remove(card.id);
                                  } else {
                                    _flipped.add(card.id);
                                  }
                                }),
                                multiSelectEnabled: multiSelect,
                                selected: selected.contains(card.id),
                                onToggleSelected: (v) =>
                                    _toggleSelected(card.id, v),
                                onLongPress: () {
                                  ref
                                          .read(
                                            studyMultiSelectEnabledProvider
                                                .notifier,
                                          )
                                          .state =
                                      true;
                                  _toggleSelected(card.id, true);
                                },
                                onEdit: () => showStudyCardEditorModal(
                                  context,
                                  ref,
                                  deckId: deckId,
                                  existing: card,
                                ),
                                onReverse: () => reverseStudyCard(ref, card),
                                onResetProgress: () =>
                                    resetStudyCardProgress(ref, card),
                                onDelete: () =>
                                    deleteStudyCard(context, ref, card),
                              );
                            },
                          ),
                  ),
                ],
              ),
            ),
            if (multiSelect && selected.isNotEmpty)
              Positioned(
                left: 0,
                right: 0,
                bottom: 16,
                child: Center(
                  child: _StudySelectionBar(deckId: deckId, selected: selected),
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// A Study session framed as this deck. Its cards arrive from links as
  /// well as from here, so the framing is what tells a linked card to show
  /// where it lives.
  void _studySession(Set<String> cardIds, {String? frameDeckId}) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => StudySessionPage(
          cardIds: cardIds,
          frameDeckId: frameDeckId ?? widget.deckId,
        ),
      ),
    );
  }

  void _cramSession(Set<String> cardIds, {String? frameDeckId}) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => StudyCramPage(
          deckId: frameDeckId ?? widget.deckId,
          cardIds: cardIds,
        ),
      ),
    );
  }

  Widget _linkTile(StudyDeckLink link, StudyDeckGraph graph, String deckName) {
    final child = graph.deck(link.childDeckId)!;
    Set<String> childIds() => {
      for (final c in graph.effectiveCards(child.id)) c.id,
    };
    return StudyLinkedDeckTile(
      key: ValueKey(link.id),
      link: link,
      deckName: child.name,
      onOpen: () async {
        final action = await showStudyLinkedDeckSheet(
          context,
          deckId: child.id,
        );
        if (!mounted || action == null) return;
        // The linked deck's own cards, framed as that deck — the set the
        // sheet counted, so the session holds what its button said (§5.3).
        final ids = {
          for (final c
              in (ref.read(studyDeckGraphProvider).valueOrNull ?? graph)
                  .ownCards(child.id))
            c.id,
        };
        switch (action) {
          case StudyLinkedDeckAction.study:
            _studySession(ids, frameDeckId: child.id);
          case StudyLinkedDeckAction.cram:
            _cramSession(ids, frameDeckId: child.id);
        }
      },
      onToggle: (enabled) =>
          setStudyDeckLinkEnabled(ref, link, enabled: enabled),
      // Framed as this deck, drawing only on the linked one (§5.4).
      onStudySubset: () => _studySession(childIds()),
      onFork: () => forkStudyDeckLink(
        context,
        ref,
        link,
        parentName: deckName,
        childName: child.name,
      ),
      onVisit: () => widget.onOpenDeck(child),
      onUnlink: () => unlinkStudyDeck(context, link, childName: child.name),
    );
  }

  void _toggleSelected(String cardId, bool value) {
    final notifier = ref.read(studySelectedCardIdsProvider.notifier);
    final next = {...notifier.state};
    if (value) {
      next.add(cardId);
    } else {
      next.remove(cardId);
    }
    notifier.state = next;
    // Unchecking the last card leaves multi-select with nothing to act on and
    // no bar to leave it by, so clearing the selection leaves the mode too.
    // Only on the way down: switching the mode on starts empty by design.
    if (!value && next.isEmpty) {
      ref.read(studyMultiSelectEnabledProvider.notifier).state = false;
    }
  }
}

/// Quiet "Included in: A, B" under the header — the decks that link this one
/// (§5.6). Each name opens that deck.
class _IncludedIn extends StatelessWidget {
  const _IncludedIn({required this.parents, required this.onOpenDeck});

  final List<StudyDeck> parents;
  final ValueChanged<StudyDeck> onOpenDeck;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final style = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
    );
    return Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Text('Included in: ', style: style),
        for (final (i, parent) in parents.indexed) ...[
          if (i > 0) Text(', ', style: style),
          MouseRegion(
            cursor: SystemMouseCursors.click,
            child: GestureDetector(
              onTap: () => onOpenDeck(parent),
              // Flutter's TextDecoration.underline has no vertical offset;
              // a bottom border with padding keeps the same look with 2px gap.
              child: Container(
                padding: const EdgeInsets.only(bottom: 1),
                decoration: BoxDecoration(
                  border: Border(
                    bottom: BorderSide(
                      color: style?.color ?? theme.colorScheme.onSurface,
                      width: 1,
                    ),
                  ),
                ),
                child: Text(parent.name, style: style),
              ),
            ),
          ),
        ],
      ],
    );
  }
}

class _StudySelectionBar extends ConsumerWidget {
  const _StudySelectionBar({required this.deckId, required this.selected});

  final String deckId;
  final Set<String> selected;

  Future<void> _duplicate(BuildContext context, WidgetRef ref) async {
    final repo = ref.read(studyRepositoryProvider);
    final media = ref.read(mediaServiceProvider);
    try {
      final copies = await repo.duplicateCards(selected.toList());
      final duplicated = <StudyCard>[];
      for (final entry in copies.entries) {
        // The copy points at the same blobs, under its own id — see
        // [MediaService.duplicateReferencesForOwner].
        await media.duplicateReferencesForOwner(
          collection: FirestoreCollections.studyCards,
          fromDocumentId: entry.key,
          toDocumentId: entry.value,
        );
        final card = await repo.getCard(entry.value);
        if (card != null) duplicated.add(card);
      }
      await ref.read(remoteSyncServiceProvider).pushStudyCardsBatch(duplicated);
      invalidateStudyCards(ref);
      ref.read(studySelectedCardIdsProvider.notifier).state = {};
      ref.read(studyMultiSelectEnabledProvider.notifier).state = false;
    } catch (error, stackTrace) {
      // Reported rather than left loose in the zone: the bar stays as it was
      // and nothing on screen would otherwise say the copies were not made.
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: error,
          stack: stackTrace,
          library: 'study workbench',
          context: ErrorDescription(
            'while duplicating ${selected.length} cards',
          ),
        ),
      );
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not duplicate the cards.')),
        );
      }
    }
  }

  /// The same confirm-then-undo machinery every other card-deletion path uses,
  /// rather than a second implementation of the delete. This was the only path
  /// that tombstoned a whole selection on one tap with no prompt and no way
  /// back short of the 30-day trash — and the only one that threw away the
  /// media detach stamps, without which those cards' images could not be
  /// restored even by hand.
  Future<void> _delete(BuildContext context, WidgetRef ref) async {
    // Captured while the bar is still mounted: the delete unmounts it, and the
    // toast offering the undo has to outlive that.
    final container = ProviderScope.containerOf(context, listen: false);
    final overlay = Overlay.of(context, rootOverlay: true);
    final ids = selected.toList();

    final confirmed = await showConfirmDialog(
      context,
      title: 'Delete ${ids.length} card${ids.length == 1 ? '' : 's'}?',
      message: 'They will be moved to trash.',
    );
    if (!confirmed) return;

    var deletions = <StudyCardDeletion>[];
    await softDeleteWithUndo(
      overlay: overlay,
      message: 'Deleted ${ids.length} card${ids.length == 1 ? '' : 's'}',
      delete: () async {
        final repo = container.read(studyRepositoryProvider);
        final collected = <StudyCardDeletion>[];
        for (final id in ids) {
          final card = await repo.getCard(id);
          if (card == null || card.deletedAt != null) continue;
          collected.add(await softDeleteStudyCard(container, card));
        }
        deletions = collected;
      },
      restore: () async {
        for (final deletion in deletions) {
          // Per card: a pull that brought one of them back on its own must not
          // stop the rest of the selection from being restored.
          try {
            await restoreStudyCard(container, deletion);
          } on RestoreSuperseded {
            continue;
          }
        }
      },
    );

    // Through the container, not `ref`: clearing the selection unmounts this
    // bar, and the delete that preceded it may already have.
    container.read(studySelectedCardIdsProvider.notifier).state = {};
    container.read(studyMultiSelectEnabledProvider.notifier).state = false;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final vc = VoyagerColors.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(28),
        boxShadow: vc.surfaceShadow(),
        border: Border.all(color: vc.strongHairline),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Text(
                '${selected.length} selected',
                style: theme.textTheme.labelLarge,
              ),
            ),
            GlassButton(
              dense: true,
              label: 'Move',
              icon: const Icon(PhosphorIconsRegular.arrowsOutSimple),
              onPressed: () =>
                  showStudyMoveModal(context, ref, cardIds: selected.toList()),
            ),
            const SizedBox(width: 8),
            GlassButton(
              dense: true,
              label: 'Duplicate',
              icon: const Icon(PhosphorIconsRegular.copySimple),
              onPressed: () => _duplicate(context, ref),
            ),
            const SizedBox(width: 8),
            GlassButton(
              dense: true,
              label: 'Delete',
              icon: const Icon(PhosphorIconsRegular.trash),
              color: theme.colorScheme.error,
              onPressed: () => _delete(context, ref),
            ),
          ],
        ),
      ),
    );
  }
}

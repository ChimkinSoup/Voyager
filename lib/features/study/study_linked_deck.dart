import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/platform/platform_info.dart';
import 'package:voyager/core/theme/voyager_theme.dart';
import 'package:voyager/core/widgets/context_menu.dart';
import 'package:voyager/core/widgets/glass_button.dart';
import 'package:voyager/core/widgets/glass_surface.dart';
import 'package:voyager/domain/models/study_models.dart';
import 'package:voyager/domain/services/study_srs_engine.dart';
import 'package:voyager/features/study/study_actions.dart';
import 'package:voyager/features/study/study_card_editor_modal.dart';
import 'package:voyager/features/study/study_card_tile.dart';

/// A linked deck's placeholder in the parent's card grid
/// (STUDY_DECK_LINKS_HLD.md §5.1): a card tile's footprint, but not a
/// flashcard — no faces, no flip. It reads as a link by its plain hairline
/// edge where a card wears its mastery colour, and by the link glyph.
class StudyLinkedDeckTile extends ConsumerWidget {
  const StudyLinkedDeckTile({
    super.key,
    required this.link,
    required this.deckName,
    required this.onOpen,
    required this.onToggle,
    required this.onStudySubset,
    required this.onFork,
    required this.onVisit,
    required this.onUnlink,
  });

  final StudyDeckLink link;

  /// The child's live name.
  final String deckName;

  final VoidCallback onOpen;
  final ValueChanged<bool> onToggle;
  final VoidCallback onStudySubset;
  final VoidCallback onFork;
  final VoidCallback onVisit;
  final VoidCallback onUnlink;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final vc = VoyagerColors.of(context);
    final stats = ref
        .watch(studyDeckStatsProvider(link.childDeckId))
        .valueOrNull;
    final due = stats?.due ?? 0;
    final muted = theme.colorScheme.onSurface.withValues(alpha: 0.5);

    return ContextMenuRegion(
      itemsBuilder: () => [
        ContextMenuItem(
          label: due == 0
              ? 'Study this linked subset (nothing due)'
              : 'Study this linked subset',
          icon: PhosphorIconsRegular.playCircle,
          enabled: due > 0,
          onTap: due > 0 ? onStudySubset : null,
        ),
        ContextMenuItem(
          label: 'Fork into this deck',
          icon: PhosphorIconsRegular.gitFork,
          onTap: onFork,
        ),
        ContextMenuItem(
          label: 'Visit deck',
          icon: PhosphorIconsRegular.arrowSquareOut,
          onTap: onVisit,
        ),
        ContextMenuItem(
          label: 'Unlink',
          icon: PhosphorIconsRegular.linkBreak,
          isDestructive: true,
          onTap: onUnlink,
        ),
      ],
      child: Card(
        margin: EdgeInsets.zero,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(18),
          side: BorderSide(color: vc.strongHairline, width: 1.5),
        ),
        child: InkWell(
          onTap: onOpen,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(10, 4, 4, 6),
            child: Column(
              children: [
                Row(
                  children: [
                    Icon(PhosphorIconsRegular.link, size: 14, color: muted),
                    const Spacer(),
                    Tooltip(
                      message: link.enabled
                          ? 'Included in this deck\'s sessions'
                          : 'Left out of this deck\'s sessions',
                      child: Transform.scale(
                        scale: 0.7,
                        alignment: Alignment.centerRight,
                        child: Switch(
                          value: link.enabled,
                          onChanged: onToggle,
                          materialTapTargetSize:
                              MaterialTapTargetSize.shrinkWrap,
                        ),
                      ),
                    ),
                  ],
                ),
                Expanded(
                  child: Center(
                    child: AnimatedOpacity(
                      // Off keeps the placeholder, but it should read as
                      // parked rather than part of the deck.
                      opacity: link.enabled ? 1 : 0.45,
                      duration: const Duration(milliseconds: 150),
                      child: Text(
                        deckName,
                        textAlign: TextAlign.center,
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleSmall,
                      ),
                    ),
                  ),
                ),
                SizedBox(
                  height: 14,
                  child: stats == null
                      ? null
                      : Text(
                          '${stats.total} card${stats.total == 1 ? '' : 's'}'
                          '${due > 0 ? ' · $due due' : ''}',
                          style: theme.textTheme.labelSmall?.copyWith(
                            fontSize: 10,
                            height: 1.2,
                            color: muted,
                          ),
                        ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// What the linked-deck sheet asks its opener to do once it has closed —
/// the session is pushed from the parent, so leaving it lands back on the
/// parent workbench rather than on the sheet (§5.3).
enum StudyLinkedDeckAction { study, cram }

/// The inspector over the parent workbench for one linked deck (§5.3): its
/// own cards, with edit and delete writing through to them, plus Study and
/// Cram of those same cards, framed as that deck. What the deck links in turn
/// is neither listed, counted nor studied here. No add, import or
/// multi-select.
Future<StudyLinkedDeckAction?> showStudyLinkedDeckSheet(
  BuildContext context, {
  required String deckId,
}) {
  return showVoyagerModal<StudyLinkedDeckAction>(
    context: context,
    // The opener's own container, not a child one: a scope that owned its
    // container would dispose it with the sheet, and a card deleted in here
    // offers an Undo that outlives the sheet and reads through it.
    builder: (ctx) => UncontrolledProviderScope(
      container: ProviderScope.containerOf(context),
      child: _StudyLinkedDeckSheet(deckId: deckId),
    ),
  );
}

class _StudyLinkedDeckSheet extends ConsumerStatefulWidget {
  const _StudyLinkedDeckSheet({required this.deckId});

  final String deckId;

  @override
  ConsumerState<_StudyLinkedDeckSheet> createState() =>
      _StudyLinkedDeckSheetState();
}

class _StudyLinkedDeckSheetState extends ConsumerState<_StudyLinkedDeckSheet> {
  /// Tiles turned over while browsing — lives and dies with the sheet.
  final Set<String> _flipped = {};

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final deckId = widget.deckId;
    // Deleted out from under the sheet — from another device, say — leaves
    // nothing to inspect. This sheet's own route, not whatever is on top: a
    // card editor opened from here would otherwise be the one closed, and the
    // sheet left standing over a deleted deck.
    ref.listen(studyDeckByIdProvider(deckId), (_, next) {
      final deck = next.valueOrNull;
      if (next.hasValue && (deck == null || deck.deletedAt != null)) {
        final route = ModalRoute.of(context);
        if (route == null || !route.isActive) return;
        final navigator = Navigator.of(context);
        if (route.isCurrent) {
          navigator.pop();
        } else {
          navigator.removeRoute(route);
        }
      }
    });
    final name =
        ref.watch(studyDeckByIdProvider(deckId)).valueOrNull?.name ?? '';
    final cards = sortStudyCardsByMastery(
      ref.watch(studyCardsProvider(deckId)).valueOrNull ?? const <StudyCard>[],
    );
    final cardImages =
        ref.watch(studyCardImagesProvider).valueOrNull ?? const {};
    // The deck's own cards only — what the grid below lists, and what its
    // Study and Cram draw on. What it links in turn stays out of the sheet.
    final now = DateTime.now().toUtc();
    final due = cards.where((c) => !c.dueAt.isAfter(now)).length;
    final total = cards.length;
    final muted = theme.colorScheme.onSurface.withValues(alpha: 0.6);

    return SizedBox(
      height: MediaQuery.of(context).size.height * 0.85,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 10, 12, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // A grab pill only where the modal is a sheet to drag: it floats
                // on desktop (showVoyagerModal).
                if (isAndroid)
                  Center(
                    child: Container(
                      width: 36,
                      height: 4,
                      margin: const EdgeInsets.only(bottom: 12),
                      decoration: BoxDecoration(
                        color: theme.colorScheme.onSurfaceVariant.withValues(
                          alpha: 0.3,
                        ),
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            name,
                            style: theme.textTheme.titleMedium,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          Text(
                            '$total card${total == 1 ? '' : 's'} · $due due',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: muted,
                            ),
                          ),
                        ],
                      ),
                    ),
                    GlassButton(
                      dense: true,
                      onPressed: due == 0
                          ? null
                          : () => Navigator.of(
                              context,
                            ).pop(StudyLinkedDeckAction.study),
                      icon: const Icon(PhosphorIconsRegular.playCircle),
                      label: due == 0 ? 'Nothing due' : 'Study $due due',
                    ),
                    const SizedBox(width: 8),
                    GlassButton(
                      dense: true,
                      onPressed: total == 0
                          ? null
                          : () => Navigator.of(
                              context,
                            ).pop(StudyLinkedDeckAction.cram),
                      icon: const Icon(PhosphorIconsRegular.lightning),
                      label: 'Cram',
                    ),
                    const SizedBox(width: 4),
                    IconButton(
                      tooltip: 'Close',
                      onPressed: Navigator.of(context).pop,
                      icon: const Icon(PhosphorIconsRegular.x, size: 18),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: cards.isEmpty
                ? Center(
                    child: Text(
                      'This deck has no cards of its own.',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurface.withValues(
                          alpha: 0.5,
                        ),
                      ),
                    ),
                  )
                : GridView.builder(
                    padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
                    gridDelegate:
                        const SliverGridDelegateWithMaxCrossAxisExtent(
                          maxCrossAxisExtent: 180,
                          mainAxisSpacing: 12,
                          crossAxisSpacing: 12,
                        ),
                    itemCount: cards.length,
                    itemBuilder: (context, index) {
                      final card = cards[index];
                      return StudyCardTile(
                        key: ValueKey(card.id),
                        card: card,
                        frontImages: cardImages[card.id]?.front ?? const [],
                        backImages: cardImages[card.id]?.back ?? const [],
                        showBack: _flipped.contains(card.id),
                        onFlipped: (showingBack) => setState(() {
                          if (showingBack) {
                            _flipped.add(card.id);
                          } else {
                            _flipped.remove(card.id);
                          }
                        }),
                        // No batch actions in here (§5.3).
                        multiSelectEnabled: false,
                        selected: false,
                        onToggleSelected: (_) {},
                        onLongPress: () {},
                        onEdit: () => showStudyCardEditorModal(
                          context,
                          ref,
                          deckId: deckId,
                          existing: card,
                        ),
                        onReverse: () => reverseStudyCard(ref, card),
                        onResetProgress: () =>
                            resetStudyCardProgress(ref, card),
                        onDelete: () => deleteStudyCard(context, ref, card),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

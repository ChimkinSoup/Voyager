import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/theme/voyager_theme.dart';
import 'package:voyager/core/widgets/glass_button.dart';
import 'package:voyager/core/widgets/voyager_text_field.dart';
import 'package:voyager/domain/models/study_models.dart';
import 'package:voyager/features/study/study_breadcrumb.dart';
import 'package:voyager/features/study/study_card_editor_modal.dart';
import 'package:voyager/features/study/study_card_row.dart';
import 'package:voyager/features/study/study_cram_page.dart';
import 'package:voyager/features/study/study_import_json_modal.dart';
import 'package:voyager/features/study/study_move_modal.dart';
import 'package:voyager/features/study/study_providers.dart';
import 'package:voyager/features/study/study_session_page.dart';

/// Administrative dashboard for a single deck — title/stats, Study/Cram
/// entry points, a search + import + multi-select control bar, and the
/// scrollable card roster.
class StudyDeckWorkbenchPage extends ConsumerWidget {
  const StudyDeckWorkbenchPage({
    super.key,
    required this.deckId,
    required this.folderStack,
    required this.onBack,
    required this.onJumpToRoot,
    required this.onJumpToFolder,
    this.deckNameHint,
  });

  final String deckId;
  final List<String> folderStack;
  final VoidCallback onBack;
  final VoidCallback onJumpToRoot;
  final ValueChanged<int> onJumpToFolder;
  final String? deckNameHint;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final deckAsync = ref.watch(studyDeckByIdProvider(deckId));
    final cardsAsync = ref.watch(studyCardsProvider(deckId));
    final dueAsync = ref.watch(studyDeckStatsProvider(deckId));
    final multiSelect = ref.watch(studyMultiSelectEnabledProvider);
    final selected = ref.watch(studySelectedCardIdsProvider);
    final query = ref.watch(studySearchQueryProvider);

    final deckName = deckAsync.valueOrNull?.name ?? deckNameHint ?? '';
    final cards = cardsAsync.valueOrNull ?? const <StudyCard>[];
    final filtered = query.trim().isEmpty
        ? cards
        : cards
              .where(
                (c) =>
                    c.frontText.toLowerCase().contains(query.toLowerCase()) ||
                    c.backText.toLowerCase().contains(query.toLowerCase()),
              )
              .toList();
    final due = dueAsync.valueOrNull?.due ?? 0;

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
                    folderStack: folderStack,
                    onTapRoot: onJumpToRoot,
                    onTapFolder: onJumpToFolder,
                    trailingLabel: deckName,
                  ),
                  const SizedBox(height: 16),
                  Text(deckName, style: theme.textTheme.headlineMedium),
                  const SizedBox(height: 4),
                  Text(
                    '${cards.length} card${cards.length == 1 ? '' : 's'} · $due due',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Expanded(
                        child: GlassButton(
                          onPressed: cards.isEmpty
                              ? null
                              : () => Navigator.of(context).push(
                                  MaterialPageRoute(
                                    builder: (_) => StudySessionPage(deckId: deckId),
                                  ),
                                ),
                          icon: const Icon(PhosphorIconsRegular.playCircle),
                          label: 'Study',
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: GlassButton(
                          onPressed: cards.isEmpty
                              ? null
                              : () => Navigator.of(context).push(
                                  MaterialPageRoute(
                                    builder: (_) => StudyCramPage(deckId: deckId),
                                  ),
                                ),
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
                              ref.read(studySearchQueryProvider.notifier).state = v,
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
                        tooltip: 'Import JSON',
                        icon: const Icon(PhosphorIconsRegular.uploadSimple),
                        onPressed: () => showStudyImportJsonModal(context, ref, deckId),
                      ),
                      const SizedBox(width: 8),
                      GlassButton(
                        dense: true,
                        tooltip: multiSelect ? 'Exit selection' : 'Select cards',
                        icon: const Icon(PhosphorIconsRegular.checkSquare),
                        color: multiSelect ? theme.colorScheme.primary : null,
                        onPressed: () {
                          final next = !multiSelect;
                          ref.read(studyMultiSelectEnabledProvider.notifier).state = next;
                          if (!next) {
                            ref.read(studySelectedCardIdsProvider.notifier).state = {};
                          }
                        },
                      ),
                      const SizedBox(width: 8),
                      GlassButton(
                        dense: true,
                        label: 'Add card',
                        icon: const Icon(PhosphorIconsRegular.plus),
                        onPressed: () => showStudyCardEditorModal(context, ref, deckId: deckId),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Expanded(
                    child: filtered.isEmpty
                        ? Center(
                            child: Text(
                              cards.isEmpty
                                  ? 'No cards yet — tap "Add card" to create one.'
                                  : 'No cards match "$query".',
                              style: theme.textTheme.bodyMedium?.copyWith(
                                color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
                              ),
                            ),
                          )
                        : ListView.builder(
                            padding: const EdgeInsets.only(bottom: 96),
                            itemCount: filtered.length,
                            itemBuilder: (context, index) {
                              final card = filtered[index];
                              return GestureDetector(
                                onTap: multiSelect
                                    ? () => _toggleSelected(ref, card.id, !selected.contains(card.id))
                                    : () => showStudyCardEditorModal(
                                        context,
                                        ref,
                                        deckId: deckId,
                                        existing: card,
                                      ),
                                behavior: multiSelect
                                    ? HitTestBehavior.opaque
                                    : HitTestBehavior.deferToChild,
                                child: StudyCardRow(
                                  card: card,
                                  multiSelectEnabled: multiSelect,
                                  selected: selected.contains(card.id),
                                  onToggleSelected: (v) => _toggleSelected(ref, card.id, v),
                                  onLongPress: () {
                                    ref.read(studyMultiSelectEnabledProvider.notifier).state =
                                        true;
                                    _toggleSelected(ref, card.id, true);
                                  },
                                ),
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

  void _toggleSelected(WidgetRef ref, String cardId, bool value) {
    final notifier = ref.read(studySelectedCardIdsProvider.notifier);
    final next = {...notifier.state};
    if (value) {
      next.add(cardId);
    } else {
      next.remove(cardId);
    }
    notifier.state = next;
  }
}

class _StudySelectionBar extends ConsumerWidget {
  const _StudySelectionBar({required this.deckId, required this.selected});

  final String deckId;
  final Set<String> selected;

  Future<void> _duplicate(WidgetRef ref) async {
    final repo = ref.read(studyRepositoryProvider);
    await repo.duplicateCards(selected.toList());
    ref.invalidate(studyCardsProvider);
    ref.invalidate(studyDeckStatsProvider);
    ref.read(studySelectedCardIdsProvider.notifier).state = {};
    ref.read(studyMultiSelectEnabledProvider.notifier).state = false;
  }

  Future<void> _delete(WidgetRef ref) async {
    final repo = ref.read(studyRepositoryProvider);
    final remoteSync = ref.read(remoteSyncServiceProvider);
    for (final id in selected) {
      await repo.softDeleteCard(id);
      final card = await repo.getCard(id);
      if (card != null) remoteSync.pushStudyCard(card);
    }
    ref.invalidate(studyCardsProvider);
    ref.invalidate(studyDeckStatsProvider);
    ref.read(studySelectedCardIdsProvider.notifier).state = {};
    ref.read(studyMultiSelectEnabledProvider.notifier).state = false;
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
              onPressed: () => showStudyMoveModal(context, ref, cardIds: selected.toList()),
            ),
            const SizedBox(width: 8),
            GlassButton(
              dense: true,
              label: 'Duplicate',
              icon: const Icon(PhosphorIconsRegular.copySimple),
              onPressed: () => _duplicate(ref),
            ),
            const SizedBox(width: 8),
            GlassButton(
              dense: true,
              label: 'Delete',
              icon: const Icon(PhosphorIconsRegular.trash),
              color: theme.colorScheme.error,
              onPressed: () => _delete(ref),
            ),
          ],
        ),
      ),
    );
  }
}

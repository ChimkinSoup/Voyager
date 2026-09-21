import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/platform/platform_info.dart';
import 'package:voyager/core/widgets/glass_surface.dart';
import 'package:voyager/domain/models/study_models.dart';
import 'package:voyager/features/study/study_actions.dart';
import 'package:voyager/features/study/study_breadcrumb.dart';
import 'package:voyager/features/study/study_providers.dart';

/// Cascading folder browser for moving multi-selected cards. Per STUDY.md's
/// Nested Folders section (as clarified: cards only ever live inside a
/// deck, never loose in a folder) tapping a folder drills into it and
/// tapping a deck immediately confirms the move — there's no separate
/// "Move Here" step for folders.
Future<void> showStudyMoveModal(
  BuildContext context,
  WidgetRef ref, {
  required List<String> cardIds,
}) {
  return showVoyagerModal<void>(
    context: context,
    builder: (ctx) => ProviderScope(
      parent: ProviderScope.containerOf(context),
      child: _StudyMoveModal(cardIds: cardIds),
    ),
  );
}

class _StudyMoveModal extends ConsumerStatefulWidget {
  const _StudyMoveModal({required this.cardIds});

  final List<String> cardIds;

  @override
  ConsumerState<_StudyMoveModal> createState() => _StudyMoveModalState();
}

class _StudyMoveModalState extends ConsumerState<_StudyMoveModal> {
  List<String> _stack = [];
  bool _moving = false;

  Future<void> _selectDeck(StudyDeck deck) async {
    if (_moving) return;
    setState(() => _moving = true);
    try {
      final repo = ref.read(studyRepositoryProvider);
      await repo.moveCards(widget.cardIds, deck.id);
      final remoteSync = ref.read(remoteSyncServiceProvider);
      final movedCards = <StudyCard>[];
      for (final id in widget.cardIds) {
        final card = await repo.getCard(id);
        if (card != null) movedCards.add(card);
      }
      await remoteSync.pushStudyCardsBatch(movedCards);
      // Both card lists and both stat providers — a move changes which deck
      // each card counts towards, and the Hub's flattened list holds the
      // pre-move `deckId` until it is refetched.
      invalidateStudyCards(ref);
      ref.read(studySelectedCardIdsProvider.notifier).state = {};
      ref.read(studyMultiSelectEnabledProvider.notifier).state = false;
      if (mounted) Navigator.of(context).pop();
    } catch (error, stackTrace) {
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: error,
          stack: stackTrace,
          library: 'study move',
          context: ErrorDescription('while moving into "${deck.name}"'),
        ),
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not move the cards.')),
        );
      }
    } finally {
      // Cleared however the write ended, or every deck row in the sheet stays
      // disabled with nothing saying why.
      if (mounted) setState(() => _moving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final parentId = _stack.isEmpty ? null : _stack.last;
    final foldersAsync = ref.watch(studyFoldersProvider(parentId));
    final decksAsync = ref.watch(studyDecksProvider(parentId));
    final folders = [...foldersAsync.valueOrNull ?? const []]
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    final decks = [...decksAsync.valueOrNull ?? const []]
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));

    return SizedBox(
      height: MediaQuery.of(context).size.height * 0.7,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 10, 20, 8),
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
                      margin: const EdgeInsets.only(bottom: 16),
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
                    Text(
                      'Move ${widget.cardIds.length} card${widget.cardIds.length == 1 ? '' : 's'}',
                      style: theme.textTheme.titleMedium,
                    ),
                    const Spacer(),
                    IconButton(
                      onPressed: Navigator.of(context).pop,
                      icon: const Icon(PhosphorIconsRegular.x, size: 18),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                StudyBreadcrumbRow(
                  folderStack: _stack,
                  onTapRoot: () => setState(() => _stack = []),
                  onTapFolder: (i) =>
                      setState(() => _stack = _stack.sublist(0, i + 1)),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: ListView(
              children: [
                for (final folder in folders)
                  ListTile(
                    leading: Icon(
                      PhosphorIconsRegular.folder,
                      color: theme.colorScheme.primary,
                    ),
                    title: Text(folder.name),
                    trailing: const Icon(
                      PhosphorIconsRegular.caretRight,
                      size: 16,
                    ),
                    onTap: () =>
                        setState(() => _stack = [..._stack, folder.id]),
                  ),
                for (final deck in decks)
                  ListTile(
                    enabled: !_moving,
                    leading: Icon(
                      PhosphorIconsRegular.cardsThree,
                      color: theme.colorScheme.secondary,
                    ),
                    title: Text(deck.name),
                    onTap: () => _selectDeck(deck),
                  ),
                if (folders.isEmpty && decks.isEmpty)
                  Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      'No folders or decks here.',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurface.withValues(
                          alpha: 0.5,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

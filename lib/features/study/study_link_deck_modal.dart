import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/platform/platform_info.dart';
import 'package:voyager/core/widgets/glass_surface.dart';
import 'package:voyager/domain/models/study_models.dart';
import 'package:voyager/domain/services/study_deck_graph.dart';
import 'package:voyager/features/study/study_breadcrumb.dart';
import 'package:voyager/features/study/study_deck_link_actions.dart';

/// Picks a deck to link into [parentDeckId] (STUDY_DECK_LINKS_HLD.md §5.7).
/// The same cascading browser as moving cards: a folder drills in, a deck
/// links. The parent itself is left out; a deck already linked, or one that
/// would close a loop, is shown but cannot be picked, with the reason.
Future<void> showStudyLinkDeckModal(
  BuildContext context, {
  required String parentDeckId,
}) {
  return showVoyagerModal<void>(
    context: context,
    builder: (ctx) => ProviderScope(
      parent: ProviderScope.containerOf(context),
      child: _StudyLinkDeckModal(parentDeckId: parentDeckId),
    ),
  );
}

class _StudyLinkDeckModal extends ConsumerStatefulWidget {
  const _StudyLinkDeckModal({required this.parentDeckId});

  final String parentDeckId;

  @override
  ConsumerState<_StudyLinkDeckModal> createState() =>
      _StudyLinkDeckModalState();
}

class _StudyLinkDeckModalState extends ConsumerState<_StudyLinkDeckModal> {
  List<String> _stack = [];
  bool _linking = false;

  Future<void> _link(StudyDeck deck) async {
    if (_linking) return;
    setState(() => _linking = true);
    try {
      final linked = await linkStudyDeck(
        ref,
        parentDeckId: widget.parentDeckId,
        childDeckId: deck.id,
      );
      if (!mounted) return;
      if (linked) {
        Navigator.of(context).pop();
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Linking "${deck.name}" would create a loop.'),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _linking = false);
    }
  }

  /// Why [deck] can't be picked, or null if it can.
  String? _blocked(StudyDeck deck, StudyDeckGraph graph) {
    final linked = graph
        .linksFrom(widget.parentDeckId)
        .any((link) => link.childDeckId == deck.id);
    if (linked) return 'Already linked';
    if (graph.wouldCreateCycle(widget.parentDeckId, deck.id)) {
      return 'Would create a loop';
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final parentId = _stack.isEmpty ? null : _stack.last;
    final graph =
        ref.watch(studyDeckGraphProvider).valueOrNull ?? StudyDeckGraph.empty;
    final folders = [
      ...ref.watch(studyFoldersProvider(parentId)).valueOrNull ?? const [],
    ]..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    final decks = [
      for (final deck
          in ref.watch(studyDecksProvider(parentId)).valueOrNull ?? const [])
        if (deck.id != widget.parentDeckId) deck,
    ]..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    final muted = theme.colorScheme.onSurface.withValues(alpha: 0.5);

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
                    Text('Link a deck', style: theme.textTheme.titleMedium),
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
                    onTap: () => setState(() => _stack = [..._stack, folder.id]),
                  ),
                for (final deck in decks)
                  Builder(
                    builder: (context) {
                      final reason = _blocked(deck, graph);
                      return ListTile(
                        enabled: reason == null && !_linking,
                        leading: Icon(
                          PhosphorIconsRegular.cardsThree,
                          color: theme.colorScheme.secondary,
                        ),
                        title: Text(deck.name),
                        subtitle: reason == null
                            ? null
                            : Text(
                                reason,
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: muted,
                                ),
                              ),
                        onTap: () => _link(deck),
                      );
                    },
                  ),
                if (folders.isEmpty && decks.isEmpty)
                  Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      'No folders or decks here.',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: muted,
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

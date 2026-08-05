import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/theme/voyager_theme.dart';
import 'package:voyager/core/utils/ids.dart';
import 'package:voyager/core/widgets/glass_button.dart';
import 'package:voyager/core/widgets/glass_surface.dart';
import 'package:voyager/domain/models/study_models.dart';
import 'package:voyager/features/study/study_breadcrumb.dart';
import 'package:voyager/features/study/study_deck_workbench_page.dart';
import 'package:voyager/features/study/study_name_modal.dart';
import 'package:voyager/features/study/study_providers.dart';

/// Global Study Hub: a centered dashboard of review stats above a library
/// grid of folders/decks, plus the zoom transition into the Deck Workbench.
class StudyPage extends ConsumerStatefulWidget {
  const StudyPage({super.key});

  @override
  ConsumerState<StudyPage> createState() => _StudyPageState();
}

class _StudyPageState extends ConsumerState<StudyPage>
    with SingleTickerProviderStateMixin {
  late final AnimationController _zoom = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 420),
  );
  final _stackKey = GlobalKey();

  Rect? _sourceRect;
  String? _openDeckId;
  String? _openDeckName;

  @override
  void dispose() {
    _zoom.dispose();
    super.dispose();
  }

  void _openDeck(StudyDeck deck, RenderBox tileBox) {
    final stackBox = _stackKey.currentContext!.findRenderObject() as RenderBox;
    final origin = tileBox.localToGlobal(Offset.zero, ancestor: stackBox);
    setState(() {
      _openDeckId = deck.id;
      _openDeckName = deck.name;
      _sourceRect = origin & tileBox.size;
    });
    ref.read(studyActiveDeckIdProvider.notifier).state = deck.id;
    _zoom.forward(from: 0);
  }

  void _closeDeck() {
    _zoom.reverse(from: 1).whenComplete(() {
      if (!mounted) return;
      setState(() {
        _openDeckId = null;
        _openDeckName = null;
        _sourceRect = null;
      });
      ref.read(studyActiveDeckIdProvider.notifier).state = null;
    });
  }

  void _jumpToRoot() {
    ref.read(studyBreadcrumbStackProvider.notifier).state = [];
    if (_openDeckId != null) _closeDeck();
  }

  void _jumpToFolderIndex(int index) {
    final stack = ref.read(studyBreadcrumbStackProvider);
    ref.read(studyBreadcrumbStackProvider.notifier).state =
        stack.sublist(0, index + 1);
    if (_openDeckId != null) _closeDeck();
  }

  Future<void> _createFolderOrDeck(bool isFolder) async {
    final name = await showStudyNameModal(
      context,
      title: isFolder ? 'New folder' : 'New deck',
      hintText: isFolder ? 'e.g. Biology' : 'e.g. Midterm 1',
    );
    if (name == null) return;
    final stack = ref.read(studyBreadcrumbStackProvider);
    final parentId = stack.isEmpty ? null : stack.last;
    final now = utcNow();
    final repo = ref.read(studyRepositoryProvider);
    final remoteSync = ref.read(remoteSyncServiceProvider);
    if (isFolder) {
      final folder = StudyFolder(
        id: newId(),
        createdAt: now,
        updatedAt: now,
        name: name,
        parentFolderId: parentId,
      );
      await repo.upsertFolder(folder);
      remoteSync.pushStudyFolder(folder);
      ref.invalidate(studyFoldersProvider);
    } else {
      final deck = StudyDeck(
        id: newId(),
        createdAt: now,
        updatedAt: now,
        name: name,
        parentFolderId: parentId,
      );
      await repo.upsertDeck(deck);
      remoteSync.pushStudyDeck(deck);
      ref.invalidate(studyDecksProvider);
    }
  }

  void _showCreateMenu() {
    showVoyagerSheet<void>(
      context: context,
      builder: (ctx) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            GlassButton(
              onPressed: () {
                Navigator.of(ctx).pop();
                _createFolderOrDeck(true);
              },
              icon: const Icon(PhosphorIconsRegular.folderPlus),
              label: 'New folder',
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 14),
            ),
            const SizedBox(height: 12),
            GlassButton(
              onPressed: () {
                Navigator.of(ctx).pop();
                _createFolderOrDeck(false);
              },
              icon: const Icon(PhosphorIconsRegular.stackPlus),
              label: 'New deck',
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 14),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final stack = ref.watch(studyBreadcrumbStackProvider);

    return Scaffold(
      backgroundColor: Colors.transparent,
      floatingActionButton: _openDeckId == null
          ? GlassButton(
              tooltip: 'New folder or deck',
              onPressed: _showCreateMenu,
              icon: const Icon(PhosphorIconsRegular.plus),
              width: 56,
              height: 56,
              borderRadius: BorderRadius.circular(28),
              elevation: 3,
            )
          : null,
      body: LayoutBuilder(
        builder: (context, constraints) {
          return Stack(
            key: _stackKey,
            children: [
              AnimatedBuilder(
                animation: _zoom,
                builder: (context, child) {
                  final fadeT = _zoom.value.clamp(0.0, 1.0);
                  return Opacity(
                    opacity: 1 - fadeT,
                    child: IgnorePointer(ignoring: fadeT > 0, child: child),
                  );
                },
                child: _HubContent(
                  folderStack: stack,
                  onOpenDeck: _openDeck,
                  onTapRoot: _jumpToRoot,
                  onTapFolder: _jumpToFolderIndex,
                ),
              ),
              if (_openDeckId != null)
                AnimatedBuilder(
                  animation: _zoom,
                  builder: (context, _) {
                    final t = Curves.easeInOutCubic.transform(_zoom.value);
                    final full = Offset.zero & constraints.biggest;
                    final rect = Rect.lerp(_sourceRect, full, t) ?? full;
                    final radius = BorderRadius.lerp(
                      BorderRadius.circular(18),
                      BorderRadius.zero,
                      t,
                    )!;
                    return Positioned.fromRect(
                      rect: rect,
                      child: Opacity(
                        opacity: t.clamp(0.0, 1.0),
                        child: ClipRRect(
                          borderRadius: radius,
                          child: StudyDeckWorkbenchPage(
                            deckId: _openDeckId!,
                            folderStack: stack,
                            deckNameHint: _openDeckName,
                            onBack: _closeDeck,
                            onJumpToRoot: _jumpToRoot,
                            onJumpToFolder: _jumpToFolderIndex,
                          ),
                        ),
                      ),
                    );
                  },
                ),
            ],
          );
        },
      ),
    );
  }
}

class _HubContent extends ConsumerWidget {
  const _HubContent({
    required this.folderStack,
    required this.onOpenDeck,
    required this.onTapRoot,
    required this.onTapFolder,
  });

  final List<String> folderStack;
  final void Function(StudyDeck deck, RenderBox tileBox) onOpenDeck;
  final VoidCallback onTapRoot;
  final ValueChanged<int> onTapFolder;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final parentId = folderStack.isEmpty ? null : folderStack.last;
    final statsAsync = ref.watch(studyStatsProvider);
    final foldersAsync = ref.watch(studyFoldersProvider(parentId));
    final decksAsync = ref.watch(studyDecksProvider(parentId));

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 24, 24, 24),
        child: Column(
          children: [
            _StudyStatsHeader(stats: statsAsync.valueOrNull),
            const SizedBox(height: 20),
            Align(
              alignment: Alignment.centerLeft,
              child: StudyBreadcrumbRow(
                folderStack: folderStack,
                onTapRoot: onTapRoot,
                onTapFolder: onTapFolder,
              ),
            ),
            const SizedBox(height: 12),
            Expanded(
              child: _StudyLibraryGrid(
                folders: foldersAsync.valueOrNull ?? const [],
                decks: decksAsync.valueOrNull ?? const [],
                loading: foldersAsync.isLoading || decksAsync.isLoading,
                onOpenFolder: (folder) {
                  ref.read(studyBreadcrumbStackProvider.notifier).state = [
                    ...folderStack,
                    folder.id,
                  ];
                },
                onOpenDeck: onOpenDeck,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _StudyStatsHeader extends StatelessWidget {
  const _StudyStatsHeader({required this.stats});

  final ({int pendingToday, int reviewedToday, int reviewedTotal})? stats;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    Widget stat(String label, int? value) {
      return Column(
        children: [
          Text(
            value?.toString() ?? '—',
            style: theme.textTheme.headlineMedium?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            label,
            style: theme.textTheme.labelMedium?.copyWith(
              color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
            ),
          ),
        ],
      );
    }

    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        stat('Due today', stats?.pendingToday),
        const SizedBox(width: 40),
        stat('Reviewed today', stats?.reviewedToday),
        const SizedBox(width: 40),
        stat('Reviewed total', stats?.reviewedTotal),
      ],
    );
  }
}

class _StudyLibraryGrid extends StatelessWidget {
  const _StudyLibraryGrid({
    required this.folders,
    required this.decks,
    required this.loading,
    required this.onOpenFolder,
    required this.onOpenDeck,
  });

  final List<StudyFolder> folders;
  final List<StudyDeck> decks;
  final bool loading;
  final ValueChanged<StudyFolder> onOpenFolder;
  final void Function(StudyDeck deck, RenderBox tileBox) onOpenDeck;

  @override
  Widget build(BuildContext context) {
    if (!loading && folders.isEmpty && decks.isEmpty) {
      final theme = Theme.of(context);
      return Center(
        child: Text(
          'Nothing here yet — use the + button to add a folder or deck.',
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
          ),
        ),
      );
    }

    final sortedFolders = [...folders]
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    final sortedDecks = [...decks]
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));

    return GridView.builder(
      padding: const EdgeInsets.only(bottom: 96),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 220,
        mainAxisSpacing: 16,
        crossAxisSpacing: 16,
        childAspectRatio: 1.15,
      ),
      itemCount: sortedFolders.length + sortedDecks.length,
      itemBuilder: (context, index) {
        if (index < sortedFolders.length) {
          final folder = sortedFolders[index];
          return _FolderTile(folder: folder, onTap: () => onOpenFolder(folder));
        }
        final deck = sortedDecks[index - sortedFolders.length];
        return _DeckTile(deck: deck, onTap: (box) => onOpenDeck(deck, box));
      },
    );
  }
}

class _FolderTile extends StatelessWidget {
  const _FolderTile({required this.folder, required this.onTap});

  final StudyFolder folder;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Icon(
                PhosphorIconsRegular.folder,
                size: 32,
                color: theme.colorScheme.primary,
              ),
              Text(
                folder.name,
                style: theme.textTheme.titleSmall,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DeckTile extends ConsumerStatefulWidget {
  const _DeckTile({required this.deck, required this.onTap});

  final StudyDeck deck;
  final void Function(RenderBox tileBox) onTap;

  @override
  ConsumerState<_DeckTile> createState() => _DeckTileState();
}

class _DeckTileState extends ConsumerState<_DeckTile> {
  final _boxKey = GlobalKey();

  void _handleTap() {
    final box = _boxKey.currentContext!.findRenderObject() as RenderBox;
    widget.onTap(box);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final vc = VoyagerColors.of(context);
    final statsAsync = ref.watch(studyDeckStatsProvider(widget.deck.id));
    final due = statsAsync.valueOrNull?.due;

    return Card(
      key: _boxKey,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: _handleTap,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Stack(
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Icon(
                    PhosphorIconsRegular.cardsThree,
                    size: 32,
                    color: theme.colorScheme.secondary,
                  ),
                  Text(
                    widget.deck.name,
                    style: theme.textTheme.titleSmall,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
              if (due != null && due > 0)
                Positioned(
                  top: 0,
                  right: 0,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.primary,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      '$due',
                      style: theme.textTheme.labelSmall?.copyWith(color: vc.onAccent),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

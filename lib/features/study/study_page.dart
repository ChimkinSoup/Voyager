import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/motion/motion.dart';
import 'package:voyager/core/theme/voyager_theme.dart';
import 'package:voyager/core/utils/ids.dart';
import 'package:voyager/core/widgets/context_menu.dart';
import 'package:voyager/core/widgets/contextual_popover.dart';
import 'package:voyager/core/widgets/glass_button.dart';
import 'package:voyager/core/widgets/palette_color_picker.dart';
import 'package:voyager/domain/models/study_models.dart';
import 'package:voyager/features/study/study_actions.dart';
import 'package:voyager/features/study/study_breadcrumb.dart';
import 'package:voyager/features/study/study_debug_generator.dart';
import 'package:voyager/features/study/study_deck_workbench_page.dart';
import 'package:voyager/features/study/study_name_modal.dart';
import 'package:voyager/features/study/study_providers.dart';
import 'package:voyager/features/study/study_session_page.dart';


/// Global Study Hub: a centered dashboard of review stats above a library
/// grid of folders/decks, plus the crossfade into the Deck Workbench.
class StudyPage extends ConsumerStatefulWidget {
  const StudyPage({super.key});

  @override
  ConsumerState<StudyPage> createState() => _StudyPageState();
}

class _StudyPageState extends ConsumerState<StudyPage>
    with SingleTickerProviderStateMixin {
  late final AnimationController _zoom = AnimationController(
    vsync: this,
    duration: kVoyagerCrossfadeDuration,
  );

  String? _openDeckId;
  String? _openDeckName;

  @override
  void dispose() {
    _zoom.dispose();
    super.dispose();
  }

  /// True while the Workbench is fading back to the Hub. The Hub stays live
  /// through this so a close can be caught and reversed mid-flight.
  bool get _closing => _zoom.status == AnimationStatus.reverse;

  void _openDeck(StudyDeck deck) {
    // Re-tapping the deck that is currently closing resumes it: forward()
    // picks up from the controller's live value, so the Workbench fades back
    // in from wherever the close had reached, with no cut.
    if (_closing && deck.id == _openDeckId) {
      _zoom.forward();
      return;
    }
    // A *different* deck during a close is a new destination — finish the
    // close outright rather than crossfading between two unrelated pages.
    if (_closing) _zoom.value = 0;

    setState(() {
      _openDeckId = deck.id;
      _openDeckName = deck.name;
    });
    ref.read(studyActiveDeckIdProvider.notifier).state = deck.id;
    // The Workbench's control-bar state outlives the Workbench itself, which
    // closing a deck unmounts — so anything left here follows the user into
    // the next deck it doesn't belong to. A stale query filters cards behind
    // a blank field; a stale selection is worse, since the bulk actions take
    // card ids without scoping them to the open deck, so "3 selected" over
    // unchecked rows would delete or move the *previous* deck's cards.
    //
    // Cleared on the way in rather than on the way out because pushing a
    // Study/Cram route leaves the Workbench mounted — that round trip should
    // come back to the search and selection still in place.
    ref.read(studySearchQueryProvider.notifier).state = '';
    ref.read(studySelectedCardIdsProvider.notifier).state = {};
    ref.read(studyMultiSelectEnabledProvider.notifier).state = false;
    // No `from:` — snapping to 0 before playing would flash to the wrong
    // endpoint if this interrupts an in-flight close.
    _zoom.forward();
  }

  void _closeDeck() {
    // No `from:` — see _openDeck.
    _zoom.reverse().whenComplete(() {
      if (!mounted) return;
      setState(() {
        _openDeckId = null;
        _openDeckName = null;
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

  Future<void> _createFolderOrDeck(bool isFolder) {
    final stack = ref.read(studyBreadcrumbStackProvider);
    return createStudyFolderOrDeck(
      context,
      ref,
      isFolder: isFolder,
      parentFolderId: stack.isEmpty ? null : stack.last,
    );
  }

  /// Anchored to the button that opened it rather than raised from the bottom
  /// edge: creating a folder is neither modal nor destructive, so it keeps its
  /// spatial tie to the "+" and skips the scrim.
  void _showCreateMenu(BuildContext buttonContext) {
    showContextualPopover<void>(
      context: context,
      buttonContext: buttonContext,
      width: 232,
      builder: (ctx) => _CreateMenu(
        onNewFolder: () => _createFolderOrDeck(true),
        onNewDeck: () => _createFolderOrDeck(false),
        onPopulateDebug: () {
          final stack = ref.read(studyBreadcrumbStackProvider);
          final parentId = stack.isEmpty ? null : stack.last;
          populateDebugStudyDeck(context, ref, parentFolderId: parentId);
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final stack = ref.watch(studyBreadcrumbStackProvider);

    return Scaffold(
      backgroundColor: Colors.transparent,
      floatingActionButton: _openDeckId == null
          ? Builder(
              builder: (fabContext) => GlassButton(
                tooltip: 'New folder or deck',
                onPressed: () => _showCreateMenu(fabContext),
                icon: const Icon(PhosphorIconsRegular.plus),
                width: 56,
                height: 56,
                borderRadius: BorderRadius.circular(28),
                elevation: 3,
              ),
            )
          : null,
      body: Builder(
        builder: (context) {
          final reducedMotion = VoyagerMotion.reduced(context);
          return Stack(
            children: [
              AnimatedBuilder(
                animation: _zoom,
                builder: (context, child) {
                  final t = _zoom.value.clamp(0.0, 1.0);
                  // Live through a close, so a fading Workbench can be caught
                  // and reopened; dead once the Workbench has committed to
                  // covering the screen.
                  final locked =
                      _zoom.status == AnimationStatus.forward || t == 1;
                  final faded = Opacity(
                    opacity: 1 - t,
                    child: IgnorePointer(ignoring: locked, child: child),
                  );
                  if (reducedMotion || t == 0) return faded;
                  return Transform.scale(
                    scale: 1 - kVoyagerCrossfadeRecede * t,
                    child: faded,
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
                    final t = _zoom.value.clamp(0.0, 1.0);
                    // Mirror of the Hub's close: fade in while enlarging from
                    // the recessed scale up to full size.
                    final faded = Opacity(
                      opacity: t,
                      child: IgnorePointer(
                        ignoring: t == 0,
                        child: StudyDeckWorkbenchPage(
                          deckId: _openDeckId!,
                          folderStack: stack,
                          deckNameHint: _openDeckName,
                          onBack: _closeDeck,
                          onJumpToRoot: _jumpToRoot,
                          onJumpToFolder: _jumpToFolderIndex,
                        ),
                      ),
                    );
                    if (reducedMotion || t == 1) {
                      return Positioned.fill(child: faded);
                    }
                    return Positioned.fill(
                      child: Transform.scale(
                        scale: 1 - kVoyagerCrossfadeRecede * (1 - t),
                        child: faded,
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

/// The "+" menu's contents. "Populate debug deck" sits below a divider as a
/// plain link rather than a third equal button — it is a development tool,
/// not one of the two things this menu is for.
class _CreateMenu extends StatelessWidget {
  const _CreateMenu({
    required this.onNewFolder,
    required this.onNewDeck,
    required this.onPopulateDebug,
  });

  final VoidCallback onNewFolder;
  final VoidCallback onNewDeck;
  final VoidCallback onPopulateDebug;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final vc = VoyagerColors.of(context);

    void run(VoidCallback action) {
      Navigator.of(context).pop();
      action();
    }

    return Padding(
      padding: const EdgeInsets.all(10),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          GlassButton(
            onPressed: () => run(onNewFolder),
            icon: const Icon(PhosphorIconsRegular.folderPlus),
            label: 'New folder',
            width: double.infinity,
            padding: const EdgeInsets.symmetric(vertical: 12),
          ),
          const SizedBox(height: 8),
          GlassButton(
            onPressed: () => run(onNewDeck),
            icon: const Icon(PhosphorIconsRegular.stackPlus),
            label: 'New deck',
            width: double.infinity,
            padding: const EdgeInsets.symmetric(vertical: 12),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Divider(height: 1, color: vc.hairline),
          ),
          InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: () => run(onPopulateDebug),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    PhosphorIconsRegular.bug,
                    size: 13,
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    'Populate debug deck',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _HubContent extends ConsumerStatefulWidget {
  const _HubContent({
    required this.folderStack,
    required this.onOpenDeck,
    required this.onTapRoot,
    required this.onTapFolder,
  });

  final List<String> folderStack;
  final ValueChanged<StudyDeck> onOpenDeck;
  final VoidCallback onTapRoot;
  final ValueChanged<int> onTapFolder;

  @override
  ConsumerState<_HubContent> createState() => _HubContentState();
}

class _HubContentState extends ConsumerState<_HubContent> {
  /// +1 when the last navigation went deeper into the tree, -1 when it came
  /// back out. The grid enters from the side it is travelling towards and
  /// leaves towards the other, so drilling in and stepping back out are
  /// visibly opposite rather than the same fade twice.
  int _direction = 1;

  @override
  void didUpdateWidget(covariant _HubContent oldWidget) {
    super.didUpdateWidget(oldWidget);
    final was = oldWidget.folderStack.length;
    final now = widget.folderStack.length;
    if (now != was) _direction = now > was ? 1 : -1;
  }

  @override
  Widget build(BuildContext context) {
    final parentId = widget.folderStack.isEmpty
        ? null
        : widget.folderStack.last;
    final foldersAsync = ref.watch(studyFoldersProvider(parentId));
    final decksAsync = ref.watch(studyDecksProvider(parentId));
    final reducedMotion = VoyagerMotion.reduced(context);

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 24, 24, 24),
        child: Column(
          children: [
            const _StudyStatsHeader(),
            const SizedBox(height: 20),
            Align(
              alignment: Alignment.centerLeft,
              child: StudyBreadcrumbRow(
                folderStack: widget.folderStack,
                onTapRoot: widget.onTapRoot,
                onTapFolder: widget.onTapFolder,
              ),
            ),
            const SizedBox(height: 12),
            Expanded(
              child: AnimatedSwitcher(
                duration: reducedMotion
                    ? VoyagerMotion.crossfade
                    : const Duration(milliseconds: 260),
                switchInCurve: reducedMotion
                    ? Curves.easeOut
                    : VoyagerSpring.moveCurve,
                switchOutCurve: reducedMotion
                    ? Curves.easeOut
                    : VoyagerSpring.moveCurve,
                // Both grids occupy the full area while they cross, so the
                // outgoing one does not collapse to the incoming one's size
                // partway through the slide. The outgoing one is also the one
                // on top — see [transitionBuilder].
                layoutBuilder: (current, previous) => Stack(
                  fit: StackFit.expand,
                  children: [?current, ...previous],
                ),
                transitionBuilder: (child, animation) {
                  final incoming = child.key == ValueKey(parentId);
                  // Only the departing grid fades. An opacity layer around the
                  // arriving one would confine what a BackdropFilter inside it
                  // can sample, so its glass would frost an empty backdrop for
                  // the whole transition and snap when the animation ended.
                  final result = incoming
                      ? child
                      : FadeTransition(opacity: animation, child: child);
                  if (reducedMotion) return result;
                  final offset = incoming ? _direction * 0.06 : -_direction * 0.06;
                  return SlideTransition(
                    position: Tween<Offset>(
                      begin: Offset(offset, 0),
                      end: Offset.zero,
                    ).animate(animation),
                    child: result,
                  );
                },
                child: _StudyLibraryGrid(
                  // Identity is the folder level, so changing levels builds a
                  // new grid with its own scroll position instead of silently
                  // inheriting where the previous level was scrolled to.
                  key: ValueKey(parentId),
                  storageKey: PageStorageKey('study-grid-${parentId ?? 'root'}'),
                  folders: foldersAsync.valueOrNull ?? const [],
                  decks: decksAsync.valueOrNull ?? const [],
                  loading: foldersAsync.isLoading || decksAsync.isLoading,
                  onNewFolder: () => _create(isFolder: true),
                  onNewDeck: () => _create(isFolder: false),
                  onOpenFolder: (folder) {
                    ref.read(studyBreadcrumbStackProvider.notifier).state = [
                      ...widget.folderStack,
                      folder.id,
                    ];
                  },
                  onOpenDeck: widget.onOpenDeck,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// The empty state offers the two things the "+" button offers, so a first
  /// run does not have to be told where to look for them.
  Future<void> _create({required bool isFolder}) => createStudyFolderOrDeck(
    context,
    ref,
    isFolder: isFolder,
    parentFolderId: widget.folderStack.isEmpty
        ? null
        : widget.folderStack.last,
  );
}

/// Prompts for a name and creates a folder or deck under [parentFolderId].
/// Shared by the "+" menu and the empty state, which offer the same two
/// actions and must not drift apart.
Future<void> createStudyFolderOrDeck(
  BuildContext context,
  WidgetRef ref, {
  required bool isFolder,
  required String? parentFolderId,
}) async {
  final name = await showStudyNameModal(
    context,
    title: isFolder ? 'New folder' : 'New deck',
    hintText: isFolder ? 'e.g. Biology' : 'e.g. Midterm 1',
  );
  if (name == null) return;
  final now = utcNow();
  final repo = ref.read(studyRepositoryProvider);
  final remoteSync = ref.read(remoteSyncServiceProvider);
  if (isFolder) {
    final folder = StudyFolder(
      id: newId(),
      createdAt: now,
      updatedAt: now,
      name: name,
      parentFolderId: parentFolderId,
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
      parentFolderId: parentFolderId,
    );
    await repo.upsertDeck(deck);
    remoteSync.pushStudyDeck(deck);
    ref.invalidate(studyDecksProvider);
  }
}

/// The Hub's header: everything due across the library, as a button that
/// studies it. The count is the page's most prominent number, so the control
/// that acts on it is the number itself rather than a stat sitting next to a
/// grid of decks you would otherwise have to pick through by hand.
class _StudyStatsHeader extends ConsumerWidget {
  const _StudyStatsHeader();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final statsAsync = ref.watch(studyStatsProvider);
    final cardsAsync = ref.watch(studyAllCardsProvider);
    final stats = statsAsync.valueOrNull;

    // Due ids and the due count come from the same list, so the button can
    // never offer to study a number of cards different from the one it shows.
    final now = DateTime.now().toUtc();
    final dueIds = {
      for (final card in cardsAsync.valueOrNull ?? const <StudyCard>[])
        if (!card.dueAt.isAfter(now)) card.id,
    };
    final ready = cardsAsync.hasValue;

    return Column(
      children: [
        GlassButton(
          tooltip: dueIds.isEmpty
              ? 'Nothing is due right now'
              : 'Review every due card, across all decks',
          onPressed: dueIds.isEmpty
              ? null
              : () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => StudySessionPage(cardIds: dueIds),
                  ),
                ),
          icon: const Icon(PhosphorIconsRegular.playCircle),
          label: !ready
              ? 'Study'
              : dueIds.isEmpty
              ? 'Nothing due'
              : 'Study ${dueIds.length} due',
          padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 14),
        ),
        const SizedBox(height: 10),
        AnimatedOpacity(
          // Fades in with the numbers rather than snapping off an em-dash.
          opacity: stats == null ? 0 : 1,
          duration: VoyagerMotion.crossfade,
          child: Text(
            stats == null
                ? ' '
                : '${stats.reviewedToday} reviewed today · '
                      '${stats.reviewedTotal} all time',
            style: theme.textTheme.labelMedium?.copyWith(
              // Kept legible by weight and contrast rather than dropped to a
              // pale grey — this sits over the app's live background.
              color: theme.colorScheme.onSurface.withValues(alpha: 0.75),
              fontWeight: FontWeight.w500,
              letterSpacing: 0.1,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ),
      ],
    );
  }
}

class _StudyLibraryGrid extends StatelessWidget {
  const _StudyLibraryGrid({
    super.key,
    required this.storageKey,
    required this.folders,
    required this.decks,
    required this.loading,
    required this.onOpenFolder,
    required this.onOpenDeck,
    required this.onNewFolder,
    required this.onNewDeck,
  });

  final PageStorageKey<String> storageKey;
  final List<StudyFolder> folders;
  final List<StudyDeck> decks;
  final bool loading;
  final ValueChanged<StudyFolder> onOpenFolder;
  final ValueChanged<StudyDeck> onOpenDeck;
  final VoidCallback onNewFolder;
  final VoidCallback onNewDeck;

  static const _gridDelegate = SliverGridDelegateWithMaxCrossAxisExtent(
    maxCrossAxisExtent: 220,
    mainAxisSpacing: 16,
    crossAxisSpacing: 16,
    childAspectRatio: 1.15,
  );

  @override
  Widget build(BuildContext context) {
    if (loading && folders.isEmpty && decks.isEmpty) {
      // Placeholder tiles rather than a blank region: the library's shape is
      // known before its contents are, and showing it stops the grid from
      // appearing out of nothing.
      return IgnorePointer(
        child: GridView.builder(
          padding: const EdgeInsets.only(bottom: 96),
          gridDelegate: _gridDelegate,
          itemCount: 6,
          itemBuilder: (context, index) => const _SkeletonTile(),
        ),
      );
    }

    if (folders.isEmpty && decks.isEmpty) {
      return _EmptyLibrary(onNewFolder: onNewFolder, onNewDeck: onNewDeck);
    }

    final sortedFolders = [...folders]
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    final sortedDecks = [...decks]
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));

    return GridView.builder(
      key: storageKey,
      padding: const EdgeInsets.only(bottom: 96),
      gridDelegate: _gridDelegate,
      itemCount: sortedFolders.length + sortedDecks.length,
      itemBuilder: (context, index) {
        if (index < sortedFolders.length) {
          final folder = sortedFolders[index];
          return _FolderTile(
            folder: folder,
            siblingFolders: sortedFolders,
            onTap: () => onOpenFolder(folder),
          );
        }
        final deck = sortedDecks[index - sortedFolders.length];
        return _DeckTile(
          deck: deck,
          siblingDecks: sortedDecks,
          onTap: () => onOpenDeck(deck),
        );
      },
    );
  }
}

/// A tile-shaped stand-in shown while the level's contents load. Deliberately
/// static — a looping shimmer is exactly the slow oscillation the reduced-
/// motion guidance asks interfaces not to put on screen.
class _SkeletonTile extends StatelessWidget {
  const _SkeletonTile();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final wash = theme.colorScheme.onSurface.withValues(alpha: 0.06);
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Container(
              width: 32,
              height: 32,
              decoration: BoxDecoration(
                color: wash,
                borderRadius: BorderRadius.circular(8),
              ),
            ),
            Container(
              width: 96,
              height: 12,
              decoration: BoxDecoration(
                color: wash,
                borderRadius: BorderRadius.circular(6),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _EmptyLibrary extends StatelessWidget {
  const _EmptyLibrary({required this.onNewFolder, required this.onNewDeck});

  final VoidCallback onNewFolder;
  final VoidCallback onNewDeck;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            'Nothing here yet',
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'Decks hold cards. Folders hold decks.',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurface.withValues(alpha: 0.7),
            ),
          ),
          const SizedBox(height: 20),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              GlassButton(
                onPressed: onNewFolder,
                icon: const Icon(PhosphorIconsRegular.folderPlus),
                label: 'New folder',
              ),
              const SizedBox(width: 12),
              GlassButton(
                onPressed: onNewDeck,
                icon: const Icon(PhosphorIconsRegular.stackPlus),
                label: 'New deck',
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Press feedback for the library tiles, matching [GlassButton]'s scale so a
/// deck responds to a press the way every other pressable surface in the app
/// does.
class _PressableTile extends StatefulWidget {
  const _PressableTile({
    required this.child,
    required this.onTap,
    this.menuKey,
    this.borderColor,
  });

  final Widget child;
  final VoidCallback onTap;

  /// Outlines the tile in this colour. Null leaves it unoutlined — the two
  /// kinds of tile are told apart by whether the edge is drawn at all, so a
  /// folder reads as a container and a deck as a solid object.
  final Color? borderColor;

  /// The tile's context menu, revealed on hover as a "⋯" affordance so the
  /// menu is not reachable by right-click alone.
  final GlobalKey<ContextMenuRegionState>? menuKey;

  @override
  State<_PressableTile> createState() => _PressableTileState();
}

class _PressableTileState extends State<_PressableTile>
    with SingleTickerProviderStateMixin {
  late final AnimationController _scale = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 120),
    reverseDuration: const Duration(milliseconds: 180),
  );
  final _moreKey = GlobalKey();
  bool _hovered = false;

  @override
  void dispose() {
    _scale.dispose();
    super.dispose();
  }

  void _openMenu() {
    final box = _moreKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null) return;
    widget.menuKey?.currentState?.openMenuAt(
      box.localToGlobal(box.size.centerLeft(Offset.zero)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final reduced = VoyagerMotion.reduced(context);
    final animation = reduced
        ? const AlwaysStoppedAnimation<double>(1)
        : Tween<double>(begin: 1, end: 0.97).animate(
            CurvedAnimation(parent: _scale, curve: VoyagerSpring.snappyCurve),
          );

    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: ScaleTransition(
        scale: animation,
        child: Stack(
          // The card is the tile: it has to take the whole grid cell, not
          // shrink to its contents the way a loose stack would let it.
          fit: StackFit.expand,
          children: [
            Card(
              clipBehavior: Clip.antiAlias,
              shape: _outline(theme),
              child: InkWell(
                onTap: widget.onTap,
                onTapDown: (_) => _scale.forward(),
                onTapCancel: () => _scale.reverse(),
                onTapUp: (_) => _scale.reverse(),
                child: widget.child,
              ),
            ),
            if (widget.menuKey != null)
              Positioned(
                top: 2,
                right: 2,
                child: IgnorePointer(
                  // Invisible means untouchable: a disabled button still
                  // absorbs the hit, which would leave a dead corner on the
                  // tile for any input that never hovers first.
                  ignoring: !_hovered,
                  child: AnimatedOpacity(
                    opacity: _hovered ? 1 : 0,
                    duration: VoyagerMotion.crossfade,
                    child: IconButton(
                      key: _moreKey,
                      onPressed: _openMenu,
                      visualDensity: VisualDensity.compact,
                    iconSize: 16,
                      tooltip: 'More actions',
                      icon: Icon(
                        PhosphorIconsRegular.dotsThree,
                        color: theme.colorScheme.onSurface.withValues(
                          alpha: 0.7,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// The theme's card outline retinted for this tile, so the corner radius
  /// keeps coming from one place and only the edge colour varies.
  ShapeBorder? _outline(ThemeData theme) {
    final base = theme.cardTheme.shape;
    if (base is! OutlinedBorder) return base;
    final color = widget.borderColor;
    return base.copyWith(
      side: color == null ? BorderSide.none : BorderSide(color: color),
    );
  }
}

class _FolderTile extends ConsumerStatefulWidget {
  const _FolderTile({
    required this.folder,
    required this.siblingFolders,
    required this.onTap,
  });

  final StudyFolder folder;
  final List<StudyFolder> siblingFolders;
  final VoidCallback onTap;

  @override
  ConsumerState<_FolderTile> createState() => _FolderTileState();
}

class _FolderTileState extends ConsumerState<_FolderTile> {
  final _menuKey = GlobalKey<ContextMenuRegionState>();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final folder = widget.folder;
    // One colour for the icon and the outline: the border is how a folder
    // wears its colour at tile size, and a mismatch would read as two things.
    final folderColor = folder.colorValue != null
        ? presetColor(folder.colorValue!)
        : theme.colorScheme.primary;
    return ContextMenuRegion(
      key: _menuKey,
      itemsBuilder: () => [
        ContextMenuItem(
          label: 'Recolor',
          icon: PhosphorIconsRegular.palette,
          onTap: () => changeStudyFolderColor(
            context,
            ref,
            folder,
            widget.siblingFolders,
          ),
        ),
        ContextMenuItem(
          label: 'Rename',
          icon: PhosphorIconsRegular.textAa,
          onTap: () => renameStudyFolder(context, ref, folder),
        ),
        ContextMenuItem(
          label: 'Move to…',
          icon: PhosphorIconsRegular.folderOpen,
          onTap: () => moveStudyFolder(context, ref, folder),
        ),
        ContextMenuItem(
          label: 'Delete',
          icon: PhosphorIconsRegular.trash,
          isDestructive: true,
          onTap: () => deleteStudyFolder(context, ref, folder),
        ),
      ],
      child: _PressableTile(
        onTap: widget.onTap,
        menuKey: _menuKey,
        borderColor: folderColor,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Icon(PhosphorIconsRegular.folder, size: 32, color: folderColor),
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
  const _DeckTile({
    required this.deck,
    required this.siblingDecks,
    required this.onTap,
  });

  final StudyDeck deck;
  final List<StudyDeck> siblingDecks;
  final VoidCallback onTap;

  @override
  ConsumerState<_DeckTile> createState() => _DeckTileState();
}

class _DeckTileState extends ConsumerState<_DeckTile> {
  final _menuKey = GlobalKey<ContextMenuRegionState>();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final vc = VoyagerColors.of(context);
    final deck = widget.deck;
    final statsAsync = ref.watch(studyDeckStatsProvider(deck.id));
    final due = statsAsync.valueOrNull?.due;

    return ContextMenuRegion(
      key: _menuKey,
      itemsBuilder: () => [
        ContextMenuItem(
          label: 'Recolor',
          icon: PhosphorIconsRegular.palette,
          onTap: () =>
              changeStudyDeckColor(context, ref, deck, widget.siblingDecks),
        ),
        ContextMenuItem(
          label: 'Rename',
          icon: PhosphorIconsRegular.textAa,
          onTap: () => renameStudyDeck(context, ref, deck),
        ),
        ContextMenuItem(
          label: 'Move to…',
          icon: PhosphorIconsRegular.folderOpen,
          onTap: () => moveStudyDeck(context, ref, deck),
        ),
        ContextMenuItem(
          label: 'Delete',
          icon: PhosphorIconsRegular.trash,
          isDestructive: true,
          onTap: () => deleteStudyDeck(context, ref, deck),
        ),
      ],
      child: _PressableTile(
        onTap: widget.onTap,
        menuKey: _menuKey,
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
                    color: deck.colorValue != null
                        ? presetColor(deck.colorValue!)
                        : theme.colorScheme.secondary,
                  ),
                  Text(
                    deck.name,
                    style: theme.textTheme.titleSmall,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
              Positioned(
                top: 0,
                right: 0,
                child: AnimatedOpacity(
                  // Each tile's count resolves on its own, so the badges
                  // fade in as they land instead of snapping one by one.
                  opacity: due != null && due > 0 ? 1 : 0,
                  duration: VoyagerMotion.crossfade,
                  child: Semantics(
                    // The bare number reads as "3" on its own; say what it
                    // counts. Empty while the badge is hidden so a deck
                    // with nothing due announces nothing.
                    label: due == null || due == 0
                        ? ''
                        : '$due card${due == 1 ? '' : 's'} due',
                    excludeSemantics: true,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 7,
                        vertical: 3,
                      ),
                      decoration: BoxDecoration(
                        color: theme.colorScheme.primary,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Text(
                        '${due ?? 0}',
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: vc.onAccent,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                    ),
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

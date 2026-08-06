import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/motion/motion.dart';
import 'package:voyager/domain/models/settings_models.dart';
import 'package:voyager/features/life_tracker/blossom_stat_popup.dart';
import 'package:voyager/features/life_tracker/bucket_list_popup.dart';
import 'package:voyager/features/life_tracker/life_tracker_providers.dart';
import 'package:voyager/features/life_tracker/life_tracker_stats.dart';
import 'package:voyager/features/life_tracker/life_tree_canvas.dart';
import 'package:voyager/features/life_tracker/life_tree_geometry.dart';
import 'package:voyager/features/life_tracker/life_tree_popover.dart';
import 'package:voyager/features/life_tracker/stat_leader_label.dart';

/// The Unified Canvas: a watercolour cherry tree annotated with one life
/// statistic per leader label, a figure resting on the trunk that opens the
/// bucket list, and a first-run leaf-fall animation for every week already
/// lived. See LIFE_TRACKER.md for the spec.
///
/// The page paints its own paper and keeps it in both themes. The whole look
/// is ink and wash on off-white stock, and re-toning it for dark mode gives up
/// the thing it is.
class LifeTrackerPage extends ConsumerStatefulWidget {
  const LifeTrackerPage({super.key});

  @override
  ConsumerState<LifeTrackerPage> createState() => _LifeTrackerPageState();
}

/// The paper and the ink it is painted with, fixed across themes.
const _paperColor = Color(0xFFF3F1EA);
const _inkColor = Color(0xFF241F1B);
const _grassColor = Color(0xFF8C9A79);

class _LifeTrackerPageState extends ConsumerState<LifeTrackerPage> {
  final _stackKey = GlobalKey();
  final _canvasController = LifeTreeCanvasController();
  bool _openingAnimationTriggered = false;

  /// Which leader label the pointer is over, so its line and dot can light up
  /// with it. -1 for none.
  int _hoveredLabel = -1;

  /// Whether the pointer is over the tree itself (outside the stat labels) —
  /// drives the whole-tree hover glow and marks where a tap opens the bucket
  /// list.
  bool _treeHovered = false;

  /// Bumped whenever the fall is reset, so a fall that was already scheduled
  /// but has not started yet doesn't kick in afterwards and undo it.
  int _openingRun = 0;

  @override
  void dispose() {
    _canvasController.dispose();
    super.dispose();
  }

  Offset _globalCenterFor(Offset normalizedPos, Size size) {
    final box = _stackKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null) return Offset.zero;
    final local = Offset(normalizedPos.dx * size.width, normalizedPos.dy * size.height);
    return box.localToGlobal(local);
  }

  Future<void> _openBlossomPopup(BlossomSpec blossom, Size size, Color accent) async {
    final anchor = _globalCenterFor(blossom.position, size);
    _canvasController.gustAt(blossom.position);
    await showTreePopover(
      context: context,
      anchorGlobalCenter: anchor,
      width: 260,
      accentColor: accent,
      builder: (_) => BlossomStatPopup(stat: blossom.stat, accentColor: accent),
    );
  }

  Future<void> _openBucketList(Offset normalizedAnchor, Size size, Color accent) async {
    final anchor = _globalCenterFor(normalizedAnchor, size);
    _canvasController.gustAt(normalizedAnchor, radius: 0.3, strength: 0.4);
    await showTreePopover(
      context: context,
      anchorGlobalCenter: anchor,
      width: 480,
      height: 460,
      accentColor: accent,
      builder: (_) => BucketListPopup(accentColor: accent),
    );
  }

  /// Debug-only: puts every leaf back on the tree and replays the opening
  /// fall from the top. No-ops without a birth date, since the number of
  /// leaves to shed is derived from it.
  void _replayOpeningAnimation() {
    final settings = ref.read(settingsProvider).valueOrNull;
    final weeks = weeksLivedFor(settings?.birthDate, DateTime.now());
    if (weeks == null || weeks <= 0) return;

    _openingRun++;
    _canvasController.resetFall();
    ref.read(lifeTreeGroundedLeavesProvider.notifier).state = null;
    setState(() => _openingAnimationTriggered = false);
  }

  /// Debug-only: puts every leaf back on the tree and leaves it there, so the
  /// canopy can be looked at whole. The grounded set goes to empty rather
  /// than null, which is also what marks the opening fall as already resolved
  /// — otherwise it would immediately shed the leaves again.
  void _restoreAllLeaves() {
    _openingRun++;
    _canvasController.resetFall();
    ref.read(lifeTreeGroundedLeavesProvider.notifier).state = const <int>{};
    setState(() => _openingAnimationTriggered = true);
  }

  void _maybeStartOpeningAnimation(LifeTreeGeometry geometry, DateTime? birthDate) {
    if (_openingAnimationTriggered) return;
    if (ref.read(lifeTreeGroundedLeavesProvider) != null) return;
    final weeks = weeksLivedFor(birthDate, DateTime.now());
    if (weeks == null || weeks <= 0) return;
    _openingAnimationTriggered = true;
    final run = ++_openingRun;

    final orderedIndices = geometry.leafIndicesByAngle;
    final count = weeks.clamp(0, orderedIndices.length);
    final stride = orderedIndices.length / count;
    final chosen = <int>[
      for (var i = 0; i < count; i++)
        orderedIndices[(i * stride).floor().clamp(0, orderedIndices.length - 1)],
    ];

    if (VoyagerMotion.reduced(context)) {
      // Skip the multi-second leaf-fall cascade — land straight on the
      // settled state.
      ref.read(lifeTreeGroundedLeavesProvider.notifier).state = chosen.toSet();
      return;
    }

    // Let the fully-leaved tree render for a beat before it starts shedding.
    Future.delayed(const Duration(milliseconds: 700), () {
      if (!mounted || run != _openingRun) return;
      _canvasController.startOpeningFall(chosen, () {
        ref.read(lifeTreeGroundedLeavesProvider.notifier).state = chosen.toSet();
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    final geometry = ref.watch(lifeTreeGeometryProvider);
    final settings = ref.watch(settingsProvider).valueOrNull;
    final cachedStats = ref.watch(lifeTrackerStatsProvider).valueOrNull;
    final grounded = ref.watch(lifeTreeGroundedLeavesProvider) ?? const <int>{};

    final minorColors = (settings?.minorPetalColors ?? const <int>[]).map(Color.new).toList();
    if (minorColors.isEmpty) {
      minorColors.addAll(const [
        Color(0xFFF3C5CE),
        Color(0xFFEAA6B5),
        Color(0xFFDF8B9C),
      ]);
    }
    final leafColors = <Color>[
      Color(settings?.petalColor ?? defaultPetalColor),
      ...minorColors,
    ];
    final accent = Color(settings?.accentColor ?? 0xFF7C9EFF);

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _maybeStartOpeningAnimation(geometry, settings?.birthDate);
    });

    return LayoutBuilder(
      builder: (context, constraints) {
        final size = Size(constraints.maxWidth, constraints.maxHeight);
        if (size.isEmpty) return const SizedBox.shrink();

        final now = DateTime.now();
        final labelWidth = math.min(230.0, size.width * 0.21);
        final hub = geometry.branchHubRect;
        final hotspot = Rect.fromLTRB(
          hub.left * size.width,
          hub.top * size.height,
          hub.right * size.width,
          hub.bottom * size.height,
        );

        return Stack(
          key: _stackKey,
          children: [
            Positioned.fill(
              child: LifeTreeCanvas(
                geometry: geometry,
                leafColors: leafColors,
                inkColor: _inkColor,
                paperColor: _paperColor,
                grassColor: _grassColor,
                groundedLeafIndices: grounded,
                controller: _canvasController,
                accentColor: accent,
                hovered: _treeHovered,
                showDebugColors: ref.watch(lifeTrackerShowDebugColorsProvider),
              ),
            ),
            Positioned.fill(
              child: IgnorePointer(
                child: CustomPaint(
                  painter: LeaderLinePainter(
                    blossoms: geometry.blossoms,
                    inkColor: _inkColor,
                    accentColor: accent,
                    highlighted: _hoveredLabel,
                  ),
                ),
              ),
            ),
            Positioned.fill(
              child: _TreeHoverRegion(
                geometry: geometry,
                onHoverChanged: (hovered) {
                  if (hovered == _treeHovered) return;
                  setState(() => _treeHovered = hovered);
                },
                onTap: () => _openBucketList(
                  Offset(
                    hotspot.center.dx / size.width,
                    hotspot.center.dy / size.height,
                  ),
                  size,
                  accent,
                ),
              ),
            ),
            for (var i = 0; i < geometry.blossoms.length; i++)
              () {
                final blossom = geometry.blossoms[i];
                final resolved = resolveLifeStat(
                  stat: blossom.stat,
                  birthDate: settings?.birthDate,
                  now: now,
                  tasksConquered: cachedStats?.tasksConquered ?? 0,
                  lifetimeMood: cachedStats?.lifetimeMood,
                );
                final x = blossom.labelAnchor.dx * size.width;
                return Positioned(
                  left: blossom.onLeft ? null : x,
                  right: blossom.onLeft ? size.width - x : null,
                  top: blossom.labelAnchor.dy * size.height,
                  child: FractionalTranslation(
                    translation: const Offset(0, -0.5),
                    child: SizedBox(
                      width: labelWidth,
                      child: StatLeaderLabel(
                        name: resolved.shortLabel,
                        value: resolved.value,
                        onLeft: blossom.onLeft,
                        inkColor: _inkColor,
                        accentColor: accent,
                        haloColor: _paperColor,
                        onTap: () => _openBlossomPopup(blossom, size, accent),
                        onHoverChanged: (hovered) => setState(
                          () => _hoveredLabel = hovered ? i : -1,
                        ),
                      ),
                    ),
                  ),
                );
              }(),
            Positioned(
              right: 16,
              top: 16,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (ref.watch(lifeTrackerShowRestoreButtonProvider))
                    Tooltip(
                      message: 'Put every fallen leaf back on the tree',
                      child: IconButton.filledTonal(
                        icon: const Icon(PhosphorIconsRegular.tree),
                        onPressed: _restoreAllLeaves,
                      ),
                    ),
                  if (ref.watch(lifeTrackerShowReplayButtonProvider))
                    Padding(
                      padding: const EdgeInsets.only(left: 8),
                      child: Tooltip(
                        message: settings?.birthDate == null
                            ? 'Set a birth date in Settings to replay the opening animation'
                            : 'Replay the opening animation',
                        child: IconButton.filledTonal(
                          icon: const Icon(
                            PhosphorIconsRegular.arrowCounterClockwise,
                          ),
                          onPressed: settings?.birthDate == null
                              ? null
                              : _replayOpeningAnimation,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

/// The hover/tap target over the trunk and branches — its silhouette is
/// baked into the canvas texture, so this is a transparent region clipped to
/// just that shape and laid over it. Hovering it lights the tree (see
/// [LifeTreeCanvas.hovered]); tapping it opens the bucket list. One and the
/// same region for both, since only the trunk and branches respond to
/// either — not the root flares or the canopy cloud. Placed below the stat
/// labels in the stack, so their own tap/hover targets still win over this
/// one.
class _TreeHoverRegion extends StatelessWidget {
  const _TreeHoverRegion({
    required this.geometry,
    required this.onHoverChanged,
    required this.onTap,
  });

  final LifeTreeGeometry geometry;
  final ValueChanged<bool> onHoverChanged;
  final Future<void> Function() onTap;

  @override
  Widget build(BuildContext context) {
    return ClipPath(
      clipper: _TrunkAndBranchesClipper(geometry),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => onHoverChanged(true),
        onExit: (_) => onHoverChanged(false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
        ),
      ),
    );
  }
}

/// The exact trunk-and-branches silhouette (per user request — not the root
/// flares, not the canopy cloud) — clips both the hover glow's trigger and
/// the bucket-list tap target down to just that shape.
class _TrunkAndBranchesClipper extends CustomClipper<Path> {
  const _TrunkAndBranchesClipper(this.geometry);

  final LifeTreeGeometry geometry;

  @override
  Path getClip(Size size) => buildTrunkAndBranchesPath(geometry, size);

  @override
  bool shouldReclip(covariant _TrunkAndBranchesClipper oldClipper) =>
      oldClipper.geometry != geometry;
}

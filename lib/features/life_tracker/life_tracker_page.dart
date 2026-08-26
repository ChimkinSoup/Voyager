import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:voyager/app/providers.dart';
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
/// bucket list, and one leaf already resting on the ground for every week
/// already lived. See LIFE_TRACKER.md for the spec.
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

  /// Which leader label the pointer is over, so its line and dot can light up
  /// with it. -1 for none.
  int _hoveredLabel = -1;

  /// Whether the pointer is over the tree itself (outside the stat labels) —
  /// drives the whole-tree hover glow and marks where a tap opens the bucket
  /// list.
  bool _treeHovered = false;

  /// Memoized result of [_groundedLeavesFor], with the week count it was built
  /// for. Choosing the leaves sorts all 4,160 of them by angle, and the page
  /// rebuilds on every hover.
  Set<int>? _livedLeaves;
  int? _livedLeavesWeeks;

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
      width: statPopupWidth,
      maxWidth: statPopupMaxWidth,
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

  /// Debug-only: puts every leaf back on the tree so the canopy can be looked
  /// at whole, and drops them back to the ground on a second press. An empty
  /// grounded set overrides the derived one; null hands it back.
  void _toggleAllLeaves() {
    final notifier = ref.read(lifeTreeGroundedLeavesProvider.notifier);
    notifier.state = notifier.state == null ? const <int>{} : null;
  }

  /// One leaf on the ground for every week already lived, spread evenly around
  /// the canopy. Derived from the birth date rather than animated into place,
  /// so the page opens straight onto the settled state.
  Set<int> _groundedLeavesFor(LifeTreeGeometry geometry, DateTime? birthDate) {
    final weeks = weeksLivedFor(birthDate, DateTime.now()) ?? 0;
    if (weeks == _livedLeavesWeeks) return _livedLeaves!;

    final orderedIndices = geometry.leafIndicesByAngle;
    final count = weeks.clamp(0, orderedIndices.length);
    final stride = count == 0 ? 0.0 : orderedIndices.length / count;
    final chosen = <int>{
      for (var i = 0; i < count; i++)
        orderedIndices[(i * stride).floor().clamp(0, orderedIndices.length - 1)],
    };

    _livedLeavesWeeks = weeks;
    _livedLeaves = chosen;
    return chosen;
  }

  @override
  Widget build(BuildContext context) {
    final geometry = ref.watch(lifeTreeGeometryProvider);
    final settings = ref.watch(settingsProvider).valueOrNull;
    final statsAsync = ref.watch(lifeTrackerStatsProvider);
    final grounded = ref.watch(lifeTreeGroundedLeavesProvider) ??
        _groundedLeavesFor(geometry, settings?.birthDate);

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
                  // Nullable rather than defaulted: the cached stats are a
                  // chain of table reads on a cold open, and a substituted 0
                  // renders as a real count for the whole of it.
                  tasksConquered: statsAsync.valueOrNull?.tasksConquered,
                  lifetimeMood: statsAsync.valueOrNull?.lifetimeMood,
                  moodKnown: statsAsync.hasValue,
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
            if (ref.watch(lifeTrackerShowRestoreButtonProvider))
              Positioned(
                right: 16,
                top: 16,
                child: Tooltip(
                  message: ref.watch(lifeTreeGroundedLeavesProvider) == null
                      ? 'Put every fallen leaf back on the tree'
                      : 'Put the leaves back on the ground',
                  child: IconButton.filledTonal(
                    icon: const Icon(PhosphorIconsRegular.tree),
                    onPressed: _toggleAllLeaves,
                  ),
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

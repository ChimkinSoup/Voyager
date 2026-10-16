import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/features/life_tracker/blossom_stat_popup.dart';
import 'package:voyager/features/life_tracker/bucket_list_popup.dart';
import 'package:voyager/features/life_tracker/life_tracker_providers.dart';
import 'package:voyager/features/life_tracker/life_tracker_stats.dart';
import 'package:voyager/features/life_tracker/life_tree_popover.dart';
import 'package:voyager/features/life_tracker/stat_leader_label.dart';
import 'package:voyager/features/life_tracker/weeping_cherry_canvas.dart';

/// The Unified Canvas: a watercolour weeping cherry, one petal per week of
/// life and the weeks lived fallen to the ground, annotated with one life
/// statistic per leader label. Tapping the trunk opens the bucket list. See
/// LIFE_TRACKER.md for the spec.
///
/// The canvas has no stock of its own: it composites straight onto the app's
/// background, full-bleed.
class LifeTrackerPage extends ConsumerStatefulWidget {
  const LifeTrackerPage({super.key});

  @override
  ConsumerState<LifeTrackerPage> createState() => _LifeTrackerPageState();
}

/// The ink the labels are set in, and the halo that keeps them readable over
/// the blossom.
const _paperColor = Color(0xFFF3F1EA);
const _inkColor = Color(0xFF241F1B);

const _nightPaperColor = Color(0xFF17151C);
const _nightInkColor = Color(0xFFE8E2D8);

class _LifeTrackerPageState extends ConsumerState<LifeTrackerPage> {
  final _stackKey = GlobalKey();

  /// Which leader label the pointer is over, so its line and dot can light up
  /// with it. -1 for none.
  int _hoveredLabel = -1;

  /// Where the pointer is over the page, for the tree to give way to it.
  final _pointer = ValueNotifier<Offset?>(null);

  @override
  void dispose() {
    _pointer.dispose();
    super.dispose();
  }

  Offset _toGlobal(Offset local) {
    final box = _stackKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null) return Offset.zero;
    return box.localToGlobal(local);
  }

  Future<void> _openBlossomPopup(
    BlossomSpec blossom,
    Size size,
    Color accent,
  ) async {
    await showTreePopover(
      context: context,
      anchorGlobalCenter: _toGlobal(weepingCanvasPoint(blossom.position, size)),
      width: statPopupWidth,
      maxWidth: statPopupMaxWidth,
      accentColor: accent,
      builder: (_) => BlossomStatPopup(stat: blossom.stat, accentColor: accent),
    );
  }

  Future<void> _openBucketList(Size size, Color accent) async {
    await showTreePopover(
      context: context,
      // Centred on the page rather than on the trunk, which sits low enough
      // to push the popup toward the bottom edge.
      anchorGlobalCenter: _toGlobal(size.center(Offset.zero)),
      width: 480,
      height: 460,
      accentColor: accent,
      builder: (_) => BucketListPopup(accentColor: accent),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final ink = isDark ? _nightInkColor : _inkColor;
    final paper = isDark ? _nightPaperColor : _paperColor;

    final settingsAsync = ref.watch(settingsProvider.settled);
    final settings = settingsAsync.valueOrNull;
    final statsAsync = ref.watch(lifeTrackerStatsProvider.settled);
    final now = ref.watch(lifeClockProvider);
    // Null until settings load, so the tree doesn't fall for zero weeks and
    // then again for the real count. A failed load counts as zero.
    final weeks = settingsAsync.hasValue || settingsAsync.hasError
        ? weeksLivedFor(settings?.birthDate, now) ?? 0
        : null;
    final accent = Color(settings?.accentColor ?? 0xFF7C9EFF);

    return LayoutBuilder(
      builder: (context, constraints) {
        final size = Size(constraints.maxWidth, constraints.maxHeight);
        if (size.isEmpty) return const SizedBox.shrink();

        final labelWidth = math.min(230.0, size.width * 0.21);
        final labels = leaderLabelLayout(lifeStatBlossoms, size);

        // Around the whole stack rather than on the canvas, so the pointer
        // still stirs the tree over the trunk's and labels' targets.
        return MouseRegion(
          opaque: false,
          onHover: (event) => _pointer.value = event.localPosition,
          onExit: (_) => _pointer.value = null,
          child: Stack(
            key: _stackKey,
            children: [
              Positioned.fill(
                child: WeepingCherryCanvas(
                  weeksLived: weeks,
                  brightness: Theme.of(context).brightness,
                  pointer: _pointer,
                ),
              ),
              Positioned.fill(
                child: IgnorePointer(
                  child: CustomPaint(
                    painter: LeaderLinePainter(
                      blossoms: lifeStatBlossoms,
                      inkColor: ink,
                      accentColor: accent,
                      highlighted: _hoveredLabel,
                    ),
                  ),
                ),
              ),
              // The trunk is the bucket list's tap target. Below the stat
              // labels in the stack, so their own targets still win over it.
              Positioned.fill(
                child: ClipPath(
                  clipper: const _TrunkClipper(),
                  child: MouseRegion(
                    cursor: SystemMouseCursors.click,
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () => _openBucketList(size, accent),
                    ),
                  ),
                ),
              ),
              for (var i = 0; i < lifeStatBlossoms.length; i++)
                () {
                  final blossom = lifeStatBlossoms[i];
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
                  final x = labels.anchors[i].dx;
                  return Positioned(
                    left: blossom.onLeft ? null : x,
                    right: blossom.onLeft ? size.width - x : null,
                    top: labels.anchors[i].dy,
                    child: FractionalTranslation(
                      translation: const Offset(0, -0.5),
                      child: SizedBox(
                        // Never wider than the room left before the canvas
                        // edge, or a long value runs off it at small sizes.
                        width: math.max(
                          0,
                          math.min(
                            labelWidth,
                            (blossom.onLeft ? x : size.width - x) - 8,
                          ),
                        ),
                        child: StatLeaderLabel(
                          name: resolved.shortLabel,
                          value: resolved.value,
                          valueIsProse: resolved.isPlaceholder,
                          onLeft: blossom.onLeft,
                          inkColor: ink,
                          accentColor: accent,
                          haloColor: paper,
                          onTap: () => _openBlossomPopup(blossom, size, accent),
                          onHoverChanged: (hovered) =>
                              setState(() => _hoveredLabel = hovered ? i : -1),
                        ),
                      ),
                    ),
                  );
                }(),
            ],
          ),
        );
      },
    );
  }
}

class _TrunkClipper extends CustomClipper<Path> {
  const _TrunkClipper();

  @override
  Path getClip(Size size) => weepingTrunkPath(size);

  @override
  bool shouldReclip(covariant _TrunkClipper oldClipper) => false;
}

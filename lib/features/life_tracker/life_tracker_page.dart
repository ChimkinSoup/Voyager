import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/domain/models/settings_models.dart';
import 'package:voyager/features/life_tracker/blossom_stat_popup.dart';
import 'package:voyager/features/life_tracker/blossom_widget.dart';
import 'package:voyager/features/life_tracker/bucket_list_popup.dart';
import 'package:voyager/features/life_tracker/life_tracker_providers.dart';
import 'package:voyager/features/life_tracker/life_tracker_stats.dart';
import 'package:voyager/features/life_tracker/life_tree_canvas.dart';
import 'package:voyager/features/life_tracker/life_tree_geometry.dart';
import 'package:voyager/features/life_tracker/life_tree_popover.dart';
import 'package:voyager/features/life_tracker/swing_bubble_widget.dart';

/// The Unified Canvas: a watercolor tree with one blossom per life
/// statistic, a swing + bucket-list bubble, and a first-run leaf-fall
/// animation for every week already lived. See LIFE_TRACKER.md for the spec.
class LifeTrackerPage extends ConsumerStatefulWidget {
  const LifeTrackerPage({super.key});

  @override
  ConsumerState<LifeTrackerPage> createState() => _LifeTrackerPageState();
}

class _LifeTrackerPageState extends ConsumerState<LifeTrackerPage> {
  final _stackKey = GlobalKey();
  final _canvasController = LifeTreeCanvasController();
  bool _openingAnimationTriggered = false;

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
      width: 360,
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
    final grounded = ref.watch(lifeTreeGroundedLeavesProvider) ?? const <int>{};

    final leafColors = <Color>[
      Color(settings?.petalColor ?? defaultPetalColor),
      ...(settings?.minorPetalColors ?? const <int>[]).map(Color.new),
    ];
    final accent = Color(settings?.accentColor ?? 0xFF7C9EFF);
    final blossomColor = Color.lerp(accent, Colors.white, 0.55)!.withValues(alpha: 0.85);

    // Wood and ground pigment: the warm mid-brown of a watercolour trunk in
    // the light theme, which would vanish against the dark theme's
    // background, so it lifts to a pale driftwood there.
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final inkColor = isDark ? const Color(0xFFC3A79E) : const Color(0xFF7A5348);
    final groundColor = isDark ? const Color(0xFF9C8A86) : const Color(0xFF8A6156);

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _maybeStartOpeningAnimation(geometry, settings?.birthDate);
    });

    return LayoutBuilder(
      builder: (context, constraints) {
        final size = Size(constraints.maxWidth, constraints.maxHeight);
        if (size.isEmpty) return const SizedBox.shrink();

        return Stack(
          key: _stackKey,
          children: [
            Positioned.fill(
              child: LifeTreeCanvas(
                geometry: geometry,
                leafColors: leafColors,
                inkColor: inkColor,
                groundColor: groundColor,
                groundedLeafIndices: grounded,
                controller: _canvasController,
              ),
            ),
            for (final blossom in geometry.blossoms)
              Positioned(
                left: blossom.position.dx * size.width - blossom.size * size.shortestSide * 1.1,
                top: blossom.position.dy * size.height - blossom.size * size.shortestSide * 1.4,
                child: BlossomWidget(
                  size: blossom.size * size.shortestSide,
                  color: blossomColor,
                  shortLabel: shortLabelForStat(blossom.stat),
                  onTap: () => _openBlossomPopup(blossom, size, accent),
                ),
              ),
            Positioned(
              left: geometry.swingAnchor.dx * size.width - 52,
              top: geometry.swingAnchor.dy * size.height,
              child: SwingAndBubble(
                accentColor: accent,
                onBubbleTap: () => _openBucketList(
                  Offset(geometry.swingAnchor.dx, geometry.swingAnchor.dy + 0.20),
                  size,
                  accent,
                ),
              ),
            ),
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

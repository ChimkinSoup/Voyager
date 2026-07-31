import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:voyager/core/dev/dev_flags.dart';
import 'package:voyager/features/life_tracker/life_tree_geometry.dart';

/// The tree's full geometry (canopy scatter, blossom placement, swing
/// anchor) — computed once and cached for the app's lifetime. It's also
/// deterministic across restarts (see [generateLifeTreeGeometry]'s fixed
/// seed), so the tree always looks like the same tree.
final lifeTreeGeometryProvider = Provider<LifeTreeGeometry>((ref) {
  return generateLifeTreeGeometry();
});

/// Which leaves have permanently landed on the ground from the first-run
/// opening animation. Null until that animation has run once this session;
/// stays populated across page navigation within the same app run, and
/// resets (like all Riverpod state) on the next app restart — matching the
/// "once per app restart" spec requirement without any persistence code.
final lifeTreeGroundedLeavesProvider = StateProvider<Set<int>?>((ref) => null);

/// Shows the debug replay button on the Life Tracker page, which resets the
/// grounded leaves and re-runs the opening fall on demand. Toggled from the
/// Dev page; lives here rather than beside the other dev flags so the page
/// can watch it without depending on the dev feature.
final lifeTrackerShowReplayButtonProvider = StateProvider<bool>(
  (ref) => DevFlags.showLifeTrackerReplay,
);

/// Shows the debug restore button on the Life Tracker page, which puts every
/// fallen leaf back on the tree without replaying the fall. Toggled from the
/// Dev page; lives here for the same reason as
/// [lifeTrackerShowReplayButtonProvider].
final lifeTrackerShowRestoreButtonProvider = StateProvider<bool>(
  (ref) => DevFlags.showLifeTrackerRestore,
);

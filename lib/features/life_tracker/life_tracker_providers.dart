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

/// Overrides which leaves rest on the ground, for the debug restore button
/// only. Null — the normal case — means the page derives them from the weeks
/// lived; an empty set puts the whole canopy back on the tree. Resets (like
/// all Riverpod state) on the next app restart.
final lifeTreeGroundedLeavesProvider = StateProvider<Set<int>?>((ref) => null);

/// Shows the debug restore button on the Life Tracker page, which toggles
/// every leaf between the tree and the ground. Toggled from the Dev page;
/// lives here rather than beside the other dev flags so the page can watch it
/// without depending on the dev feature.
final lifeTrackerShowRestoreButtonProvider = StateProvider<bool>(
  (ref) => DevFlags.showLifeTrackerRestore,
);

/// Toggles highlighting each tree segment in distinct glowing debug colors.
final lifeTrackerShowDebugColorsProvider = StateProvider<bool>(
  (ref) => DevFlags.showLifeTreeSegmentDebug,
);

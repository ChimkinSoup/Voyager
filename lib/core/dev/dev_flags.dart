import 'dart:io';

class DevFlags {
  static bool verboseSync = false;
  static bool showTimeSelectorHitboxes = false;
  static bool slowHeatmapPopoverAnimation = false;
  static bool slowTodoEditPanelAnimation = false;
  // Lets the always-on light-theme petal background be switched off live for
  // A/B testing whether it contributes to UI-isolate jank elsewhere in the
  // app, without needing a rebuild.
  static bool disablePetalField = false;
  static bool disableCache = false;
  // Shows a button on the Life Tracker page that toggles every leaf between
  // the tree and the ground, for looking at the full canopy.
  static bool showLifeTrackerRestore = false;
  // Highlights each segment of the tree trunk, roots, and branches in distinct
  // glowing debug colors and labels.
  static bool showLifeTreeSegmentDebug = false;
  // Cuts the app off from the network without touching the PC's: the Dev page
  // toggle also disables Firestore's network, and the connectivity probe,
  // media storage, Geoapify search and map tiles fail via
  // [throwIfForcedOffline]. Weather and sign-in are not cut. Session-only;
  // not persisted.
  static bool forceOffline = false;

  /// Throws what an unreachable host would, while [forceOffline] is on.
  static void throwIfForcedOffline() {
    if (forceOffline) throw const SocketException('DevFlags.forceOffline');
  }

  // Shows the rankings map's current zoom level over the map.
  static bool showRankingsMapZoom = false;
}

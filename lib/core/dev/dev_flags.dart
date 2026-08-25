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
  // Makes the connectivity probe throw, so the shell offline badge (and the
  // reconnect→resume-sync path) run through the same failure streak they
  // would against an unreachable Firestore. Session-only; not persisted.
  static bool forceOffline = false;
}

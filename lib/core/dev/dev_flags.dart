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
  // Shows a replay button on the Life Tracker page, so the once-per-restart
  // opening leaf-fall can be re-run without restarting the app.
  static bool showLifeTrackerReplay = false;
  // Shows a button on the Life Tracker page that puts every fallen leaf back
  // on the tree and leaves it there, for looking at the full canopy.
  static bool showLifeTrackerRestore = false;
  // Highlights each segment of the tree trunk, roots, and branches in distinct
  // glowing debug colors and labels.
  static bool showLifeTreeSegmentDebug = false;
}

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
}

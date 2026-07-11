enum TrackerType { integer, boolean, enumType }

enum TrackerCadence { daily, weekly, monthly, yearly }

/// How an integer tracker's history is visualised.
/// - [independent]: each period stands alone → heatmap square.
/// - [consecutive]: values form a continuous series → line/sparkline graph.
/// Always `null` for boolean and enum trackers (they are inherently independent).
enum TrackerStyle { independent, consecutive }

enum CalendarViewMode { week, month, year }

enum HeatmapMode { defaultAll, mood, studying, writing, custom }

enum StartupPageMode { first, custom, lastSeen }

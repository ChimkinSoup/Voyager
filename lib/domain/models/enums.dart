enum TrackerType { integer, boolean, enumType }

/// Direction of a financial ledger transaction.
/// - [expense]: money flowing out (rendered in the main accent color).
/// - [deposit]: money flowing in (rendered in green).
enum TransactionType { expense, deposit }

/// Billing cadence of a recurring subscription or bill.
enum BillingPeriod { weekly, biweekly, monthly, quarterly, yearly }

enum TrackerCadence { daily, weekly, monthly, yearly }

/// How an integer tracker's history is visualised.
/// - [independent]: each period stands alone → heatmap square.
/// - [consecutive]: values form a continuous series → line/sparkline graph.
/// Always `null` for boolean and enum trackers (they are inherently independent).
enum TrackerStyle { independent, consecutive }

enum CalendarViewMode { week, month, year }

/// LeetCode problem difficulty tier.
enum LeetCodeDifficulty { easy, medium, hard }

enum HeatmapMode { defaultAll, mood, studying, writing, custom }

enum StartupPageMode { first, custom, lastSeen }

/// Which of the two hand-built app themes is active.
///
/// Deliberately not tied to the platform brightness: each theme carries its own
/// background pipeline (dark = triangle grid shader, light = paper grain +
/// falling petals), so switching is a real choice rather than an ambient one.
enum AppThemeMode { dark, light }

/// Shape of the geometric-texture background's animated wave SDF.
enum GeometricWaveShape {
  /// A straight line sweeping across the grid.
  linear,

  /// A ring expanding outward from the focal point.
  radial,
}

/// Calendar-day arithmetic that survives daylight-saving transitions.
///
/// [DateTime]'s own `add`/`subtract`/`difference` work in absolute elapsed
/// time, so a `Duration(days: n)` is exactly `n * 24h` — which is not what a
/// calendar day is worth across a DST boundary. In a zone that observes one,
/// `DateTime(2025, 11, 1).add(const Duration(days: 10))` lands on
/// `2025-11-10 23:00` rather than on the 11th, and
/// `DateTime(2026, 3, 15).difference(DateTime(2026, 3, 1)).inDays` is 13
/// rather than 14.
///
/// Both are wrong in a way that hides: the hour-short result *floors* to the
/// previous day. The sparklines put a calendar-day offset on their x axis, so
/// an offset computed one day short makes a hovered point resolve to the
/// period before the one under the cursor — and the hover bubble then reports
/// its neighbour's value. It only bites in the half of the year on the far
/// side of a transition from the window's start, which is why it reads as
/// intermittent rather than as broken arithmetic.
library;

/// [date] moved by [days] calendar days, at local midnight.
///
/// Goes through the [DateTime] constructor, which normalises out-of-range
/// fields (`day: 0` is the previous month's last day, `day: 32` rolls into the
/// next month) and resolves the result in local time *after* normalising — so
/// it lands on the intended calendar day whatever DST did in between.
DateTime addCalendarDays(DateTime date, int days) =>
    DateTime(date.year, date.month, date.day + days);

/// Whole calendar days from [from] to [to], ignoring both times of day.
///
/// Compares in UTC, which has no transitions to lose an hour to. The local
/// y/m/d fields are carried across rather than converted, so this counts days
/// on the calendar instead of elapsed time between two instants.
int calendarDaysBetween(DateTime from, DateTime to) =>
    DateTime.utc(to.year, to.month, to.day)
        .difference(DateTime.utc(from.year, from.month, from.day))
        .inDays;

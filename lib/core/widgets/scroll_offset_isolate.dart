import 'package:flutter/widgets.dart';

/// Gives [child] a [PageStorage] bucket of its own, so a scrollable inside it
/// neither restores nor overwrites an offset belonging to another scrollable.
///
/// [ScrollPosition] remembers its offset through [PageStorage], under an
/// identifier built from the [PageStorageKey]s on its *ancestors* — the
/// scrollable itself contributes nothing. Two keyless scrollables in one route
/// therefore share a single slot. A page that keys its list for the shell
/// (`PageStorageKey('analyticsList')`) and then nests a shrink-wrapped
/// `ReorderableListView` inside it is exactly that case: both write to the one
/// identifier the page key produces.
///
/// The visible failure is on *mount*. A nested list that appears mid-session
/// — a bucket crossing the point where it stops being a plain [Column], a
/// section that was empty until an undo put a row back — calls
/// `restoreScrollOffset` and adopts whatever the page last scrolled to, even
/// though its own extent is zero. [RangeMaintainingScrollPhysics] declines to
/// clamp it (the offset was already out of range, so it assumes the overscroll
/// is wanted), and this app runs [BouncingScrollPhysics] on every platform,
/// whose ballistic simulation springs an out-of-range position back. The rows
/// start off the top of their own viewport and slide down into place over a
/// few hundred milliseconds, while nothing else on the page moves.
///
/// The reverse leak is quieter but real: an inert nested list settles at 0 and
/// saves *that*, wiping the offset the page meant to return to.
///
/// A private bucket lives exactly as long as this widget's [State], so a
/// scrollable under it still keeps its place across rebuilds — it just can no
/// longer read or clobber a sibling's.
///
/// **When a site is exposed.** [PageStorageBucket.writeState] drops the offset
/// outright unless [PageStorage] finds at least one [PageStorageKey] between
/// the scrollable and its route, so only a descendant of a keyed scroll view
/// can leak or be leaked into. Today that means the `KeepAlive*` wrappers in
/// `keep_alive_scroll.dart` and their `ShellPageStorageKeys`, plus the two
/// per-item keys — the study folder grid and the rankings category list —
/// that use one deliberately so each item keeps its own place: a dialog gets a
/// bucket of its own from its route and carries no key, and a panel that is a
/// *sibling* of a keyed list rather than a child of it is likewise clear.
///
/// This is applied to every nested scrollable regardless, not only the ones
/// currently exposed. The exposure turns on one ancestor a page does not
/// otherwise think about — a page adopting [KeepAliveScrollView] the way most
/// shell pages already have would arm every keyless scrollable beneath it at
/// once, and the symptom gives no hint where to look.
class ScrollOffsetIsolate extends StatefulWidget {
  const ScrollOffsetIsolate({super.key, required this.child});

  final Widget child;

  @override
  State<ScrollOffsetIsolate> createState() => _ScrollOffsetIsolateState();
}

class _ScrollOffsetIsolateState extends State<ScrollOffsetIsolate> {
  final _bucket = PageStorageBucket();

  @override
  Widget build(BuildContext context) {
    return PageStorage(bucket: _bucket, child: widget.child);
  }
}

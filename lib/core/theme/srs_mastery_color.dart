import 'package:flutter/material.dart';

/// Color coding for how well an SRS item is known, drawn as the border around
/// its tile in a review grid: grey for a never-reviewed item, amber while
/// still in the sub-day "learning" phase, blue once it holds a multi-day
/// interval, green once it's comfortably spaced out. Mirrors the interval
/// bands most SRS tools use to communicate progress at a glance.
///
/// Shared by the Study deck grid and the LeetCode Review Deck so a green ring
/// means the same thing on both pages.
Color srsMasteryColor({
  required int reviewCount,
  required double interval,
  required ColorScheme scheme,
}) {
  if (reviewCount == 0) return scheme.onSurface.withValues(alpha: 0.25);
  if (interval < 1) return const Color(0xFFE0A63A);
  if (interval < 21) return const Color(0xFF5C8BE0);
  return const Color(0xFF4CAF7D);
}

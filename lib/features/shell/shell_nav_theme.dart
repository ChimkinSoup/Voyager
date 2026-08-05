import 'package:flutter/material.dart';

/// Shared visual tokens for the two shell navigations.
///
/// The desktop rail and the phone bottom bar are separate compositions on
/// purpose, but they are the same control wearing different proportions: an
/// 18px-radius highlight, a hairline accent border when selected, icon over
/// label. These live here so the two cannot drift apart.

/// Both navigations use a 68x56 item box, so a destination looks identical
/// whether it sits in the rail or the bottom bar.
const double shellNavItemWidth = 68.0;
const double shellNavItemHeight = 56.0;

/// The resting fill behind a selected destination: the card tone pulled a
/// third of the way back toward the scaffold, then held just short of opaque
/// so the paper grain still reads through it.
Color shellNavSelectedFill(ThemeData theme) => Color.lerp(
  theme.colorScheme.surface,
  theme.scaffoldBackgroundColor,
  0.35,
)!.withValues(alpha: 0.92);

/// Pointer-hover fill. Never appears on touch, where there is no hover state
/// to enter — the selected fill is what marks position there.
Color shellNavHoverFill(ThemeData theme) =>
    theme.colorScheme.onSurface.withValues(alpha: 0.10);

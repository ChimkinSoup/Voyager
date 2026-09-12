import 'package:flutter/material.dart';
import 'package:voyager/core/utils/journal_tags.dart' show resolveTagColor;

/// A stored entity color — a category, a bill, a calendar, a tracker — as it
/// should be painted under [brightness].
///
/// Those colors are picked from `defaultColorPalette`, which is the curated
/// tag ramp, so they are stored at the tint that reads on a dark surface.
/// That tint is a pastel: on a light surface Rosewater lands near 1.4:1,
/// which is tolerable as an 8px dot and invisible as the label text half
/// these sites paint with it.
///
/// Swapped here, at paint time, rather than at the picker, for the same
/// reason tags do it: the stored value syncs, and a device in light mode
/// must not rewrite the row a device in dark mode just wrote.
///
/// It is the tag resolve because it is the same ramp — one list, one light
/// twin, one index. Anything off the ramp comes back untouched: a color from
/// the pre-palette defaults, an accent derived from the theme, a swatch the
/// user added to their own palette.
int resolvePaletteColor(int stored, Brightness brightness) =>
    resolveTagColor(stored, brightness);

/// [stored] as it should be painted in [context]'s theme.
Color paletteColor(int stored, BuildContext context) =>
    Color(resolvePaletteColor(stored, Theme.of(context).brightness));

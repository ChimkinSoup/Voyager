import 'dart:ui' show Brightness;

/// A `#tag`: word characters, with inner hyphens joining them into one tag.
///
/// The hyphen is what lets a multi-word name be a single tag — LeetCode's topic
/// tags arrive as prose ("Hash Table", "Depth-First Search"), and without it
/// each word would be filed as a tag of its own. It has to be *inner*: a
/// trailing hyphen is punctuation the user is still typing past ("#done-"),
/// not part of the name.
final journalTagPattern = RegExp(r'#(\w+(?:-\w+)*)');

List<String> extractTags(String body) {
  final matches = journalTagPattern.allMatches(body);
  return {for (final match in matches) match.group(1)!}.toList();
}

/// The fourteen tag accents, at the tint that reads on a dark surface.
///
/// Catppuccin Frappe's accent ramp. Hand-picked rather than derived: mashing
/// a hash straight into RGB produced muds and near-blacks, and an accent-
/// derived ramp would reshuffle every tag whenever the accent changed.
const kTagPaletteDark = <int>[
  0xFFF2D5CF, // Rosewater
  0xFFEEBEBE, // Flamingo
  0xFFF4B8E4, // Pink
  0xFFCA9EE6, // Mauve
  0xFFE78284, // Red
  0xFFEA999C, // Maroon
  0xFFEF9F76, // Peach
  0xFFE5C890, // Yellow
  0xFFA6D189, // Green
  0xFF81C8BE, // Teal
  0xFF99D1DB, // Sky
  0xFF85C1DC, // Sapphire
  0xFF8CAAEE, // Blue
  0xFFBABBF1, // Lavender
];

/// The same fourteen accents at the tint that reads on a light surface.
///
/// Catppuccin Latte, **index for index** with [kTagPaletteDark] — Rosewater is
/// 0 in both. [resolveTagColor] leans on that alignment, so the two lists have
/// to be reordered together or not at all.
///
/// Two things forced the split. A dark palette's pastels are close to white:
/// Frappe's Rosewater lands around 1.4:1 on the cream card, which is fine as
/// an 8px dot and invisible as the `#tag` *text* the budget rows and the field
/// overlays paint with it. And stock Latte alone was not enough either — half
/// its accents sit between 2.3 and 3.0 there — so each one is scaled toward
/// black, hue held, until it clears 4.5:1. Mauve, Red and Blue already did and
/// are untouched.
///
/// Teal, Sapphire and Sky stay a close family, as they are in every Catppuccin
/// flavour; darkening compresses them a little further. They are far enough
/// apart to tell in a legend, not far enough to tell at a glance in a pie.
const kTagPaletteLight = <int>[
  0xFF9F6357, // Rosewater
  0xFFAA5C5C, // Flamingo
  0xFFA95593, // Pink
  0xFF8839EF, // Mauve
  0xFFD20F39, // Red
  0xFFCE3E4A, // Maroon
  0xFFC44D09, // Peach
  0xFFA06615, // Yellow
  0xFF348223, // Green
  0xFF147F86, // Teal
  0xFF037AAA, // Sky
  0xFF197D8F, // Sapphire
  0xFF1E66F5, // Blue
  0xFF5B6BC9, // Lavender
];

/// The stable color for [tag], in the canonical (dark) palette.
///
/// This is the value that gets *stored* and synced. Storage stays on one
/// palette on purpose: a device in light mode and a device in dark mode would
/// otherwise each rewrite the shared row to its own tint on every launch and
/// overwrite the other forever. The theme swap happens at paint time instead,
/// through [resolveTagColor].
///
/// Case-sensitive, deliberately — `#Food` and `#food` are stored as two tags
/// (see `rankTagsByUsage`), and folding here would only hide that.
int colorForTag(String tag) =>
    kTagPaletteDark[tag.hashCode.abs() % kTagPaletteDark.length];

/// [stored] as it should be painted under [brightness].
///
/// A color that isn't on the canonical palette comes back untouched: it is
/// either a row a pre-palette build wrote and [reconcileTagPalette] hasn't
/// reached yet, or a color that means something the palette doesn't, and
/// guessing an index for it would be worse than leaving it alone.
int resolveTagColor(int stored, Brightness brightness) {
  if (brightness != Brightness.light) return stored;
  final index = kTagPaletteDark.indexOf(stored);
  return index < 0 ? stored : kTagPaletteLight[index];
}

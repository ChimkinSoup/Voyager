import 'package:voyager/core/utils/journal_tags.dart' show kTagPaletteDark;

/// Default preset colors seeded on first launch and after migration.
///
/// The curated tag ramp by reference, not by copy. `resolvePaletteColor`
/// swaps a stored preset for its light twin *by index* into
/// `kTagPaletteLight`, so a second copy of these fourteen values could drift
/// out of alignment and quietly stop resolving. One app, one ramp — and
/// splitting entity presets off later means splitting both lists together.
const defaultColorPalette = kTagPaletteDark;

"""Regenerate the bundled IosevkaMono faces in assets/Iosevka-Regular/.

The upstream Iosevka Term release ships .ttc collections of ~66 MB holding
every width and slope; Flutter can only load .ttf, and the full single faces
are still ~10 MB each. This extracts the two faces the LeetCode code block
actually renders (upright and italic, weight 400) and subsets them to a
code-oriented character set, landing at roughly 400 KB apiece.

Usage:
    pip install fonttools
    python tool/subset_mono_font.py path/to/PkgTTC-SGr-IosevkaTerm-<version>

Dropping --layout-features leaves the subsetter's default retention list,
which keeps `calt` (Iosevka's code ligatures), `ccmp`, `locl` and the mark
positioning, while discarding the ss01..ssXX stylistic sets and the several
thousand alternate glyphs they pull in.
"""

import os
import sys

from fontTools import subset
from fontTools.ttLib import TTCollection

# Latin (+ext, IPA, combining diacritics), Greek, Cyrillic, general
# punctuation, currency, letterlike, arrows, math operators, misc technical,
# box drawing, block elements, geometric shapes, misc symbols, and the
# alphabetic presentation forms.
UNICODES = (
    "U+0000-024F,U+0250-02AF,U+0300-036F,U+0370-03FF,U+0400-04FF,"
    "U+2000-206F,U+20A0-20BF,U+2100-214F,U+2190-21FF,U+2200-22FF,"
    "U+2300-23FF,U+2500-257F,U+2580-259F,U+25A0-25FF,U+2600-26FF,"
    "U+FB00-FB4F,U+FE20-FE2F"
)

# (collection file, face index within it, output name). Face indices come from
# the collection's name table: 0 is the upright, 4 the true italic — 1/3/5 are
# the Extended width and the Oblique slope, which we do not ship.
FACES = [
    ("SGr-IosevkaTerm-Regular.ttc", 0, "Iosevka-Term-01.ttf"),
    ("SGr-IosevkaTerm-Regular.ttc", 4, "Iosevka-Term-Italic-03.ttf"),
]

DEST = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                    "assets", "Iosevka-Regular")


def main(source_dir: str) -> None:
    for collection, index, out_name in FACES:
        src = os.path.join(source_dir, collection)
        font = TTCollection(src).fonts[index]

        extracted = os.path.join(DEST, out_name + ".full")
        font.save(extracted)
        try:
            out = os.path.join(DEST, out_name)
            subset.main([extracted, "--unicodes=" + UNICODES, "--output-file=" + out])
            print("%-32s %6.0f KB" % (out_name, os.path.getsize(out) / 1024))
        finally:
            os.remove(extracted)


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    main(sys.argv[1])

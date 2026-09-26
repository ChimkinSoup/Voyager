/// Where the dense numbering put active starred tasks: [0, 999]. Keys are
/// sparse now (see [todoSortKeyGap]) and hold to no range; older builds, and
/// the rows they wrote, still use this one.
const starredSortOrderMax = 999;

/// The gap left between neighbouring to-do sort keys when a segment is
/// numbered afresh, and between a key placed past either end and its
/// neighbour.
///
/// Sparse keys let one placement write one row. Halving it leaves 32
/// placements at one spot before that segment has to be renumbered.
const todoSortKeyGap = 1 << 32;

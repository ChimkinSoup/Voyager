/// What one row of a side-by-side comparison is.
enum LeetCodeDiffKind {
  /// The same line on both sides.
  same,

  /// A line that exists on both sides but reads differently.
  changed,

  /// Only in the scratch pad — the user wrote it and the saved solution has
  /// no counterpart.
  removed,

  /// Only in the saved solution — the scratch pad is missing it.
  added,
}

/// One row of the comparison, holding whichever sides have a line for it.
///
/// Both panes are built from the same row list, so a row index means the same
/// place in both — which is what makes one scroll position drive both columns
/// without the two drifting apart wherever one side is longer.
class LeetCodeDiffRow {
  const LeetCodeDiffRow({
    required this.kind,
    this.left,
    this.right,
    this.leftNumber,
    this.rightNumber,
  });

  final LeetCodeDiffKind kind;

  /// Null on the side that has no line here — the pane renders a blank gutter
  /// and an empty row rather than pulling its next line up.
  final String? left;
  final String? right;

  /// 1-based line numbers in the original texts, so each column still counts
  /// its own file rather than the merged row list.
  final int? leftNumber;
  final int? rightNumber;
}

/// Beyond this many lines on either side the quadratic table is not worth
/// building — a comparison that big is scrolled, not read line by line, so the
/// rows are paired by position instead.
const _kLcsLineLimit = 400;

/// Aligns [scratch] against [solution] line by line.
///
/// A plain longest-common-subsequence: the lines both sides share stay put, and
/// what is left over between them is a run that changed. Runs are zipped so an
/// edited line sits opposite the line it replaced instead of below it — the
/// whole reason for a side-by-side rather than two independent listings.
List<LeetCodeDiffRow> leetCodeDiffLines(String scratch, String solution) {
  final left = scratch.split('\n');
  final right = solution.split('\n');
  if (left.length > _kLcsLineLimit || right.length > _kLcsLineLimit) {
    return _pairByPosition(left, right);
  }

  // table[i][j] = length of the LCS of left[i..] and right[j..].
  final table = List.generate(
    left.length + 1,
    (_) => List.filled(right.length + 1, 0),
    growable: false,
  );
  for (var i = left.length - 1; i >= 0; i--) {
    for (var j = right.length - 1; j >= 0; j--) {
      table[i][j] = left[i] == right[j]
          ? table[i + 1][j + 1] + 1
          : (table[i + 1][j] >= table[i][j + 1]
                ? table[i + 1][j]
                : table[i][j + 1]);
    }
  }

  final rows = <LeetCodeDiffRow>[];
  var i = 0;
  var j = 0;
  while (i < left.length && j < right.length) {
    if (left[i] == right[j]) {
      rows.add(
        LeetCodeDiffRow(
          kind: LeetCodeDiffKind.same,
          left: left[i],
          right: right[j],
          leftNumber: i + 1,
          rightNumber: j + 1,
        ),
      );
      i++;
      j++;
      continue;
    }
    // Collect the whole divergent run on both sides before emitting any of it,
    // so the two runs can be zipped rather than stacked.
    final removed = <int>[];
    final added = <int>[];
    while (i < left.length &&
        j < right.length &&
        left[i] != right[j]) {
      if (table[i + 1][j] >= table[i][j + 1]) {
        removed.add(i++);
      } else {
        added.add(j++);
      }
    }
    rows.addAll(_zip(left, right, removed, added));
  }
  rows.addAll(
    _zip(
      left,
      right,
      [for (var k = i; k < left.length; k++) k],
      [for (var k = j; k < right.length; k++) k],
    ),
  );
  return rows;
}

/// Puts a removed line opposite the added line that stands in its place, and
/// gives whichever run is longer blank counterparts for its tail.
List<LeetCodeDiffRow> _zip(
  List<String> left,
  List<String> right,
  List<int> removed,
  List<int> added,
) {
  final rows = <LeetCodeDiffRow>[];
  final pairs = removed.length < added.length ? removed.length : added.length;
  for (var k = 0; k < pairs; k++) {
    rows.add(
      LeetCodeDiffRow(
        kind: LeetCodeDiffKind.changed,
        left: left[removed[k]],
        right: right[added[k]],
        leftNumber: removed[k] + 1,
        rightNumber: added[k] + 1,
      ),
    );
  }
  for (var k = pairs; k < removed.length; k++) {
    rows.add(
      LeetCodeDiffRow(
        kind: LeetCodeDiffKind.removed,
        left: left[removed[k]],
        leftNumber: removed[k] + 1,
      ),
    );
  }
  for (var k = pairs; k < added.length; k++) {
    rows.add(
      LeetCodeDiffRow(
        kind: LeetCodeDiffKind.added,
        right: right[added[k]],
        rightNumber: added[k] + 1,
      ),
    );
  }
  return rows;
}

List<LeetCodeDiffRow> _pairByPosition(List<String> left, List<String> right) {
  final rows = <LeetCodeDiffRow>[];
  final longest = left.length > right.length ? left.length : right.length;
  for (var k = 0; k < longest; k++) {
    final l = k < left.length ? left[k] : null;
    final r = k < right.length ? right[k] : null;
    rows.add(
      LeetCodeDiffRow(
        kind: l == null
            ? LeetCodeDiffKind.added
            : (r == null
                  ? LeetCodeDiffKind.removed
                  : (l == r
                        ? LeetCodeDiffKind.same
                        : LeetCodeDiffKind.changed)),
        left: l,
        right: r,
        leftNumber: l == null ? null : k + 1,
        rightNumber: r == null ? null : k + 1,
      ),
    );
  }
  return rows;
}

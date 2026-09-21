/// What one user edit to an ordered, synced list means for its stored rows.
///
/// The edit arrives as the list the editor started from ([before]) and the one
/// it produced ([after]). Only the difference between the two is applied, never
/// [after] wholesale: the stored list may have gained or changed items from
/// another device since [before] was read, and replacing it with [after] would
/// delete them.
class OrderedListEdit<T> {
  const OrderedListEdit({required this.written, required this.removedIds});

  /// Items to write, each with the position it should be stored at: new items,
  /// items whose content changed, and items the user moved.
  final List<({T item, double position})> written;

  /// Ids the user removed.
  final List<String> removedIds;

  bool get isEmpty => written.isEmpty && removedIds.isEmpty;
}

/// Plans [before] → [after] against [storedPositions], the live stored rows'
/// positions by id.
///
/// An item counts as moved when it falls outside the longest run of items that
/// kept their relative order, so dragging one item moves only that item, and
/// adding or removing one moves nothing. A moved or added item is placed
/// between its nearest neighbours in [after] that have a stored position.
OrderedListEdit<T> planOrderedListEdit<T>({
  required List<T> before,
  required List<T> after,
  required String Function(T) idOf,
  required Map<String, double> storedPositions,
}) {
  final beforeById = {for (final item in before) idOf(item): item};
  final afterIds = {for (final item in after) idOf(item)};

  final keptInOrder = _longestCommonSubsequence(
    [
      for (final item in before)
        if (afterIds.contains(idOf(item))) idOf(item),
    ],
    [
      for (final item in after)
        if (beforeById.containsKey(idOf(item))) idOf(item),
    ],
  );

  // Positions the planner can place new items against: stored rows that stay
  // put, plus each item as it is placed.
  final anchored = <String, double>{
    for (final id in keptInOrder)
      if (storedPositions.containsKey(id)) id: storedPositions[id]!,
  };

  final written = <({T item, double position})>[];
  for (var i = 0; i < after.length; i++) {
    final item = after[i];
    final id = idOf(item);
    final original = beforeById[id];
    // Deleted on another device since the editor read the list. Dragging it
    // around is not a reason to bring it back; editing its content is.
    if (original == item && !storedPositions.containsKey(id)) continue;
    final moved =
        original == null ||
        !keptInOrder.contains(id) ||
        !storedPositions.containsKey(id);
    if (!moved) {
      if (original != item) {
        written.add((item: item, position: storedPositions[id]!));
      }
      continue;
    }
    double? previous;
    for (var j = i - 1; j >= 0 && previous == null; j--) {
      previous = anchored[idOf(after[j])];
    }
    double? next;
    for (var j = i + 1; j < after.length && next == null; j++) {
      next = anchored[idOf(after[j])];
    }
    final position = switch ((previous, next)) {
      (null, null) => 0.0,
      (final double p, null) => p + 1,
      (null, final double n) => n - 1,
      (final double p, final double n) => (p + n) / 2,
    };
    anchored[id] = position;
    written.add((item: item, position: position));
  }

  return OrderedListEdit(
    written: written,
    removedIds: [
      for (final item in before)
        if (!afterIds.contains(idOf(item))) idOf(item),
    ],
  );
}

Set<String> _longestCommonSubsequence(List<String> a, List<String> b) {
  final lengths = List.generate(
    a.length + 1,
    (_) => List<int>.filled(b.length + 1, 0),
  );
  for (var i = a.length - 1; i >= 0; i--) {
    for (var j = b.length - 1; j >= 0; j--) {
      lengths[i][j] = a[i] == b[j]
          ? lengths[i + 1][j + 1] + 1
          : (lengths[i + 1][j] > lengths[i][j + 1]
                ? lengths[i + 1][j]
                : lengths[i][j + 1]);
    }
  }
  final out = <String>{};
  var i = 0;
  var j = 0;
  while (i < a.length && j < b.length) {
    if (a[i] == b[j]) {
      out.add(a[i]);
      i++;
      j++;
    } else if (lengths[i + 1][j] >= lengths[i][j + 1]) {
      i++;
    } else {
      j++;
    }
  }
  return out;
}

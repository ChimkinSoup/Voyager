/// Active starred tasks use sort orders in [0, starredSortOrderMax].
const starredSortOrderMax = 999;

/// Unstarred active tasks use sort orders starting here.
const unstarredSortOrderBase = 1000;

int normalizeUnstarredSortOrder(int order) {
  if (order >= unstarredSortOrderBase) return order;
  return unstarredSortOrderBase + order;
}

/// The container a deleted one's contents go to: the one [preferredId] names
/// when it is among [candidates], or else the oldest. The id breaks ties so
/// every device picks the same one. Null when [candidates] is empty.
///
/// Shared by the journal delete's "Move" and the trash's restore, so the two
/// always agree.
T? pickFallbackContainer<T>(
  Iterable<T> candidates, {
  required String Function(T item) id,
  required DateTime Function(T item) createdAt,
  String? preferredId,
}) {
  T? oldest;
  for (final item in candidates) {
    if (id(item) == preferredId) return item;
    if (oldest == null) {
      oldest = item;
      continue;
    }
    final byAge = createdAt(item).compareTo(createdAt(oldest));
    if (byAge < 0 || (byAge == 0 && id(item).compareTo(id(oldest)) < 0)) {
      oldest = item;
    }
  }
  return oldest;
}

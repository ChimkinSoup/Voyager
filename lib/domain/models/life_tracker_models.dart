/// A single item on the Life Tracker bubble's bucket list. Unlike a to-do
/// task this has no due date or subtasks; completing one gives the option of
/// writing a note with background on how it happened.
class BucketListItem {
  const BucketListItem({
    required this.id,
    required this.title,
    this.note,
    this.completed = false,
    this.completedAt,
    this.sortOrder = 0,
    required this.createdAt,
    required this.updatedAt,
    this.version = 0,
    this.deletedAt,
  });

  final String id;
  final String title;
  final String? note;
  final bool completed;
  final DateTime? completedAt;
  final int sortOrder;
  final DateTime createdAt;
  final DateTime updatedAt;
  final int version;

  /// Set when the item is removed. A tombstone rather than a delete so the
  /// removal reaches the user's other devices.
  final DateTime? deletedAt;

  BucketListItem copyWith({
    String? title,
    String? note,
    /// Wipes an existing note. Needed because passing `note: ''` is
    /// indistinguishable from passing nothing under the `??` fallback, and
    /// re-completing an item with the note field left blank has to remove
    /// whatever the previous completion wrote.
    bool clearNote = false,
    bool? completed,
    DateTime? completedAt,
    bool clearCompletedAt = false,
    int? sortOrder,
    DateTime? updatedAt,
    int? version,
    DateTime? deletedAt,
    bool clearDeletedAt = false,
  }) {
    return BucketListItem(
      id: id,
      title: title ?? this.title,
      note: clearNote ? null : (note ?? this.note),
      completed: completed ?? this.completed,
      completedAt: clearCompletedAt ? null : (completedAt ?? this.completedAt),
      sortOrder: sortOrder ?? this.sortOrder,
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      version: version ?? this.version,
      deletedAt: clearDeletedAt ? null : (deletedAt ?? this.deletedAt),
    );
  }
}

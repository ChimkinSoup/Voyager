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
  });

  final String id;
  final String title;
  final String? note;
  final bool completed;
  final DateTime? completedAt;
  final int sortOrder;
  final DateTime createdAt;
  final DateTime updatedAt;

  BucketListItem copyWith({
    String? title,
    String? note,
    bool? completed,
    DateTime? completedAt,
    bool clearCompletedAt = false,
    int? sortOrder,
    DateTime? updatedAt,
  }) {
    return BucketListItem(
      id: id,
      title: title ?? this.title,
      note: note ?? this.note,
      completed: completed ?? this.completed,
      completedAt: clearCompletedAt ? null : (completedAt ?? this.completedAt),
      sortOrder: sortOrder ?? this.sortOrder,
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }
}

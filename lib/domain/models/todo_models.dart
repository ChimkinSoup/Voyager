import 'package:voyager/domain/models/soft_deletable.dart';

class TodoListModel extends SoftDeletable {
  const TodoListModel({
    required super.id,
    required super.createdAt,
    required super.updatedAt,
    super.version,
    super.deletedAt,
    required this.name,
    this.colorValue,
  });

  final String name;
  final int? colorValue;

  TodoListModel copyWith({
    String? name,
    int? colorValue,
    DateTime? deletedAt,
    bool bumpVersion = true,
  }) {
    return TodoListModel(
      id: id,
      createdAt: createdAt,
      updatedAt: DateTime.now().toUtc(),
      version: bumpVersion ? version + 1 : version,
      deletedAt: deletedAt ?? this.deletedAt,
      name: name ?? this.name,
      colorValue: colorValue ?? this.colorValue,
    );
  }
}

class TodoTask extends SoftDeletable {
  const TodoTask({
    required super.id,
    required super.createdAt,
    required super.updatedAt,
    super.version,
    super.deletedAt,
    required this.listId,
    required this.title,
    this.notes,
    this.dueDate,
    this.completed = false,
    this.starred = false,
    this.sortOrder = 0,
    this.preStarSortOrder,
    this.dueDateSetAt,
    this.parentTaskId,
  });

  final String listId;
  final String title;
  final String? notes;
  final DateTime? dueDate;
  final bool completed;
  final bool starred;
  final int sortOrder;
  final int? preStarSortOrder;
  final DateTime? dueDateSetAt;
  final String? parentTaskId;

  bool get isSubtask => parentTaskId != null;

  TodoTask copyWith({
    String? listId,
    String? title,
    String? notes,
    DateTime? dueDate,
    bool clearDueDate = false,
    bool clearNotes = false,
    bool? completed,
    bool? starred,
    int? sortOrder,
    int? preStarSortOrder,
    bool clearPreStarSortOrder = false,
    DateTime? dueDateSetAt,
    bool clearDueDateSetAt = false,
    DateTime? deletedAt,
    int? version,
    bool bumpVersion = true,
  }) {
    return TodoTask(
      id: id,
      createdAt: createdAt,
      updatedAt: DateTime.now().toUtc(),
      version: version ?? (bumpVersion ? this.version + 1 : this.version),
      deletedAt: deletedAt ?? this.deletedAt,
      listId: listId ?? this.listId,
      title: title ?? this.title,
      notes: clearNotes ? null : (notes ?? this.notes),
      dueDate: clearDueDate ? null : (dueDate ?? this.dueDate),
      completed: completed ?? this.completed,
      starred: starred ?? this.starred,
      sortOrder: sortOrder ?? this.sortOrder,
      preStarSortOrder: clearPreStarSortOrder
          ? null
          : (preStarSortOrder ?? this.preStarSortOrder),
      dueDateSetAt: clearDueDateSetAt
          ? null
          : (dueDateSetAt ?? this.dueDateSetAt),
      parentTaskId: parentTaskId,
    );
  }
}

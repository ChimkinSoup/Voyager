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

  Map<String, dynamic> toJson() => {
    'id': id,
    'createdAt': createdAt.toIso8601String(),
    'updatedAt': updatedAt.toIso8601String(),
    'version': version,
    'deletedAt': deletedAt?.toIso8601String(),
    'listId': listId,
    'title': title,
    'notes': notes,
    'dueDate': dueDate?.toIso8601String(),
    'completed': completed,
    'starred': starred,
    'sortOrder': sortOrder,
    'preStarSortOrder': preStarSortOrder,
    'dueDateSetAt': dueDateSetAt?.toIso8601String(),
    'parentTaskId': parentTaskId,
  };

  factory TodoTask.fromJson(Map<String, dynamic> json) {
    return TodoTask(
      id: json['id'] as String,
      createdAt: DateTime.parse(json['createdAt'] as String).toUtc(),
      updatedAt: DateTime.parse(json['updatedAt'] as String).toUtc(),
      version: json['version'] as int? ?? 0,
      deletedAt: json['deletedAt'] != null ? DateTime.parse(json['deletedAt'] as String).toUtc() : null,
      listId: json['listId'] as String,
      title: json['title'] as String,
      notes: json['notes'] as String?,
      dueDate: json['dueDate'] != null ? DateTime.parse(json['dueDate'] as String).toUtc() : null,
      completed: json['completed'] as bool? ?? false,
      starred: json['starred'] as bool? ?? false,
      sortOrder: json['sortOrder'] as int? ?? 0,
      preStarSortOrder: json['preStarSortOrder'] as int?,
      dueDateSetAt: json['dueDateSetAt'] != null ? DateTime.parse(json['dueDateSetAt'] as String).toUtc() : null,
      parentTaskId: json['parentTaskId'] as String?,
    );
  }
}

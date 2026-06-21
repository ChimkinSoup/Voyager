import 'package:voyager/domain/models/soft_deletable.dart';

class TodoListModel extends SoftDeletable {
  const TodoListModel({
    required super.id,
    required super.createdAt,
    required super.updatedAt,
    super.deletedAt,
    required this.name,
    this.colorValue,
  });

  final String name;
  final int? colorValue;

  TodoListModel copyWith({String? name, int? colorValue, DateTime? deletedAt}) {
    return TodoListModel(
      id: id,
      createdAt: createdAt,
      updatedAt: DateTime.now().toUtc(),
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
    super.deletedAt,
    required this.listId,
    required this.title,
    this.notes,
    this.dueDate,
    this.completed = false,
    this.starred = false,
    this.sortOrder = 0,
    this.preStarSortOrder,
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
  final String? parentTaskId;

  bool get isSubtask => parentTaskId != null;

  TodoTask copyWith({
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
    DateTime? deletedAt,
  }) {
    return TodoTask(
      id: id,
      createdAt: createdAt,
      updatedAt: DateTime.now().toUtc(),
      deletedAt: deletedAt ?? this.deletedAt,
      listId: listId,
      title: title ?? this.title,
      notes: clearNotes ? null : (notes ?? this.notes),
      dueDate: clearDueDate ? null : (dueDate ?? this.dueDate),
      completed: completed ?? this.completed,
      starred: starred ?? this.starred,
      sortOrder: sortOrder ?? this.sortOrder,
      preStarSortOrder: clearPreStarSortOrder
          ? null
          : (preStarSortOrder ?? this.preStarSortOrder),
      parentTaskId: parentTaskId,
    );
  }
}

int compareTodoTasks(TodoTask a, TodoTask b) {
  if (a.starred != b.starred) return a.starred ? -1 : 1;
  final order = a.sortOrder.compareTo(b.sortOrder);
  if (order != 0) return order;
  return a.createdAt.compareTo(b.createdAt);
}

List<TodoTask> sortTodoTasks(Iterable<TodoTask> tasks) {
  final sorted = tasks.toList()..sort(compareTodoTasks);
  return sorted;
}

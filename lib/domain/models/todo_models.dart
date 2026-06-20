import 'package:voyager/domain/models/soft_deletable.dart';

class TodoListModel extends SoftDeletable {
  const TodoListModel({
    required super.id,
    required super.createdAt,
    required super.updatedAt,
    super.deletedAt,
    required this.name,
  });

  final String name;

  TodoListModel copyWith({String? name, DateTime? deletedAt}) {
    return TodoListModel(
      id: id,
      createdAt: createdAt,
      updatedAt: DateTime.now().toUtc(),
      deletedAt: deletedAt ?? this.deletedAt,
      name: name ?? this.name,
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
  });

  final String listId;
  final String title;
  final String? notes;
  final DateTime? dueDate;
  final bool completed;

  TodoTask copyWith({
    String? title,
    String? notes,
    DateTime? dueDate,
    bool? completed,
    DateTime? deletedAt,
  }) {
    return TodoTask(
      id: id,
      createdAt: createdAt,
      updatedAt: DateTime.now().toUtc(),
      deletedAt: deletedAt ?? this.deletedAt,
      listId: listId,
      title: title ?? this.title,
      notes: notes ?? this.notes,
      dueDate: dueDate ?? this.dueDate,
      completed: completed ?? this.completed,
    );
  }
}

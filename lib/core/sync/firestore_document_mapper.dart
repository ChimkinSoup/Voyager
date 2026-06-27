import 'package:voyager/core/constants/journal_constants.dart';
import 'package:voyager/core/utils/ids.dart';
import 'package:voyager/domain/models/journal_models.dart';
import 'package:voyager/domain/models/todo_models.dart';
import 'package:voyager/core/constants/todo_constants.dart';

DateTime? parseFirestoreDate(dynamic value) {
  if (value == null) return null;
  if (value is DateTime) return value.toUtc();
  if (value is String) return DateTime.tryParse(value)?.toUtc();
  try {
    final result = value.toDate();
    if (result is DateTime) return result.toUtc();
  } catch (_) {
    // Not a Firestore Timestamp.
  }
  return null;
}

DateTime parseFirestoreDateOrNow(dynamic value) =>
    parseFirestoreDate(value) ?? utcNow();

String? _dateToFirestore(DateTime? value) => value?.toUtc().toIso8601String();

bool remoteUpdatedAtWins(DateTime? remote, DateTime? local) {
  final r = remote ?? DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
  final l = local ?? DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
  return !r.isBefore(l);
}

Map<String, dynamic> journalToFirestore(Journal journal) => {
  'id': journalDocumentIdForFirestore(journal.id),
  'name': journal.name,
  'colorValue': journal.colorValue,
  'guidedJournaling': journal.guidedJournaling,
  'promptCycleDays': journal.promptCycleDays,
  'createdAt': journal.createdAt.toIso8601String(),
  'updatedAt': journal.updatedAt.toIso8601String(),
  'deletedAt': _dateToFirestore(journal.deletedAt),
};

Journal mergeJournalFromRemote(
  Map<String, dynamic> data,
  String id, {
  Journal? local,
}) {
  final remoteUpdated = parseFirestoreDate(data['updatedAt']) ?? utcNow();
  if (local != null && !remoteUpdatedAtWins(remoteUpdated, local.updatedAt)) {
    return local;
  }

  return Journal(
    id: id,
    name: data['name'] as String? ?? local?.name ?? 'Journal',
    colorValue: data.containsKey('colorValue')
        ? data['colorValue'] as int?
        : local?.colorValue,
    guidedJournaling: data['guidedJournaling'] as bool? ??
        local?.guidedJournaling ??
        false,
    promptCycleDays: (data['promptCycleDays'] as num?)?.toInt() ??
        local?.promptCycleDays ??
        7,
    createdAt: parseFirestoreDate(data['createdAt']) ??
        local?.createdAt ??
        remoteUpdated,
    updatedAt: remoteUpdated,
    deletedAt: parseFirestoreDate(data['deletedAt']) ?? local?.deletedAt,
  );
}

Map<String, dynamic> journalEntryToFirestore(JournalEntry entry) => {
  'id': entry.id,
  'journalId': journalReferenceIdForFirestore(entry.journalId),
  'title': entry.title,
  'body': entry.body,
  'richBodyJson': entry.richBodyJson,
  'entryDate': entry.entryDate.toIso8601String(),
  'timestamp': _dateToFirestore(entry.timestamp),
  'tags': entry.tags,
  'mood': entry.mood,
  'quoteId': entry.quoteId,
  'customQuote': entry.customQuote,
  'weatherIcon': entry.weatherIcon,
  'guidedPrompt': entry.guidedPrompt,
  'createdAt': entry.createdAt.toIso8601String(),
  'updatedAt': entry.updatedAt.toIso8601String(),
  'deletedAt': _dateToFirestore(entry.deletedAt),
};

JournalEntry mergeJournalEntryFromRemote(
  Map<String, dynamic> data,
  String id, {
  JournalEntry? local,
}) {
  final remoteUpdated = parseFirestoreDate(data['updatedAt']) ?? utcNow();
  if (local != null && !remoteUpdatedAtWins(remoteUpdated, local.updatedAt)) {
    return local;
  }

  return JournalEntry(
    id: id,
    journalId: journalReferenceIdFromFirestore(
      data['journalId'] as String? ?? local?.journalId ?? legacyJournalId,
    ),
    title: data['title'] as String? ?? local?.title ?? '',
    body: data['body'] as String? ?? local?.body ?? '',
    richBodyJson: data.containsKey('richBodyJson')
        ? data['richBodyJson'] as String?
        : local?.richBodyJson,
    entryDate: parseFirestoreDate(data['entryDate']) ??
        local?.entryDate ??
        remoteUpdated,
    timestamp: data.containsKey('timestamp')
        ? parseFirestoreDate(data['timestamp'])
        : local?.timestamp,
    tags: data['tags'] != null
        ? List<String>.from(data['tags'] as List)
        : local?.tags ?? const [],
    mood: data.containsKey('mood') ? data['mood'] as int? : local?.mood,
    quoteId: data.containsKey('quoteId')
        ? data['quoteId'] as String?
        : local?.quoteId,
    customQuote: data.containsKey('customQuote')
        ? data['customQuote'] as String?
        : local?.customQuote,
    weatherIcon: data.containsKey('weatherIcon')
        ? data['weatherIcon'] as String?
        : local?.weatherIcon,
    guidedPrompt: data.containsKey('guidedPrompt')
        ? data['guidedPrompt'] as String?
        : local?.guidedPrompt,
    createdAt: parseFirestoreDate(data['createdAt']) ??
        local?.createdAt ??
        remoteUpdated,
    updatedAt: remoteUpdated,
    deletedAt: parseFirestoreDate(data['deletedAt']) ?? local?.deletedAt,
  );
}

Map<String, dynamic> todoListToFirestore(TodoListModel list) => {
  'id': todoListDocumentIdForFirestore(list.id),
  'name': list.name,
  'colorValue': list.colorValue,
  'createdAt': list.createdAt.toIso8601String(),
  'updatedAt': list.updatedAt.toIso8601String(),
  'deletedAt': _dateToFirestore(list.deletedAt),
};

TodoListModel mergeTodoListFromRemote(
  Map<String, dynamic> data,
  String id, {
  TodoListModel? local,
}) {
  final remoteUpdated = parseFirestoreDate(data['updatedAt']) ?? utcNow();
  if (local != null && !remoteUpdatedAtWins(remoteUpdated, local.updatedAt)) {
    return local;
  }

  return TodoListModel(
    id: id,
    name: data['name'] as String? ?? local?.name ?? 'List',
    colorValue: data.containsKey('colorValue')
        ? data['colorValue'] as int?
        : local?.colorValue,
    createdAt: parseFirestoreDate(data['createdAt']) ??
        local?.createdAt ??
        remoteUpdated,
    updatedAt: remoteUpdated,
    deletedAt: parseFirestoreDate(data['deletedAt']) ?? local?.deletedAt,
  );
}

Map<String, dynamic> todoTaskToFirestore(TodoTask task) => {
  'id': task.id,
  'listId': todoListDocumentIdForFirestore(task.listId),
  'title': task.title,
  'notes': task.notes,
  'dueDate': _dateToFirestore(task.dueDate),
  'completed': task.completed,
  'starred': task.starred,
  'sortOrder': task.sortOrder,
  'preStarSortOrder': task.preStarSortOrder,
  'dueDateSetAt': _dateToFirestore(task.dueDateSetAt),
  'parentTaskId': task.parentTaskId,
  'createdAt': task.createdAt.toIso8601String(),
  'updatedAt': task.updatedAt.toIso8601String(),
  'deletedAt': _dateToFirestore(task.deletedAt),
};

TodoTask mergeTodoTaskFromRemote(
  Map<String, dynamic> data,
  String id, {
  TodoTask? local,
}) {
  final remoteUpdated = parseFirestoreDate(data['updatedAt']) ?? utcNow();
  if (local != null && !remoteUpdatedAtWins(remoteUpdated, local.updatedAt)) {
    return local;
  }

  final listId = data['listId'] as String? ?? local?.listId;
  if (listId == null) {
    throw StateError('Remote todo task $id is missing listId.');
  }

  return TodoTask(
    id: id,
    listId: listId,
    title: data['title'] as String? ?? local?.title ?? '',
    notes: data.containsKey('notes') ? data['notes'] as String? : local?.notes,
    dueDate: data.containsKey('dueDate')
        ? parseFirestoreDate(data['dueDate'])
        : local?.dueDate,
    completed: data['completed'] as bool? ?? local?.completed ?? false,
    starred: data['starred'] as bool? ?? local?.starred ?? false,
    sortOrder: (data['sortOrder'] as num?)?.toInt() ??
        local?.sortOrder ??
        0,
    preStarSortOrder: data.containsKey('preStarSortOrder')
        ? (data['preStarSortOrder'] as num?)?.toInt()
        : local?.preStarSortOrder,
    dueDateSetAt: data.containsKey('dueDateSetAt')
        ? parseFirestoreDate(data['dueDateSetAt'])
        : local?.dueDateSetAt,
    parentTaskId: data.containsKey('parentTaskId')
        ? data['parentTaskId'] as String?
        : local?.parentTaskId,
    createdAt: parseFirestoreDate(data['createdAt']) ??
        local?.createdAt ??
        remoteUpdated,
    updatedAt: remoteUpdated,
    deletedAt: parseFirestoreDate(data['deletedAt']) ?? local?.deletedAt,
  );
}

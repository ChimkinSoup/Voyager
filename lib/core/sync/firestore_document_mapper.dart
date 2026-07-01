import 'package:voyager/core/constants/journal_constants.dart';
import 'package:voyager/core/constants/todo_constants.dart';
import 'package:voyager/core/sync/firestore_collections.dart';
import 'package:voyager/core/utils/ids.dart';
import 'package:voyager/domain/models/journal_models.dart';
import 'package:voyager/domain/models/todo_models.dart';

/// Firestore document id for a locally stored document (handles legacy id mapping).
String firestoreDocumentIdForLocal(String collection, String localDocumentId) {
  if (collection == FirestoreCollections.journals) {
    return journalDocumentIdForFirestore(localDocumentId);
  }
  if (collection == FirestoreCollections.todoLists) {
    return todoListDocumentIdForFirestore(localDocumentId);
  }
  return localDocumentId;
}

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

int parseVersion(Map<String, dynamic> data) =>
    (data['version'] as num?)?.toInt() ?? 0;

bool remoteUpdatedAtWins(DateTime? remote, DateTime? local) {
  final r = remote ?? DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
  final l = local ?? DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
  return !r.isBefore(l);
}

/// Version-first conflict resolution; [updatedAt] is the tie-breaker.
bool remoteVersionWins({
  required int remoteVersion,
  required int localVersion,
  required DateTime? remoteUpdated,
  required DateTime? localUpdated,
}) {
  if (remoteVersion != localVersion) return remoteVersion > localVersion;
  return remoteUpdatedAtWins(remoteUpdated, localUpdated);
}

/// Keeps a local soft-delete when remote payloads omit [deletedAt].
DateTime? mergeDeletedAtFromRemote(
  Map<String, dynamic> data,
  DateTime? localDeletedAt, {
  bool remoteWins = true,
}) {
  if (!remoteWins) return localDeletedAt;
  final remoteDeleted = parseFirestoreDate(data['deletedAt']);
  if (remoteDeleted != null) return remoteDeleted;
  return localDeletedAt;
}

/// CRDT-resolved text fields that bypass document-level LWW gates.
class CrdtTextFields {
  const CrdtTextFields({
    required this.body,
    this.richBodyJson,
    this.tags = const [],
    this.notes,
  });

  final String body;
  final String? richBodyJson;
  final List<String> tags;
  final String? notes;

  factory CrdtTextFields.fromJournalPayload(Map<String, dynamic> data) {
    return CrdtTextFields(
      body: data['body'] as String? ?? '',
      richBodyJson: data.containsKey('richBodyJson')
          ? data['richBodyJson'] as String?
          : null,
      tags: data['tags'] != null
          ? List<String>.from(data['tags'] as List)
          : const [],
    );
  }

  factory CrdtTextFields.fromTodoPayload(Map<String, dynamic> data) {
    return CrdtTextFields(
      body: '',
      notes: data.containsKey('notes') ? data['notes'] as String? : null,
    );
  }
}

Map<String, dynamic> journalToFirestore(Journal journal) => {
  'id': journalDocumentIdForFirestore(journal.id),
  'name': journal.name,
  'colorValue': journal.colorValue,
  'guidedJournaling': journal.guidedJournaling,
  'promptCycleDays': journal.promptCycleDays,
  'createdAt': journal.createdAt.toIso8601String(),
  'updatedAt': journal.updatedAt.toIso8601String(),
  'version': journal.version,
  'deletedAt': _dateToFirestore(journal.deletedAt),
};

Journal mergeJournalFromRemote(
  Map<String, dynamic> data,
  String id, {
  Journal? local,
}) {
  final remoteUpdated = parseFirestoreDate(data['updatedAt']) ?? utcNow();
  final remoteVersion = parseVersion(data);
  if (local != null &&
      !remoteVersionWins(
        remoteVersion: remoteVersion,
        localVersion: local.version,
        remoteUpdated: remoteUpdated,
        localUpdated: local.updatedAt,
      )) {
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
    version: remoteVersion,
    deletedAt: mergeDeletedAtFromRemote(data, local?.deletedAt),
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
  'version': entry.version,
  'deletedAt': _dateToFirestore(entry.deletedAt),
};

JournalEntry mergeJournalEntryFromRemote(
  Map<String, dynamic> data,
  String id, {
  JournalEntry? local,
  CrdtTextFields? crdtText,
}) {
  final remoteUpdated = parseFirestoreDate(data['updatedAt']) ?? utcNow();
  final remoteVersion = parseVersion(data);
  final metadataRemoteWins = local == null ||
      remoteVersionWins(
        remoteVersion: remoteVersion,
        localVersion: local.version,
        remoteUpdated: remoteUpdated,
        localUpdated: local.updatedAt,
      );

  final String body;
  final String? richBodyJson;
  final List<String> tags;
  if (crdtText != null) {
    body = crdtText.body;
    richBodyJson = crdtText.richBodyJson ?? local?.richBodyJson;
    tags = crdtText.tags;
  } else if (metadataRemoteWins) {
    body = data['body'] as String? ?? local?.body ?? '';
    richBodyJson = data.containsKey('richBodyJson')
        ? data['richBodyJson'] as String?
        : local?.richBodyJson;
    tags = data['tags'] != null
        ? List<String>.from(data['tags'] as List)
        : local?.tags ?? const [];
  } else {
    body = local!.body;
    richBodyJson = local.richBodyJson;
    tags = local.tags;
  }

  final resolvedVersion = metadataRemoteWins
      ? remoteVersion
      : local?.version ?? remoteVersion;
  final resolvedUpdated = metadataRemoteWins
      ? remoteUpdated
      : local?.updatedAt ?? remoteUpdated;

  return JournalEntry(
    id: id,
    journalId: journalReferenceIdFromFirestore(
      data['journalId'] as String? ?? local?.journalId ?? legacyJournalId,
    ),
    title: metadataRemoteWins
        ? (data['title'] as String? ?? local?.title ?? '')
        : local!.title,
    body: body,
    richBodyJson: richBodyJson,
    entryDate: metadataRemoteWins
        ? (parseFirestoreDate(data['entryDate']) ??
            local?.entryDate ??
            remoteUpdated)
        : local!.entryDate,
    timestamp: metadataRemoteWins
        ? (data.containsKey('timestamp')
            ? parseFirestoreDate(data['timestamp'])
            : local?.timestamp)
        : local!.timestamp,
    tags: tags,
    mood: metadataRemoteWins
        ? (data.containsKey('mood') ? data['mood'] as int? : local?.mood)
        : local!.mood,
    quoteId: metadataRemoteWins
        ? (data.containsKey('quoteId')
            ? data['quoteId'] as String?
            : local?.quoteId)
        : local!.quoteId,
    customQuote: metadataRemoteWins
        ? (data.containsKey('customQuote')
            ? data['customQuote'] as String?
            : local?.customQuote)
        : local!.customQuote,
    weatherIcon: metadataRemoteWins
        ? (data.containsKey('weatherIcon')
            ? data['weatherIcon'] as String?
            : local?.weatherIcon)
        : local!.weatherIcon,
    guidedPrompt: metadataRemoteWins
        ? (data.containsKey('guidedPrompt')
            ? data['guidedPrompt'] as String?
            : local?.guidedPrompt)
        : local!.guidedPrompt,
    createdAt: parseFirestoreDate(data['createdAt']) ??
        local?.createdAt ??
        remoteUpdated,
    updatedAt: resolvedUpdated,
    version: resolvedVersion,
    deletedAt: mergeDeletedAtFromRemote(data, local?.deletedAt, remoteWins: metadataRemoteWins),
  );
}

Map<String, dynamic> todoListToFirestore(TodoListModel list) => {
  'id': todoListDocumentIdForFirestore(list.id),
  'name': list.name,
  'colorValue': list.colorValue,
  'createdAt': list.createdAt.toIso8601String(),
  'updatedAt': list.updatedAt.toIso8601String(),
  'version': list.version,
  'deletedAt': _dateToFirestore(list.deletedAt),
};

TodoListModel mergeTodoListFromRemote(
  Map<String, dynamic> data,
  String id, {
  TodoListModel? local,
}) {
  final remoteUpdated = parseFirestoreDate(data['updatedAt']) ?? utcNow();
  final remoteVersion = parseVersion(data);
  if (local != null &&
      !remoteVersionWins(
        remoteVersion: remoteVersion,
        localVersion: local.version,
        remoteUpdated: remoteUpdated,
        localUpdated: local.updatedAt,
      )) {
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
    version: remoteVersion,
    deletedAt: mergeDeletedAtFromRemote(data, local?.deletedAt),
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
  'version': task.version,
  'deletedAt': _dateToFirestore(task.deletedAt),
};

TodoTask mergeTodoTaskFromRemote(
  Map<String, dynamic> data,
  String id, {
  TodoTask? local,
  CrdtTextFields? crdtText,
}) {
  final remoteUpdated = parseFirestoreDate(data['updatedAt']) ?? utcNow();
  final remoteVersion = parseVersion(data);
  final metadataRemoteWins = local == null ||
      remoteVersionWins(
        remoteVersion: remoteVersion,
        localVersion: local.version,
        remoteUpdated: remoteUpdated,
        localUpdated: local.updatedAt,
      );

  final String? notes;
  if (crdtText != null) {
    notes = crdtText.notes;
  } else if (metadataRemoteWins) {
    notes = data.containsKey('notes') ? data['notes'] as String? : local?.notes;
  } else {
    notes = local!.notes;
  }

  final listId = data['listId'] as String? ?? local?.listId;
  if (listId == null) {
    throw StateError('Remote todo task $id is missing listId.');
  }

  final resolvedVersion = metadataRemoteWins
      ? remoteVersion
      : local?.version ?? remoteVersion;
  final resolvedUpdated = metadataRemoteWins
      ? remoteUpdated
      : local?.updatedAt ?? remoteUpdated;

  return TodoTask(
    id: id,
    listId: listId,
    title: metadataRemoteWins
        ? (data['title'] as String? ?? local?.title ?? '')
        : local!.title,
    notes: notes,
    dueDate: metadataRemoteWins
        ? (data.containsKey('dueDate')
            ? parseFirestoreDate(data['dueDate'])
            : local?.dueDate)
        : local!.dueDate,
    completed: metadataRemoteWins
        ? (data['completed'] as bool? ?? local?.completed ?? false)
        : local!.completed,
    starred: metadataRemoteWins
        ? (data['starred'] as bool? ?? local?.starred ?? false)
        : local!.starred,
    sortOrder: metadataRemoteWins
        ? ((data['sortOrder'] as num?)?.toInt() ?? local?.sortOrder ?? 0)
        : local!.sortOrder,
    preStarSortOrder: metadataRemoteWins
        ? (data.containsKey('preStarSortOrder')
            ? (data['preStarSortOrder'] as num?)?.toInt()
            : local?.preStarSortOrder)
        : local!.preStarSortOrder,
    dueDateSetAt: metadataRemoteWins
        ? (data.containsKey('dueDateSetAt')
            ? parseFirestoreDate(data['dueDateSetAt'])
            : local?.dueDateSetAt)
        : local!.dueDateSetAt,
    parentTaskId: metadataRemoteWins
        ? (data.containsKey('parentTaskId')
            ? data['parentTaskId'] as String?
            : local?.parentTaskId)
        : local!.parentTaskId,
    createdAt: parseFirestoreDate(data['createdAt']) ??
        local?.createdAt ??
        remoteUpdated,
    updatedAt: resolvedUpdated,
    version: resolvedVersion,
    deletedAt: mergeDeletedAtFromRemote(data, local?.deletedAt, remoteWins: metadataRemoteWins),
  );
}

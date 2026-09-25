import 'dart:convert';

import 'package:voyager/core/constants/default_color_palette.dart';
import 'package:voyager/core/constants/calendar_constants.dart';
import 'package:voyager/core/constants/journal_constants.dart';
import 'package:voyager/core/constants/todo_constants.dart';
import 'package:voyager/core/sync/firestore_collections.dart';
import 'package:voyager/core/utils/ids.dart';
import 'package:voyager/domain/models/analytics_models.dart';
import 'package:voyager/domain/models/calendar_models.dart';
import 'package:voyager/domain/services/calendar_recurrence.dart';
import 'package:voyager/domain/models/contribution_room_models.dart';
import 'package:voyager/domain/models/dream_models.dart';
import 'package:voyager/domain/models/enums.dart';
import 'package:voyager/domain/models/finance_models.dart';
import 'package:voyager/domain/models/job_models.dart';
import 'package:voyager/domain/models/journal_models.dart';
import 'package:voyager/domain/models/leetcode_cheat_models.dart';
import 'package:voyager/domain/models/leetcode_models.dart';
import 'package:voyager/domain/models/life_tracker_models.dart';
import 'package:voyager/domain/models/media_models.dart';
import 'package:voyager/domain/models/notification_models.dart';
import 'package:voyager/domain/models/ranking_models.dart';
import 'package:voyager/domain/models/reminder_models.dart';
import 'package:voyager/domain/models/settings_models.dart';
import 'package:voyager/domain/models/study_models.dart';
import 'package:voyager/domain/models/workout_models.dart';
import 'package:voyager/domain/models/todo_models.dart';

/// Collections whose document id is user text — a tag, a dictionary word, a
/// dismissal key — and so has to be encoded to be legal as a Firestore id.
const encodedIdCollections = {
  FirestoreCollections.tagColors,
  FirestoreCollections.customWords,
  FirestoreCollections.flaggedWords,
  FirestoreCollections.dismissedNotifications,
};

/// Firestore document id for a locally stored document.
///
/// The one place the local → remote id mapping lives, so the outbox, the
/// pulls and the deletes cannot disagree about where a document lives. Handles
/// both legacy id mapping and the text-keyed collections; everything else is
/// its own id.
String firestoreDocumentIdForLocal(String collection, String localDocumentId) {
  if (collection == FirestoreCollections.journals) {
    return journalDocumentIdForFirestore(localDocumentId);
  }
  if (collection == FirestoreCollections.todoLists) {
    return todoListDocumentIdForFirestore(localDocumentId);
  }
  if (collection == FirestoreCollections.calendars) {
    return calendarDocumentIdForFirestore(localDocumentId);
  }
  if (encodedIdCollections.contains(collection)) {
    return encodeDocumentId(localDocumentId);
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

/// Non-nullable counterpart of [_dateToFirestore].
///
/// Required because Drift returns `DateTime` values read from SQLite with
/// `isUtc == false` (it stores unix timestamps and reconstructs them as
/// local time), even though the app always writes UTC instants. Serializing
/// those values with a bare `.toIso8601String()` silently prints the wall
/// clock time with no timezone marker, which is off by the device's UTC
/// offset from the real instant once compared elsewhere (e.g. in the sync
/// conflict UI). Always normalize to UTC before serializing.
String _dateToFirestoreRequired(DateTime value) =>
    value.toUtc().toIso8601String();

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

/// Resolves [deletedAt] for a record whose remote copy is being adopted.
///
/// [remoteWins] is the caller's document-level verdict: it is only true once
/// the remote record has already outranked the local one on version (see
/// `remoteVersionWins`). When it has, the remote payload is authoritative for
/// *every* field, including the absence of a tombstone — so a record restored
/// on another device un-deletes here.
///
/// This previously kept the local tombstone whenever the remote payload
/// omitted one, which made an un-delete impossible to propagate in either
/// direction: `softDelete` could set a tombstone but no newer revision could
/// ever lift it, so a value re-entered on one device stayed invisible on the
/// others forever.
///
/// A record that only *predates* the local one never reaches here with
/// [remoteWins] true, so a stale remote copy still cannot resurrect something
/// this device deleted.
DateTime? mergeDeletedAtFromRemote(
  Map<String, dynamic> data,
  DateTime? localDeletedAt, {
  bool remoteWins = true,
}) {
  if (!remoteWins) return localDeletedAt;
  return parseFirestoreDate(data['deletedAt']);
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

  factory CrdtTextFields.fromDreamPayload(Map<String, dynamic> data) {
    return CrdtTextFields(body: data['body'] as String? ?? '');
  }
}

Map<String, dynamic> journalToFirestore(Journal journal) => {
  'id': journalDocumentIdForFirestore(journal.id),
  'name': journal.name,
  'colorValue': journal.colorValue,
  'guidedJournaling': journal.guidedJournaling,
  'promptCycleDays': journal.promptCycleDays,
  'showMood': journal.showMood,
  'showWeather': journal.showWeather,
  'showQuotes': journal.showQuotes,
  'includeInAllView': journal.includeInAllView,
  'onThisDayCadence': journal.onThisDayCadence.name,
  'createdAt': _dateToFirestoreRequired(journal.createdAt),
  'updatedAt': _dateToFirestoreRequired(journal.updatedAt),
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
    guidedJournaling:
        data['guidedJournaling'] as bool? ?? local?.guidedJournaling ?? false,
    promptCycleDays:
        (data['promptCycleDays'] as num?)?.toInt() ??
        local?.promptCycleDays ??
        7,
    showMood: data['showMood'] as bool? ?? local?.showMood ?? true,
    showWeather: data['showWeather'] as bool? ?? local?.showWeather ?? true,
    showQuotes: data['showQuotes'] as bool? ?? local?.showQuotes ?? true,
    includeInAllView:
        data['includeInAllView'] as bool? ?? local?.includeInAllView ?? true,
    onThisDayCadence: _enumFromName(
      OnThisDayCadence.values,
      data['onThisDayCadence'],
      local?.onThisDayCadence ?? OnThisDayCadence.off,
    ),
    createdAt:
        parseFirestoreDate(data['createdAt']) ??
        local?.createdAt ??
        remoteUpdated,
    updatedAt: remoteUpdated,
    version: remoteVersion,
    deletedAt: mergeDeletedAtFromRemote(data, local?.deletedAt),
  );
}

Map<String, dynamic> leetCodeProblemToFirestore(LeetCodeProblem problem) => {
  'id': problem.id,
  'title': problem.title,
  'questionId': problem.questionId,
  'questionFrontendId': problem.questionFrontendId,
  'titleSlug': problem.titleSlug,
  'difficulty': problem.difficulty.name,
  'tags': problem.tags,
  'description': problem.description,
  'examples': problem.examples,
  'solutions': [for (final s in problem.solutions) s.toJson()],
  // Solution 1 also goes out in the flat keys a device on an older build
  // reads, so it shows the primary write-up instead of a blank card. That
  // device writing back is handled on the way in.
  ...leetCodeLegacySolutionFields(problem.primarySolution),
  'solvedAt': _dateToFirestoreRequired(problem.solvedAt),
  'interval': problem.interval,
  'ease': problem.ease,
  'dueAt': _dateToFirestore(problem.dueAt),
  'reviewCount': problem.reviewCount,
  'createdAt': _dateToFirestoreRequired(problem.createdAt),
  'updatedAt': _dateToFirestoreRequired(problem.updatedAt),
  'version': problem.version,
  'deletedAt': _dateToFirestore(problem.deletedAt),
};

LeetCodeDifficulty _parseLeetCodeDifficulty(dynamic value) {
  if (value is String) {
    for (final d in LeetCodeDifficulty.values) {
      if (d.name == value) return d;
    }
  }
  return LeetCodeDifficulty.medium;
}

const _legacyLeetCodeSolutionKeys = [
  'algorithm',
  'timeComplexity',
  'spaceComplexity',
  'explanation',
  'code',
  'notes',
];

List<LeetCodeSolution> _mergeLeetCodeSolutions(
  Map<String, dynamic> data,
  LeetCodeProblem? local,
) {
  if (data['solutions'] != null) {
    return LeetCodeSolution.listFromJson(data['solutions'] as List);
  }
  // `codeLanguage` is deliberately not on its own a sign of an edit: it has a
  // default, so a document can carry one with nothing else written down.
  if (_legacyLeetCodeSolutionKeys.any(data.containsKey)) {
    return leetCodeSolutionsFromLegacyFields(
      algorithm: data['algorithm'] as String?,
      timeComplexity: data['timeComplexity'] as String?,
      spaceComplexity: data['spaceComplexity'] as String?,
      explanation: data['explanation'] as String?,
      codeLanguage: data['codeLanguage'] as String?,
      code: data['code'] as String?,
      notes: data['notes'] as String?,
    );
  }
  return local?.solutions ?? const [];
}

LeetCodeProblem mergeLeetCodeProblemFromRemote(
  Map<String, dynamic> data,
  String id, {
  LeetCodeProblem? local,
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

  return LeetCodeProblem(
    id: id,
    title: data['title'] as String? ?? local?.title ?? 'Untitled problem',
    questionId: data.containsKey('questionId')
        ? data['questionId'] as String?
        : local?.questionId,
    questionFrontendId: data.containsKey('questionFrontendId')
        ? data['questionFrontendId'] as String?
        : local?.questionFrontendId,
    titleSlug: data.containsKey('titleSlug')
        ? data['titleSlug'] as String?
        : local?.titleSlug,
    difficulty: data.containsKey('difficulty')
        ? _parseLeetCodeDifficulty(data['difficulty'])
        : local?.difficulty ?? LeetCodeDifficulty.medium,
    tags: data['tags'] != null
        ? List<String>.from(data['tags'] as List)
        : local?.tags ?? const [],
    description: data.containsKey('description')
        ? data['description'] as String?
        : local?.description,
    // A device on the pre-examples build writes no key at all, so an absent
    // one keeps what this device has rather than clearing the list.
    examples: data['examples'] != null
        ? List<String>.from(data['examples'] as List)
        : local?.examples ?? const [],
    // Three shapes to tell apart. A current device writes the list. A device
    // on a build that predates alternatives writes only the flat fields, and
    // its edit is a real edit — read the solution out of those. A document
    // written before either existed has neither key, and keeps what this
    // device already has rather than being blanked.
    solutions: _mergeLeetCodeSolutions(data, local),
    solvedAt:
        parseFirestoreDate(data['solvedAt']) ??
        local?.solvedAt ??
        remoteUpdated,
    interval: (data['interval'] as num?)?.toDouble() ?? local?.interval ?? 0,
    ease: (data['ease'] as num?)?.toDouble() ?? local?.ease ?? 2.5,
    // A device still running the pre-SRS build writes no dueAt at all, so an
    // absent key falls back to what this device knows rather than clearing
    // the schedule; an explicit null is that device's own "due now".
    dueAt: data.containsKey('dueAt')
        ? parseFirestoreDate(data['dueAt'])
        : local?.dueAt,
    reviewCount: data['reviewCount'] as int? ?? local?.reviewCount ?? 0,
    createdAt:
        parseFirestoreDate(data['createdAt']) ??
        local?.createdAt ??
        remoteUpdated,
    updatedAt: remoteUpdated,
    version: remoteVersion,
    deletedAt: mergeDeletedAtFromRemote(data, local?.deletedAt),
  );
}

Map<String, dynamic> leetCodeReviewLogToFirestore(LeetCodeReviewLog log) => {
  'id': log.id,
  'problemId': log.problemId,
  'grade': log.grade.name,
  'reviewedAt': _dateToFirestoreRequired(log.reviewedAt),
  'version': log.version,
  'deletedAt': _dateToFirestore(log.deletedAt),
};

/// Version-first with no `updatedAt` tie-break, exactly as
/// [mergeStudyReviewLogFromRemote] resolves its rows: every field but the
/// tombstone is fixed at insert, so the higher version is the later revision
/// and a row at the same version is the same row.
LeetCodeReviewLog mergeLeetCodeReviewLogFromRemote(
  Map<String, dynamic> data,
  String id, {
  LeetCodeReviewLog? local,
}) {
  final remoteVersion = parseVersion(data);
  if (local != null && remoteVersion <= local.version) return local;
  return LeetCodeReviewLog(
    id: id,
    problemId: data['problemId'] as String? ?? local?.problemId ?? '',
    grade: StudyGrade.values.byName(data['grade'] as String? ?? 'good'),
    reviewedAt:
        parseFirestoreDate(data['reviewedAt']) ?? local?.reviewedAt ?? utcNow(),
    version: remoteVersion,
    deletedAt: mergeDeletedAtFromRemote(data, local?.deletedAt),
  );
}

Map<String, dynamic> leetCodeCheatTabToFirestore(LeetCodeCheatTab tab) => {
  'id': tab.id,
  'name': tab.name,
  'languageKey': tab.languageKey,
  'position': tab.position,
  'createdAt': _dateToFirestoreRequired(tab.createdAt),
  'updatedAt': _dateToFirestoreRequired(tab.updatedAt),
  'version': tab.version,
  'deletedAt': _dateToFirestore(tab.deletedAt),
};

/// Plain version-then-updatedAt, as every snapshot-only record resolves.
///
/// A tab, a section and an entry are separate documents, so the realistic
/// concurrent case — two devices editing different commands — never reaches a
/// merge at all. Two devices editing the *same* record loses one side's text,
/// which `LEETCODE_CHEAT_SHEET_HLD.md` §5.3 accepts.
LeetCodeCheatTab mergeLeetCodeCheatTabFromRemote(
  Map<String, dynamic> data,
  String id, {
  LeetCodeCheatTab? local,
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

  return LeetCodeCheatTab(
    id: id,
    name: data['name'] as String? ?? local?.name ?? '',
    // A remote written before the field existed carries no key; a tab whose
    // language was cleared carries an explicit null. Only the first should
    // keep the local value, so the key's presence is what decides.
    languageKey: data.containsKey('languageKey')
        ? data['languageKey'] as String?
        : local?.languageKey,
    position:
        (data['position'] as num?)?.toDouble() ??
        local?.position ??
        kCheatPositionStep,
    createdAt:
        parseFirestoreDate(data['createdAt']) ??
        local?.createdAt ??
        remoteUpdated,
    updatedAt: remoteUpdated,
    version: remoteVersion,
    deletedAt: mergeDeletedAtFromRemote(data, local?.deletedAt),
  );
}

Map<String, dynamic> leetCodeCheatSectionToFirestore(
  LeetCodeCheatSection section,
) => {
  'id': section.id,
  'tabId': section.tabId,
  'name': section.name,
  'position': section.position,
  'createdAt': _dateToFirestoreRequired(section.createdAt),
  'updatedAt': _dateToFirestoreRequired(section.updatedAt),
  'version': section.version,
  'deletedAt': _dateToFirestore(section.deletedAt),
};

/// [mergeLeetCodeCheatTabFromRemote] for a section.
LeetCodeCheatSection mergeLeetCodeCheatSectionFromRemote(
  Map<String, dynamic> data,
  String id, {
  LeetCodeCheatSection? local,
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

  return LeetCodeCheatSection(
    id: id,
    tabId: data['tabId'] as String? ?? local?.tabId ?? '',
    name: data['name'] as String? ?? local?.name ?? '',
    position:
        (data['position'] as num?)?.toDouble() ??
        local?.position ??
        kCheatPositionStep,
    createdAt:
        parseFirestoreDate(data['createdAt']) ??
        local?.createdAt ??
        remoteUpdated,
    updatedAt: remoteUpdated,
    version: remoteVersion,
    deletedAt: mergeDeletedAtFromRemote(data, local?.deletedAt),
  );
}

Map<String, dynamic> leetCodeCheatEntryToFirestore(LeetCodeCheatEntry entry) =>
    {
      'id': entry.id,
      'sectionId': entry.sectionId,
      'command': entry.command,
      'label': entry.label,
      'description': entry.description,
      'complexity': entry.complexity,
      'position': entry.position,
      'createdAt': _dateToFirestoreRequired(entry.createdAt),
      'updatedAt': _dateToFirestoreRequired(entry.updatedAt),
      'version': entry.version,
      'deletedAt': _dateToFirestore(entry.deletedAt),
    };

/// [mergeLeetCodeCheatTabFromRemote] for an entry.
LeetCodeCheatEntry mergeLeetCodeCheatEntryFromRemote(
  Map<String, dynamic> data,
  String id, {
  LeetCodeCheatEntry? local,
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

  return LeetCodeCheatEntry(
    id: id,
    sectionId: data['sectionId'] as String? ?? local?.sectionId ?? '',
    command: data['command'] as String? ?? local?.command ?? '',
    // Null and absent differ, as for complexity below.
    label: data.containsKey('label') ? data['label'] as String? : local?.label,
    description: data['description'] as String? ?? local?.description ?? '',
    // Null and absent differ here too: null is a complexity the user cleared,
    // and the badge's presence is the only flag the entry has.
    complexity: data.containsKey('complexity')
        ? data['complexity'] as String?
        : local?.complexity,
    position:
        (data['position'] as num?)?.toDouble() ??
        local?.position ??
        kCheatPositionStep,
    createdAt:
        parseFirestoreDate(data['createdAt']) ??
        local?.createdAt ??
        remoteUpdated,
    updatedAt: remoteUpdated,
    version: remoteVersion,
    deletedAt: mergeDeletedAtFromRemote(data, local?.deletedAt),
  );
}

Map<String, dynamic> customQuoteToFirestore(CustomQuote quote) => {
  'id': quote.id,
  'text': quote.text,
  'createdAt': _dateToFirestoreRequired(quote.createdAt),
  'updatedAt': _dateToFirestoreRequired(quote.updatedAt),
  'version': quote.version,
  'deletedAt': _dateToFirestore(quote.deletedAt),
};

CustomQuote mergeCustomQuoteFromRemote(
  Map<String, dynamic> data,
  String id, {
  CustomQuote? local,
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

  return CustomQuote(
    id: id,
    text: data['text'] as String? ?? local?.text ?? '',
    createdAt:
        parseFirestoreDate(data['createdAt']) ??
        local?.createdAt ??
        remoteUpdated,
    updatedAt: remoteUpdated,
    version: remoteVersion,
    deletedAt: mergeDeletedAtFromRemote(data, local?.deletedAt),
  );
}

Map<String, dynamic> snippetToFirestore(SyncedListItem<Snippet> record) => {
  ...record.item.toJson(),
  'position': record.position,
  'createdAt': _dateToFirestoreRequired(record.createdAt),
  'updatedAt': _dateToFirestoreRequired(record.updatedAt),
  'version': record.version,
  'deletedAt': _dateToFirestore(record.deletedAt),
};

/// Null when the remote document isn't a usable snippet and there is no local
/// copy to keep — one malformed document must not stop the pull.
SyncedListItem<Snippet>? mergeSnippetFromRemote(
  Map<String, dynamic> data,
  String id, {
  SyncedListItem<Snippet>? local,
}) {
  if (!_remoteRecordWins(
    data,
    localVersion: local?.version,
    localUpdatedAt: local?.updatedAt,
  )) {
    return local;
  }
  final snippet = Snippet.fromJson({...data, 'id': id});
  if (snippet == null) return local;
  return _mergedListItem(data, snippet, local);
}

Map<String, dynamic> jobExperienceSnippetToFirestore(
  SyncedListItem<JobExperienceSnippet> record,
) => {
  ...record.item.toJson(),
  'position': record.position,
  'createdAt': _dateToFirestoreRequired(record.createdAt),
  'updatedAt': _dateToFirestoreRequired(record.updatedAt),
  'version': record.version,
  'deletedAt': _dateToFirestore(record.deletedAt),
};

SyncedListItem<JobExperienceSnippet>? mergeJobExperienceSnippetFromRemote(
  Map<String, dynamic> data,
  String id, {
  SyncedListItem<JobExperienceSnippet>? local,
}) {
  if (!_remoteRecordWins(
    data,
    localVersion: local?.version,
    localUpdatedAt: local?.updatedAt,
  )) {
    return local;
  }
  final snippet = JobExperienceSnippet.fromJson({...data, 'id': id});
  if (snippet == null) return local;
  return _mergedListItem(data, snippet, local);
}

SyncedListItem<T> _mergedListItem<T>(
  Map<String, dynamic> data,
  T item,
  SyncedListItem<T>? local,
) {
  final remoteUpdated = parseFirestoreDate(data['updatedAt']) ?? utcNow();
  return SyncedListItem(
    item: item,
    position: (data['position'] as num?)?.toDouble() ?? local?.position ?? 0,
    createdAt:
        parseFirestoreDate(data['createdAt']) ??
        local?.createdAt ??
        remoteUpdated,
    updatedAt: remoteUpdated,
    version: parseVersion(data),
    // A re-added snippet clears its tombstone, so the remote value is taken
    // verbatim, as for custom words.
    deletedAt: parseFirestoreDate(data['deletedAt']),
  );
}

Map<String, dynamic> studyFolderToFirestore(StudyFolder folder) => {
  'id': folder.id,
  'name': folder.name,
  'parentFolderId': folder.parentFolderId,
  'colorValue': folder.colorValue,
  'createdAt': _dateToFirestoreRequired(folder.createdAt),
  'updatedAt': _dateToFirestoreRequired(folder.updatedAt),
  'version': folder.version,
  'deletedAt': _dateToFirestore(folder.deletedAt),
};

StudyFolder mergeStudyFolderFromRemote(
  Map<String, dynamic> data,
  String id, {
  StudyFolder? local,
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

  return StudyFolder(
    id: id,
    name: data['name'] as String? ?? local?.name ?? 'Folder',
    parentFolderId: data.containsKey('parentFolderId')
        ? data['parentFolderId'] as String?
        : local?.parentFolderId,
    colorValue: data.containsKey('colorValue')
        ? data['colorValue'] as int?
        : local?.colorValue,
    createdAt:
        parseFirestoreDate(data['createdAt']) ??
        local?.createdAt ??
        remoteUpdated,
    updatedAt: remoteUpdated,
    version: remoteVersion,
    deletedAt: mergeDeletedAtFromRemote(data, local?.deletedAt),
  );
}

Map<String, dynamic> studyDeckToFirestore(StudyDeck deck) => {
  'id': deck.id,
  'name': deck.name,
  'parentFolderId': deck.parentFolderId,
  'colorValue': deck.colorValue,
  'createdAt': _dateToFirestoreRequired(deck.createdAt),
  'updatedAt': _dateToFirestoreRequired(deck.updatedAt),
  'version': deck.version,
  'deletedAt': _dateToFirestore(deck.deletedAt),
};

StudyDeck mergeStudyDeckFromRemote(
  Map<String, dynamic> data,
  String id, {
  StudyDeck? local,
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

  return StudyDeck(
    id: id,
    name: data['name'] as String? ?? local?.name ?? 'Deck',
    parentFolderId: data.containsKey('parentFolderId')
        ? data['parentFolderId'] as String?
        : local?.parentFolderId,
    colorValue: data.containsKey('colorValue')
        ? data['colorValue'] as int?
        : local?.colorValue,
    createdAt:
        parseFirestoreDate(data['createdAt']) ??
        local?.createdAt ??
        remoteUpdated,
    updatedAt: remoteUpdated,
    version: remoteVersion,
    deletedAt: mergeDeletedAtFromRemote(data, local?.deletedAt),
  );
}

Map<String, dynamic> studyDeckLinkToFirestore(StudyDeckLink link) => {
  'id': link.id,
  'parentDeckId': link.parentDeckId,
  'childDeckId': link.childDeckId,
  'enabled': link.enabled,
  'createdAt': _dateToFirestoreRequired(link.createdAt),
  'updatedAt': _dateToFirestoreRequired(link.updatedAt),
  'version': link.version,
  'deletedAt': _dateToFirestore(link.deletedAt),
};

StudyDeckLink mergeStudyDeckLinkFromRemote(
  Map<String, dynamic> data,
  String id, {
  StudyDeckLink? local,
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

  return StudyDeckLink(
    id: id,
    parentDeckId: data['parentDeckId'] as String? ?? local?.parentDeckId ?? '',
    childDeckId: data['childDeckId'] as String? ?? local?.childDeckId ?? '',
    enabled: data['enabled'] as bool? ?? local?.enabled ?? true,
    createdAt:
        parseFirestoreDate(data['createdAt']) ??
        local?.createdAt ??
        remoteUpdated,
    updatedAt: remoteUpdated,
    version: remoteVersion,
    deletedAt: mergeDeletedAtFromRemote(data, local?.deletedAt),
  );
}

Map<String, dynamic> studyCardToFirestore(StudyCard card) => {
  'id': card.id,
  'deckId': card.deckId,
  'frontText': card.frontText,
  'backText': card.backText,
  'interval': card.interval,
  'ease': card.ease,
  'dueAt': _dateToFirestoreRequired(card.dueAt),
  'reviewCount': card.reviewCount,
  'createdAt': _dateToFirestoreRequired(card.createdAt),
  'updatedAt': _dateToFirestoreRequired(card.updatedAt),
  'version': card.version,
  'deletedAt': _dateToFirestore(card.deletedAt),
};

StudyCard mergeStudyCardFromRemote(
  Map<String, dynamic> data,
  String id, {
  StudyCard? local,
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

  return StudyCard(
    id: id,
    deckId: data['deckId'] as String? ?? local?.deckId ?? '',
    frontText: data['frontText'] as String? ?? local?.frontText ?? '',
    backText: data['backText'] as String? ?? local?.backText ?? '',
    interval: (data['interval'] as num?)?.toDouble() ?? local?.interval ?? 0,
    ease: (data['ease'] as num?)?.toDouble() ?? local?.ease ?? 2.5,
    dueAt: parseFirestoreDate(data['dueAt']) ?? local?.dueAt ?? remoteUpdated,
    reviewCount:
        (data['reviewCount'] as num?)?.toInt() ?? local?.reviewCount ?? 0,
    createdAt:
        parseFirestoreDate(data['createdAt']) ??
        local?.createdAt ??
        remoteUpdated,
    updatedAt: remoteUpdated,
    version: remoteVersion,
    deletedAt: mergeDeletedAtFromRemote(data, local?.deletedAt),
  );
}

/// The blob metadata that travels between devices.
///
/// [MediaAsset.uploadState] and [MediaAsset.downloadState] are deliberately
/// *not* on the wire: they describe where this particular device has got to
/// with the bytes, and syncing them would tell a phone that a file it has
/// never seen is already `present`. Every device works its own transfer
/// state out from what it finds on disk.
Map<String, dynamic> mediaAssetToFirestore(MediaAsset asset) => {
  'id': asset.id,
  'contentHash': asset.contentHash,
  'byteSize': asset.byteSize,
  'mimeType': asset.mimeType,
  'width': asset.width,
  'height': asset.height,
  'unreferencedAt': _dateToFirestore(asset.unreferencedAt),
  'createdAt': _dateToFirestoreRequired(asset.createdAt),
  'updatedAt': _dateToFirestoreRequired(asset.updatedAt),
  'version': asset.version,
  'deletedAt': _dateToFirestore(asset.deletedAt),
};

MediaAsset mergeMediaAssetFromRemote(
  Map<String, dynamic> data,
  String id, {
  MediaAsset? local,
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

  // Transfer state is carried over from the local row rather than read off
  // the document. A newly learned asset has no local row, so it starts as
  // `missing` — which is exactly what it is: this device knows the image
  // exists and does not have it. The download queue takes it from there.
  return MediaAsset(
    id: id,
    contentHash: data['contentHash'] as String? ?? local?.contentHash ?? '',
    byteSize: (data['byteSize'] as num?)?.toInt() ?? local?.byteSize ?? 0,
    mimeType: data['mimeType'] as String? ?? local?.mimeType ?? 'image/jpeg',
    width: (data['width'] as num?)?.toInt() ?? local?.width ?? 0,
    height: (data['height'] as num?)?.toInt() ?? local?.height ?? 0,
    uploadState: local?.uploadState ?? MediaUploadState.uploaded,
    downloadState: local?.downloadState ?? MediaDownloadState.missing,
    failureReason: local?.failureReason,
    unreferencedAt: parseFirestoreDate(data['unreferencedAt']),
    createdAt:
        parseFirestoreDate(data['createdAt']) ??
        local?.createdAt ??
        remoteUpdated,
    updatedAt: remoteUpdated,
    version: remoteVersion,
    deletedAt: mergeDeletedAtFromRemote(data, local?.deletedAt),
  );
}

Map<String, dynamic> mediaReferenceToFirestore(MediaReference reference) => {
  'id': reference.id,
  'mediaId': reference.mediaId,
  'collection': reference.collection,
  'documentId': mediaOwnerDocumentIdForFirestore(
    reference.collection,
    reference.documentId,
  ),
  'facet': reference.facet.name,
  'sortOrder': reference.sortOrder,
  'displayWidthPx': reference.displayWidthPx,
  'createdAt': _dateToFirestoreRequired(reference.createdAt),
  'updatedAt': _dateToFirestoreRequired(reference.updatedAt),
  'version': reference.version,
  'deletedAt': _dateToFirestore(reference.deletedAt),
};

MediaReference mergeMediaReferenceFromRemote(
  Map<String, dynamic> data,
  String id, {
  MediaReference? local,
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

  // A reference whose owner is a todo list or journal carries that parent's
  // *Firestore* id on the wire, so it has to come back through the same
  // legacy mapping the parent document itself does — otherwise the gallery
  // on the device that pulled it hangs off an id no local row has.
  final collection = data['collection'] as String? ?? local?.collection ?? '';
  final rawDocumentId =
      data['documentId'] as String? ?? local?.documentId ?? '';

  return MediaReference(
    id: id,
    mediaId: data['mediaId'] as String? ?? local?.mediaId ?? '',
    collection: collection,
    documentId: mediaOwnerDocumentIdFromFirestore(collection, rawDocumentId),
    facet: _enumFromName(
      MediaFacet.values,
      data['facet'],
      local?.facet ?? MediaFacet.gallery,
    ),
    sortOrder: (data['sortOrder'] as num?)?.toInt() ?? local?.sortOrder ?? 0,
    displayWidthPx:
        (data['displayWidthPx'] as num?)?.toInt() ?? local?.displayWidthPx,
    createdAt:
        parseFirestoreDate(data['createdAt']) ??
        local?.createdAt ??
        remoteUpdated,
    updatedAt: remoteUpdated,
    version: remoteVersion,
    deletedAt: mergeDeletedAtFromRemote(data, local?.deletedAt),
  );
}

/// Maps a media reference's owner id to the form the wire uses.
///
/// Journals and todo lists are the two collections whose local id differs
/// from their Firestore id, and a reference stores its owner's id as data
/// rather than as a document name — so [firestoreDocumentIdForLocal], which
/// the outbox applies to document *names*, never sees it. Without this a
/// gallery attached to a todo task in a legacy-id list would sync as an
/// orphan.
String mediaOwnerDocumentIdForFirestore(
  String collection,
  String localDocumentId,
) {
  return firestoreDocumentIdForLocal(collection, localDocumentId);
}

/// Inverse of [mediaOwnerDocumentIdForFirestore].
String mediaOwnerDocumentIdFromFirestore(
  String collection,
  String firestoreDocumentId,
) {
  if (collection == FirestoreCollections.journals) {
    return journalDocumentIdFromFirestore(firestoreDocumentId);
  }
  if (collection == FirestoreCollections.todoLists) {
    return todoListDocumentIdFromFirestore(firestoreDocumentId);
  }
  if (collection == FirestoreCollections.calendars) {
    return calendarDocumentIdFromFirestore(firestoreDocumentId);
  }
  if (encodedIdCollections.contains(collection)) {
    return decodeDocumentId(firestoreDocumentId) ?? firestoreDocumentId;
  }
  return firestoreDocumentId;
}

Map<String, dynamic> studyReviewLogToFirestore(StudyReviewLog log) => {
  'id': log.id,
  'cardId': log.cardId,
  'grade': log.grade.name,
  'reviewedAt': _dateToFirestoreRequired(log.reviewedAt),
  'version': log.version,
  'deletedAt': _dateToFirestore(log.deletedAt),
};

/// Version-first, with no `updatedAt` tie-break: every field but the tombstone
/// is fixed at insert, so two revisions of a log row can only differ by having
/// been deleted or restored, and the higher version is the later one. A row at
/// the same version is the same row.
StudyReviewLog mergeStudyReviewLogFromRemote(
  Map<String, dynamic> data,
  String id, {
  StudyReviewLog? local,
}) {
  final remoteVersion = parseVersion(data);
  if (local != null && remoteVersion <= local.version) return local;
  return StudyReviewLog(
    id: id,
    cardId: data['cardId'] as String? ?? local?.cardId ?? '',
    grade: StudyGrade.values.byName(data['grade'] as String? ?? 'good'),
    reviewedAt:
        parseFirestoreDate(data['reviewedAt']) ?? local?.reviewedAt ?? utcNow(),
    version: remoteVersion,
    deletedAt: mergeDeletedAtFromRemote(data, local?.deletedAt),
  );
}

Map<String, dynamic> exerciseToFirestore(Exercise exercise) => {
  'id': exercise.id,
  'name': exercise.name,
  'formCues': exercise.formCues,
  'colorValue': exercise.colorValue,
  'sortOrder': exercise.sortOrder,
  'targetSets': exercise.targetSets,
  'targetReps': exercise.targetReps,
  'targetWeightKg': exercise.targetWeightKg,
  'prescriptionMode': exercise.prescriptionMode.name,
  'setPrescriptions': [for (final p in exercise.setPrescriptions) p.toJson()],
  'createdAt': _dateToFirestoreRequired(exercise.createdAt),
  'updatedAt': _dateToFirestoreRequired(exercise.updatedAt),
  'version': exercise.version,
  'deletedAt': _dateToFirestore(exercise.deletedAt),
};

Exercise mergeExerciseFromRemote(
  Map<String, dynamic> data,
  String id, {
  Exercise? local,
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

  // Both prescription fields fall back to the local value when the remote
  // payload has no such key: that is a write from a build that predates set
  // recipes living on the movement, and taking its silence as "inherit, no
  // sets" would wipe the recipe.
  final modeName = data['prescriptionMode'] as String?;
  return Exercise(
    id: id,
    name: data['name'] as String? ?? local?.name ?? 'Exercise',
    formCues: data['formCues'] as String? ?? local?.formCues ?? '',
    colorValue: data.containsKey('colorValue')
        ? data['colorValue'] as int?
        : local?.colorValue,
    sortOrder: (data['sortOrder'] as num?)?.toInt() ?? local?.sortOrder ?? 0,
    targetSets:
        (data['targetSets'] as num?)?.toInt() ??
        local?.targetSets ??
        kDefaultTargetSets,
    targetReps:
        (data['targetReps'] as num?)?.toInt() ??
        local?.targetReps ??
        kDefaultTargetReps,
    targetWeightKg:
        (data['targetWeightKg'] as num?)?.toDouble() ??
        local?.targetWeightKg ??
        0,
    prescriptionMode: modeName == null
        ? local?.prescriptionMode ?? WorkoutPrescriptionMode.inherit
        : WorkoutPrescriptionMode.values.asNameMap()[modeName] ??
              WorkoutPrescriptionMode.inherit,
    setPrescriptions: data['setPrescriptions'] is List
        ? setPrescriptionsFromJson(data['setPrescriptions'])
        : local?.setPrescriptions ?? const [],
    createdAt:
        parseFirestoreDate(data['createdAt']) ??
        local?.createdAt ??
        remoteUpdated,
    updatedAt: remoteUpdated,
    version: remoteVersion,
    deletedAt: mergeDeletedAtFromRemote(data, local?.deletedAt),
  );
}

Map<String, dynamic> workoutPlanToFirestore(WorkoutPlan plan) => {
  'id': plan.id,
  'name': plan.name,
  'mode': plan.mode.name,
  'cycleLength': plan.cycleLength,
  'cycleAnchor': _dateToFirestoreRequired(plan.cycleAnchor),
  'isActive': plan.isActive,
  'createdAt': _dateToFirestoreRequired(plan.createdAt),
  'updatedAt': _dateToFirestoreRequired(plan.updatedAt),
  'version': plan.version,
  'deletedAt': _dateToFirestore(plan.deletedAt),
};

WorkoutPlan mergeWorkoutPlanFromRemote(
  Map<String, dynamic> data,
  String id, {
  WorkoutPlan? local,
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

  final rawMode = data['mode'] as String?;
  return WorkoutPlan(
    id: id,
    name: data['name'] as String? ?? local?.name ?? 'Plan',
    mode:
        (rawMode != null && WorkoutPlanMode.values.any((m) => m.name == rawMode)
            ? WorkoutPlanMode.values.byName(rawMode)
            : null) ??
        local?.mode ??
        WorkoutPlanMode.weekly,
    cycleLength:
        (data['cycleLength'] as num?)?.toInt() ?? local?.cycleLength ?? 4,
    cycleAnchor:
        parseFirestoreDate(data['cycleAnchor']) ??
        local?.cycleAnchor ??
        remoteUpdated,
    isActive: data['isActive'] as bool? ?? local?.isActive ?? false,
    createdAt:
        parseFirestoreDate(data['createdAt']) ??
        local?.createdAt ??
        remoteUpdated,
    updatedAt: remoteUpdated,
    version: remoteVersion,
    deletedAt: mergeDeletedAtFromRemote(data, local?.deletedAt),
  );
}

Map<String, dynamic> workoutPlanEntryToFirestore(WorkoutPlanEntry entry) => {
  'id': entry.id,
  'planId': entry.planId,
  'dayIndex': entry.dayIndex,
  'exerciseId': entry.exerciseId,
  'sortOrder': entry.sortOrder,
  'createdAt': _dateToFirestoreRequired(entry.createdAt),
  'updatedAt': _dateToFirestoreRequired(entry.updatedAt),
  'version': entry.version,
  'deletedAt': _dateToFirestore(entry.deletedAt),
};

WorkoutPlanEntry mergeWorkoutPlanEntryFromRemote(
  Map<String, dynamic> data,
  String id, {
  WorkoutPlanEntry? local,
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

  return WorkoutPlanEntry(
    id: id,
    planId: data['planId'] as String? ?? local?.planId ?? '',
    dayIndex: (data['dayIndex'] as num?)?.toInt() ?? local?.dayIndex ?? 0,
    exerciseId: data['exerciseId'] as String? ?? local?.exerciseId ?? '',
    sortOrder: (data['sortOrder'] as num?)?.toInt() ?? local?.sortOrder ?? 0,
    createdAt:
        parseFirestoreDate(data['createdAt']) ??
        local?.createdAt ??
        remoteUpdated,
    updatedAt: remoteUpdated,
    version: remoteVersion,
    deletedAt: mergeDeletedAtFromRemote(data, local?.deletedAt),
  );
}

Map<String, dynamic> workoutSessionToFirestore(WorkoutSession session) => {
  'id': session.id,
  'planId': session.planId,
  'dayIndex': session.dayIndex,
  'date': _dateToFirestoreRequired(session.date),
  'startedAt': _dateToFirestoreRequired(session.startedAt),
  'endedAt': _dateToFirestore(session.endedAt),
  'createdAt': _dateToFirestoreRequired(session.createdAt),
  'updatedAt': _dateToFirestoreRequired(session.updatedAt),
  'version': session.version,
  'deletedAt': _dateToFirestore(session.deletedAt),
};

WorkoutSession mergeWorkoutSessionFromRemote(
  Map<String, dynamic> data,
  String id, {
  WorkoutSession? local,
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

  return WorkoutSession(
    id: id,
    planId: data.containsKey('planId')
        ? data['planId'] as String?
        : local?.planId,
    dayIndex: data.containsKey('dayIndex')
        ? (data['dayIndex'] as num?)?.toInt()
        : local?.dayIndex,
    date: parseFirestoreDate(data['date']) ?? local?.date ?? remoteUpdated,
    startedAt:
        parseFirestoreDate(data['startedAt']) ??
        local?.startedAt ??
        remoteUpdated,
    // Never falls back to the local value: a session finished on another
    // device has to be able to close this one, or the island would stay live
    // here forever.
    endedAt: parseFirestoreDate(data['endedAt']),
    createdAt:
        parseFirestoreDate(data['createdAt']) ??
        local?.createdAt ??
        remoteUpdated,
    updatedAt: remoteUpdated,
    version: remoteVersion,
    deletedAt: mergeDeletedAtFromRemote(data, local?.deletedAt),
  );
}

Map<String, dynamic> workoutSetLogToFirestore(WorkoutSetLog log) => {
  'id': log.id,
  'sessionId': log.sessionId,
  'exerciseId': log.exerciseId,
  'exerciseOrder': log.exerciseOrder,
  'setIndex': log.setIndex,
  'weightKg': log.weightKg,
  'reps': log.reps,
  'plannedWeightKg': log.plannedWeightKg,
  'plannedReps': log.plannedReps,
  'dropSegments': [for (final s in log.dropSegments) s.toJson()],
  'plannedDropSegments': [for (final s in log.plannedDropSegments) s.toJson()],
  'completed': log.completed,
  'completedAt': _dateToFirestore(log.completedAt),
  'createdAt': _dateToFirestoreRequired(log.createdAt),
  'updatedAt': _dateToFirestoreRequired(log.updatedAt),
  'version': log.version,
  'deletedAt': _dateToFirestore(log.deletedAt),
};

WorkoutSetLog mergeWorkoutSetLogFromRemote(
  Map<String, dynamic> data,
  String id, {
  WorkoutSetLog? local,
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

  List<SetSegment> parseSegments(Object? raw, List<SetSegment>? fallback) {
    if (raw is! List) return fallback ?? const [];
    return [
      for (final item in raw)
        if (item is Map<String, dynamic>)
          SetSegment.fromJson(item)
        else if (item is Map)
          SetSegment.fromJson(Map<String, dynamic>.from(item)),
    ];
  }

  return WorkoutSetLog(
    id: id,
    sessionId: data['sessionId'] as String? ?? local?.sessionId ?? '',
    exerciseId: data['exerciseId'] as String? ?? local?.exerciseId ?? '',
    exerciseOrder:
        (data['exerciseOrder'] as num?)?.toInt() ?? local?.exerciseOrder ?? 0,
    setIndex: (data['setIndex'] as num?)?.toInt() ?? local?.setIndex ?? 0,
    weightKg: (data['weightKg'] as num?)?.toDouble() ?? local?.weightKg ?? 0,
    reps: (data['reps'] as num?)?.toInt() ?? local?.reps ?? 0,
    plannedWeightKg:
        (data['plannedWeightKg'] as num?)?.toDouble() ??
        local?.plannedWeightKg ??
        0,
    plannedReps:
        (data['plannedReps'] as num?)?.toInt() ?? local?.plannedReps ?? 0,
    dropSegments: parseSegments(data['dropSegments'], local?.dropSegments),
    plannedDropSegments: parseSegments(
      data['plannedDropSegments'],
      local?.plannedDropSegments,
    ),
    completed: data['completed'] as bool? ?? local?.completed ?? false,
    completedAt: parseFirestoreDate(data['completedAt']),
    createdAt:
        parseFirestoreDate(data['createdAt']) ??
        local?.createdAt ??
        remoteUpdated,
    updatedAt: remoteUpdated,
    version: remoteVersion,
    deletedAt: mergeDeletedAtFromRemote(data, local?.deletedAt),
  );
}

Map<String, dynamic> jobApplicationToFirestore(JobApplication application) => {
  'id': application.id,
  'company': application.company,
  'title': application.title,
  'status': application.status,
  'dateApplied': _dateToFirestoreRequired(
    jobCalendarDay(application.dateApplied),
  ),
  'applicationUrl': application.applicationUrl,
  'notes': application.notes,
  'seasonIds': application.seasonIds,
  'fieldUpdatedAt': _fieldStampsToFirestore(application.fieldUpdatedAt),
  'fieldStampsVersion': application.version,
  'createdAt': _dateToFirestoreRequired(application.createdAt),
  'updatedAt': _dateToFirestoreRequired(application.updatedAt),
  'version': application.version,
  'deletedAt': _dateToFirestore(application.deletedAt),
};

/// The seasons a remote application is filed under, reading a document from a
/// device that still writes the single `seasonId` as the one-element list it
/// means. Absent on both sides is "no season", not "unknown".
List<String> _jobSeasonIdsFromFirestore(Map<String, dynamic> data) {
  if (data['seasonIds'] case final List<dynamic> ids) {
    return [
      for (final id in ids)
        if (id is String && id.isNotEmpty) id,
    ];
  }
  final legacy = data['seasonId'] as String?;
  return legacy == null || legacy.isEmpty ? const [] : [legacy];
}

JobApplication mergeJobApplicationFromRemote(
  Map<String, dynamic> data,
  String id, {
  JobApplication? local,
}) => resolveJobApplicationFromRemote(data, id, local: local).merged;

/// Merges a remote application into [local] field by field when the remote
/// carries stamps it can vouch for, and falls back to whole-document
/// version-wins when it does not — the same scheme as
/// [resolveRankingParentFromRemote].
///
/// Whole-document merging kept only one side of two concurrent edits: a note
/// typed on one device and a status moved on another could not both survive.
/// `deletedAt` stays document-level: whichever side wins on version decides
/// whether the application exists.
RankingMergeResult<JobApplication> resolveJobApplicationFromRemote(
  Map<String, dynamic> data,
  String id, {
  JobApplication? local,
}) {
  final remoteUpdated = parseFirestoreDate(data['updatedAt']) ?? utcNow();
  final remoteVersion = parseVersion(data);
  final remoteStamps = _fieldStampsFromRemote(data);
  final remoteWins =
      local == null ||
      remoteVersionWins(
        remoteVersion: remoteVersion,
        localVersion: local.version,
        remoteUpdated: remoteUpdated,
        localUpdated: local.updatedAt,
      );
  if (local != null && remoteStamps == null && !remoteWins) {
    return (merged: local, localWon: false);
  }

  // `seasonIds` and the two optional text fields fall back to empty/null rather
  // than to the local value: taking an application out of every season and
  // clearing a URL are both expressed as the field going away, and inheriting
  // the local value would make either change impossible to sync.
  final remoteDate = parseFirestoreDate(data['dateApplied']);
  final remote = JobApplication(
    id: id,
    company: data['company'] as String? ?? local?.company ?? '',
    title: data['title'] as String? ?? local?.title ?? '',
    status: data['status'] as String? ?? local?.status ?? '',
    dateApplied: remoteDate == null
        ? (local?.dateApplied ?? jobCalendarDay(remoteUpdated))
        : jobCalendarDay(remoteDate),
    applicationUrl: data['applicationUrl'] as String?,
    notes: data['notes'] as String?,
    seasonIds: _jobSeasonIdsFromFirestore(data),
    createdAt:
        parseFirestoreDate(data['createdAt']) ??
        local?.createdAt ??
        remoteUpdated,
    updatedAt: remoteUpdated,
    version: remoteVersion,
    deletedAt: mergeDeletedAtFromRemote(data, local?.deletedAt),
    fieldUpdatedAt: remoteStamps ?? const {},
  );
  if (local == null || remoteStamps == null) {
    return (merged: remote, localWon: false);
  }

  final pick = _RankingFieldPicker(
    localStamps: local.fieldUpdatedAt,
    localUpdated: local.updatedAt,
    localValues: jobApplicationStampValues(local),
    remoteStamps: remote.fieldUpdatedAt,
    remoteUpdated: remote.updatedAt,
    remoteValues: jobApplicationStampValues(remote),
  );
  final company = pick('company', local.company, remote.company);
  final title = pick('title', local.title, remote.title);
  final status = pick('status', local.status, remote.status);
  final dateApplied = pick(
    'dateApplied',
    local.dateApplied,
    remote.dateApplied,
  );
  final applicationUrl = pick(
    'applicationUrl',
    local.applicationUrl,
    remote.applicationUrl,
  );
  final notes = pick('notes', local.notes, remote.notes);
  final seasonIds = pick('seasonIds', local.seasonIds, remote.seasonIds);
  // Keeping the local verdict on deletion is also a state only this device
  // holds, so it has to go back up the same way a kept field does.
  if (!remoteWins && local.deletedAt != remote.deletedAt) pick.localWon = true;
  final merged = JobApplication(
    id: id,
    company: company,
    title: title,
    status: status,
    dateApplied: dateApplied,
    applicationUrl: applicationUrl,
    notes: notes,
    seasonIds: seasonIds,
    createdAt: remoteWins ? remote.createdAt : local.createdAt,
    deletedAt: remoteWins ? remote.deletedAt : local.deletedAt,
    updatedAt: pick.updatedAt,
    version: pick.version(local.version, remote.version),
    fieldUpdatedAt: pick.stamps,
  );
  return (merged: merged, localWon: pick.localWon);
}

Map<String, dynamic> jobStatusEventToFirestore(JobStatusEvent event) => {
  'id': event.id,
  'applicationId': event.applicationId,
  'fromStatus': event.fromStatus,
  'toStatus': event.toStatus,
  'changedAt': _dateToFirestoreRequired(event.changedAt),
  'createdAt': _dateToFirestoreRequired(event.createdAt),
  'updatedAt': _dateToFirestoreRequired(event.updatedAt),
  'version': event.version,
  'deletedAt': _dateToFirestore(event.deletedAt),
};

JobStatusEvent mergeJobStatusEventFromRemote(
  Map<String, dynamic> data,
  String id, {
  JobStatusEvent? local,
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

  return JobStatusEvent(
    id: id,
    applicationId:
        data['applicationId'] as String? ?? local?.applicationId ?? '',
    fromStatus: data['fromStatus'] as String? ?? local?.fromStatus,
    toStatus: data['toStatus'] as String? ?? local?.toStatus ?? '',
    changedAt:
        parseFirestoreDate(data['changedAt']) ??
        local?.changedAt ??
        remoteUpdated,
    createdAt:
        parseFirestoreDate(data['createdAt']) ??
        local?.createdAt ??
        remoteUpdated,
    updatedAt: remoteUpdated,
    version: remoteVersion,
    deletedAt: mergeDeletedAtFromRemote(data, local?.deletedAt),
  );
}

Map<String, dynamic> jobStageToFirestore(JobStage stage) => {
  'id': stage.id,
  'name': stage.name,
  'sortOrder': stage.sortOrder,
  'colorValue': stage.colorValue,
  'createdAt': _dateToFirestoreRequired(stage.createdAt),
  'updatedAt': _dateToFirestoreRequired(stage.updatedAt),
  'version': stage.version,
  'deletedAt': _dateToFirestore(stage.deletedAt),
};

JobStage mergeJobStageFromRemote(
  Map<String, dynamic> data,
  String id, {
  JobStage? local,
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

  return JobStage(
    id: id,
    name: data['name'] as String? ?? local?.name ?? '',
    sortOrder: (data['sortOrder'] as num?)?.toInt() ?? local?.sortOrder ?? 0,
    // A remote that predates the field carries no key at all; a stage whose
    // colour was cleared carries an explicit null. Only the first should keep
    // the local colour, so the key's presence is what decides.
    colorValue: data.containsKey('colorValue')
        ? (data['colorValue'] as num?)?.toInt()
        : local?.colorValue,
    createdAt:
        parseFirestoreDate(data['createdAt']) ??
        local?.createdAt ??
        remoteUpdated,
    updatedAt: remoteUpdated,
    version: remoteVersion,
    deletedAt: mergeDeletedAtFromRemote(data, local?.deletedAt),
  );
}

Map<String, dynamic> jobCompanyToFirestore(JobCompany company) => {
  'id': company.id,
  'name': company.name,
  'categoryId': company.categoryId,
  'createdAt': _dateToFirestoreRequired(company.createdAt),
  'updatedAt': _dateToFirestoreRequired(company.updatedAt),
  'version': company.version,
  'deletedAt': _dateToFirestore(company.deletedAt),
};

JobCompany mergeJobCompanyFromRemote(
  Map<String, dynamic> data,
  String id, {
  JobCompany? local,
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

  // Null rather than the local value: deleting a category clears it off every
  // company, and that clearing has to be able to reach the other devices.
  return JobCompany(
    id: id,
    name: data['name'] as String? ?? local?.name ?? '',
    categoryId: data['categoryId'] as String?,
    createdAt:
        parseFirestoreDate(data['createdAt']) ??
        local?.createdAt ??
        remoteUpdated,
    updatedAt: remoteUpdated,
    version: remoteVersion,
    deletedAt: mergeDeletedAtFromRemote(data, local?.deletedAt),
  );
}

Map<String, dynamic> jobCategoryToFirestore(JobCategory category) => {
  'id': category.id,
  'name': category.name,
  'colorValue': category.colorValue,
  'sortOrder': category.sortOrder,
  'createdAt': _dateToFirestoreRequired(category.createdAt),
  'updatedAt': _dateToFirestoreRequired(category.updatedAt),
  'version': category.version,
  'deletedAt': _dateToFirestore(category.deletedAt),
};

JobCategory mergeJobCategoryFromRemote(
  Map<String, dynamic> data,
  String id, {
  JobCategory? local,
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

  return JobCategory(
    id: id,
    name: data['name'] as String? ?? local?.name ?? '',
    colorValue: (data['colorValue'] as num?)?.toInt() ?? local?.colorValue ?? 0,
    sortOrder: (data['sortOrder'] as num?)?.toInt() ?? local?.sortOrder ?? 0,
    createdAt:
        parseFirestoreDate(data['createdAt']) ??
        local?.createdAt ??
        remoteUpdated,
    updatedAt: remoteUpdated,
    version: remoteVersion,
    deletedAt: mergeDeletedAtFromRemote(data, local?.deletedAt),
  );
}

Map<String, dynamic> jobSeasonToFirestore(JobSeason season) => {
  'id': season.id,
  'name': season.name,
  'sortOrder': season.sortOrder,
  'archivedAt': _dateToFirestore(season.archivedAt),
  'createdAt': _dateToFirestoreRequired(season.createdAt),
  'updatedAt': _dateToFirestoreRequired(season.updatedAt),
  'version': season.version,
  'deletedAt': _dateToFirestore(season.deletedAt),
};

JobSeason mergeJobSeasonFromRemote(
  Map<String, dynamic> data,
  String id, {
  JobSeason? local,
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

  return JobSeason(
    id: id,
    name: data['name'] as String? ?? local?.name ?? '',
    sortOrder: (data['sortOrder'] as num?)?.toInt() ?? local?.sortOrder ?? 0,
    // Un-archiving has to survive the round trip, so a document that carries
    // the key with a null value clears it rather than falling back to the
    // local value. Only a document from before this field existed — no key at
    // all — keeps what is here.
    archivedAt: data.containsKey('archivedAt')
        ? parseFirestoreDate(data['archivedAt'])
        : local?.archivedAt,
    createdAt:
        parseFirestoreDate(data['createdAt']) ??
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
  'entryDate': _dateToFirestoreRequired(entry.entryDate),
  'timestamp': _dateToFirestore(entry.timestamp),
  'tags': entry.tags,
  'mood': entry.mood,
  'quoteId': entry.quoteId,
  'customQuote': entry.customQuote,
  'weatherIcon': entry.weatherIcon,
  'guidedPrompt': entry.guidedPrompt,
  'createdAt': _dateToFirestoreRequired(entry.createdAt),
  'updatedAt': _dateToFirestoreRequired(entry.updatedAt),
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
  final metadataRemoteWins =
      local == null ||
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
      metadataRemoteWins
          ? (data['journalId'] as String? ??
                local?.journalId ??
                legacyJournalId)
          : local!.journalId,
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
    createdAt:
        parseFirestoreDate(data['createdAt']) ??
        local?.createdAt ??
        remoteUpdated,
    updatedAt: resolvedUpdated,
    version: resolvedVersion,
    deletedAt: mergeDeletedAtFromRemote(
      data,
      local?.deletedAt,
      remoteWins: metadataRemoteWins,
    ),
  );
}

Map<String, dynamic> todoListToFirestore(TodoListModel list) => {
  'id': todoListDocumentIdForFirestore(list.id),
  'name': list.name,
  'colorValue': list.colorValue,
  'includeInAllView': list.includeInAllView,
  'createdAt': _dateToFirestoreRequired(list.createdAt),
  'updatedAt': _dateToFirestoreRequired(list.updatedAt),
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
    includeInAllView:
        data['includeInAllView'] as bool? ?? local?.includeInAllView ?? true,
    createdAt:
        parseFirestoreDate(data['createdAt']) ??
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
  'dueDateSetAt': _dateToFirestore(task.dueDateSetAt),
  'recurrence': task.recurrence.toStorage(),
  'recurrenceAnchor': _dateToFirestore(task.recurrenceAnchor),
  'parentTaskId': task.parentTaskId,
  'createdAt': _dateToFirestoreRequired(task.createdAt),
  'updatedAt': _dateToFirestoreRequired(task.updatedAt),
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
  final metadataRemoteWins =
      local == null ||
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

  final listId = metadataRemoteWins
      ? (data['listId'] as String? ?? local?.listId)
      : local?.listId;
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
    recurrence: metadataRemoteWins
        ? (data.containsKey('recurrence')
              ? RecurrenceRule.parse(data['recurrence'] as String?)
              : (local?.recurrence ?? RecurrenceRule.none))
        : local!.recurrence,
    recurrenceAnchor: metadataRemoteWins
        ? (data.containsKey('recurrenceAnchor')
              ? parseFirestoreDate(data['recurrenceAnchor'])
              : local?.recurrenceAnchor)
        : local!.recurrenceAnchor,
    createdAt:
        parseFirestoreDate(data['createdAt']) ??
        local?.createdAt ??
        remoteUpdated,
    updatedAt: resolvedUpdated,
    version: resolvedVersion,
    deletedAt: mergeDeletedAtFromRemote(
      data,
      local?.deletedAt,
      remoteWins: metadataRemoteWins,
    ),
  );
}

Map<String, dynamic> dreamEntryToFirestore(DreamEntry entry) => {
  'id': entry.id,
  'title': entry.title,
  'body': entry.body,
  'notes': entry.notes,
  'entryDate': _dateToFirestoreRequired(entry.entryDate),
  'tags': entry.tags,
  'createdAt': _dateToFirestoreRequired(entry.createdAt),
  'updatedAt': _dateToFirestoreRequired(entry.updatedAt),
  'version': entry.version,
  'deletedAt': _dateToFirestore(entry.deletedAt),
};

DreamEntry mergeDreamEntryFromRemote(
  Map<String, dynamic> data,
  String id, {
  DreamEntry? local,
  CrdtTextFields? crdtText,
}) {
  final remoteUpdated = parseFirestoreDate(data['updatedAt']) ?? utcNow();
  final remoteVersion = parseVersion(data);
  final metadataRemoteWins =
      local == null ||
      remoteVersionWins(
        remoteVersion: remoteVersion,
        localVersion: local.version,
        remoteUpdated: remoteUpdated,
        localUpdated: local.updatedAt,
      );

  final String body;
  final List<String> tags;
  if (crdtText != null) {
    body = crdtText.body;
    tags = data['tags'] != null
        ? List<String>.from(data['tags'] as List)
        : local?.tags ?? const [];
  } else if (metadataRemoteWins) {
    body = data['body'] as String? ?? local?.body ?? '';
    tags = data['tags'] != null
        ? List<String>.from(data['tags'] as List)
        : local?.tags ?? const [];
  } else {
    body = local!.body;
    tags = local.tags;
  }

  final resolvedVersion = metadataRemoteWins
      ? remoteVersion
      : local?.version ?? remoteVersion;
  final resolvedUpdated = metadataRemoteWins
      ? remoteUpdated
      : local?.updatedAt ?? remoteUpdated;

  return DreamEntry(
    id: id,
    title: metadataRemoteWins
        ? (data['title'] as String? ?? local?.title ?? '')
        : local!.title,
    body: body,
    notes: metadataRemoteWins
        ? (data.containsKey('notes') ? data['notes'] as String? : local?.notes)
        : local!.notes,
    entryDate: metadataRemoteWins
        ? (parseFirestoreDate(data['entryDate']) ??
              local?.entryDate ??
              remoteUpdated)
        : local!.entryDate,
    tags: tags,
    createdAt:
        parseFirestoreDate(data['createdAt']) ??
        local?.createdAt ??
        remoteUpdated,
    updatedAt: resolvedUpdated,
    version: resolvedVersion,
    deletedAt: mergeDeletedAtFromRemote(
      data,
      local?.deletedAt,
      remoteWins: metadataRemoteWins,
    ),
  );
}

// ---------------------------------------------------------------------------
// Calendars, analytics, finance, the notification inbox, the bucket list and
// the settings document.
//
// These are plain records: no collaborative text, so nothing here writes to
// the character-level operation log (see [FirestoreCollections.snapshotOnly])
// and every merge resolves by version-then-updatedAt.
// ---------------------------------------------------------------------------

/// Firestore document id for a record keyed by arbitrary user text — a tag, a
/// dictionary word, a dismissal key.
///
/// Firestore rejects `/` in a document id and treats `.`, `..` and `__…__`
/// specially, while these keys are whatever the user typed. base64url is
/// reversible and collision-free, so the key survives the round trip intact.
String encodeDocumentId(String key) => base64Url.encode(utf8.encode(key));

/// Inverse of [encodeDocumentId]. Returns null for an id that isn't one of
/// ours, so a stray document can be skipped rather than failing the pull.
String? decodeDocumentId(String documentId) {
  try {
    return utf8.decode(base64Url.decode(documentId));
  } catch (_) {
    return null;
  }
}

T _enumFromName<T extends Enum>(List<T> values, Object? name, T fallback) {
  if (name is! String) return fallback;
  for (final value in values) {
    if (value.name == name) return value;
  }
  return fallback;
}

List<String> _stringListFromRemote(Object? value, List<String> fallback) {
  if (value is! List) return fallback;
  return [
    for (final item in value)
      if (item is String) item,
  ];
}

/// Whether the remote document should replace the local record under
/// version-first conflict resolution. A record we've never seen wins by
/// default — there is nothing local for it to lose to.
bool _remoteRecordWins(
  Map<String, dynamic> data, {
  required int? localVersion,
  required DateTime? localUpdatedAt,
}) {
  if (localVersion == null) return true;
  return remoteVersionWins(
    remoteVersion: parseVersion(data),
    localVersion: localVersion,
    remoteUpdated: parseFirestoreDate(data['updatedAt']),
    localUpdated: localUpdatedAt,
  );
}

Map<String, dynamic> calendarToFirestore(Calendar calendar) => {
  'id': calendarDocumentIdForFirestore(calendar.id),
  'name': calendar.name,
  'colorValue': calendar.colorValue,
  'overlayCalendarIds': calendar.overlayCalendarIds,
  'createdAt': _dateToFirestoreRequired(calendar.createdAt),
  'updatedAt': _dateToFirestoreRequired(calendar.updatedAt),
  'version': calendar.version,
  'deletedAt': _dateToFirestore(calendar.deletedAt),
};

Calendar mergeCalendarFromRemote(
  Map<String, dynamic> data,
  String id, {
  Calendar? local,
}) {
  if (!_remoteRecordWins(
    data,
    localVersion: local?.version,
    localUpdatedAt: local?.updatedAt,
  )) {
    return local!;
  }
  final remoteUpdated = parseFirestoreDate(data['updatedAt']) ?? utcNow();
  return Calendar(
    id: id,
    name: data['name'] as String? ?? local?.name ?? '',
    colorValue: (data['colorValue'] as num?)?.toInt() ?? local?.colorValue,
    // Falls back to what is already here rather than to empty, so a document
    // written before the field existed does not wipe the overlays on the next
    // pull. An explicit empty list still clears them.
    overlayCalendarIds: _stringListFromRemote(
      data['overlayCalendarIds'],
      local?.overlayCalendarIds ?? const [],
    ),
    createdAt:
        parseFirestoreDate(data['createdAt']) ??
        local?.createdAt ??
        remoteUpdated,
    updatedAt: remoteUpdated,
    version: parseVersion(data),
    deletedAt: mergeDeletedAtFromRemote(data, local?.deletedAt),
  );
}

Map<String, dynamic> calendarEventToFirestore(CalendarEvent event) => {
  'id': event.id,
  'calendarId': calendarReferenceIdForFirestore(event.calendarId),
  'title': event.title,
  'start': _dateToFirestoreRequired(event.start),
  'end': _dateToFirestoreRequired(event.end),
  'isFullDay': event.isFullDay,
  'colorValue': event.colorValue,
  'notes': event.notes,
  'source': event.source.name,
  'externalId': event.externalId,
  'recurrence': event.recurrence.toStorage(),
  'recurrenceEndDate': _dateToFirestore(event.recurrenceEndDate),
  'exceptionDates': encodeExceptionDates(event.exceptionDates),
  'recurrenceParentId': event.recurrenceParentId,
  'recurrenceDate': _dateToFirestore(event.recurrenceDate),
  'createdAt': _dateToFirestoreRequired(event.createdAt),
  'updatedAt': _dateToFirestoreRequired(event.updatedAt),
  'version': event.version,
  'deletedAt': _dateToFirestore(event.deletedAt),
};

CalendarEvent mergeCalendarEventFromRemote(
  Map<String, dynamic> data,
  String id, {
  CalendarEvent? local,
}) {
  if (!_remoteRecordWins(
    data,
    localVersion: local?.version,
    localUpdatedAt: local?.updatedAt,
  )) {
    return local!;
  }
  final remoteUpdated = parseFirestoreDate(data['updatedAt']) ?? utcNow();
  return CalendarEvent(
    id: id,
    calendarId: switch (data['calendarId']) {
      final String remote => calendarReferenceIdFromFirestore(remote),
      _ => local?.calendarId ?? legacyCalendarId,
    },
    title: data['title'] as String? ?? local?.title ?? '',
    start: parseFirestoreDate(data['start']) ?? local?.start ?? remoteUpdated,
    end: parseFirestoreDate(data['end']) ?? local?.end ?? remoteUpdated,
    isFullDay: data['isFullDay'] as bool? ?? local?.isFullDay ?? true,
    colorValue:
        (data['colorValue'] as num?)?.toInt() ??
        local?.colorValue ??
        0xFF7C9EFF,
    notes: data['notes'] as String? ?? local?.notes ?? '',
    source: _enumFromName(
      EventSource.values,
      data['source'],
      local?.source ?? EventSource.local,
    ),
    externalId: data['externalId'] as String? ?? local?.externalId,
    recurrence: data.containsKey('recurrence')
        ? RecurrenceRule.parse(data['recurrence'] as String?)
        : (local?.recurrence ?? RecurrenceRule.none),
    recurrenceEndDate:
        parseFirestoreDate(data['recurrenceEndDate']) ??
        (data.containsKey('recurrenceEndDate')
            ? null
            : local?.recurrenceEndDate),
    exceptionDates: data.containsKey('exceptionDates')
        ? decodeExceptionDates(data['exceptionDates'] as String?)
        : (local?.exceptionDates ?? const []),
    recurrenceParentId: data.containsKey('recurrenceParentId')
        ? data['recurrenceParentId'] as String?
        : local?.recurrenceParentId,
    recurrenceDate:
        parseFirestoreDate(data['recurrenceDate']) ??
        (data.containsKey('recurrenceDate') ? null : local?.recurrenceDate),
    createdAt:
        parseFirestoreDate(data['createdAt']) ??
        local?.createdAt ??
        remoteUpdated,
    updatedAt: remoteUpdated,
    version: parseVersion(data),
    deletedAt: mergeDeletedAtFromRemote(data, local?.deletedAt),
  );
}

Map<String, dynamic> trackerToFirestore(StatisticTracker tracker) => {
  'id': tracker.id,
  'name': tracker.name,
  'type': tracker.type.name,
  'cadence': tracker.cadence.name,
  'colorValue': tracker.colorValue,
  'showOnCalendar': tracker.showOnCalendar,
  'integerCap': tracker.integerCap,
  'defaultInt': tracker.defaultInt,
  'defaultBool': tracker.defaultBool,
  'enumOptions': tracker.enumOptions,
  'defaultEnumOption': tracker.defaultEnumOption,
  'trackingStyle': tracker.trackingStyle?.name,
  'starred': tracker.starred,
  'sortOrder': tracker.sortOrder,
  'createdAt': _dateToFirestoreRequired(tracker.createdAt),
  'updatedAt': _dateToFirestoreRequired(tracker.updatedAt),
  'version': tracker.version,
  'deletedAt': _dateToFirestore(tracker.deletedAt),
};

StatisticTracker mergeTrackerFromRemote(
  Map<String, dynamic> data,
  String id, {
  StatisticTracker? local,
}) {
  if (!_remoteRecordWins(
    data,
    localVersion: local?.version,
    localUpdatedAt: local?.updatedAt,
  )) {
    return local!;
  }
  final remoteUpdated = parseFirestoreDate(data['updatedAt']) ?? utcNow();
  final remoteStyle = data['trackingStyle'];
  return StatisticTracker(
    id: id,
    name: data['name'] as String? ?? local?.name ?? '',
    type: _enumFromName(
      TrackerType.values,
      data['type'],
      local?.type ?? TrackerType.integer,
    ),
    cadence: _enumFromName(
      TrackerCadence.values,
      data['cadence'],
      local?.cadence ?? TrackerCadence.daily,
    ),
    colorValue:
        (data['colorValue'] as num?)?.toInt() ??
        local?.colorValue ??
        0xFF7C9EFF,
    showOnCalendar:
        data['showOnCalendar'] as bool? ?? local?.showOnCalendar ?? false,
    integerCap: (data['integerCap'] as num?)?.toInt() ?? local?.integerCap,
    defaultInt: (data['defaultInt'] as num?)?.toInt() ?? local?.defaultInt ?? 0,
    defaultBool: data['defaultBool'] as bool? ?? local?.defaultBool ?? false,
    enumOptions: _stringListFromRemote(
      data['enumOptions'],
      local?.enumOptions ?? const [],
    ),
    defaultEnumOption:
        data['defaultEnumOption'] as String? ?? local?.defaultEnumOption,
    // Null is meaningful here — boolean and enum trackers have no style — so
    // an explicit remote null clears the local value rather than falling back.
    trackingStyle: remoteStyle == null
        ? null
        : _enumFromName(
            TrackerStyle.values,
            remoteStyle,
            local?.trackingStyle ?? TrackerStyle.independent,
          ),
    starred: data['starred'] as bool? ?? local?.starred ?? false,
    sortOrder: (data['sortOrder'] as num?)?.toInt() ?? local?.sortOrder ?? 0,
    createdAt:
        parseFirestoreDate(data['createdAt']) ??
        local?.createdAt ??
        remoteUpdated,
    updatedAt: remoteUpdated,
    version: parseVersion(data),
    deletedAt: mergeDeletedAtFromRemote(data, local?.deletedAt),
  );
}

Map<String, dynamic> trackerValueToFirestore(TrackerValue value) => {
  'id': value.id,
  'trackerId': value.trackerId,
  'periodStart': _dateToFirestoreRequired(value.periodStart),
  'intValue': value.intValue,
  'boolValue': value.boolValue,
  'enumValue': value.enumValue,
  'createdAt': _dateToFirestoreRequired(value.createdAt),
  'updatedAt': _dateToFirestoreRequired(value.updatedAt),
  'version': value.version,
  'deletedAt': _dateToFirestore(value.deletedAt),
};

TrackerValue mergeTrackerValueFromRemote(
  Map<String, dynamic> data,
  String id, {
  TrackerValue? local,
}) {
  if (!_remoteRecordWins(
    data,
    localVersion: local?.version,
    localUpdatedAt: local?.updatedAt,
  )) {
    return local!;
  }
  final remoteUpdated = parseFirestoreDate(data['updatedAt']) ?? utcNow();
  // A value is exactly one of int/bool/enum and clearing one is a real edit,
  // so each takes the remote value verbatim instead of falling back to local.
  return TrackerValue(
    id: id,
    trackerId: data['trackerId'] as String? ?? local?.trackerId ?? '',
    periodStart:
        parseFirestoreDate(data['periodStart']) ??
        local?.periodStart ??
        remoteUpdated,
    intValue: (data['intValue'] as num?)?.toDouble(),
    boolValue: data['boolValue'] as bool?,
    enumValue: data['enumValue'] as String?,
    createdAt:
        parseFirestoreDate(data['createdAt']) ??
        local?.createdAt ??
        remoteUpdated,
    updatedAt: remoteUpdated,
    version: parseVersion(data),
    deletedAt: mergeDeletedAtFromRemote(data, local?.deletedAt),
  );
}

Map<String, dynamic> transactionToFirestore(FinancialTransaction tx) => {
  'id': tx.id,
  'type': tx.type.name,
  'amountCents': tx.amountCents,
  'occurredAt': _dateToFirestoreRequired(tx.occurredAt),
  'origin': tx.origin,
  'note': tx.note,
  'tags': tx.tags,
  'roomEventId': tx.roomEventId,
  'createdAt': _dateToFirestoreRequired(tx.createdAt),
  'updatedAt': _dateToFirestoreRequired(tx.updatedAt),
  'version': tx.version,
  'deletedAt': _dateToFirestore(tx.deletedAt),
};

FinancialTransaction mergeTransactionFromRemote(
  Map<String, dynamic> data,
  String id, {
  FinancialTransaction? local,
}) {
  if (!_remoteRecordWins(
    data,
    localVersion: local?.version,
    localUpdatedAt: local?.updatedAt,
  )) {
    return local!;
  }
  final remoteUpdated = parseFirestoreDate(data['updatedAt']) ?? utcNow();
  return FinancialTransaction(
    id: id,
    type: _enumFromName(
      TransactionType.values,
      data['type'],
      local?.type ?? TransactionType.expense,
    ),
    amountCents:
        (data['amountCents'] as num?)?.toInt() ?? local?.amountCents ?? 0,
    occurredAt:
        parseFirestoreDate(data['occurredAt']) ??
        local?.occurredAt ??
        remoteUpdated,
    origin: data.containsKey('origin')
        ? data['origin'] as String?
        : local?.origin,
    note: data['note'] as String?,
    tags: _stringListFromRemote(data['tags'], local?.tags ?? const []),
    // Keyed on presence: a document written before the field existed says
    // nothing about the link, but one written after it says so even when null.
    roomEventId: data.containsKey('roomEventId')
        ? data['roomEventId'] as String?
        : local?.roomEventId,
    createdAt:
        parseFirestoreDate(data['createdAt']) ??
        local?.createdAt ??
        remoteUpdated,
    updatedAt: remoteUpdated,
    version: parseVersion(data),
    deletedAt: mergeDeletedAtFromRemote(data, local?.deletedAt),
  );
}

Map<String, dynamic> subscriptionToFirestore(Subscription subscription) => {
  'id': subscription.id,
  'name': subscription.name,
  'amountCents': subscription.amountCents,
  'period': subscription.period.name,
  'anchorDueDate': _dateToFirestoreRequired(subscription.anchorDueDate),
  'paidThroughDate': _dateToFirestore(subscription.paidThroughDate),
  'colorValue': subscription.colorValue,
  'note': subscription.note,
  'createdAt': _dateToFirestoreRequired(subscription.createdAt),
  'updatedAt': _dateToFirestoreRequired(subscription.updatedAt),
  'version': subscription.version,
  'deletedAt': _dateToFirestore(subscription.deletedAt),
};

Subscription mergeSubscriptionFromRemote(
  Map<String, dynamic> data,
  String id, {
  Subscription? local,
}) {
  if (!_remoteRecordWins(
    data,
    localVersion: local?.version,
    localUpdatedAt: local?.updatedAt,
  )) {
    return local!;
  }
  final remoteUpdated = parseFirestoreDate(data['updatedAt']) ?? utcNow();
  return Subscription(
    id: id,
    name: data['name'] as String? ?? local?.name ?? '',
    amountCents:
        (data['amountCents'] as num?)?.toInt() ?? local?.amountCents ?? 0,
    period: _enumFromName(
      BillingPeriod.values,
      data['period'],
      local?.period ?? BillingPeriod.monthly,
    ),
    anchorDueDate:
        parseFirestoreDate(data['anchorDueDate']) ??
        local?.anchorDueDate ??
        remoteUpdated,
    // Keyed on presence, not on null: clearing a recorded payment is what an
    // edited due date does, and `?? local` would let every device that had
    // one keep it forever.
    paidThroughDate: data.containsKey('paidThroughDate')
        ? parseFirestoreDate(data['paidThroughDate'])
        : local?.paidThroughDate,
    colorValue:
        (data['colorValue'] as num?)?.toInt() ??
        local?.colorValue ??
        0xFF7C9EFF,
    note: data['note'] as String?,
    createdAt:
        parseFirestoreDate(data['createdAt']) ??
        local?.createdAt ??
        remoteUpdated,
    updatedAt: remoteUpdated,
    version: parseVersion(data),
    deletedAt: mergeDeletedAtFromRemote(data, local?.deletedAt),
  );
}

Map<String, dynamic> budgetToFirestore(Budget budget) => {
  'id': budget.id,
  'tag': budget.tag,
  'limitCents': budget.limitCents,
  'createdAt': _dateToFirestoreRequired(budget.createdAt),
  'updatedAt': _dateToFirestoreRequired(budget.updatedAt),
  'version': budget.version,
  'deletedAt': _dateToFirestore(budget.deletedAt),
};

Budget mergeBudgetFromRemote(
  Map<String, dynamic> data,
  String id, {
  Budget? local,
}) {
  if (!_remoteRecordWins(
    data,
    localVersion: local?.version,
    localUpdatedAt: local?.updatedAt,
  )) {
    return local!;
  }
  final remoteUpdated = parseFirestoreDate(data['updatedAt']) ?? utcNow();
  return Budget(
    id: id,
    tag: data['tag'] as String? ?? local?.tag ?? '',
    limitCents: (data['limitCents'] as num?)?.toInt() ?? local?.limitCents ?? 0,
    createdAt:
        parseFirestoreDate(data['createdAt']) ??
        local?.createdAt ??
        remoteUpdated,
    updatedAt: remoteUpdated,
    version: parseVersion(data),
    deletedAt: mergeDeletedAtFromRemote(data, local?.deletedAt),
  );
}

Map<String, dynamic> financeCategoryToFirestore(FinanceCategory category) => {
  'id': category.id,
  'name': category.name,
  'colorValue': category.colorValue,
  'tags': category.tags,
  'createdAt': _dateToFirestoreRequired(category.createdAt),
  'updatedAt': _dateToFirestoreRequired(category.updatedAt),
  'version': category.version,
  'deletedAt': _dateToFirestore(category.deletedAt),
};

FinanceCategory mergeFinanceCategoryFromRemote(
  Map<String, dynamic> data,
  String id, {
  FinanceCategory? local,
}) {
  if (!_remoteRecordWins(
    data,
    localVersion: local?.version,
    localUpdatedAt: local?.updatedAt,
  )) {
    return local!;
  }
  final remoteUpdated = parseFirestoreDate(data['updatedAt']) ?? utcNow();
  return FinanceCategory(
    id: id,
    name: data['name'] as String? ?? local?.name ?? '',
    colorValue:
        (data['colorValue'] as num?)?.toInt() ??
        local?.colorValue ??
        0xFF7C9EFF,
    tags: _stringListFromRemote(data['tags'], local?.tags ?? const []),
    createdAt:
        parseFirestoreDate(data['createdAt']) ??
        local?.createdAt ??
        remoteUpdated,
    updatedAt: remoteUpdated,
    version: parseVersion(data),
    deletedAt: mergeDeletedAtFromRemote(data, local?.deletedAt),
  );
}

Map<String, dynamic> assetToFirestore(Asset asset) => {
  'id': asset.id,
  'name': asset.name,
  'note': asset.note,
  'colorValue': asset.colorValue,
  // Written even when null, so detaching reaches the other devices.
  'contributionRoomId': asset.contributionRoomId,
  'createdAt': _dateToFirestoreRequired(asset.createdAt),
  'updatedAt': _dateToFirestoreRequired(asset.updatedAt),
  'version': asset.version,
  'deletedAt': _dateToFirestore(asset.deletedAt),
};

Asset mergeAssetFromRemote(
  Map<String, dynamic> data,
  String id, {
  Asset? local,
}) {
  if (!_remoteRecordWins(
    data,
    localVersion: local?.version,
    localUpdatedAt: local?.updatedAt,
  )) {
    return local!;
  }
  final remoteUpdated = parseFirestoreDate(data['updatedAt']) ?? utcNow();
  return Asset(
    id: id,
    name: data['name'] as String? ?? local?.name ?? '',
    note: data['note'] as String?,
    colorValue:
        (data['colorValue'] as num?)?.toInt() ??
        local?.colorValue ??
        0xFF7C9EFF,
    contributionRoomId: data.containsKey('contributionRoomId')
        ? data['contributionRoomId'] as String?
        : local?.contributionRoomId,
    createdAt:
        parseFirestoreDate(data['createdAt']) ??
        local?.createdAt ??
        remoteUpdated,
    updatedAt: remoteUpdated,
    version: parseVersion(data),
    deletedAt: mergeDeletedAtFromRemote(data, local?.deletedAt),
  );
}

Map<String, dynamic> assetValuationToFirestore(AssetValuation valuation) => {
  'id': valuation.id,
  'assetId': valuation.assetId,
  'valueCents': valuation.valueCents,
  'asOf': _dateToFirestoreRequired(valuation.asOf),
  'createdAt': _dateToFirestoreRequired(valuation.createdAt),
  'updatedAt': _dateToFirestoreRequired(valuation.updatedAt),
  'version': valuation.version,
  'deletedAt': _dateToFirestore(valuation.deletedAt),
};

AssetValuation mergeAssetValuationFromRemote(
  Map<String, dynamic> data,
  String id, {
  AssetValuation? local,
}) {
  if (!_remoteRecordWins(
    data,
    localVersion: local?.version,
    localUpdatedAt: local?.updatedAt,
  )) {
    return local!;
  }
  final remoteUpdated = parseFirestoreDate(data['updatedAt']) ?? utcNow();
  return AssetValuation(
    id: id,
    assetId: data['assetId'] as String? ?? local?.assetId ?? '',
    valueCents: (data['valueCents'] as num?)?.toInt() ?? local?.valueCents ?? 0,
    asOf: parseFirestoreDate(data['asOf']) ?? local?.asOf ?? remoteUpdated,
    createdAt:
        parseFirestoreDate(data['createdAt']) ??
        local?.createdAt ??
        remoteUpdated,
    updatedAt: remoteUpdated,
    version: parseVersion(data),
    deletedAt: mergeDeletedAtFromRemote(data, local?.deletedAt),
  );
}

Map<String, dynamic> contributionRoomToFirestore(ContributionRoom room) => {
  'id': room.id,
  'name': room.name,
  'baselineRemainingCents': room.baselineRemainingCents,
  'baselineAsOf': _dateToFirestoreRequired(room.baselineAsOf),
  'annualLimits': [for (final l in room.annualLimits) l.toJson()],
  'createdAt': _dateToFirestoreRequired(room.createdAt),
  'updatedAt': _dateToFirestoreRequired(room.updatedAt),
  'version': room.version,
  'deletedAt': _dateToFirestore(room.deletedAt),
};

ContributionRoom mergeContributionRoomFromRemote(
  Map<String, dynamic> data,
  String id, {
  ContributionRoom? local,
}) {
  if (!_remoteRecordWins(
    data,
    localVersion: local?.version,
    localUpdatedAt: local?.updatedAt,
  )) {
    return local!;
  }
  final remoteUpdated = parseFirestoreDate(data['updatedAt']) ?? utcNow();
  return ContributionRoom(
    id: id,
    name: data['name'] as String? ?? local?.name ?? '',
    baselineRemainingCents:
        (data['baselineRemainingCents'] as num?)?.toInt() ??
        local?.baselineRemainingCents ??
        0,
    baselineAsOf:
        parseFirestoreDate(data['baselineAsOf']) ??
        local?.baselineAsOf ??
        remoteUpdated,
    annualLimits: data.containsKey('annualLimits')
        ? AnnualLimit.listFromJson(data['annualLimits'])
        : local?.annualLimits ?? const [],
    createdAt:
        parseFirestoreDate(data['createdAt']) ??
        local?.createdAt ??
        remoteUpdated,
    updatedAt: remoteUpdated,
    version: parseVersion(data),
    deletedAt: mergeDeletedAtFromRemote(data, local?.deletedAt),
  );
}

Map<String, dynamic> assetRoomEventToFirestore(AssetRoomEvent event) => {
  'id': event.id,
  'assetId': event.assetId,
  'roomId': event.roomId,
  'kind': event.kind.name,
  'amountCents': event.amountCents,
  'occurredAt': _dateToFirestoreRequired(event.occurredAt),
  'transactionId': event.transactionId,
  'valuationId': event.valuationId,
  'counterAssetId': event.counterAssetId,
  'transferGroupId': event.transferGroupId,
  'note': event.note,
  'createdAt': _dateToFirestoreRequired(event.createdAt),
  'updatedAt': _dateToFirestoreRequired(event.updatedAt),
  'version': event.version,
  'deletedAt': _dateToFirestore(event.deletedAt),
};

AssetRoomEvent mergeAssetRoomEventFromRemote(
  Map<String, dynamic> data,
  String id, {
  AssetRoomEvent? local,
}) {
  if (!_remoteRecordWins(
    data,
    localVersion: local?.version,
    localUpdatedAt: local?.updatedAt,
  )) {
    return local!;
  }
  final remoteUpdated = parseFirestoreDate(data['updatedAt']) ?? utcNow();
  return AssetRoomEvent(
    id: id,
    assetId: data['assetId'] as String? ?? local?.assetId ?? '',
    roomId: data['roomId'] as String? ?? local?.roomId ?? '',
    kind: _enumFromName(
      RoomEventKind.values,
      data['kind'],
      local?.kind ?? RoomEventKind.contribution,
    ),
    amountCents:
        (data['amountCents'] as num?)?.toInt() ?? local?.amountCents ?? 0,
    occurredAt:
        parseFirestoreDate(data['occurredAt']) ??
        local?.occurredAt ??
        remoteUpdated,
    transactionId: data['transactionId'] as String?,
    valuationId: data['valuationId'] as String?,
    counterAssetId: data['counterAssetId'] as String?,
    transferGroupId: data['transferGroupId'] as String?,
    note: data['note'] as String?,
    createdAt:
        parseFirestoreDate(data['createdAt']) ??
        local?.createdAt ??
        remoteUpdated,
    updatedAt: remoteUpdated,
    version: parseVersion(data),
    deletedAt: mergeDeletedAtFromRemote(data, local?.deletedAt),
  );
}

Map<String, dynamic> savingsGoalToFirestore(SavingsGoal goal) => {
  'id': goal.id,
  'name': goal.name,
  'targetCents': goal.targetCents,
  'colorValue': goal.colorValue,
  'note': goal.note,
  'targetDate': _dateToFirestore(goal.targetDate),
  'createdAt': _dateToFirestoreRequired(goal.createdAt),
  'updatedAt': _dateToFirestoreRequired(goal.updatedAt),
  'version': goal.version,
  'deletedAt': _dateToFirestore(goal.deletedAt),
};

SavingsGoal mergeSavingsGoalFromRemote(
  Map<String, dynamic> data,
  String id, {
  SavingsGoal? local,
}) {
  if (!_remoteRecordWins(
    data,
    localVersion: local?.version,
    localUpdatedAt: local?.updatedAt,
  )) {
    return local!;
  }
  final remoteUpdated = parseFirestoreDate(data['updatedAt']) ?? utcNow();
  return SavingsGoal(
    id: id,
    name: data['name'] as String? ?? local?.name ?? '',
    targetCents:
        (data['targetCents'] as num?)?.toInt() ?? local?.targetCents ?? 0,
    colorValue:
        (data['colorValue'] as num?)?.toInt() ??
        local?.colorValue ??
        0xFF7C9EFF,
    note: data['note'] as String?,
    targetDate: parseFirestoreDate(data['targetDate']),
    createdAt:
        parseFirestoreDate(data['createdAt']) ??
        local?.createdAt ??
        remoteUpdated,
    updatedAt: remoteUpdated,
    version: parseVersion(data),
    deletedAt: mergeDeletedAtFromRemote(data, local?.deletedAt),
  );
}

Map<String, dynamic> goalAllocationToFirestore(GoalAllocation allocation) => {
  'id': allocation.id,
  'goalId': allocation.goalId,
  'amountCents': allocation.amountCents,
  'allocatedAt': _dateToFirestoreRequired(allocation.allocatedAt),
  'note': allocation.note,
  'createdAt': _dateToFirestoreRequired(allocation.createdAt),
  'updatedAt': _dateToFirestoreRequired(allocation.updatedAt),
  'version': allocation.version,
  'deletedAt': _dateToFirestore(allocation.deletedAt),
};

GoalAllocation mergeGoalAllocationFromRemote(
  Map<String, dynamic> data,
  String id, {
  GoalAllocation? local,
}) {
  if (!_remoteRecordWins(
    data,
    localVersion: local?.version,
    localUpdatedAt: local?.updatedAt,
  )) {
    return local!;
  }
  final remoteUpdated = parseFirestoreDate(data['updatedAt']) ?? utcNow();
  return GoalAllocation(
    id: id,
    goalId: data['goalId'] as String? ?? local?.goalId ?? '',
    amountCents:
        (data['amountCents'] as num?)?.toInt() ?? local?.amountCents ?? 0,
    allocatedAt:
        parseFirestoreDate(data['allocatedAt']) ??
        local?.allocatedAt ??
        remoteUpdated,
    note: data['note'] as String?,
    createdAt:
        parseFirestoreDate(data['createdAt']) ??
        local?.createdAt ??
        remoteUpdated,
    updatedAt: remoteUpdated,
    version: parseVersion(data),
    deletedAt: mergeDeletedAtFromRemote(data, local?.deletedAt),
  );
}

Map<String, dynamic> pinnedNoteToFirestore(PinnedNote note) => {
  'id': note.id,
  'text': note.text,
  'createdAt': _dateToFirestoreRequired(note.createdAt),
  'updatedAt': _dateToFirestoreRequired(note.updatedAt),
  'version': note.version,
  'deletedAt': _dateToFirestore(note.deletedAt),
};

PinnedNote mergePinnedNoteFromRemote(
  Map<String, dynamic> data,
  String id, {
  PinnedNote? local,
}) {
  if (!_remoteRecordWins(
    data,
    localVersion: local?.version,
    localUpdatedAt: local?.updatedAt,
  )) {
    return local!;
  }
  final remoteUpdated = parseFirestoreDate(data['updatedAt']) ?? utcNow();
  return PinnedNote(
    id: id,
    text: data['text'] as String? ?? local?.text ?? '',
    createdAt:
        parseFirestoreDate(data['createdAt']) ??
        local?.createdAt ??
        remoteUpdated,
    updatedAt: remoteUpdated,
    version: parseVersion(data),
    deletedAt: mergeDeletedAtFromRemote(data, local?.deletedAt),
  );
}

Map<String, dynamic> dismissedNotificationToFirestore(
  DismissedNotification dismissal,
) => {
  'key': dismissal.key,
  'dismissedAt': _dateToFirestoreRequired(dismissal.dismissedAt),
  'updatedAt': _dateToFirestoreRequired(dismissal.updatedAt),
  'version': dismissal.version,
  'deletedAt': _dateToFirestore(dismissal.deletedAt),
};

DismissedNotification mergeDismissedNotificationFromRemote(
  Map<String, dynamic> data,
  String key, {
  DismissedNotification? local,
}) {
  if (!_remoteRecordWins(
    data,
    localVersion: local?.version,
    localUpdatedAt: local?.updatedAt,
  )) {
    return local!;
  }
  final remoteUpdated = parseFirestoreDate(data['updatedAt']) ?? utcNow();
  return DismissedNotification(
    key: key,
    dismissedAt:
        parseFirestoreDate(data['dismissedAt']) ??
        local?.dismissedAt ??
        remoteUpdated,
    updatedAt: remoteUpdated,
    version: parseVersion(data),
    // Unlike the other records here a tombstone must be undoable: the same key
    // cycles between dismissed and un-dismissed as the item comes back.
    deletedAt: parseFirestoreDate(data['deletedAt']),
  );
}

Map<String, dynamic> deviceRegistrationToFirestore(DeviceRegistration device) =>
    {
      'id': device.id,
      'displayName': device.displayName,
      'platform': device.platform.name,
      'lastSeenAt': _dateToFirestoreRequired(device.lastSeenAt),
      'createdAt': _dateToFirestoreRequired(device.createdAt),
      'updatedAt': _dateToFirestoreRequired(device.updatedAt),
      'version': device.version,
      'deletedAt': _dateToFirestore(device.deletedAt),
    };

DeviceRegistration mergeDeviceRegistrationFromRemote(
  Map<String, dynamic> data,
  String id, {
  DeviceRegistration? local,
}) {
  if (!_remoteRecordWins(
    data,
    localVersion: local?.version,
    localUpdatedAt: local?.updatedAt,
  )) {
    return local!;
  }
  final remoteUpdated = parseFirestoreDate(data['updatedAt']) ?? utcNow();
  return DeviceRegistration(
    id: id,
    displayName:
        data['displayName'] as String? ?? local?.displayName ?? 'Device',
    platform: reminderEnumByName(
      DevicePlatform.values,
      data['platform'] as String? ?? local?.platform.name,
      DevicePlatform.web,
    ),
    lastSeenAt:
        parseFirestoreDate(data['lastSeenAt']) ??
        local?.lastSeenAt ??
        remoteUpdated,
    createdAt:
        parseFirestoreDate(data['createdAt']) ??
        local?.createdAt ??
        remoteUpdated,
    updatedAt: remoteUpdated,
    version: parseVersion(data),
    deletedAt: mergeDeletedAtFromRemote(data, local?.deletedAt),
  );
}

Map<String, dynamic> scheduledReminderRuleToFirestore(
  ScheduledReminderRule rule,
) {
  final onceDate = rule.onceLocalDate;
  return {
    'id': rule.id,
    'title': rule.title,
    'body': rule.body,
    'enabled': rule.enabled,
    'scheduleKind': rule.scheduleKind.name,
    'localTimeMinutes': rule.localTimeMinutes,
    'weeklyWeekdays': rule.weeklyWeekdays.toList()..sort(),
    'onceLocalDate': onceDate == null
        ? null
        : reminderLocalDateToString(onceDate),
    'targetDeviceIds': rule.targetDeviceIds,
    'armedAt': _dateToFirestoreRequired(rule.armedAt),
    'createdAt': _dateToFirestoreRequired(rule.createdAt),
    'updatedAt': _dateToFirestoreRequired(rule.updatedAt),
    'version': rule.version,
    'deletedAt': _dateToFirestore(rule.deletedAt),
  };
}

ScheduledReminderRule mergeScheduledReminderRuleFromRemote(
  Map<String, dynamic> data,
  String id, {
  ScheduledReminderRule? local,
}) {
  if (!_remoteRecordWins(
    data,
    localVersion: local?.version,
    localUpdatedAt: local?.updatedAt,
  )) {
    return local!;
  }
  final remoteUpdated = parseFirestoreDate(data['updatedAt']) ?? utcNow();
  return ScheduledReminderRule(
    id: id,
    title: data['title'] as String? ?? local?.title ?? '',
    body: data['body'] as String?,
    enabled: data['enabled'] as bool? ?? local?.enabled ?? true,
    scheduleKind: reminderEnumByName(
      ReminderScheduleKind.values,
      data['scheduleKind'] as String? ?? local?.scheduleKind.name,
      ReminderScheduleKind.daily,
    ),
    localTimeMinutes:
        (data['localTimeMinutes'] as num?)?.toInt() ??
        local?.localTimeMinutes ??
        0,
    weeklyWeekdays: data['weeklyWeekdays'] is List
        ? {
            for (final day in data['weeklyWeekdays'] as List)
              if (day is num) day.toInt(),
          }
        : (local?.weeklyWeekdays ?? const {}),
    onceLocalDate: parseReminderLocalDate(data['onceLocalDate'] as String?),
    targetDeviceIds: data['targetDeviceIds'] is List
        ? List<String>.from(data['targetDeviceIds'] as List)
        : (local?.targetDeviceIds ?? const []),
    armedAt:
        parseFirestoreDate(data['armedAt']) ?? local?.armedAt ?? remoteUpdated,
    createdAt:
        parseFirestoreDate(data['createdAt']) ??
        local?.createdAt ??
        remoteUpdated,
    updatedAt: remoteUpdated,
    version: parseVersion(data),
    deletedAt: mergeDeletedAtFromRemote(data, local?.deletedAt),
  );
}

Map<String, dynamic> entityReminderToFirestore(EntityReminder reminder) => {
  'id': reminder.id,
  'sourceKind': reminder.sourceKind.name,
  'entityId': reminder.entityId,
  'enabled': reminder.enabled,
  'offsetMinutes': reminder.offsetMinutes,
  'armedAt': _dateToFirestoreRequired(reminder.armedAt),
  'createdAt': _dateToFirestoreRequired(reminder.createdAt),
  'updatedAt': _dateToFirestoreRequired(reminder.updatedAt),
  'version': reminder.version,
  'deletedAt': _dateToFirestore(reminder.deletedAt),
};

EntityReminder mergeEntityReminderFromRemote(
  Map<String, dynamic> data,
  String id, {
  EntityReminder? local,
}) {
  if (!_remoteRecordWins(
    data,
    localVersion: local?.version,
    localUpdatedAt: local?.updatedAt,
  )) {
    return local!;
  }
  final remoteUpdated = parseFirestoreDate(data['updatedAt']) ?? utcNow();
  return EntityReminder(
    id: id,
    sourceKind: reminderEnumByName(
      ReminderSourceKind.values,
      data['sourceKind'] as String? ?? local?.sourceKind.name,
      ReminderSourceKind.todo,
    ),
    entityId: data['entityId'] as String? ?? local?.entityId ?? '',
    enabled: data['enabled'] as bool? ?? local?.enabled ?? true,
    offsetMinutes:
        (data['offsetMinutes'] as num?)?.toInt() ?? local?.offsetMinutes ?? 0,
    armedAt:
        parseFirestoreDate(data['armedAt']) ?? local?.armedAt ?? remoteUpdated,
    createdAt:
        parseFirestoreDate(data['createdAt']) ??
        local?.createdAt ??
        remoteUpdated,
    updatedAt: remoteUpdated,
    version: parseVersion(data),
    deletedAt: mergeDeletedAtFromRemote(data, local?.deletedAt),
  );
}

Map<String, dynamic> reminderDeliveryStateToFirestore(
  ReminderDeliveryState state,
) => {
  'id': state.id,
  'sourceKind': state.sourceKind.name,
  'sourceId': state.sourceId,
  'occurrenceKey': state.occurrenceKey,
  'status': state.status.name,
  'snoozeUntil': _dateToFirestore(state.snoozeUntil),
  'ackedAt': _dateToFirestore(state.ackedAt),
  'createdAt': _dateToFirestoreRequired(state.createdAt),
  'updatedAt': _dateToFirestoreRequired(state.updatedAt),
  'version': state.version,
};

/// Last writer wins on version, then [ReminderDeliveryState.updatedAt] — so of
/// an acknowledge and a snooze made concurrently on two devices, the later
/// press stands (§8).
ReminderDeliveryState mergeReminderDeliveryStateFromRemote(
  Map<String, dynamic> data,
  String id, {
  ReminderDeliveryState? local,
}) {
  if (!_remoteRecordWins(
    data,
    localVersion: local?.version,
    localUpdatedAt: local?.updatedAt,
  )) {
    return local!;
  }
  final remoteUpdated = parseFirestoreDate(data['updatedAt']) ?? utcNow();
  return ReminderDeliveryState(
    id: id,
    sourceKind: reminderEnumByName(
      ReminderSourceKind.values,
      data['sourceKind'] as String? ?? local?.sourceKind.name,
      ReminderSourceKind.scheduledRule,
    ),
    sourceId: data['sourceId'] as String? ?? local?.sourceId ?? '',
    occurrenceKey:
        data['occurrenceKey'] as String? ?? local?.occurrenceKey ?? '',
    status: reminderEnumByName(
      ReminderDeliveryStatus.values,
      data['status'] as String? ?? local?.status.name,
      ReminderDeliveryStatus.acked,
    ),
    snoozeUntil: parseFirestoreDate(data['snoozeUntil']),
    ackedAt: parseFirestoreDate(data['ackedAt']),
    createdAt:
        parseFirestoreDate(data['createdAt']) ??
        local?.createdAt ??
        remoteUpdated,
    updatedAt: remoteUpdated,
    version: parseVersion(data),
  );
}

Map<String, dynamic> reminderDeliveryLogToFirestore(ReminderDeliveryLog log) =>
    {
      'id': log.id,
      'deliveryStateId': log.deliveryStateId,
      'sourceKind': log.sourceKind.name,
      'sourceId': log.sourceId,
      'occurrenceKey': log.occurrenceKey,
      'eventType': log.eventType.name,
      'deviceId': log.deviceId,
      'at': _dateToFirestoreRequired(log.at),
      'detail': log.detail,
      'createdAt': _dateToFirestoreRequired(log.createdAt),
      'updatedAt': _dateToFirestoreRequired(log.updatedAt),
      'version': log.version,
      'deletedAt': _dateToFirestore(log.deletedAt),
    };

ReminderDeliveryLog mergeReminderDeliveryLogFromRemote(
  Map<String, dynamic> data,
  String id, {
  ReminderDeliveryLog? local,
}) {
  if (!_remoteRecordWins(
    data,
    localVersion: local?.version,
    localUpdatedAt: local?.updatedAt,
  )) {
    return local!;
  }
  final remoteUpdated = parseFirestoreDate(data['updatedAt']) ?? utcNow();
  return ReminderDeliveryLog(
    id: id,
    deliveryStateId:
        data['deliveryStateId'] as String? ?? local?.deliveryStateId ?? '',
    sourceKind: reminderEnumByName(
      ReminderSourceKind.values,
      data['sourceKind'] as String? ?? local?.sourceKind.name,
      ReminderSourceKind.scheduledRule,
    ),
    sourceId: data['sourceId'] as String? ?? local?.sourceId ?? '',
    occurrenceKey:
        data['occurrenceKey'] as String? ?? local?.occurrenceKey ?? '',
    eventType: reminderEnumByName(
      ReminderLogEvent.values,
      data['eventType'] as String? ?? local?.eventType.name,
      ReminderLogEvent.osFired,
    ),
    deviceId: data['deviceId'] as String? ?? local?.deviceId ?? '',
    at: parseFirestoreDate(data['at']) ?? local?.at ?? remoteUpdated,
    detail: data['detail'] as String?,
    createdAt:
        parseFirestoreDate(data['createdAt']) ??
        local?.createdAt ??
        remoteUpdated,
    updatedAt: remoteUpdated,
    version: parseVersion(data),
    deletedAt: mergeDeletedAtFromRemote(data, local?.deletedAt),
  );
}

Map<String, dynamic> bucketListItemToFirestore(BucketListItem item) => {
  'id': item.id,
  'title': item.title,
  'note': item.note,
  'completed': item.completed,
  'completedAt': _dateToFirestore(item.completedAt),
  'sortOrder': item.sortOrder,
  'createdAt': _dateToFirestoreRequired(item.createdAt),
  'updatedAt': _dateToFirestoreRequired(item.updatedAt),
  'version': item.version,
  'deletedAt': _dateToFirestore(item.deletedAt),
};

BucketListItem mergeBucketListItemFromRemote(
  Map<String, dynamic> data,
  String id, {
  BucketListItem? local,
}) {
  if (!_remoteRecordWins(
    data,
    localVersion: local?.version,
    localUpdatedAt: local?.updatedAt,
  )) {
    return local!;
  }
  final remoteUpdated = parseFirestoreDate(data['updatedAt']) ?? utcNow();
  return BucketListItem(
    id: id,
    title: data['title'] as String? ?? local?.title ?? '',
    note: data['note'] as String?,
    completed: data['completed'] as bool? ?? local?.completed ?? false,
    // Un-completing an item clears this, so the remote value is taken as-is.
    completedAt: parseFirestoreDate(data['completedAt']),
    sortOrder: (data['sortOrder'] as num?)?.toInt() ?? local?.sortOrder ?? 0,
    createdAt:
        parseFirestoreDate(data['createdAt']) ??
        local?.createdAt ??
        remoteUpdated,
    updatedAt: remoteUpdated,
    version: parseVersion(data),
    deletedAt: mergeDeletedAtFromRemote(data, local?.deletedAt),
  );
}

Map<String, dynamic> tagColorToFirestore(TagColorRecord tagColor) => {
  'tag': tagColor.tag,
  'colorValue': tagColor.colorValue,
  'updatedAt': _dateToFirestoreRequired(tagColor.updatedAt),
  'version': tagColor.version,
};

TagColorRecord mergeTagColorFromRemote(
  Map<String, dynamic> data,
  String tag, {
  TagColorRecord? local,
}) {
  if (!_remoteRecordWins(
    data,
    localVersion: local?.version,
    localUpdatedAt: local?.updatedAt,
  )) {
    return local!;
  }
  return TagColorRecord(
    tag: tag,
    colorValue:
        (data['colorValue'] as num?)?.toInt() ??
        local?.colorValue ??
        0xFF7C9EFF,
    updatedAt: parseFirestoreDate(data['updatedAt']) ?? utcNow(),
    version: parseVersion(data),
  );
}

Map<String, dynamic> customWordToFirestore(CustomWord word) => {
  'word': word.word,
  'createdAt': _dateToFirestoreRequired(word.createdAt),
  'updatedAt': _dateToFirestoreRequired(word.updatedAt),
  'version': word.version,
  'deletedAt': _dateToFirestore(word.deletedAt),
};

CustomWord mergeCustomWordFromRemote(
  Map<String, dynamic> data,
  String word, {
  CustomWord? local,
}) {
  if (!_remoteRecordWins(
    data,
    localVersion: local?.version,
    localUpdatedAt: local?.updatedAt,
  )) {
    return local!;
  }
  final remoteUpdated = parseFirestoreDate(data['updatedAt']) ?? utcNow();
  return CustomWord(
    word: word,
    createdAt:
        parseFirestoreDate(data['createdAt']) ??
        local?.createdAt ??
        remoteUpdated,
    updatedAt: remoteUpdated,
    version: parseVersion(data),
    // Re-adding a removed word clears its tombstone, so the remote value is
    // taken verbatim rather than falling back to the local one.
    deletedAt: parseFirestoreDate(data['deletedAt']),
  );
}

Map<String, dynamic> flaggedWordToFirestore(FlaggedWord word) => {
  'word': word.word,
  'replacement': word.replacement,
  'createdAt': _dateToFirestoreRequired(word.createdAt),
  'updatedAt': _dateToFirestoreRequired(word.updatedAt),
  'version': word.version,
  'deletedAt': _dateToFirestore(word.deletedAt),
};

FlaggedWord mergeFlaggedWordFromRemote(
  Map<String, dynamic> data,
  String word, {
  FlaggedWord? local,
}) {
  if (!_remoteRecordWins(
    data,
    localVersion: local?.version,
    localUpdatedAt: local?.updatedAt,
  )) {
    return local!;
  }
  final remoteUpdated = parseFirestoreDate(data['updatedAt']) ?? utcNow();
  return FlaggedWord(
    word: word,
    // Taken verbatim, never falling back to the local value: clearing a
    // replacement while keeping the flag is a real edit, and a fallback would
    // silently restore the rule the user deleted.
    replacement: (data['replacement'] as String?),
    createdAt:
        parseFirestoreDate(data['createdAt']) ??
        local?.createdAt ??
        remoteUpdated,
    updatedAt: remoteUpdated,
    version: parseVersion(data),
    // Re-flagging a word whose flag was lifted clears its tombstone, so the
    // remote value wins here too.
    deletedAt: parseFirestoreDate(data['deletedAt']),
  );
}

// ---------------------------------------------------------------------------
// The settings document (`users/{uid}/settings/app`, alongside the weather
// location the weather service already keeps there).
// ---------------------------------------------------------------------------

int? _remoteInt(Map<String, dynamic> data, String key) =>
    (data[key] as num?)?.toInt();

double? _remoteDouble(Map<String, dynamic> data, String key) =>
    (data[key] as num?)?.toDouble();

List<int>? _remoteIntList(Map<String, dynamic> data, String key) {
  final value = data[key];
  if (value is! List) return null;
  return [
    for (final item in value)
      if (item is num) item.toInt(),
  ];
}

/// True when the remote document says this field is now empty, as opposed to
/// not mentioning it at all. Only the first case should clear the local value.
bool _remoteClears(Map<String, dynamic> data, String key) =>
    data.containsKey(key) && data[key] == null;

/// The settings that follow the user between devices.
///
/// Deliberately excluded, because they describe *this* device rather than the
/// user's preferences:
///  - `deviceId`, which identifies the installation;
///  - the whole weather cache, which the weather service already syncs through
///    its own keys in this same document;
///  - every `dev*` debugging flag;
///  - `journalEntryListWidth`, `dreamSplitWidth`, `editSidePanelWidth` and
///    `workoutLibraryWidth`, which are sized for the screen they were dragged
///    on;
///  - where the user is: `lastSeenNavPage`, the `lastViewed*Id`s, the
///    `*ShowAll*` scopes and `todoCompletedSectionExpanded`. These change on
///    every page or list switch, and while they synced, merely navigating on a
///    device that hadn't pulled moved the clock and re-uploaded its stale copy
///    of every other setting over newer edits made elsewhere.
///
/// This map is also the single definition of "did a synced setting change" —
/// see `DriftSettingsRepository.saveSettings`, which compares two of them to
/// decide whether to move the last-write-wins clock. Adding a field here is
/// therefore all that syncing a new setting takes.
Map<String, dynamic> settingsSyncPayload(AppSettings s) => {
  'accentColor': s.accentColor,
  'themeMode': s.themeMode.name,
  'petalColor': s.petalColor,
  'minorPetalColors': s.minorPetalColors,
  'petalMaxCount': s.petalMaxCount,
  'petalFallSpeed': s.petalFallSpeed,
  'petalWindFrequency': s.petalWindFrequency,
  'petalWindStrength': s.petalWindStrength,
  'weekStartsOnMonday': s.weekStartsOnMonday,
  'showQuotes': s.showQuotes,
  'customQuotesOnly': s.customQuotesOnly,
  'showDefaultTrackersInGrid': s.showDefaultTrackersInGrid,
  'showDefaultTrackersInCalendar': s.showDefaultTrackersInCalendar,
  'journalHotkey': s.journalHotkey,
  'todoHotkey': s.todoHotkey,
  'financeHotkey': s.financeHotkey,
  'reminderHotkey': s.reminderHotkey,
  'calendarNavigateLeftKey': s.calendarNavigateLeftKey,
  'calendarNavigateRightKey': s.calendarNavigateRightKey,
  'srsFailKey': s.srsFailKey,
  'srsHardKey': s.srsHardKey,
  'srsGoodKey': s.srsGoodKey,
  'srsEasyKey': s.srsEasyKey,
  'timelineModeYearZero': s.timelineModeYearZero,
  'birthYear': s.birthYear,
  'birthDate': _dateToFirestore(s.birthDate),
  'alertOnPeriodicPrompts': s.alertOnPeriodicPrompts,
  'alertTimeHour': s.alertTimeHour,
  'hideCompletedTasks': s.hideCompletedTasks,
  'vimModeEnabled': s.vimModeEnabled,
  'snippetsEnabled': s.snippetsEnabled,
  'autocorrectEnabled': s.autocorrectEnabled,
  'capsLockIndicatorEnabled': s.capsLockIndicatorEnabled,
  'mediaRemoteUploadsEnabled': s.mediaRemoteUploadsEnabled,
  'mediaRemoteDownloadsEnabled': s.mediaRemoteDownloadsEnabled,
  'mediaBackgroundPrefetchEnabled': s.mediaBackgroundPrefetchEnabled,
  'snippetExpandKey': s.snippetExpandKey.name,
  'defaultJournalId': s.defaultJournalId,
  'defaultTodoListId': s.defaultTodoListId,
  'geometricTextureScale': s.geometricTextureScale,
  'geometricTextureIntensity': s.geometricTextureIntensity,
  'geometricTextureFocalSpread': s.geometricTextureFocalSpread,
  'geometricTextureFocalPointX': s.geometricTextureFocalPointX,
  'geometricTextureFocalPointY': s.geometricTextureFocalPointY,
  'geometricTextureVariationFloor': s.geometricTextureVariationFloor,
  'geometricWaveEnabled': s.geometricWaveEnabled,
  'geometricWaveShape': s.geometricWaveShape.name,
  'geometricWaveDirectionDegrees': s.geometricWaveDirectionDegrees,
  'geometricWaveSpeed': s.geometricWaveSpeed,
  'geometricWaveWidth': s.geometricWaveWidth,
  'geometricWavePeriod': s.geometricWavePeriod,
  'geometricWavePopHoldSeconds': s.geometricWavePopHoldSeconds,
  'geometricWavePopScale': s.geometricWavePopScale,
  'geometricWavePopBrightness': s.geometricWavePopBrightness,
  'geometricWaveMaskDensity': s.geometricWaveMaskDensity,
  'geometricWaveMaskClusterScale': s.geometricWaveMaskClusterScale,
  'geometricWaveTwinkleSparsity': s.geometricWaveTwinkleSparsity,
  'geometricWaveShadowLightDegrees': s.geometricWaveShadowLightDegrees,
  'geometricWaveShadowOffset': s.geometricWaveShadowOffset,
  'geometricWaveShadowSoftness': s.geometricWaveShadowSoftness,
  'geometricWaveShadowStrength': s.geometricWaveShadowStrength,
  'geometricWavePopBrightnessVariance': s.geometricWavePopBrightnessVariance,
  'geometricWaveTiltAmount': s.geometricWaveTiltAmount,
  'geometricWaveTiltShading': s.geometricWaveTiltShading,
  'geometricWaveMassLagSeconds': s.geometricWaveMassLagSeconds,
  'geometricWaveMassSpring': s.geometricWaveMassSpring,
  'geometricWaveScatterMode': s.geometricWaveScatterMode,
  'geometricWaveScatterLitAmount': s.geometricWaveScatterLitAmount,
  'weatherChartTempColor': s.weatherChartTempColor,
  'weatherChartRainColor': s.weatherChartRainColor,
  'weatherChartCurveTension': s.weatherChartCurveTension,
  'colorPalette': s.colorPalette,
  'navPageOrder': s.navPageOrder,
  'jobsHiddenColumns': s.jobsHiddenColumns,
  'jobsIncludeArchived': s.jobsIncludeArchived,
  'rankingsCollapsedQueueCategories': s.rankingsCollapsedQueueCategories,
  'jobProfileLinkedInUrl': s.jobProfileLinkedInUrl,
  'jobProfileGitHubUrl': s.jobProfileGitHubUrl,
  'jobProfilePortfolioUrl': s.jobProfilePortfolioUrl,
  'startupPageMode': s.startupPageMode.name,
  'customStartupPage': s.customStartupPage,
  'showAnnualizedSubscriptionCost': s.showAnnualizedSubscriptionCost,
  'showDreamStatistics': s.showDreamStatistics,
  'dreamNotesPinned': s.dreamNotesPinned,
  'leetcodeUsername': s.leetcodeUsername,
  'showNeetCode150': s.showNeetCode150,
  'leetCodeHideDifficulty': s.leetCodeHideDifficulty,
  'leetCodeHideTags': s.leetCodeHideTags,
  'leetCodeHideQuestionName': s.leetCodeHideQuestionName,
  'leetCodeHideDescription': s.leetCodeHideDescription,
  'leetCodeHideExamples': s.leetCodeHideExamples,
  'leetCodeHideComplexity': s.leetCodeHideComplexity,
  'leetCodeHideCode': s.leetCodeHideCode,
  'leetCodeEnableScratchCode': s.leetCodeEnableScratchCode,
  'weightUnit': s.weightUnit.name,
  'workoutRestTimerEnabled': s.workoutRestTimerEnabled,
  'workoutRestSeconds': s.workoutRestSeconds,
  'showWorkoutsOnCalendar': s.showWorkoutsOnCalendar,
  'showWorkoutStatistics': s.showWorkoutStatistics,
};

/// [settingsSyncPayload] plus the clock the merge compares. Written with
/// `SetOptions(merge: true)`, so the weather keys sharing this document are
/// left untouched.
Map<String, dynamic> settingsToFirestore(AppSettings settings) => {
  ...settingsSyncPayload(settings),
  'settingsUpdatedAt': _dateToFirestore(settings.updatedAt ?? utcNow()),
};

/// Applies a remote settings document to [local], whole-document
/// last-write-wins: the device that most recently changed a synced setting
/// wins for all of them at once.
///
/// Returns [local] unchanged when it is the newer of the two, so a pull that
/// finds nothing newer costs no write.
AppSettings mergeSettingsFromRemote(
  Map<String, dynamic> data,
  AppSettings local,
) {
  final remoteUpdated = parseFirestoreDate(data['settingsUpdatedAt']);
  // A document with no clock predates settings syncing (the weather service
  // has been writing this document all along) and has nothing to apply.
  if (remoteUpdated == null) return local;
  // Strictly newer, unlike the record merges: an equal clock means this is the
  // document *we* just wrote. Firestore echoes our own writes back through the
  // snapshot listener, and re-applying one would rewrite the settings row and
  // invalidate every provider in the app on every save.
  final localUpdated = local.updatedAt;
  if (localUpdated != null && !remoteUpdated.isAfter(localUpdated)) {
    return local;
  }

  return local.copyWith(
    accentColor: _remoteInt(data, 'accentColor'),
    themeMode: _enumFromName(
      AppThemeMode.values,
      data['themeMode'],
      local.themeMode,
    ),
    petalColor: _remoteInt(data, 'petalColor'),
    minorPetalColors: _remoteIntList(data, 'minorPetalColors'),
    petalMaxCount: _remoteInt(data, 'petalMaxCount'),
    petalFallSpeed: _remoteDouble(data, 'petalFallSpeed'),
    petalWindFrequency: _remoteDouble(data, 'petalWindFrequency'),
    petalWindStrength: _remoteDouble(data, 'petalWindStrength'),
    weekStartsOnMonday: data['weekStartsOnMonday'] as bool?,
    showQuotes: data['showQuotes'] as bool?,
    customQuotesOnly: data['customQuotesOnly'] as bool?,
    showDefaultTrackersInGrid: data['showDefaultTrackersInGrid'] as bool?,
    showDefaultTrackersInCalendar:
        data['showDefaultTrackersInCalendar'] as bool?,
    journalHotkey: data['journalHotkey'] as String?,
    todoHotkey: data['todoHotkey'] as String?,
    financeHotkey: data['financeHotkey'] as String?,
    reminderHotkey: data['reminderHotkey'] as String?,
    calendarNavigateLeftKey: data['calendarNavigateLeftKey'] as String?,
    calendarNavigateRightKey: data['calendarNavigateRightKey'] as String?,
    srsFailKey: data['srsFailKey'] as String?,
    srsHardKey: data['srsHardKey'] as String?,
    srsGoodKey: data['srsGoodKey'] as String?,
    srsEasyKey: data['srsEasyKey'] as String?,
    timelineModeYearZero: data['timelineModeYearZero'] as bool?,
    birthYear: _remoteInt(data, 'birthYear'),
    clearBirthYear: _remoteClears(data, 'birthYear'),
    birthDate: parseFirestoreDate(data['birthDate']),
    clearBirthDate: _remoteClears(data, 'birthDate'),
    alertOnPeriodicPrompts: data['alertOnPeriodicPrompts'] as bool?,
    alertTimeHour: _remoteInt(data, 'alertTimeHour'),
    hideCompletedTasks: data['hideCompletedTasks'] as bool?,
    vimModeEnabled: data['vimModeEnabled'] as bool?,
    snippetsEnabled: data['snippetsEnabled'] as bool?,
    autocorrectEnabled: data['autocorrectEnabled'] as bool?,
    capsLockIndicatorEnabled: data['capsLockIndicatorEnabled'] as bool?,
    mediaRemoteUploadsEnabled: data['mediaRemoteUploadsEnabled'] as bool?,
    mediaRemoteDownloadsEnabled: data['mediaRemoteDownloadsEnabled'] as bool?,
    mediaBackgroundPrefetchEnabled:
        data['mediaBackgroundPrefetchEnabled'] as bool?,
    snippetExpandKey: _enumFromName(
      SnippetExpandKey.values,
      data['snippetExpandKey'],
      local.snippetExpandKey,
    ),
    defaultJournalId: data['defaultJournalId'] as String?,
    clearDefaultJournalId: _remoteClears(data, 'defaultJournalId'),
    defaultTodoListId: data['defaultTodoListId'] as String?,
    clearDefaultTodoListId: _remoteClears(data, 'defaultTodoListId'),
    geometricTextureScale: _remoteDouble(data, 'geometricTextureScale'),
    geometricTextureIntensity: _remoteDouble(data, 'geometricTextureIntensity'),
    geometricTextureFocalSpread: _remoteDouble(
      data,
      'geometricTextureFocalSpread',
    ),
    geometricTextureFocalPointX: _remoteDouble(
      data,
      'geometricTextureFocalPointX',
    ),
    geometricTextureFocalPointY: _remoteDouble(
      data,
      'geometricTextureFocalPointY',
    ),
    geometricTextureVariationFloor: _remoteDouble(
      data,
      'geometricTextureVariationFloor',
    ),
    geometricWaveEnabled: data['geometricWaveEnabled'] as bool?,
    geometricWaveShape: _enumFromName(
      GeometricWaveShape.values,
      data['geometricWaveShape'],
      local.geometricWaveShape,
    ),
    geometricWaveDirectionDegrees: _remoteDouble(
      data,
      'geometricWaveDirectionDegrees',
    ),
    geometricWaveSpeed: _remoteDouble(data, 'geometricWaveSpeed'),
    geometricWaveWidth: _remoteDouble(data, 'geometricWaveWidth'),
    geometricWavePeriod: _remoteDouble(data, 'geometricWavePeriod'),
    geometricWavePopHoldSeconds: _remoteDouble(
      data,
      'geometricWavePopHoldSeconds',
    ),
    geometricWavePopScale: _remoteDouble(data, 'geometricWavePopScale'),
    geometricWavePopBrightness: _remoteDouble(
      data,
      'geometricWavePopBrightness',
    ),
    geometricWaveMaskDensity: _remoteDouble(data, 'geometricWaveMaskDensity'),
    geometricWaveMaskClusterScale: _remoteDouble(
      data,
      'geometricWaveMaskClusterScale',
    ),
    geometricWaveTwinkleSparsity: _remoteDouble(
      data,
      'geometricWaveTwinkleSparsity',
    ),
    geometricWaveShadowLightDegrees: _remoteDouble(
      data,
      'geometricWaveShadowLightDegrees',
    ),
    geometricWaveShadowOffset: _remoteDouble(data, 'geometricWaveShadowOffset'),
    geometricWaveShadowSoftness: _remoteDouble(
      data,
      'geometricWaveShadowSoftness',
    ),
    geometricWaveShadowStrength: _remoteDouble(
      data,
      'geometricWaveShadowStrength',
    ),
    geometricWavePopBrightnessVariance: _remoteDouble(
      data,
      'geometricWavePopBrightnessVariance',
    ),
    geometricWaveTiltAmount: _remoteDouble(data, 'geometricWaveTiltAmount'),
    geometricWaveTiltShading: _remoteDouble(data, 'geometricWaveTiltShading'),
    geometricWaveMassLagSeconds: _remoteDouble(
      data,
      'geometricWaveMassLagSeconds',
    ),
    geometricWaveMassSpring: _remoteDouble(data, 'geometricWaveMassSpring'),
    geometricWaveScatterMode: data['geometricWaveScatterMode'] as bool?,
    geometricWaveScatterLitAmount: _remoteDouble(
      data,
      'geometricWaveScatterLitAmount',
    ),
    weatherChartTempColor: _remoteInt(data, 'weatherChartTempColor'),
    clearWeatherChartTempColor: _remoteClears(data, 'weatherChartTempColor'),
    weatherChartRainColor: _remoteInt(data, 'weatherChartRainColor'),
    clearWeatherChartRainColor: _remoteClears(data, 'weatherChartRainColor'),
    weatherChartCurveTension: _remoteDouble(data, 'weatherChartCurveTension'),
    colorPalette: _remoteIntList(data, 'colorPalette'),
    navPageOrder: _stringListOrNull(data['navPageOrder']),
    clearNavPageOrder: _remoteClears(data, 'navPageOrder'),
    jobsHiddenColumns: _stringListOrNull(data['jobsHiddenColumns']),
    jobsIncludeArchived: data['jobsIncludeArchived'] as bool?,
    rankingsCollapsedQueueCategories: _stringListOrNull(
      data['rankingsCollapsedQueueCategories'],
    ),
    startupPageMode: _enumFromName(
      StartupPageMode.values,
      data['startupPageMode'],
      local.startupPageMode,
    ),
    customStartupPage: data['customStartupPage'] as String?,
    clearCustomStartupPage: _remoteClears(data, 'customStartupPage'),
    showAnnualizedSubscriptionCost:
        data['showAnnualizedSubscriptionCost'] as bool?,
    showDreamStatistics: data['showDreamStatistics'] as bool?,
    dreamNotesPinned: data['dreamNotesPinned'] as bool?,
    jobProfileLinkedInUrl: data['jobProfileLinkedInUrl'] as String?,
    clearJobProfileLinkedInUrl: _remoteClears(data, 'jobProfileLinkedInUrl'),
    jobProfileGitHubUrl: data['jobProfileGitHubUrl'] as String?,
    clearJobProfileGitHubUrl: _remoteClears(data, 'jobProfileGitHubUrl'),
    jobProfilePortfolioUrl: data['jobProfilePortfolioUrl'] as String?,
    clearJobProfilePortfolioUrl: _remoteClears(data, 'jobProfilePortfolioUrl'),
    leetcodeUsername: data['leetcodeUsername'] as String?,
    clearLeetcodeUsername: _remoteClears(data, 'leetcodeUsername'),
    showNeetCode150: data['showNeetCode150'] as bool?,
    leetCodeHideDifficulty: data['leetCodeHideDifficulty'] as bool?,
    leetCodeHideTags: data['leetCodeHideTags'] as bool?,
    leetCodeHideQuestionName: data['leetCodeHideQuestionName'] as bool?,
    leetCodeHideDescription: data['leetCodeHideDescription'] as bool?,
    leetCodeHideExamples: data['leetCodeHideExamples'] as bool?,
    leetCodeHideComplexity: data['leetCodeHideComplexity'] as bool?,
    leetCodeHideCode: data['leetCodeHideCode'] as bool?,
    leetCodeEnableScratchCode: data['leetCodeEnableScratchCode'] as bool?,
    weightUnit: _enumFromName(
      WeightUnit.values,
      data['weightUnit'],
      local.weightUnit,
    ),
    workoutRestTimerEnabled: data['workoutRestTimerEnabled'] as bool?,
    workoutRestSeconds: _remoteInt(data, 'workoutRestSeconds'),
    showWorkoutsOnCalendar: data['showWorkoutsOnCalendar'] as bool?,
    showWorkoutStatistics: data['showWorkoutStatistics'] as bool?,
    updatedAt: remoteUpdated,
  );
}

List<String>? _stringListOrNull(Object? value) {
  if (value is! List) return null;
  return [
    for (final item in value)
      if (item is String) item,
  ];
}

/// Templates and field values travel as native Firestore arrays and maps
/// rather than as the JSON strings the local columns hold: the payload is what
/// a backup file stores too, and a nested map survives a mapper gaining a
/// field where an opaque string would not.
Map<String, dynamic> rankingCategoryToFirestore(RankingCategory category) => {
  'id': category.id,
  'name': category.name,
  'colorValue': category.colorValue,
  'iconKey': category.iconKey,
  'sortOrder': category.sortOrder,
  'childUnitsEnabled': category.childUnitsEnabled,
  'childUnitLabel': category.childUnitLabel,
  'imagesOnParent': category.imagesOnParent,
  'imagesOnChild': category.imagesOnChild,
  'parentScoreMax': category.parentScoreMax,
  'childScoreMax': category.childScoreMax,
  'parentScorePrecision': category.parentScorePrecision.name,
  'childScorePrecision': category.childScorePrecision.name,
  // Written alongside the enums, not instead of them: a device still on the
  // build before precision existed reads only these, and without them it
  // would push its own stale half-step setting back over a tenths category.
  'parentHalfStepsEnabled': category.parentScorePrecision.halfStepsEquivalent,
  'childHalfStepsEnabled': category.childScorePrecision.halfStepsEquivalent,
  'parentTemplate': [for (final f in category.parentTemplate) f.toJson()],
  'childTemplate': [for (final f in category.childTemplate) f.toJson()],
  'sortMode': category.sortMode.name,
  'sortFieldId': category.sortFieldId,
  'sortAscending': category.sortAscending,
  'archivedAt': _dateToFirestore(category.archivedAt),
  'createdAt': _dateToFirestoreRequired(category.createdAt),
  'updatedAt': _dateToFirestoreRequired(category.updatedAt),
  'version': category.version,
  'deletedAt': _dateToFirestore(category.deletedAt),
};

/// The precision a remote category is on, preferring the enum and falling
/// back to the half-step boolean a payload written before it carries.
RankingScorePrecision _precisionFromRemote(
  dynamic precision,
  dynamic legacyHalfSteps,
  RankingScorePrecision? local,
) {
  if (precision is String) return RankingScorePrecision.fromName(precision);
  if (legacyHalfSteps is bool) {
    return RankingScorePrecision.fromHalfSteps(legacyHalfSteps);
  }
  return local ?? RankingScorePrecision.half;
}

List<RankingTemplateField> _templateFromRemote(
  dynamic value,
  List<RankingTemplateField> fallback,
) {
  if (value is! List) return fallback;
  final fields = [
    for (final entry in value)
      if (entry is Map)
        RankingTemplateField.fromJson(Map<String, dynamic>.from(entry)),
  ];
  fields.sort((a, b) => a.sortOrder.compareTo(b.sortOrder));
  return fields;
}

RankingCategory mergeRankingCategoryFromRemote(
  Map<String, dynamic> data,
  String id, {
  RankingCategory? local,
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

  return RankingCategory(
    id: id,
    name: data['name'] as String? ?? local?.name ?? '',
    colorValue:
        (data['colorValue'] as num?)?.toInt() ??
        local?.colorValue ??
        defaultColorPalette.first,
    iconKey: data['iconKey'] as String? ?? local?.iconKey ?? 'star',
    sortOrder: (data['sortOrder'] as num?)?.toInt() ?? local?.sortOrder ?? 0,
    childUnitsEnabled:
        data['childUnitsEnabled'] as bool? ?? local?.childUnitsEnabled ?? false,
    childUnitLabel:
        data['childUnitLabel'] as String? ?? local?.childUnitLabel ?? 'Episode',
    imagesOnParent:
        data['imagesOnParent'] as bool? ?? local?.imagesOnParent ?? true,
    imagesOnChild:
        data['imagesOnChild'] as bool? ?? local?.imagesOnChild ?? false,
    parentScoreMax:
        (data['parentScoreMax'] as num?)?.toInt() ?? local?.parentScoreMax ?? 5,
    childScoreMax:
        (data['childScoreMax'] as num?)?.toInt() ?? local?.childScoreMax ?? 5,
    parentScorePrecision: _precisionFromRemote(
      data['parentScorePrecision'],
      data['parentHalfStepsEnabled'],
      local?.parentScorePrecision,
    ),
    childScorePrecision: _precisionFromRemote(
      data['childScorePrecision'],
      data['childHalfStepsEnabled'],
      local?.childScorePrecision,
    ),
    parentTemplate: _templateFromRemote(
      data['parentTemplate'],
      local?.parentTemplate ?? const [],
    ),
    childTemplate: _templateFromRemote(
      data['childTemplate'],
      local?.childTemplate ?? const [],
    ),
    sortMode: RankingSortMode.fromName(
      data['sortMode'] as String? ?? local?.sortMode.name,
    ),
    // Presence, not nullness: a remote that predates the field keeps whatever
    // sort this device had, while one that cleared it must clear it here too.
    sortFieldId: data.containsKey('sortFieldId')
        ? data['sortFieldId'] as String?
        : local?.sortFieldId,
    sortAscending:
        data['sortAscending'] as bool? ?? local?.sortAscending ?? false,
    archivedAt: data.containsKey('archivedAt')
        ? parseFirestoreDate(data['archivedAt'])
        : local?.archivedAt,
    createdAt:
        parseFirestoreDate(data['createdAt']) ??
        local?.createdAt ??
        remoteUpdated,
    updatedAt: remoteUpdated,
    version: remoteVersion,
    deletedAt: mergeDeletedAtFromRemote(data, local?.deletedAt),
  );
}

/// Every value written whole, a cleared half as an explicit null, and every
/// field the row has ever stamped written even once it is empty.
///
/// Uploads merge into the stored document, and a merge keeps any nested key
/// the payload leaves out. A score cleared by leaving it out was never
/// cleared remotely, and the next device to read the document put it back.
Map<String, dynamic> _fieldValuesToFirestore(
  Map<String, RankingFieldValue> values,
  RankingFieldStamps stamps,
) {
  final ids = {...values.keys, ..._stampedFieldIds(stamps)};
  return {
    for (final id in ids)
      id: {'score': values[id]?.score, 'notes': values[id]?.notes ?? ''},
  };
}

Iterable<String> _stampedFieldIds(RankingFieldStamps stamps) sync* {
  for (final key in stamps.keys) {
    if (key.startsWith('fv:')) yield key.substring(3, key.lastIndexOf(':'));
  }
}

Map<String, RankingFieldValue> _fieldValuesFromRemote(
  dynamic value,
  Map<String, RankingFieldValue> fallback,
) {
  if (value is! Map) return fallback;
  final values = <String, RankingFieldValue>{};
  for (final entry in value.entries) {
    if (entry.value is! Map) continue;
    final parsed = RankingFieldValue.fromJson(
      Map<String, dynamic>.from(entry.value as Map),
    );
    // Written as nulls so a merge clears them remotely; not a value here.
    if (!parsed.isEmpty) values[entry.key as String] = parsed;
  }
  return values;
}

Map<String, String> _fieldStampsToFirestore(RankingFieldStamps stamps) => {
  for (final entry in stamps.entries)
    entry.key: _dateToFirestoreRequired(entry.value),
};

/// The remote's field stamps, or null when it has none this device can trust.
///
/// A build that predates stamps writes none. It can also write over a document
/// a newer build stamped, and because uploads merge, the old stamps survive
/// that write while describing an earlier version. `fieldStampsVersion` is
/// the version the stamps were written with, so a mismatch gives that case
/// away.
RankingFieldStamps? _fieldStampsFromRemote(Map<String, dynamic> data) {
  if (data['fieldUpdatedAt'] is! Map) return null;
  final stampedVersion = (data['fieldStampsVersion'] as num?)?.toInt();
  if (stampedVersion != parseVersion(data)) return null;
  return decodeRankingFieldStamps(data['fieldUpdatedAt']);
}

/// What merging a remote entry or unit into the local one produced.
///
/// [localWon] is true when the local row held a newer value for some field
/// than the remote document did. That device is then the only one holding
/// the merged row, so the caller has to upload it or the other devices never
/// see it.
typedef RankingMergeResult<T> = ({T merged, bool localWon});

/// Picks each field from whichever side changed it last, and keeps the stamps
/// to match. An equal stamp goes to the remote, the same tie-break
/// `remoteVersionWins` makes, so two devices that merged the same pair agree.
class _RankingFieldPicker {
  _RankingFieldPicker({
    required this.localStamps,
    required this.localUpdated,
    required this.localValues,
    required this.remoteStamps,
    required this.remoteUpdated,
    required this.remoteValues,
  });

  final RankingFieldStamps localStamps;
  final DateTime localUpdated;
  final Map<String, Object?> localValues;
  final RankingFieldStamps remoteStamps;
  final DateTime remoteUpdated;
  final Map<String, Object?> remoteValues;

  final stamps = <String, DateTime>{};
  var localWon = false;

  T call<T>(String key, T local, T remote) {
    final l = localStamps[key] ?? localUpdated;
    final r = remoteStamps[key] ?? remoteUpdated;
    if (!r.isBefore(l)) {
      stamps[key] = r.toUtc();
      return remote;
    }
    stamps[key] = l.toUtc();
    if (localValues[key] != remoteValues[key]) localWon = true;
    return local;
  }

  Map<String, RankingFieldValue> fieldValues(
    Map<String, RankingFieldValue> local,
    Map<String, RankingFieldValue> remote,
  ) {
    final ids = {
      ...local.keys,
      ...remote.keys,
      ..._stampedFieldIds(localStamps),
      ..._stampedFieldIds(remoteStamps),
    };
    final result = <String, RankingFieldValue>{};
    for (final id in ids) {
      final value = RankingFieldValue(
        score: call(
          rankingFieldValueScoreKey(id),
          local[id]?.score,
          remote[id]?.score,
        ),
        notes: call(
          rankingFieldValueNotesKey(id),
          local[id]?.notes ?? '',
          remote[id]?.notes ?? '',
        ),
      );
      if (!value.isEmpty) result[id] = value;
    }
    return result;
  }

  DateTime get updatedAt =>
      remoteUpdated.isBefore(localUpdated) ? localUpdated : remoteUpdated;

  int version(int local, int remote) {
    final newest = local > remote ? local : remote;
    // A merged row that differs from the remote one is a new revision, and has
    // to outrank it for a device still comparing whole documents.
    return localWon ? newest + 1 : newest;
  }
}

Map<String, dynamic> rankingParentToFirestore(RankingParent parent) => {
  'id': parent.id,
  'categoryId': parent.categoryId,
  'title': parent.title,
  'overallScore': parent.overallScore,
  'notes': parent.notes,
  'fieldValues': _fieldValuesToFirestore(
    parent.fieldValues,
    parent.fieldUpdatedAt,
  ),
  'tags': parent.tags,
  'status': parent.status.name,
  'starred': parent.starred,
  'queueSortOrder': parent.queueSortOrder,
  'fieldUpdatedAt': _fieldStampsToFirestore(parent.fieldUpdatedAt),
  'fieldStampsVersion': parent.version,
  'createdAt': _dateToFirestoreRequired(parent.createdAt),
  'updatedAt': _dateToFirestoreRequired(parent.updatedAt),
  'version': parent.version,
  'deletedAt': _dateToFirestore(parent.deletedAt),
};

RankingParent mergeRankingParentFromRemote(
  Map<String, dynamic> data,
  String id, {
  RankingParent? local,
}) => resolveRankingParentFromRemote(data, id, local: local).merged;

/// Merges a remote entry into [local] field by field when both sides carry
/// stamps, and falls back to whole-document version-wins when the remote has
/// none it can vouch for (see [_fieldStampsFromRemote]).
///
/// Whole-document merging took every field from whichever side had the higher
/// version. A note typed offline on one device and a score set on another
/// could not both survive, and the one that lost had no say in it.
RankingMergeResult<RankingParent> resolveRankingParentFromRemote(
  Map<String, dynamic> data,
  String id, {
  RankingParent? local,
}) {
  final remoteUpdated = parseFirestoreDate(data['updatedAt']) ?? utcNow();
  final remoteVersion = parseVersion(data);
  final remoteStamps = _fieldStampsFromRemote(data);
  if (local != null &&
      remoteStamps == null &&
      !remoteVersionWins(
        remoteVersion: remoteVersion,
        localVersion: local.version,
        remoteUpdated: remoteUpdated,
        localUpdated: local.updatedAt,
      )) {
    return (merged: local, localWon: false);
  }

  final remote = RankingParent(
    id: id,
    categoryId: data['categoryId'] as String? ?? local?.categoryId ?? '',
    title: data['title'] as String? ?? local?.title ?? '',
    // Presence again: clearing an overall score is how a ranked entry is
    // demoted, and treating that null as "no news" would keep it ranked here.
    overallScore: data.containsKey('overallScore')
        ? (data['overallScore'] as num?)?.toDouble()
        : local?.overallScore,
    notes: data['notes'] as String? ?? local?.notes ?? '',
    fieldValues: _fieldValuesFromRemote(
      data['fieldValues'],
      local?.fieldValues ?? const {},
    ),
    // Normalized on the way in as well as on the way out: a payload written by
    // a build that predates the cap or the lowercasing is still a payload this
    // one has to be able to hold.
    tags: normalizeRankingTags(
      _stringListFromRemote(data['tags'], local?.tags ?? const []),
    ),
    status: RankingStatus.fromName(
      data['status'] as String? ?? local?.status.name,
    ),
    starred: data['starred'] as bool? ?? local?.starred ?? false,
    queueSortOrder:
        (data['queueSortOrder'] as num?)?.toInt() ?? local?.queueSortOrder ?? 0,
    createdAt:
        parseFirestoreDate(data['createdAt']) ??
        local?.createdAt ??
        remoteUpdated,
    updatedAt: remoteUpdated,
    version: remoteVersion,
    deletedAt: mergeDeletedAtFromRemote(data, local?.deletedAt),
    fieldUpdatedAt: remoteStamps ?? const {},
  );
  if (local == null || remoteStamps == null) {
    return (merged: remote, localWon: false);
  }

  final pick = _RankingFieldPicker(
    localStamps: local.fieldUpdatedAt,
    localUpdated: local.updatedAt,
    localValues: rankingParentStampValues(local),
    remoteStamps: remote.fieldUpdatedAt,
    remoteUpdated: remote.updatedAt,
    remoteValues: rankingParentStampValues(remote),
  );
  final merged = RankingParent(
    id: id,
    categoryId: remote.categoryId,
    title: pick('title', local.title, remote.title),
    overallScore: pick('overallScore', local.overallScore, remote.overallScore),
    notes: pick('notes', local.notes, remote.notes),
    fieldValues: pick.fieldValues(local.fieldValues, remote.fieldValues),
    tags: pick('tags', local.tags, remote.tags),
    status: pick('status', local.status, remote.status),
    starred: pick('starred', local.starred, remote.starred),
    queueSortOrder: pick(
      'queueSortOrder',
      local.queueSortOrder,
      remote.queueSortOrder,
    ),
    createdAt: pick('createdAt', local.createdAt, remote.createdAt),
    deletedAt: pick('deletedAt', local.deletedAt, remote.deletedAt),
    updatedAt: pick.updatedAt,
    version: pick.version(local.version, remote.version),
    fieldUpdatedAt: pick.stamps,
  );
  return (merged: merged, localWon: pick.localWon);
}

Map<String, dynamic> rankingChildToFirestore(RankingChild child) => {
  'id': child.id,
  'parentId': child.parentId,
  'name': child.name,
  'overallScore': child.overallScore,
  'notes': child.notes,
  'fieldValues': _fieldValuesToFirestore(
    child.fieldValues,
    child.fieldUpdatedAt,
  ),
  'sortOrder': child.sortOrder,
  'fieldUpdatedAt': _fieldStampsToFirestore(child.fieldUpdatedAt),
  'fieldStampsVersion': child.version,
  'createdAt': _dateToFirestoreRequired(child.createdAt),
  'updatedAt': _dateToFirestoreRequired(child.updatedAt),
  'version': child.version,
  'deletedAt': _dateToFirestore(child.deletedAt),
};

RankingChild mergeRankingChildFromRemote(
  Map<String, dynamic> data,
  String id, {
  RankingChild? local,
}) => resolveRankingChildFromRemote(data, id, local: local).merged;

/// [resolveRankingParentFromRemote] for a unit.
RankingMergeResult<RankingChild> resolveRankingChildFromRemote(
  Map<String, dynamic> data,
  String id, {
  RankingChild? local,
}) {
  final remoteUpdated = parseFirestoreDate(data['updatedAt']) ?? utcNow();
  final remoteVersion = parseVersion(data);
  final remoteStamps = _fieldStampsFromRemote(data);
  if (local != null &&
      remoteStamps == null &&
      !remoteVersionWins(
        remoteVersion: remoteVersion,
        localVersion: local.version,
        remoteUpdated: remoteUpdated,
        localUpdated: local.updatedAt,
      )) {
    return (merged: local, localWon: false);
  }

  final remote = RankingChild(
    id: id,
    parentId: data['parentId'] as String? ?? local?.parentId ?? '',
    name: data['name'] as String? ?? local?.name ?? '',
    overallScore: data.containsKey('overallScore')
        ? (data['overallScore'] as num?)?.toDouble()
        : local?.overallScore,
    notes: data['notes'] as String? ?? local?.notes ?? '',
    fieldValues: _fieldValuesFromRemote(
      data['fieldValues'],
      local?.fieldValues ?? const {},
    ),
    sortOrder: (data['sortOrder'] as num?)?.toInt() ?? local?.sortOrder ?? 0,
    createdAt:
        parseFirestoreDate(data['createdAt']) ??
        local?.createdAt ??
        remoteUpdated,
    updatedAt: remoteUpdated,
    version: remoteVersion,
    deletedAt: mergeDeletedAtFromRemote(data, local?.deletedAt),
    fieldUpdatedAt: remoteStamps ?? const {},
  );
  if (local == null || remoteStamps == null) {
    return (merged: remote, localWon: false);
  }

  final pick = _RankingFieldPicker(
    localStamps: local.fieldUpdatedAt,
    localUpdated: local.updatedAt,
    localValues: rankingChildStampValues(local),
    remoteStamps: remote.fieldUpdatedAt,
    remoteUpdated: remote.updatedAt,
    remoteValues: rankingChildStampValues(remote),
  );
  final merged = RankingChild(
    id: id,
    parentId: remote.parentId,
    name: pick('name', local.name, remote.name),
    overallScore: pick('overallScore', local.overallScore, remote.overallScore),
    notes: pick('notes', local.notes, remote.notes),
    fieldValues: pick.fieldValues(local.fieldValues, remote.fieldValues),
    sortOrder: pick('sortOrder', local.sortOrder, remote.sortOrder),
    createdAt: pick('createdAt', local.createdAt, remote.createdAt),
    deletedAt: pick('deletedAt', local.deletedAt, remote.deletedAt),
    updatedAt: pick.updatedAt,
    version: pick.version(local.version, remote.version),
    fieldUpdatedAt: pick.stamps,
  );
  return (merged: merged, localWon: pick.localWon);
}

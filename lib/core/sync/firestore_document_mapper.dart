import 'dart:convert';

import 'package:voyager/core/constants/calendar_constants.dart';
import 'package:voyager/core/constants/journal_constants.dart';
import 'package:voyager/core/constants/todo_constants.dart';
import 'package:voyager/core/sync/firestore_collections.dart';
import 'package:voyager/core/utils/ids.dart';
import 'package:voyager/domain/models/analytics_models.dart';
import 'package:voyager/domain/models/calendar_models.dart';
import 'package:voyager/domain/services/calendar_recurrence.dart';
import 'package:voyager/domain/models/dream_models.dart';
import 'package:voyager/domain/models/enums.dart';
import 'package:voyager/domain/models/finance_models.dart';
import 'package:voyager/domain/models/job_models.dart';
import 'package:voyager/domain/models/journal_models.dart';
import 'package:voyager/domain/models/leetcode_models.dart';
import 'package:voyager/domain/models/life_tracker_models.dart';
import 'package:voyager/domain/models/notification_models.dart';
import 'package:voyager/domain/models/settings_models.dart';
import 'package:voyager/domain/models/study_models.dart';
import 'package:voyager/domain/models/workout_models.dart';
import 'package:voyager/domain/models/todo_models.dart';

/// Collections whose document id is user text — a tag, a dictionary word, a
/// dismissal key — and so has to be encoded to be legal as a Firestore id.
const encodedIdCollections = {
  FirestoreCollections.tagColors,
  FirestoreCollections.customWords,
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
String _dateToFirestoreRequired(DateTime value) => value.toUtc().toIso8601String();

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
    guidedJournaling: data['guidedJournaling'] as bool? ??
        local?.guidedJournaling ??
        false,
    promptCycleDays: (data['promptCycleDays'] as num?)?.toInt() ??
        local?.promptCycleDays ??
        7,
    showMood: data['showMood'] as bool? ?? local?.showMood ?? true,
    showWeather: data['showWeather'] as bool? ?? local?.showWeather ?? true,
    showQuotes: data['showQuotes'] as bool? ?? local?.showQuotes ?? true,
    includeInAllView:
        data['includeInAllView'] as bool? ?? local?.includeInAllView ?? true,
    createdAt: parseFirestoreDate(data['createdAt']) ??
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
    solvedAt: parseFirestoreDate(data['solvedAt']) ??
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
    createdAt: parseFirestoreDate(data['createdAt']) ??
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
    createdAt: parseFirestoreDate(data['createdAt']) ??
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
    createdAt: parseFirestoreDate(data['createdAt']) ??
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
    reviewCount: (data['reviewCount'] as num?)?.toInt() ?? local?.reviewCount ?? 0,
    createdAt: parseFirestoreDate(data['createdAt']) ??
        local?.createdAt ??
        remoteUpdated,
    updatedAt: remoteUpdated,
    version: remoteVersion,
    deletedAt: mergeDeletedAtFromRemote(data, local?.deletedAt),
  );
}

Map<String, dynamic> studyReviewLogToFirestore(StudyReviewLog log) => {
  'id': log.id,
  'cardId': log.cardId,
  'grade': log.grade.name,
  'reviewedAt': _dateToFirestoreRequired(log.reviewedAt),
};

StudyReviewLog mergeStudyReviewLogFromRemote(
  Map<String, dynamic> data,
  String id,
) {
  return StudyReviewLog(
    id: id,
    cardId: data['cardId'] as String? ?? '',
    grade: StudyGrade.values.byName(data['grade'] as String? ?? 'good'),
    reviewedAt: parseFirestoreDate(data['reviewedAt']) ?? utcNow(),
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
  'dateApplied': _dateToFirestoreRequired(application.dateApplied),
  'applicationUrl': application.applicationUrl,
  'notes': application.notes,
  'seasonId': application.seasonId,
  'createdAt': _dateToFirestoreRequired(application.createdAt),
  'updatedAt': _dateToFirestoreRequired(application.updatedAt),
  'version': application.version,
  'deletedAt': _dateToFirestore(application.deletedAt),
};

JobApplication mergeJobApplicationFromRemote(
  Map<String, dynamic> data,
  String id, {
  JobApplication? local,
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

  // `seasonId` and the two optional text fields fall back to null rather than
  // to the local value: un-archiving and clearing a URL are both expressed as
  // the field going away, and inheriting the local value would make either
  // change impossible to sync.
  return JobApplication(
    id: id,
    company: data['company'] as String? ?? local?.company ?? '',
    title: data['title'] as String? ?? local?.title ?? '',
    status: data['status'] as String? ?? local?.status ?? '',
    dateApplied:
        parseFirestoreDate(data['dateApplied']) ??
        local?.dateApplied ??
        remoteUpdated,
    applicationUrl: data['applicationUrl'] as String?,
    notes: data['notes'] as String?,
    seasonId: data['seasonId'] as String?,
    createdAt:
        parseFirestoreDate(data['createdAt']) ??
        local?.createdAt ??
        remoteUpdated,
    updatedAt: remoteUpdated,
    version: remoteVersion,
    deletedAt: mergeDeletedAtFromRemote(data, local?.deletedAt),
  );
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
    colorValue:
        (data['colorValue'] as num?)?.toInt() ?? local?.colorValue ?? 0,
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
      metadataRemoteWins
          ? (data['journalId'] as String? ?? local?.journalId ?? legacyJournalId)
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
    createdAt: parseFirestoreDate(data['createdAt']) ??
        local?.createdAt ??
        remoteUpdated,
    updatedAt: resolvedUpdated,
    version: resolvedVersion,
    deletedAt: mergeDeletedAtFromRemote(data, local?.deletedAt, remoteWins: metadataRemoteWins),
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
  final metadataRemoteWins = local == null ||
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
    createdAt: parseFirestoreDate(data['createdAt']) ??
        local?.createdAt ??
        remoteUpdated,
    updatedAt: resolvedUpdated,
    version: resolvedVersion,
    deletedAt: mergeDeletedAtFromRemote(data, local?.deletedAt, remoteWins: metadataRemoteWins),
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
  'id': calendar.id,
  'name': calendar.name,
  'colorValue': calendar.colorValue,
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
  'calendarId': event.calendarId,
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
    calendarId:
        data['calendarId'] as String? ?? local?.calendarId ?? legacyCalendarId,
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
    intValue: (data['intValue'] as num?)?.toInt(),
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
  'note': tx.note,
  'tags': tx.tags,
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
    note: data['note'] as String?,
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

Map<String, dynamic> subscriptionToFirestore(Subscription subscription) => {
  'id': subscription.id,
  'name': subscription.name,
  'amountCents': subscription.amountCents,
  'period': subscription.period.name,
  'anchorDueDate': _dateToFirestoreRequired(subscription.anchorDueDate),
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
///  - `journalEntryListWidth` and `dreamSplitWidth`, which are sized for the
///    screen they were dragged on.
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
  'showDefaultTrackersInGrid': s.showDefaultTrackersInGrid,
  'showDefaultTrackersInCalendar': s.showDefaultTrackersInCalendar,
  'journalHotkey': s.journalHotkey,
  'todoHotkey': s.todoHotkey,
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
  'snippetExpandKey': s.snippetExpandKey.name,
  'snippets': [for (final snippet in s.snippets) snippet.toJson()],
  'lastViewedJournalId': s.lastViewedJournalId,
  'lastViewedTodoListId': s.lastViewedTodoListId,
  'defaultJournalId': s.defaultJournalId,
  'defaultTodoListId': s.defaultTodoListId,
  'journalShowAllEntries': s.journalShowAllEntries,
  'todoShowAllTasks': s.todoShowAllTasks,
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
  'startupPageMode': s.startupPageMode.name,
  'customStartupPage': s.customStartupPage,
  'lastSeenNavPage': s.lastSeenNavPage,
  'todoCompletedSectionExpanded': s.todoCompletedSectionExpanded,
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
    showDefaultTrackersInGrid: data['showDefaultTrackersInGrid'] as bool?,
    showDefaultTrackersInCalendar:
        data['showDefaultTrackersInCalendar'] as bool?,
    journalHotkey: data['journalHotkey'] as String?,
    todoHotkey: data['todoHotkey'] as String?,
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
    snippetExpandKey: _enumFromName(
      SnippetExpandKey.values,
      data['snippetExpandKey'],
      local.snippetExpandKey,
    ),
    // Absent means "this document predates snippets", which must leave the
    // local list alone; present-but-empty is a real "the user deleted them
    // all" and has to come through as an empty list, not as unspecified.
    snippets: data.containsKey('snippets')
        ? Snippet.listFromJson(data['snippets'])
        : null,
    lastViewedJournalId: data['lastViewedJournalId'] as String?,
    clearLastViewedJournalId: _remoteClears(data, 'lastViewedJournalId'),
    lastViewedTodoListId: data['lastViewedTodoListId'] as String?,
    clearLastViewedTodoListId: _remoteClears(data, 'lastViewedTodoListId'),
    defaultJournalId: data['defaultJournalId'] as String?,
    clearDefaultJournalId: _remoteClears(data, 'defaultJournalId'),
    defaultTodoListId: data['defaultTodoListId'] as String?,
    clearDefaultTodoListId: _remoteClears(data, 'defaultTodoListId'),
    journalShowAllEntries: data['journalShowAllEntries'] as bool?,
    todoShowAllTasks: data['todoShowAllTasks'] as bool?,
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
    startupPageMode: _enumFromName(
      StartupPageMode.values,
      data['startupPageMode'],
      local.startupPageMode,
    ),
    customStartupPage: data['customStartupPage'] as String?,
    clearCustomStartupPage: _remoteClears(data, 'customStartupPage'),
    lastSeenNavPage: data['lastSeenNavPage'] as String?,
    clearLastSeenNavPage: _remoteClears(data, 'lastSeenNavPage'),
    todoCompletedSectionExpanded: data['todoCompletedSectionExpanded'] as bool?,
    showAnnualizedSubscriptionCost:
        data['showAnnualizedSubscriptionCost'] as bool?,
    showDreamStatistics: data['showDreamStatistics'] as bool?,
    dreamNotesPinned: data['dreamNotesPinned'] as bool?,
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

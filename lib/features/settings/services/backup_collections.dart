import 'package:collection/collection.dart';
import 'package:voyager/core/sync/firestore_collections.dart';
import 'package:voyager/core/sync/firestore_document_mapper.dart';
import 'package:voyager/core/utils/ids.dart';
import 'package:voyager/domain/models/calendar_models.dart';
import 'package:voyager/domain/repositories/repositories.dart';
import 'package:voyager/domain/services/study_deck_graph.dart';

/// One record in a backup file: the **local** document id plus the document
/// payload in exactly the shape the sync layer writes to Firestore.
///
/// Reusing the Firestore payload rather than inventing a backup format means
/// every collection already has a serializer (`xToFirestore`) and a
/// deserializer (`mergeXFromRemote`), and both stay correct for free as
/// collections gain fields. The id is stored separately because two
/// collections (journals, todo lists) map a legacy local id to a different
/// Firestore id inside their payload — see [firestoreDocumentIdForLocal].
class BackupRecord {
  const BackupRecord({required this.id, required this.data});

  factory BackupRecord.fromJson(Map<String, dynamic> json) => BackupRecord(
    id: json['id'] as String,
    data: Map<String, dynamic>.from(json['data'] as Map),
  );

  final String id;
  final Map<String, dynamic> data;

  Map<String, dynamic> toJson() => {'id': id, 'data': data};
}

/// How one synced collection is read out of, and written back into, the local
/// database.
class BackupCollection {
  const BackupCollection({
    required this.name,
    required this.read,
    required this.restore,
    this.prepare,
    this.afterRestore,
  });

  /// The Firestore collection name, which is also the name of this
  /// collection's file inside the backup archive.
  final String name;

  /// Every local record, tombstones included.
  final Future<List<BackupRecord>> Function() read;

  /// Writes [data] to the local database under [id], and returns the model it
  /// wrote so the caller can hand it to the sync layer.
  final Future<Object> Function(String id, Map<String, dynamic> data) restore;

  /// Sees every record the backup holds for this collection before any of
  /// them is restored, for a [restore] that has to check one record against
  /// its siblings.
  final void Function(List<BackupRecord> records)? prepare;

  /// Runs once this collection's restored records are all written, inside
  /// the same transaction — for a rule that holds across the collection, not
  /// per record, and so has to see the backup and the local rows together.
  /// Returns any further models it wrote, so they upload with the rest.
  /// Skipped when nothing in the collection was restored.
  final Future<List<Object>> Function()? afterRestore;
}

/// Fields that say *when* a record was written rather than *what* it holds.
///
/// Excluded from [backupContentEquals] so that re-importing a backup of
/// records the database already holds is recognised as a no-op, even though
/// the local copy has since been bumped by an unrelated sync round trip.
const _metadataFields = {
  'version',
  'updatedAt',
  'settingsUpdatedAt',
  // Rankings' per-field merge stamps, and the version they were written at.
  'fieldUpdatedAt',
  'fieldStampsVersion',
};

/// Whether two payloads describe the same record content, ignoring sync
/// bookkeeping. `deletedAt` is content: a tombstone differs from a live row.
bool backupContentEquals(
  Map<String, dynamic> a,
  Map<String, dynamic> b,
) {
  Map<String, dynamic> content(Map<String, dynamic> payload) => {
    for (final entry in payload.entries)
      if (!_metadataFields.contains(entry.key)) entry.key: entry.value,
  };
  return const DeepCollectionEquality().equals(content(a), content(b));
}

/// Every synced collection, ordered so that restoring the list front to back
/// never writes a child before its container — journals before their entries,
/// study folders before decks before cards, workout plans before their entries.
///
/// Two collections are deliberately absent. [FirestoreCollections.settings] is
/// a single document rather than a collection of records and is handled on its
/// own; [FirestoreCollections.syncOperations] is the character-level CRDT
/// operation log, which is a transport detail of collaborative editing rather
/// than user data — the restored document snapshots carry the resolved text.
List<BackupCollection> buildBackupCollections({
  required JournalRepository journalRepository,
  required DreamRepository dreamRepository,
  required TodoRepository todoRepository,
  required LeetCodeRepository leetCodeRepository,
  required StudyRepository studyRepository,
  required WorkoutRepository workoutRepository,
  required CalendarRepository calendarRepository,
  required TrackerRepository trackerRepository,
  required FinanceRepository financeRepository,
  required NotificationRepository notificationRepository,
  required ReminderRepository reminderRepository,
  required BucketListRepository bucketListRepository,
  required SettingsRepository settingsRepository,
  required JobRepository jobRepository,
  required RankingRepository rankingRepository,
  required MediaRepository mediaRepository,
}) {
  // The live calendars in the backup being restored, so a restored calendar's
  // overlay list keeps only ids that point at one of them.
  var backupLiveCalendarIds = const <String>{};
  return [
    BackupCollection(
      name: FirestoreCollections.journals,
      read: () async => [
        for (final journal in await journalRepository.listJournals(
          includeDeleted: true,
        ))
          BackupRecord(id: journal.id, data: journalToFirestore(journal)),
      ],
      restore: (id, data) async {
        final journal = mergeJournalFromRemote(data, id);
        await journalRepository.upsertJournal(
          journal,
          recordLocalActivity: false,
        );
        return journal;
      },
    ),
    BackupCollection(
      name: FirestoreCollections.journalEntries,
      read: () async => [
        for (final entry in await journalRepository.getAllEntries(
          includeDeleted: true,
        ))
          BackupRecord(id: entry.id, data: journalEntryToFirestore(entry)),
      ],
      restore: (id, data) async {
        final entry = mergeJournalEntryFromRemote(data, id);
        await journalRepository.upsertEntry(entry, recordLocalActivity: false);
        return entry;
      },
    ),
    BackupCollection(
      name: FirestoreCollections.dreamEntries,
      read: () async => [
        for (final entry in await dreamRepository.getAllEntries(
          includeDeleted: true,
        ))
          BackupRecord(id: entry.id, data: dreamEntryToFirestore(entry)),
      ],
      restore: (id, data) async {
        final entry = mergeDreamEntryFromRemote(data, id);
        await dreamRepository.upsertEntry(entry, recordLocalActivity: false);
        return entry;
      },
    ),
    BackupCollection(
      name: FirestoreCollections.todoLists,
      read: () async => [
        for (final list in await todoRepository.listLists(includeDeleted: true))
          BackupRecord(id: list.id, data: todoListToFirestore(list)),
      ],
      restore: (id, data) async {
        final list = mergeTodoListFromRemote(data, id);
        await todoRepository.upsertList(list, recordLocalActivity: false);
        return list;
      },
    ),
    BackupCollection(
      name: FirestoreCollections.todoTasks,
      read: () async => [
        for (final task in await todoRepository.getAllTasks(
          includeDeleted: true,
        ))
          BackupRecord(id: task.id, data: todoTaskToFirestore(task)),
      ],
      restore: (id, data) async {
        final task = mergeTodoTaskFromRemote(data, id);
        await todoRepository.upsertTask(task, recordLocalActivity: false);
        return task;
      },
    ),
    BackupCollection(
      name: FirestoreCollections.leetcodeProblems,
      read: () async => [
        for (final problem in await leetCodeRepository.getAllProblems(
          includeDeleted: true,
        ))
          BackupRecord(id: problem.id, data: leetCodeProblemToFirestore(problem)),
      ],
      restore: (id, data) async {
        final problem = mergeLeetCodeProblemFromRemote(data, id);
        await leetCodeRepository.upsertProblem(
          problem,
          recordLocalActivity: false,
        );
        return problem;
      },
    ),
    BackupCollection(
      name: FirestoreCollections.studyFolders,
      read: () async => [
        for (final folder in await studyRepository.getAllFolders(
          includeDeleted: true,
        ))
          BackupRecord(id: folder.id, data: studyFolderToFirestore(folder)),
      ],
      restore: (id, data) async {
        final folder = mergeStudyFolderFromRemote(data, id);
        await studyRepository.upsertFolder(folder, recordLocalActivity: false);
        return folder;
      },
    ),
    BackupCollection(
      name: FirestoreCollections.studyDecks,
      read: () async => [
        for (final deck in await studyRepository.getAllDecks(
          includeDeleted: true,
        ))
          BackupRecord(id: deck.id, data: studyDeckToFirestore(deck)),
      ],
      restore: (id, data) async {
        final deck = mergeStudyDeckFromRemote(data, id);
        await studyRepository.upsertDeck(deck, recordLocalActivity: false);
        return deck;
      },
    ),
    BackupCollection(
      name: FirestoreCollections.studyCards,
      read: () async => [
        for (final card in await studyRepository.getAllCards(
          includeDeleted: true,
        ))
          BackupRecord(id: card.id, data: studyCardToFirestore(card)),
      ],
      restore: (id, data) async {
        final card = mergeStudyCardFromRemote(data, id);
        await studyRepository.upsertCard(card, recordLocalActivity: false);
        return card;
      },
    ),
    BackupCollection(
      name: FirestoreCollections.studyReviewLog,
      read: () async => [
        for (final log in await studyRepository.getAllReviewLogs())
          BackupRecord(id: log.id, data: studyReviewLogToFirestore(log)),
      ],
      restore: (id, data) async {
        final log = mergeStudyReviewLogFromRemote(data, id);
        await studyRepository.logReview(log);
        return log;
      },
    ),
    // After decks, so a restored link never points at a deck not written yet.
    BackupCollection(
      name: FirestoreCollections.studyDeckLinks,
      read: () async => [
        for (final link in await studyRepository.listDeckLinks(
          includeDeleted: true,
        ))
          BackupRecord(id: link.id, data: studyDeckLinkToFirestore(link)),
      ],
      restore: (id, data) async {
        final link = mergeStudyDeckLinkFromRemote(data, id);
        await studyRepository.upsertDeckLink(link, recordLocalActivity: false);
        return link;
      },
      // The backup's links and the ones already here can close a loop that
      // neither held alone. Broken by the same rule a sync pull uses — the
      // newest edge of each loop goes — so every device agrees on the result.
      afterRestore: () async {
        final tombstones = <Object>[];
        for (final link in studyDeckLinksClosingCycles(
          await studyRepository.listDeckLinks(),
        )) {
          final tombstone = link.copyWith(deletedAt: utcNow());
          await studyRepository.upsertDeckLink(
            tombstone,
            recordLocalActivity: false,
          );
          tombstones.add(tombstone);
        }
        return tombstones;
      },
    ),
    BackupCollection(
      name: FirestoreCollections.exercises,
      read: () async => [
        for (final exercise in await workoutRepository.getAllExercises(
          includeDeleted: true,
        ))
          BackupRecord(id: exercise.id, data: exerciseToFirestore(exercise)),
      ],
      restore: (id, data) async {
        final exercise = mergeExerciseFromRemote(data, id);
        await workoutRepository.upsertExercise(
          exercise,
          recordLocalActivity: false,
        );
        return exercise;
      },
    ),
    BackupCollection(
      name: FirestoreCollections.workoutPlans,
      read: () async => [
        for (final plan in await workoutRepository.getAllPlans(
          includeDeleted: true,
        ))
          BackupRecord(id: plan.id, data: workoutPlanToFirestore(plan)),
      ],
      restore: (id, data) async {
        final plan = mergeWorkoutPlanFromRemote(data, id);
        await workoutRepository.upsertPlan(plan, recordLocalActivity: false);
        return plan;
      },
    ),
    BackupCollection(
      name: FirestoreCollections.workoutPlanEntries,
      read: () async => [
        for (final entry in await workoutRepository.getAllPlanEntries(
          includeDeleted: true,
        ))
          BackupRecord(id: entry.id, data: workoutPlanEntryToFirestore(entry)),
      ],
      restore: (id, data) async {
        final entry = mergeWorkoutPlanEntryFromRemote(data, id);
        await workoutRepository.upsertPlanEntry(
          entry,
          recordLocalActivity: false,
        );
        return entry;
      },
    ),
    BackupCollection(
      name: FirestoreCollections.workoutSessions,
      read: () async => [
        for (final session in await workoutRepository.getAllSessions(
          includeDeleted: true,
        ))
          BackupRecord(id: session.id, data: workoutSessionToFirestore(session)),
      ],
      restore: (id, data) async {
        final session = mergeWorkoutSessionFromRemote(data, id);
        await workoutRepository.upsertSession(
          session,
          recordLocalActivity: false,
        );
        return session;
      },
    ),
    BackupCollection(
      name: FirestoreCollections.workoutSetLogs,
      read: () async => [
        for (final log in await workoutRepository.getAllSetLogs(
          includeDeleted: true,
        ))
          BackupRecord(id: log.id, data: workoutSetLogToFirestore(log)),
      ],
      restore: (id, data) async {
        final log = mergeWorkoutSetLogFromRemote(data, id);
        await workoutRepository.upsertSetLog(log, recordLocalActivity: false);
        return log;
      },
    ),
    BackupCollection(
      name: FirestoreCollections.customQuotes,
      read: () async => [
        for (final quote in await settingsRepository.getCustomQuotes(
          includeDeleted: true,
        ))
          BackupRecord(id: quote.id, data: customQuoteToFirestore(quote)),
      ],
      restore: (id, data) async {
        final quote = mergeCustomQuoteFromRemote(data, id);
        await settingsRepository.upsertCustomQuote(
          quote,
          recordLocalActivity: false,
        );
        return quote;
      },
    ),
    BackupCollection(
      name: FirestoreCollections.snippets,
      read: () async => [
        for (final record in await settingsRepository.getSnippetRecords(
          includeDeleted: true,
        ))
          BackupRecord(id: record.item.id, data: snippetToFirestore(record)),
      ],
      restore: (id, data) async {
        final record =
            mergeSnippetFromRemote(data, id) ??
            (throw FormatException('Unreadable snippet $id'));
        await settingsRepository.upsertSnippetRecord(
          record,
          recordLocalActivity: false,
        );
        return record;
      },
    ),
    BackupCollection(
      name: FirestoreCollections.jobExperienceSnippets,
      read: () async => [
        for (final record
            in await settingsRepository.getJobExperienceSnippetRecords(
              includeDeleted: true,
            ))
          BackupRecord(
            id: record.item.id,
            data: jobExperienceSnippetToFirestore(record),
          ),
      ],
      restore: (id, data) async {
        final record =
            mergeJobExperienceSnippetFromRemote(data, id) ??
            (throw FormatException('Unreadable experience snippet $id'));
        await settingsRepository.upsertJobExperienceSnippetRecord(
          record,
          recordLocalActivity: false,
        );
        return record;
      },
    ),
    BackupCollection(
      name: FirestoreCollections.calendars,
      read: () async => [
        for (final calendar in await calendarRepository.listCalendars(
          includeDeleted: true,
        ))
          BackupRecord(id: calendar.id, data: calendarToFirestore(calendar)),
      ],
      prepare: (records) => backupLiveCalendarIds = {
        for (final record in records)
          if (record.data['deletedAt'] == null) record.id,
      },
      restore: (id, data) async {
        final calendar = mergeCalendarFromRemote({
          ...data,
          'overlayCalendarIds': [
            for (final overlayId
                in data['overlayCalendarIds'] as List? ?? const [])
              if (backupLiveCalendarIds.contains(overlayId)) overlayId,
          ],
        }, id);
        await calendarRepository.upsertCalendar(
          calendar,
          recordLocalActivity: false,
        );
        return calendar;
      },
    ),
    BackupCollection(
      name: FirestoreCollections.calendarEvents,
      // Google-imported events are rebuilt from the calendar API on each
      // device and never sync, so backing them up would restore duplicates
      // alongside the ones the next Google sync recreates. The sync layer
      // skips them for the same reason.
      read: () async => [
        for (final event in await calendarRepository.listEvents(
          includeDeleted: true,
        ))
          if (event.source != EventSource.google)
            BackupRecord(id: event.id, data: calendarEventToFirestore(event)),
      ],
      restore: (id, data) async {
        final event = mergeCalendarEventFromRemote(data, id);
        await calendarRepository.upsertEvent(event, recordLocalActivity: false);
        return event;
      },
    ),
    BackupCollection(
      name: FirestoreCollections.trackers,
      read: () async => [
        for (final tracker in await trackerRepository.listTrackers(
          includeDeleted: true,
        ))
          BackupRecord(id: tracker.id, data: trackerToFirestore(tracker)),
      ],
      restore: (id, data) async {
        final tracker = mergeTrackerFromRemote(data, id);
        await trackerRepository.upsertTracker(
          tracker,
          recordLocalActivity: false,
        );
        return tracker;
      },
    ),
    BackupCollection(
      name: FirestoreCollections.trackerValues,
      // Values are stored per tracker and there is no "every value" query, so
      // this walks the trackers — tombstoned ones included, since their values
      // are still real history.
      read: () async => [
        for (final tracker in await trackerRepository.listTrackers(
          includeDeleted: true,
        ))
          for (final value in await trackerRepository.listValues(
            tracker.id,
            includeDeleted: true,
          ))
            BackupRecord(id: value.id, data: trackerValueToFirestore(value)),
      ],
      restore: (id, data) async {
        final value = mergeTrackerValueFromRemote(data, id);
        await trackerRepository.upsertValue(value, recordLocalActivity: false);
        return value;
      },
    ),
    BackupCollection(
      name: FirestoreCollections.financeCategories,
      read: () async => [
        for (final category in await financeRepository.listCategories(
          includeDeleted: true,
        ))
          BackupRecord(id: category.id, data: financeCategoryToFirestore(category)),
      ],
      restore: (id, data) async {
        final category = mergeFinanceCategoryFromRemote(data, id);
        await financeRepository.upsertCategory(
          category,
          recordLocalActivity: false,
        );
        return category;
      },
    ),
    BackupCollection(
      name: FirestoreCollections.transactions,
      read: () async => [
        for (final transaction in await financeRepository.listTransactions(
          includeDeleted: true,
        ))
          BackupRecord(id: transaction.id, data: transactionToFirestore(transaction)),
      ],
      restore: (id, data) async {
        final transaction = mergeTransactionFromRemote(data, id);
        await financeRepository.upsertTransaction(
          transaction,
          recordLocalActivity: false,
        );
        return transaction;
      },
    ),
    BackupCollection(
      name: FirestoreCollections.subscriptions,
      read: () async => [
        for (final subscription in await financeRepository.listSubscriptions(
          includeDeleted: true,
        ))
          BackupRecord(id: subscription.id, data: subscriptionToFirestore(subscription)),
      ],
      restore: (id, data) async {
        final subscription = mergeSubscriptionFromRemote(data, id);
        await financeRepository.upsertSubscription(
          subscription,
          recordLocalActivity: false,
        );
        return subscription;
      },
    ),
    BackupCollection(
      name: FirestoreCollections.budgets,
      read: () async => [
        for (final budget in await financeRepository.listBudgets(
          includeDeleted: true,
        ))
          BackupRecord(id: budget.id, data: budgetToFirestore(budget)),
      ],
      restore: (id, data) async {
        final budget = mergeBudgetFromRemote(data, id);
        await financeRepository.upsertBudget(budget, recordLocalActivity: false);
        return budget;
      },
    ),
    BackupCollection(
      name: FirestoreCollections.contributionRooms,
      read: () async => [
        for (final room in await financeRepository.listContributionRooms(
          includeDeleted: true,
        ))
          BackupRecord(id: room.id, data: contributionRoomToFirestore(room)),
      ],
      restore: (id, data) async {
        final room = mergeContributionRoomFromRemote(data, id);
        await financeRepository.upsertContributionRoom(
          room,
          recordLocalActivity: false,
        );
        return room;
      },
    ),
    BackupCollection(
      name: FirestoreCollections.assets,
      read: () async => [
        for (final asset in await financeRepository.listAssets(
          includeDeleted: true,
        ))
          BackupRecord(id: asset.id, data: assetToFirestore(asset)),
      ],
      restore: (id, data) async {
        final asset = mergeAssetFromRemote(data, id);
        await financeRepository.upsertAsset(asset, recordLocalActivity: false);
        return asset;
      },
    ),
    BackupCollection(
      name: FirestoreCollections.assetValuations,
      read: () async => [
        for (final valuation in await financeRepository.listAssetValuations(
          includeDeleted: true,
        ))
          BackupRecord(id: valuation.id, data: assetValuationToFirestore(valuation)),
      ],
      restore: (id, data) async {
        final valuation = mergeAssetValuationFromRemote(data, id);
        await financeRepository.upsertAssetValuation(
          valuation,
          recordLocalActivity: false,
        );
        return valuation;
      },
    ),
    BackupCollection(
      name: FirestoreCollections.assetRoomEvents,
      read: () async => [
        for (final event in await financeRepository.listAssetRoomEvents(
          includeDeleted: true,
        ))
          BackupRecord(id: event.id, data: assetRoomEventToFirestore(event)),
      ],
      restore: (id, data) async {
        final event = mergeAssetRoomEventFromRemote(data, id);
        await financeRepository.upsertAssetRoomEvent(
          event,
          recordLocalActivity: false,
        );
        return event;
      },
    ),
    BackupCollection(
      name: FirestoreCollections.savingsGoals,
      read: () async => [
        for (final goal in await financeRepository.listSavingsGoals(
          includeDeleted: true,
        ))
          BackupRecord(id: goal.id, data: savingsGoalToFirestore(goal)),
      ],
      restore: (id, data) async {
        final goal = mergeSavingsGoalFromRemote(data, id);
        await financeRepository.upsertSavingsGoal(
          goal,
          recordLocalActivity: false,
        );
        return goal;
      },
    ),
    BackupCollection(
      name: FirestoreCollections.goalAllocations,
      read: () async => [
        for (final allocation in await financeRepository.listGoalAllocations(
          includeDeleted: true,
        ))
          BackupRecord(id: allocation.id, data: goalAllocationToFirestore(allocation)),
      ],
      restore: (id, data) async {
        final allocation = mergeGoalAllocationFromRemote(data, id);
        await financeRepository.upsertGoalAllocation(
          allocation,
          recordLocalActivity: false,
        );
        return allocation;
      },
    ),
    BackupCollection(
      name: FirestoreCollections.pinnedNotes,
      read: () async => [
        for (final note in await notificationRepository.listPinnedNotes(
          includeDeleted: true,
        ))
          BackupRecord(id: note.id, data: pinnedNoteToFirestore(note)),
      ],
      restore: (id, data) async {
        final note = mergePinnedNoteFromRemote(data, id);
        await notificationRepository.upsertPinnedNote(
          note,
          recordLocalActivity: false,
        );
        return note;
      },
    ),
    BackupCollection(
      name: FirestoreCollections.deviceRegistrations,
      read: () async => [
        for (final device in await reminderRepository.listDevices(
          includeDeleted: true,
        ))
          BackupRecord(id: device.id, data: deviceRegistrationToFirestore(device)),
      ],
      restore: (id, data) async {
        final device = mergeDeviceRegistrationFromRemote(data, id);
        await reminderRepository.upsertDevice(
          device,
          recordLocalActivity: false,
        );
        return device;
      },
    ),
    BackupCollection(
      name: FirestoreCollections.scheduledReminderRules,
      read: () async => [
        for (final rule in await reminderRepository.listRules(
          includeDeleted: true,
        ))
          BackupRecord(id: rule.id, data: scheduledReminderRuleToFirestore(rule)),
      ],
      restore: (id, data) async {
        final rule = mergeScheduledReminderRuleFromRemote(data, id);
        await reminderRepository.upsertRule(rule, recordLocalActivity: false);
        return rule;
      },
    ),
    BackupCollection(
      name: FirestoreCollections.entityReminders,
      read: () async => [
        for (final reminder in await reminderRepository.listEntityReminders(
          includeDeleted: true,
        ))
          BackupRecord(
            id: reminder.id,
            data: entityReminderToFirestore(reminder),
          ),
      ],
      restore: (id, data) async {
        final reminder = mergeEntityReminderFromRemote(data, id);
        await reminderRepository.upsertEntityReminder(
          reminder,
          recordLocalActivity: false,
        );
        return reminder;
      },
    ),
    BackupCollection(
      name: FirestoreCollections.reminderDeliveryStates,
      read: () async => [
        for (final state in await reminderRepository.listDeliveryStates())
          BackupRecord(
            id: state.id,
            data: reminderDeliveryStateToFirestore(state),
          ),
      ],
      restore: (id, data) async {
        final state = mergeReminderDeliveryStateFromRemote(data, id);
        await reminderRepository.upsertDeliveryState(
          state,
          recordLocalActivity: false,
        );
        return state;
      },
    ),
    BackupCollection(
      name: FirestoreCollections.reminderDeliveryLogs,
      read: () async => [
        for (final log in await reminderRepository.listLogs(
          includeDeleted: true,
        ))
          BackupRecord(id: log.id, data: reminderDeliveryLogToFirestore(log)),
      ],
      restore: (id, data) async {
        final log = mergeReminderDeliveryLogFromRemote(data, id);
        await reminderRepository.upsertLog(log, recordLocalActivity: false);
        return log;
      },
    ),
    BackupCollection(
      name: FirestoreCollections.dismissedNotifications,
      // Keyed by the dismissal key, not a uuid.
      read: () async => [
        for (final dismissal in await notificationRepository
            .listDismissalRecords())
          BackupRecord(
            id: dismissal.key,
            data: dismissedNotificationToFirestore(dismissal),
          ),
      ],
      restore: (id, data) async {
        final dismissal = mergeDismissedNotificationFromRemote(data, id);
        await notificationRepository.upsertDismissal(
          dismissal,
          recordLocalActivity: false,
        );
        return dismissal;
      },
    ),
    BackupCollection(
      name: FirestoreCollections.bucketListItems,
      read: () async => [
        for (final item in await bucketListRepository.listItems(
          includeDeleted: true,
        ))
          BackupRecord(id: item.id, data: bucketListItemToFirestore(item)),
      ],
      restore: (id, data) async {
        final item = mergeBucketListItemFromRemote(data, id);
        await bucketListRepository.upsertItem(item, recordLocalActivity: false);
        return item;
      },
    ),
    // Stages, categories and seasons before applications and companies: the
    // things that reference them read better on restore if their target
    // already exists, even though none of these are enforced foreign keys.
    BackupCollection(
      name: FirestoreCollections.jobStages,
      read: () async => [
        for (final stage in await jobRepository.getAllStages())
          BackupRecord(id: stage.id, data: jobStageToFirestore(stage)),
      ],
      restore: (id, data) async {
        final stage = mergeJobStageFromRemote(data, id);
        await jobRepository.upsertStage(stage, recordLocalActivity: false);
        return stage;
      },
    ),
    BackupCollection(
      name: FirestoreCollections.jobCategories,
      read: () async => [
        for (final category in await jobRepository.getAllCategories())
          BackupRecord(id: category.id, data: jobCategoryToFirestore(category)),
      ],
      restore: (id, data) async {
        final category = mergeJobCategoryFromRemote(data, id);
        await jobRepository.upsertCategory(
          category,
          recordLocalActivity: false,
        );
        return category;
      },
    ),
    BackupCollection(
      name: FirestoreCollections.jobSeasons,
      read: () async => [
        for (final season in await jobRepository.getAllSeasons())
          BackupRecord(id: season.id, data: jobSeasonToFirestore(season)),
      ],
      restore: (id, data) async {
        final season = mergeJobSeasonFromRemote(data, id);
        await jobRepository.upsertSeason(season, recordLocalActivity: false);
        return season;
      },
    ),
    BackupCollection(
      name: FirestoreCollections.jobCompanies,
      read: () async => [
        for (final company in await jobRepository.getAllCompanies())
          BackupRecord(id: company.id, data: jobCompanyToFirestore(company)),
      ],
      restore: (id, data) async {
        final company = mergeJobCompanyFromRemote(data, id);
        await jobRepository.upsertCompany(company, recordLocalActivity: false);
        return company;
      },
    ),
    BackupCollection(
      name: FirestoreCollections.jobApplications,
      read: () async => [
        for (final application in await jobRepository.getAllApplications())
          BackupRecord(
            id: application.id,
            data: jobApplicationToFirestore(application),
          ),
      ],
      restore: (id, data) async {
        final application = mergeJobApplicationFromRemote(data, id);
        await jobRepository.upsertApplication(
          application,
          recordLocalActivity: false,
        );
        return application;
      },
    ),
    BackupCollection(
      name: FirestoreCollections.jobStatusEvents,
      read: () async => [
        for (final event in await jobRepository.getAllStatusEvents())
          BackupRecord(id: event.id, data: jobStatusEventToFirestore(event)),
      ],
      restore: (id, data) async {
        final event = mergeJobStatusEventFromRemote(data, id);
        await jobRepository.upsertStatusEvent(
          event,
          recordLocalActivity: false,
        );
        return event;
      },
    ),
    // Assets before the references that point at them, so a restore never
    // writes a reference to an asset row that does not exist yet.
    // Categories before their entries, entries before their units: nothing
    // here is an enforced foreign key, but a restore that lands them in that
    // order never has a row pointing at something not written yet.
    BackupCollection(
      name: FirestoreCollections.rankingCategories,
      read: () async => [
        for (final category in await rankingRepository.getAllCategories())
          BackupRecord(
            id: category.id,
            data: rankingCategoryToFirestore(category),
          ),
      ],
      restore: (id, data) async {
        final category = mergeRankingCategoryFromRemote(data, id);
        await rankingRepository.upsertCategory(
          category,
          recordLocalActivity: false,
        );
        return category;
      },
    ),
    BackupCollection(
      name: FirestoreCollections.rankingParents,
      read: () async => [
        for (final parent in await rankingRepository.getAllParents())
          BackupRecord(id: parent.id, data: rankingParentToFirestore(parent)),
      ],
      restore: (id, data) async {
        final parent = mergeRankingParentFromRemote(data, id);
        await rankingRepository.upsertParent(
          parent,
          recordLocalActivity: false,
        );
        return parent;
      },
    ),
    BackupCollection(
      name: FirestoreCollections.rankingChildren,
      read: () async => [
        for (final child in await rankingRepository.getAllChildren())
          BackupRecord(id: child.id, data: rankingChildToFirestore(child)),
      ],
      restore: (id, data) async {
        final child = mergeRankingChildFromRemote(data, id);
        await rankingRepository.upsertChild(child, recordLocalActivity: false);
        return child;
      },
    ),
    BackupCollection(
      name: FirestoreCollections.mediaAssets,
      read: () async => [
        for (final asset in await mediaRepository.getAllAssets())
          BackupRecord(id: asset.id, data: mediaAssetToFirestore(asset)),
      ],
      restore: (id, data) async {
        final local = await mediaRepository.getAsset(id);
        final asset = mergeMediaAssetFromRemote(data, id, local: local);
        await mediaRepository.upsertAsset(asset, recordLocalActivity: false);
        return asset;
      },
    ),
    BackupCollection(
      name: FirestoreCollections.mediaReferences,
      read: () async => [
        for (final reference in await mediaRepository.getAllReferences())
          BackupRecord(
            id: reference.id,
            data: mediaReferenceToFirestore(reference),
          ),
      ],
      restore: (id, data) async {
        final local = await mediaRepository.getReference(id);
        final reference = mergeMediaReferenceFromRemote(data, id, local: local);
        await mediaRepository.upsertReference(
          reference,
          recordLocalActivity: false,
        );
        return reference;
      },
    ),
    BackupCollection(
      name: FirestoreCollections.tagColors,
      // Keyed by the tag itself.
      read: () async => [
        for (final tagColor in await settingsRepository.getTagColorRecords())
          BackupRecord(id: tagColor.tag, data: tagColorToFirestore(tagColor)),
      ],
      restore: (id, data) async {
        final tagColor = mergeTagColorFromRemote(data, id);
        await settingsRepository.upsertTagColor(
          tagColor,
          recordLocalActivity: false,
        );
        return tagColor;
      },
    ),
    BackupCollection(
      name: FirestoreCollections.customWords,
      // Keyed by the word itself.
      read: () async => [
        for (final word in await settingsRepository.getCustomWordRecords())
          BackupRecord(id: word.word, data: customWordToFirestore(word)),
      ],
      restore: (id, data) async {
        final word = mergeCustomWordFromRemote(data, id);
        await settingsRepository.upsertCustomWord(
          word,
          recordLocalActivity: false,
        );
        return word;
      },
    ),
    BackupCollection(
      name: FirestoreCollections.flaggedWords,
      // Keyed by the word itself.
      read: () async => [
        for (final word in await settingsRepository.getFlaggedWordRecords())
          BackupRecord(id: word.word, data: flaggedWordToFirestore(word)),
      ],
      restore: (id, data) async {
        final word = mergeFlaggedWordFromRemote(data, id);
        await settingsRepository.upsertFlaggedWord(
          word,
          recordLocalActivity: false,
        );
        return word;
      },
    ),
  ];
}

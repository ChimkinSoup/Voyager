import 'package:voyager/domain/models/analytics_models.dart';
import 'package:voyager/domain/models/calendar_models.dart';
import 'package:voyager/domain/models/contribution_room_models.dart';
import 'package:voyager/domain/models/dream_models.dart';
import 'package:voyager/domain/models/finance_models.dart';
import 'package:voyager/domain/models/job_models.dart';
import 'package:voyager/domain/models/journal_models.dart';
import 'package:voyager/domain/models/leetcode_models.dart';
import 'package:voyager/domain/models/life_tracker_models.dart';
import 'package:voyager/domain/models/media_models.dart';
import 'package:voyager/domain/models/notification_models.dart';
import 'package:voyager/domain/models/ranking_models.dart';
import 'package:voyager/domain/models/settings_models.dart';
import 'package:voyager/domain/models/study_models.dart';
import 'package:voyager/domain/models/todo_models.dart';
import 'package:voyager/domain/models/weather_models.dart';
import 'package:voyager/domain/models/workout_models.dart';

import 'package:voyager/domain/models/sync_conflict.dart';

abstract class JournalRepository {
  Future<List<Journal>> listJournals({bool includeDeleted = false});
  Future<Journal?> getJournal(String id);
  Future<void> upsertJournal(Journal journal, {bool recordLocalActivity = true});
  Future<void> softDeleteJournal(String id);
  Future<void> softDeleteEntriesInJournal(String journalId);
  Future<void> deleteAllJournals();
  Future<void> deleteAllEntries();
  Future<void> reassignEntriesJournal(String fromJournalId, String toJournalId);

  Future<List<JournalEntry>> listEntries({
    String? journalId,
    DateTime? from,
    DateTime? to,
    int? limit,
    bool includeDeleted = false,
  });
  Future<Map<String, int>> countEntriesByJournal({bool includeDeleted = false});
  Future<JournalEntry?> getEntry(String id);
  Future<void> upsertEntry(JournalEntry entry, {bool recordLocalActivity = true});
  Future<void> softDeleteEntry(String id);
  Future<void> hardDeleteEntry(String id);
  Future<void> purgeExpiredDeleted(DateTime now);
  Future<List<JournalEntry>> getAllEntries({bool includeDeleted = true});
}

abstract class DreamRepository {
  Future<List<DreamEntry>> listEntries({
    DateTime? from,
    DateTime? to,
    int? limit,
    bool includeDeleted = false,
  });
  Future<DreamEntry?> getEntry(String id);
  Future<void> upsertEntry(DreamEntry entry, {bool recordLocalActivity = true});
  Future<void> softDeleteEntry(String id);
  Future<void> hardDeleteEntry(String id);
  Future<void> purgeExpiredDeleted(DateTime now);
  Future<List<DreamEntry>> getAllEntries({bool includeDeleted = true});
}

abstract class LeetCodeRepository {
  Future<List<LeetCodeProblem>> listProblems({bool includeDeleted = false});
  Future<LeetCodeProblem?> getProblem(String id);
  Future<void> upsertProblem(
    LeetCodeProblem problem, {
    bool recordLocalActivity = true,
  });
  Future<void> softDeleteProblem(String id);
  Future<void> hardDeleteProblem(String id);
  Future<void> purgeExpiredDeleted(DateTime now);
  Future<List<LeetCodeProblem>> getAllProblems({bool includeDeleted = true});
}

abstract class TodoRepository {
  Future<List<TodoListModel>> listLists({bool includeDeleted = false});
  Future<void> upsertList(TodoListModel list, {bool recordLocalActivity = true});
  Future<void> softDeleteList(String id);

  /// Soft-deletes every task in [listId], subtasks included, and returns the
  /// rows as written so the caller can push exactly those to the remote.
  Future<List<TodoTask>> softDeleteTasksInList(String listId);

  Future<List<TodoTask>> listTasks(
    String listId, {
    bool includeDeleted = false,
    bool topLevelOnly = true,
  });
  Future<List<TodoTask>> listSubtasks(String parentTaskId);
  Future<int> nextSortOrder(String listId);
  Future<void> upsertTask(TodoTask task, {bool recordLocalActivity = true});
  Future<void> upsertTasksBatch(
    List<TodoTask> tasks, {
    bool recordLocalActivity = true,
  });
  Future<void> softDeleteTask(String id);
  Future<void> purgeExpiredDeleted(DateTime now);
  Future<List<TodoTask>> getAllTasks({bool includeDeleted = true});
  Future<TodoTask?> getTask(String id);
}

abstract class CalendarRepository {
  Future<List<Calendar>> listCalendars({bool includeDeleted = false});
  Future<Calendar?> getCalendar(String id);

  /// [recordLocalActivity] is false when the write is applying a document
  /// pulled from Firestore. It suppresses the upload the write would otherwise
  /// trigger, so a download can't bounce straight back up.
  Future<void> upsertCalendar(
    Calendar calendar, {
    bool recordLocalActivity = true,
  });
  Future<void> softDeleteCalendar(String id);
  Future<void> softDeleteEventsInCalendar(String calendarId);
  Future<void> reassignEventsCalendar(String fromCalendarId, String toCalendarId);

  Future<List<CalendarEvent>> listEvents({
    String? calendarId,
    DateTime? from,
    DateTime? to,
    bool includeDeleted = false,
  });
  Future<CalendarEvent?> getEvent(String id);
  Future<void> upsertEvent(
    CalendarEvent event, {
    bool recordLocalActivity = true,
  });
  Future<void> softDeleteEvent(String id);
  Future<void> deleteAllEvents();
  Future<void> replaceGoogleEvents(List<CalendarEvent> events);
  Future<void> purgeExpiredDeleted(DateTime now);
}

abstract class TrackerRepository {
  Future<List<StatisticTracker>> listTrackers({bool includeDeleted = false});
  Future<StatisticTracker?> getTracker(String id);
  Future<void> upsertTracker(
    StatisticTracker tracker, {
    bool recordLocalActivity = true,
  });
  Future<void> softDeleteTracker(String id);

  Future<List<TrackerValue>> listValues(
    String trackerId, {
    bool includeDeleted = false,
  });
  Future<TrackerValue?> getValue(String id);
  Future<void> upsertValue(TrackerValue value, {bool recordLocalActivity = true});
  Future<void> softDeleteValue(String id);

  Future<void> purgeExpiredDeleted(DateTime now);
}

/// The notification popover's pinned reminders and dismissed-feed-item
/// tracking. Both sync; unpinning and un-dismissing are soft deletes, because
/// a pull only ever sees the documents that still exist.
abstract class NotificationRepository {
  Future<List<PinnedNote>> listPinnedNotes({bool includeDeleted = false});
  Future<PinnedNote?> getPinnedNote(String id);
  Future<void> upsertPinnedNote(
    PinnedNote note, {
    bool recordLocalActivity = true,
  });
  Future<void> deletePinnedNote(String id);

  /// Dismissal keys currently recorded (see [NotificationFeedItem.dismissalKey]).
  Future<Set<String>> listDismissals();

  /// Every dismissal row including tombstoned ones — what the sync layer
  /// uploads, as distinct from [listDismissals]' "what is dismissed right now".
  Future<List<DismissedNotification>> listDismissalRecords();
  Future<DismissedNotification?> getDismissal(String dismissalKey);
  Future<void> dismiss(String dismissalKey);
  Future<void> undismiss(String dismissalKey);
  Future<void> upsertDismissal(
    DismissedNotification dismissal, {
    bool recordLocalActivity = true,
  });

  Future<void> purgeExpiredDeleted(DateTime now);
}

/// The Life Tracker page's bucket list.
abstract class BucketListRepository {
  Future<List<BucketListItem>> listItems({bool includeDeleted = false});
  Future<BucketListItem?> getItem(String id);
  Future<void> upsertItem(
    BucketListItem item, {
    bool recordLocalActivity = true,
  });
  Future<void> deleteItem(String id);
  Future<void> purgeExpiredDeleted(DateTime now);
}

abstract class FinanceRepository {
  Future<List<FinancialTransaction>> listTransactions({
    bool includeDeleted = false,
  });

  /// The row as it stands right now, tombstone included — what a restore reads
  /// to resolve the version it has to write. Null when the row is not there.
  Future<FinancialTransaction?> getTransaction(String id);
  Future<void> upsertTransaction(
    FinancialTransaction transaction, {
    bool recordLocalActivity = true,
  });

  /// Also tombstones the room event the row is the cash side of, if any.
  Future<void> softDeleteTransaction(String id);

  Future<List<Subscription>> listSubscriptions({bool includeDeleted = false});

  /// See [getTransaction].
  Future<Subscription?> getSubscription(String id);
  Future<void> upsertSubscription(
    Subscription subscription, {
    bool recordLocalActivity = true,
  });
  Future<void> softDeleteSubscription(String id);

  Future<List<Budget>> listBudgets({bool includeDeleted = false});
  Future<void> upsertBudget(Budget budget, {bool recordLocalActivity = true});
  Future<void> softDeleteBudget(String id);

  Future<List<FinanceCategory>> listCategories({bool includeDeleted = false});
  Future<void> upsertCategory(
    FinanceCategory category, {
    bool recordLocalActivity = true,
  });
  Future<void> softDeleteCategory(String id);

  Future<List<Asset>> listAssets({bool includeDeleted = false});
  Future<void> upsertAsset(Asset asset, {bool recordLocalActivity = true});
  Future<void> softDeleteAsset(String id);

  Future<List<AssetValuation>> listAssetValuations({
    String? assetId,
    bool includeDeleted = false,
  });
  Future<void> upsertAssetValuation(
    AssetValuation valuation, {
    bool recordLocalActivity = true,
  });
  Future<void> softDeleteAssetValuation(String id);

  Future<List<ContributionRoom>> listContributionRooms({
    bool includeDeleted = false,
  });
  Future<void> upsertContributionRoom(
    ContributionRoom room, {
    bool recordLocalActivity = true,
  });

  /// Tombstones the room and detaches every asset still in it. The room's
  /// events are kept.
  Future<void> softDeleteContributionRoom(String id);

  Future<List<AssetRoomEvent>> listAssetRoomEvents({
    bool includeDeleted = false,
  });

  /// See [getTransaction].
  Future<AssetRoomEvent?> getAssetRoomEvent(String id);
  Future<void> upsertAssetRoomEvent(
    AssetRoomEvent event, {
    bool recordLocalActivity = true,
  });

  /// Tombstones the event together with its ledger row and, for a transfer,
  /// its other leg. Valuations are left alone: they are history.
  Future<void> softDeleteAssetRoomEvent(String id);

  /// Undoes [softDeleteAssetRoomEvent]: the event, its ledger row and its
  /// other leg come back, each at a version above its tombstone's.
  Future<void> restoreAssetRoomEvent(String id);

  Future<List<SavingsGoal>> listSavingsGoals({bool includeDeleted = false});
  Future<void> upsertSavingsGoal(
    SavingsGoal goal, {
    bool recordLocalActivity = true,
  });
  Future<void> softDeleteSavingsGoal(String id);

  Future<List<GoalAllocation>> listGoalAllocations({
    String? goalId,
    bool includeDeleted = false,
  });
  Future<void> upsertGoalAllocation(
    GoalAllocation allocation, {
    bool recordLocalActivity = true,
  });
  Future<void> softDeleteGoalAllocation(String id);

  Future<void> purgeExpiredDeleted(DateTime now);
}

/// Folders/decks form an arbitrary-depth tree via `parentFolderId`. Callers
/// browse one level at a time (a breadcrumb stack of UUIDs), matching
/// STUDY.md's "in-memory stack" navigation model rather than loading the
/// whole tree at once.
abstract class StudyRepository {
  Future<List<StudyFolder>> listFolders({
    String? parentFolderId,
    bool includeDeleted = false,
  });
  Future<StudyFolder?> getFolder(String id);
  Future<void> upsertFolder(StudyFolder folder, {bool recordLocalActivity = true});
  Future<void> softDeleteFolder(String id);

  /// True if moving [folderId] under [targetParentFolderId] would create a
  /// cycle (the target is the folder itself or one of its own descendants).
  /// Must be checked before every folder move.
  Future<bool> wouldCreateCycle(String folderId, String? targetParentFolderId);
  Future<void> moveFolder(String folderId, String? newParentFolderId);

  Future<List<StudyDeck>> listDecks({
    String? parentFolderId,
    bool includeDeleted = false,
  });
  Future<StudyDeck?> getDeck(String id);
  Future<void> upsertDeck(StudyDeck deck, {bool recordLocalActivity = true});
  Future<void> softDeleteDeck(String id);
  Future<void> moveDeck(String deckId, String? newParentFolderId);

  Future<List<StudyCard>> listCards(String deckId, {bool includeDeleted = false});
  Future<StudyCard?> getCard(String id);
  Future<void> upsertCard(StudyCard card, {bool recordLocalActivity = true});
  Future<void> softDeleteCard(String id);
  Future<void> moveCards(List<String> cardIds, String targetDeckId);
  /// Copies each card in [cardIds] into its own deck, returning the source
  /// card id mapped to the id of the copy.
  ///
  /// The mapping is what lets the caller finish the job the text alone
  /// cannot: pushing the copies to sync, and giving each one its own
  /// references to the originals' images.
  Future<Map<String, String>> duplicateCards(List<String> cardIds);

  /// Every deck-in-deck link, both directions, for resolving effective card
  /// sets — see STUDY_DECK_LINKS_HLD.md.
  Future<List<StudyDeckLink>> listDeckLinks({bool includeDeleted = false});
  Future<StudyDeckLink?> getDeckLink(String id);
  Future<void> upsertDeckLink(
    StudyDeckLink link, {
    bool recordLocalActivity = true,
  });
  Future<void> softDeleteDeckLink(String id);

  Future<void> logReview(StudyReviewLog log, {bool recordLocalActivity = true});

  Future<StudyReviewLog?> getReviewLog(String id);

  /// Takes a logged review back, for a session whose undo removed the grade
  /// that wrote it. A tombstone rather than a row delete, so the removal
  /// reaches the other devices — see [StudyReviewLog].
  Future<void> softDeleteReviewLog(String id);
  Future<int> countCardsReviewedToday({DateTime? now});
  Future<int> countCardsReviewedTotal();
  Future<int> countDueCards({DateTime? now});

  Future<void> purgeExpiredDeleted(DateTime now);
  Future<List<StudyFolder>> getAllFolders({bool includeDeleted = true});
  Future<List<StudyDeck>> getAllDecks({bool includeDeleted = true});
  Future<List<StudyCard>> getAllCards({bool includeDeleted = true});

  /// The whole review history. Append-only and never tombstoned, so unlike the
  /// other `getAll` methods there is nothing to include or exclude.
  Future<List<StudyReviewLog>> getAllReviewLogs();
}

/// Exercises, the two plans and their day entries, plus performed sessions and
/// their set logs. Sessions are append-only history: nothing here rewrites a
/// past workout when the plan it came from is later edited.
abstract class WorkoutRepository {
  /// Creates the weekly and cycle plans if they're missing, and seeds the
  /// starter exercise library the very first time (gated on the table being
  /// completely empty, deleted rows included, so clearing the library out
  /// doesn't resurrect it on next launch). Idempotent.
  Future<void> ensureSeeded();

  Future<List<Exercise>> listExercises({bool includeDeleted = false});
  Future<Exercise?> getExercise(String id);
  Future<void> upsertExercise(
    Exercise exercise, {
    bool recordLocalActivity = true,
  });
  Future<void> softDeleteExercise(String id);

  Future<List<WorkoutPlan>> listPlans({bool includeDeleted = false});
  Future<WorkoutPlan?> getPlan(String id);
  Future<void> upsertPlan(WorkoutPlan plan, {bool recordLocalActivity = true});

  /// Marks [planId] active and clears the flag on every other plan, so
  /// "which plan decides today's workout" can never be ambiguous.
  Future<void> setActivePlan(String planId);

  Future<List<WorkoutPlanEntry>> listPlanEntries(
    String planId, {
    bool includeDeleted = false,
  });
  Future<WorkoutPlanEntry?> getPlanEntry(String id);
  Future<void> upsertPlanEntry(
    WorkoutPlanEntry entry, {
    bool recordLocalActivity = true,
  });
  Future<void> softDeletePlanEntry(String id);

  Future<List<WorkoutSession>> listSessions({bool includeDeleted = false});
  Future<WorkoutSession?> getSession(String id);

  /// The single in-progress session, if one exists. More than one would mean a
  /// sync raced two devices; the most recently started wins.
  Future<WorkoutSession?> getActiveSession();
  Future<void> upsertSession(
    WorkoutSession session, {
    bool recordLocalActivity = true,
  });
  Future<void> softDeleteSession(String id);

  Future<List<WorkoutSetLog>> listSetLogs({
    String? sessionId,
    String? exerciseId,
    bool includeDeleted = false,
  });
  Future<WorkoutSetLog?> getSetLog(String id);
  Future<void> upsertSetLog(
    WorkoutSetLog log, {
    bool recordLocalActivity = true,
  });
  Future<void> upsertSetLogsBatch(
    List<WorkoutSetLog> logs, {
    bool recordLocalActivity = true,
  });
  Future<void> softDeleteSetLog(String id);

  Future<void> purgeExpiredDeleted(DateTime now);
  Future<List<Exercise>> getAllExercises({bool includeDeleted = true});
  Future<List<WorkoutPlan>> getAllPlans({bool includeDeleted = true});
  Future<List<WorkoutPlanEntry>> getAllPlanEntries({
    bool includeDeleted = true,
  });
  Future<List<WorkoutSession>> getAllSessions({bool includeDeleted = true});
  Future<List<WorkoutSetLog>> getAllSetLogs({bool includeDeleted = true});
}

/// Metadata half of the media module: asset rows and the references that
/// point at them. The bytes themselves live in `MediaFileStore`, and nothing
/// here touches them.
abstract class MediaRepository {
  Future<List<MediaAsset>> listAssets({bool includeDeleted = false});
  Future<MediaAsset?> getAsset(String id);

  /// [getAsset] for many ids in one read, keyed by id and skipping any whose
  /// row has gone. A caller resolving a whole gallery — or every gallery in the
  /// library — would otherwise pay one round-trip per image.
  Future<Map<String, MediaAsset>> getAssets(Iterable<String> ids);

  /// The live asset with these exact post-ingest bytes, if this account
  /// already has one. The dedupe lookup, run on every ingest.
  ///
  /// A soft-deleted or unreferenced asset still counts as a hit — reusing it
  /// and clearing its retention clock is what makes re-pasting an image the
  /// user deleted last week cost nothing and resurrect nothing.
  Future<MediaAsset?> findAssetByContentHash(String contentHash);

  Future<void> upsertAsset(MediaAsset asset, {bool recordLocalActivity = true});
  Future<void> softDeleteAsset(String id);

  /// Assets whose bytes this device is meant to be moving, in either
  /// direction. Drives both transfer queues.
  Future<List<MediaAsset>> listAssetsByUploadState(Set<MediaUploadState> states);
  Future<List<MediaAsset>> listAssetsByDownloadState(
    Set<MediaDownloadState> states,
  );

  Future<List<MediaReference>> listReferences({bool includeDeleted = false});

  /// Every live reference on one parent, in [MediaReference.sortOrder] order —
  /// which is also the lightbox's swipe order.
  Future<List<MediaReference>> listReferencesForOwner(
    String collection,
    String documentId, {
    MediaFacet? facet,
    bool includeDeleted = false,
  });

  /// Live references pointing at [mediaId]. The refcount, in list form.
  Future<List<MediaReference>> listReferencesForAsset(String mediaId);

  Future<MediaReference?> getReference(String id);
  Future<void> upsertReference(
    MediaReference reference, {
    bool recordLocalActivity = true,
  });
  Future<void> softDeleteReference(String id);

  /// Soft-deletes every live reference on a parent, for when the parent
  /// itself is soft-deleted. Returns the affected references so the caller
  /// can re-check the refcount of each asset they pointed at.
  Future<List<MediaReference>> softDeleteReferencesForOwner(
    String collection,
    String documentId,
  );

  /// Mirror of [softDeleteReferencesForOwner], for a parent whose deletion was
  /// undone. Only references tombstoned at [deletedAt] come back, so an image
  /// the user had removed on its own beforehand stays removed.
  Future<List<MediaReference>> restoreReferencesForOwner(
    String collection,
    String documentId,
    DateTime deletedAt,
  );

  /// Permanently removes assets and references whose retention window has
  /// closed, and returns the assets removed so their bytes can be deleted
  /// too. [now] is the moment the 30-day cutoff is measured back from.
  Future<List<MediaAsset>> purgeExpiredDeleted(DateTime now);

  Future<List<MediaAsset>> getAllAssets({bool includeDeleted = true});
  Future<List<MediaReference>> getAllReferences({bool includeDeleted = true});
}

abstract class SettingsRepository {
  Future<AppSettings> getSettings();

  /// [recordLocalActivity] is false when applying settings pulled from
  /// Firestore, which both suppresses the re-upload and leaves
  /// [AppSettings.updatedAt] at the remote value that won.
  Future<void> saveSettings(
    AppSettings settings, {
    bool recordLocalActivity = true,
  });

  Future<Map<String, int>> getTagColors();

  /// Tag colors with their sync metadata, as distinct from [getTagColors]'
  /// plain tag-to-color map.
  Future<List<TagColorRecord>> getTagColorRecords();
  Future<TagColorRecord?> getTagColorRecord(String tag);
  Future<void> setTagColor(String tag, int colorValue);
  Future<void> upsertTagColor(
    TagColorRecord tagColor, {
    bool recordLocalActivity = true,
  });

  /// The dictionary as the spell checker sees it — tombstoned words excluded.
  Future<Set<String>> getCustomWords();

  /// Every custom-word row including tombstoned ones, for the sync layer.
  Future<List<CustomWord>> getCustomWordRecords();
  Future<CustomWord?> getCustomWordRecord(String word);
  Future<void> addCustomWord(String word);
  Future<void> removeCustomWord(String word);

  /// Changes the spelling of a custom word: tombstones [from] and adds [to] in
  /// one transaction, since the word string is this collection's primary key
  /// and there is no row to edit in place.
  ///
  /// [to] must not be a word the bundled dictionary already has — the
  /// repository can't see that set. A caller renaming onto a bundled word
  /// calls [removeCustomWord] instead: the new spelling is already accepted,
  /// so the rename is only the tombstone, and a single write needs no
  /// transaction.
  ///
  /// A no-op if [from] isn't a live custom word, if [to] isn't a single word
  /// token, or if [to] is already a custom word — the same "reject rather than
  /// corrupt" stance the other custom-word writes take on input they can't
  /// use.
  Future<void> renameCustomWord(String from, String to);
  Future<void> upsertCustomWord(
    CustomWord word, {
    bool recordLocalActivity = true,
  });

  /// Live flags, word -> replacement (null for a flag with no replacement).
  /// The map the checker subtracts from `bundled u custom`.
  Future<Map<String, String?>> getFlaggedWords();

  /// Every flagged-word row including tombstoned ones, for the sync layer.
  Future<List<FlaggedWord>> getFlaggedWordRecords();
  Future<FlaggedWord?> getFlaggedWordRecord(String word);

  /// Flags [word], optionally storing [replacement], and tombstones a live
  /// custom row for the same string in the same transaction
  /// (`FLAGGED_WORDS.md` §10) — otherwise "remove the custom word" would look
  /// like it worked while the bundled spelling kept the word known.
  ///
  /// A no-op if [word] isn't a single word token, or if [replacement] is
  /// non-null and either isn't a word token or equals [word]. The caller owns
  /// the rest of §10's validation (the target must be known and not itself
  /// flagged), which needs the dictionary this layer can't see.
  Future<void> flagWord(String word, {String? replacement});

  /// Changes or clears a live flag's replacement in place. Clearing keeps the
  /// flag. A no-op if [word] isn't currently flagged.
  Future<void> setFlaggedReplacement(String word, String? replacement);

  /// Lifts the flag: tombstones the row, so a bundled word is allowed again.
  Future<void> unflagWord(String word);

  Future<void> upsertFlaggedWord(
    FlaggedWord word, {
    bool recordLocalActivity = true,
  });

  Future<void> purgeExpiredDeleted(DateTime now);

  /// User-written quotes, newest first. Tombstoned rows are included only when
  /// [includeDeleted] is set — the sync layer needs them, the quote pool
  /// doesn't.
  Future<List<CustomQuote>> getCustomQuotes({bool includeDeleted = false});
  Future<CustomQuote?> getCustomQuote(String id);
  Future<void> upsertCustomQuote(
    CustomQuote quote, {
    bool recordLocalActivity = true,
  });
  Future<void> softDeleteCustomQuote(String id);

  /// The text-expansion snippets as synced records, in list order. Tombstoned
  /// rows are included only when [includeDeleted] is set.
  ///
  /// [getSettings] carries the live ones as [AppSettings.snippets];
  /// [saveSettings] ignores that list, and edits go through [applySnippetEdit].
  Future<List<SyncedListItem<Snippet>>> getSnippetRecords({
    bool includeDeleted = false,
  });
  Future<SyncedListItem<Snippet>?> getSnippetRecord(String id);
  Future<void> upsertSnippetRecord(
    SyncedListItem<Snippet> record, {
    bool recordLocalActivity = true,
  });

  /// Applies the user's edit — the list the editor started from, and the list
  /// it produced — as the rows it adds, changes, moves and removes, leaving
  /// everything else stored untouched. See `planOrderedListEdit`.
  Future<void> applySnippetEdit(List<Snippet> before, List<Snippet> after);

  /// [getSnippetRecords] for [AppSettings.jobExperienceSnippets].
  Future<List<SyncedListItem<JobExperienceSnippet>>>
  getJobExperienceSnippetRecords({bool includeDeleted = false});
  Future<SyncedListItem<JobExperienceSnippet>?> getJobExperienceSnippetRecord(
    String id,
  );
  Future<void> upsertJobExperienceSnippetRecord(
    SyncedListItem<JobExperienceSnippet> record, {
    bool recordLocalActivity = true,
  });

  /// [applySnippetEdit] for [AppSettings.jobExperienceSnippets].
  Future<void> applyJobExperienceSnippetEdit(
    List<JobExperienceSnippet> before,
    List<JobExperienceSnippet> after,
  );

  /// Snippets in a settings document written before they became records — by
  /// an older build, or in an older backup — whose ids this device has no row
  /// for, tombstones included. Built as records appended after the stored
  /// ones, but not written.
  Future<
    ({
      List<SyncedListItem<Snippet>> snippets,
      List<SyncedListItem<JobExperienceSnippet>> jobExperienceSnippets,
    })
  >
  unknownLegacySnippets(Map<String, dynamic> settingsDocument);
}

/// Job applications and everything the Jobs page configures around them:
/// pipeline stages, the company typeahead, category colours and archive
/// seasons.
///
/// Applications soft-delete like everything else in the app (§7.4): the row
/// stays as a tombstone the other devices can read the deletion off — the sync
/// layer has no way to propagate a Firestore document removal — and
/// [purgeExpiredDeleted] drops it for good once it has had time to reach every
/// device.
abstract class JobRepository {
  /// Adds each seed stage and seed company under its name-derived id unless a
  /// row with that id is already here, tombstones included — so deleting a
  /// seed does not resurrect it, and a seed pulled from another device is not
  /// doubled. Idempotent.
  Future<void> ensureSeeded();

  Future<List<JobApplication>> listApplications({bool includeDeleted = false});
  Future<JobApplication?> getApplication(String id);
  Future<void> upsertApplication(
    JobApplication application, {
    bool recordLocalActivity = true,
  });

  /// Writes [application], its [events] and — when [registerCompany] is given
  /// — the company suggestion in one transaction, so a failure part-way
  /// leaves none of them behind. Returns the company it added, if any.
  Future<JobCompany?> writeApplication(
    JobApplication application, {
    List<JobStatusEvent> events = const [],
    String? registerCompany,
  });

  /// Soft-deletes the application and its status timeline with it. Content is
  /// left on the row, so a caller holding a pre-delete snapshot can put the
  /// application back. Returns the tombstoned application and the tombstoned
  /// events so the caller can push all of them.
  Future<({JobApplication application, List<JobStatusEvent> events})>
  deleteApplication(String id);

  Future<List<JobStatusEvent>> listStatusEvents(
    String applicationId, {
    bool includeDeleted = false,
  });
  Future<void> upsertStatusEvent(
    JobStatusEvent event, {
    bool recordLocalActivity = true,
  });

  Future<List<JobStage>> listStages({bool includeDeleted = false});
  Future<void> upsertStage(JobStage stage, {bool recordLocalActivity = true});

  /// Tombstones the stage at a bumped version and returns the tombstone as
  /// written, for the caller to push. Null when there was no live stage.
  Future<JobStage?> softDeleteStage(String id);

  /// Rewrites [sortOrder] across [orderedIds] in one transaction. Returns the
  /// stages it wrote so the caller can push them.
  Future<List<JobStage>> reorderStages(List<String> orderedIds);

  Future<List<JobCompany>> listCompanies({bool includeDeleted = false});
  Future<void> upsertCompany(
    JobCompany company, {
    bool recordLocalActivity = true,
  });
  /// See [softDeleteStage].
  Future<JobCompany?> softDeleteCompany(String id);

  /// Adds [name] to the suggestion list unless an entry already matches it
  /// case-insensitively. Returns the new entry, or null when one already
  /// existed — so callers only push when there is something to push.
  Future<JobCompany?> ensureCompany(String name);

  Future<List<JobCategory>> listCategories({bool includeDeleted = false});
  Future<void> upsertCategory(
    JobCategory category, {
    bool recordLocalActivity = true,
  });

  /// Tombstones the category and clears it off every company filed under it.
  /// Returns the tombstone (see [softDeleteStage]) and the companies it
  /// rewrote, so the caller can push them.
  Future<({JobCategory? tombstone, List<JobCompany> orphaned})>
  softDeleteCategory(String id);

  Future<List<JobSeason>> listSeasons({bool includeDeleted = false});
  Future<void> upsertSeason(JobSeason season, {bool recordLocalActivity = true});

  /// Rewrites season sort order to match [orderedIds]. Returns only the
  /// seasons whose position actually moved, so the caller pushes the minimum.
  Future<List<JobSeason>> reorderSeasons(List<String> orderedIds);

  /// Tombstones the season and clears it off every application filed under it,
  /// so no application is ever stranded pointing at a season that no longer
  /// exists. Returns the tombstone (see [softDeleteStage]) and the
  /// applications it rewrote.
  Future<({JobSeason? tombstone, List<JobApplication> released})>
  softDeleteSeason(String id);

  Future<void> purgeExpiredDeleted(DateTime now);
  Future<List<JobApplication>> getAllApplications({bool includeDeleted = true});
  Future<List<JobStatusEvent>> getAllStatusEvents({bool includeDeleted = true});
  Future<List<JobStage>> getAllStages({bool includeDeleted = true});
  Future<List<JobCompany>> getAllCompanies({bool includeDeleted = true});
  Future<List<JobCategory>> getAllCategories({bool includeDeleted = true});
  Future<List<JobSeason>> getAllSeasons({bool includeDeleted = true});
}

/// Rankings: categories, their entries, and the optional units under them.
///
/// Everything soft-deletes. Deleting a category cascades to its parents and
/// their children in one transaction, and restoring it brings back exactly
/// what that cascade tombstoned — which is why the cascade records nothing
/// beyond `deletedAt`, leaving the content intact to come back to.
/// A category written together with the rows a change to it rewrote.
typedef RankingCategoryRewrite = ({
  RankingCategory category,
  List<RankingParent> parents,
  List<RankingChild> children,
});

abstract class RankingRepository {
  Future<List<RankingCategory>> listCategories({bool includeDeleted = false});
  Future<RankingCategory?> getCategory(String id);
  Future<void> upsertCategory(
    RankingCategory category, {
    bool recordLocalActivity = true,
  });

  /// Rewrites `sortOrder` across [orderedIds]. Returns only the categories
  /// that actually moved, so the caller pushes the minimum.
  Future<List<RankingCategory>> reorderCategories(List<String> orderedIds);

  /// Tombstones the category and everything filed under it. Returns all three
  /// lists so the caller can push the whole cascade.
  Future<
    ({
      RankingCategory category,
      List<RankingParent> parents,
      List<RankingChild> children,
    })
  >
  softDeleteCategory(String id);

  /// Undoes [softDeleteCategory] — the category and every entry the same
  /// cascade tombstoned come back together, since a restored category with an
  /// empty list would read as data loss.
  Future<
    ({
      RankingCategory category,
      List<RankingParent> parents,
      List<RankingChild> children,
    })
  >
  restoreCategory(String id);

  /// Moves one template field onto [scoreMax] and carries every stored value
  /// with it, deleted rows included, in one transaction.
  ///
  /// Reads the category fresh inside that transaction and returns null —
  /// writing nothing — when the field is already on [scoreMax]. That is what
  /// makes a second confirm, or a rescale another device already made, a no-op
  /// instead of a second halving.
  Future<RankingCategoryRewrite?> rescaleTemplateField(
    String categoryId,
    String fieldId, {
    required int scoreMax,
    required bool isParentTemplate,
  });

  /// [rescaleTemplateField] for the entry ([isParent]) or unit overall score.
  Future<RankingCategoryRewrite?> rescaleOverall(
    String categoryId, {
    required int scoreMax,
    required bool isParent,
  });

  Future<List<RankingParent>> listParents(
    String categoryId, {
    bool includeDeleted = false,
  });
  /// Live entries per category id, in one grouped query. A category with none
  /// is absent.
  Future<Map<String, int>> countParentsByCategory();
  Future<RankingParent?> getParent(String id);
  Future<void> upsertParent(
    RankingParent parent, {
    bool recordLocalActivity = true,
  });

  /// Tombstones the parent and its children. Returns both so the caller can
  /// push them and offer an undo.
  Future<({RankingParent parent, List<RankingChild> children})> softDeleteParent(
    String id,
  );

  Future<({RankingParent parent, List<RankingChild> children})> restoreParent(
    String id,
  );

  /// Rewrites `queueSortOrder` across [orderedIds]. Returns only the parents
  /// that moved.
  Future<List<RankingParent>> reorderQueue(List<String> orderedIds);

  Future<List<RankingChild>> listChildren(
    String parentId, {
    bool includeDeleted = false,
  });
  /// Every unit under every entry in [categoryId], in one query.
  Future<List<RankingChild>> listChildrenOfCategory(
    String categoryId, {
    bool includeDeleted = false,
  });
  Future<RankingChild?> getChild(String id);
  Future<void> upsertChild(
    RankingChild child, {
    bool recordLocalActivity = true,
  });
  Future<RankingChild> softDeleteChild(String id);
  Future<RankingChild> restoreChild(String id);

  /// Rewrites `sortOrder` across [orderedIds]. Returns only the children that
  /// moved.
  Future<List<RankingChild>> reorderChildren(List<String> orderedIds);

  Future<void> purgeExpiredDeleted(DateTime now);
  Future<List<RankingCategory>> getAllCategories({bool includeDeleted = true});
  Future<List<RankingParent>> getAllParents({bool includeDeleted = true});
  Future<List<RankingChild>> getAllChildren({bool includeDeleted = true});
}

abstract class AuthRepository {
  Stream<bool> get authStateChanges;
  Future<void> signInWithEmail(String email, String password);
  Future<void> signUpWithEmail(String email, String password);
  Future<void> sendPasswordResetEmail(String email);
  Future<void> signInWithGoogle();
  Future<void> signOut();
  String? get currentUserId;
}

abstract class SyncConflictRepository {
  Future<List<SyncConflict>> listConflicts();
  Future<SyncConflict?> getConflict(String id);
  Future<void> upsertConflict(SyncConflict conflict);
  Future<void> deleteConflict(String id);
  Future<void> deleteConflictsForDocument(String collection, String documentId);
}

abstract class SyncRepository {
  Future<void> upsertDocument(
    String collection,
    String id,
    Map<String, dynamic> data,
  );
  Stream<Map<String, dynamic>> watchDocument(String collection, String id);

  /// Emits the documents that changed (added or modified) in [collection],
  /// keyed by id, each time the backend's snapshot listener fires.
  ///
  /// The payloads come with the notification because the backend has already
  /// sent them — and already charged for them. Emitting bare ids and letting
  /// the caller `getDocument` each one turns a single snapshot carrying forty
  /// documents into forty more billed reads, serialised, for data that was
  /// sitting in the snapshot all along.
  ///
  /// This includes echoes of this device's own writes — callers that already
  /// know they just wrote a given id should treat that as a no-op rather
  /// than re-merging it.
  Stream<Map<String, Map<String, dynamic>>> watchCollection(String collection);
  Future<Map<String, dynamic>?> getDocument(String collection, String id);
  Future<List<({String id, Map<String, dynamic> data})>> listCollectionDocuments(
    String collection,
  );
  Future<Map<String, dynamic>?> getRemoteSettings();
  Future<void> upsertRemoteSettings(Map<String, dynamic> data);

  /// Whether writes are already piling up unacknowledged.
  ///
  /// True means the backend has not kept up — either this session has more
  /// writes outstanding than it is willing to hold, or a queue inherited from
  /// an earlier run of the app has still not been confirmed sent. Housekeeping
  /// that generates writes of its own (operation-log compaction, most of all)
  /// asks first and stands down, because adding to a queue that isn't moving
  /// is how the queue stops moving permanently. See `FirestoreWriteGate`.
  ///
  /// Backends that cannot queue — the in-memory and no-op ones — are never
  /// backlogged, which is why this defaults to false rather than being
  /// abstract.
  bool get hasUnsentWriteBacklog => false;
  Future<GoogleCalendarSyncLock?> getCalendarLock();
  Future<bool> claimCalendarLock(GoogleCalendarSyncLock lock);
  Future<void> releaseCalendarLock(String deviceId);
  Future<WeatherFetchLock?> getWeatherFetchLock();
  Future<bool> claimWeatherFetchLock(WeatherFetchLock lock);
  Future<void> releaseWeatherFetchLock(String deviceId);
  Future<WeatherSnapshot?> getCurrentWeather();
  Future<void> upsertCurrentWeather(WeatherSnapshot weather);
  Future<WeatherForecast?> getStoredForecast();
  Future<void> appendOperation(SyncOperation operation);

  /// Same effect as calling [appendOperation] once per entry, committed as
  /// one or few network round-trips instead of one per operation. Used for
  /// sort-order-only cascades (uncompleting a task in a large list can shift
  /// every row below it) where firing dozens of concurrent single-document
  /// writes was enough to starve the UI isolate and stall other Timer-driven
  /// work, like the background animation.
  Future<void> appendOperationsBatch(List<SyncOperation> operations);

  /// Appends every entry in [operations] as one all-or-nothing unit.
  ///
  /// Used for a single logical write whose character operations had to be
  /// split across several documents to fit the per-document size limit. Unlike
  /// [appendOperationsBatch], which is a throughput optimisation over
  /// independent writes, the entries here are meaningless apart: a reader that
  /// saw some but not all of them would reconstruct text missing whatever the
  /// absent ones carried. Implementations must commit them atomically.
  Future<void> appendOperationGroup(List<SyncOperation> operations);
  Future<List<SyncOperation>> listOperations(String documentId);

  /// Batched counterpart to [upsertDocument] — see [appendOperationsBatch].
  Future<void> upsertDocumentsBatch(
    String collection,
    Map<String, Map<String, dynamic>> documentsById,
  );
  Future<void> deleteDocument(String collection, String id);
  Future<int> deleteOperationsForDocument(String documentId);

  /// Deletes only the named operations of [documentId], leaving the rest of
  /// its log intact. Used by compaction to retire the operations a freshly
  /// written baseline supersedes.
  Future<int> deleteOperations(String documentId, List<String> operationIds);

  /// Round-trips to the backend to prove it is reachable, throwing if it is
  /// not.
  ///
  /// The only way to learn this from Firestore: writes are queued silently
  /// while offline and reads are answered from the local cache, so nothing in
  /// the normal sync path ever fails just because the network is gone.
  /// Implementations must therefore force a real server round-trip and treat a
  /// cache-answered result as a failure. Backends with no network behind them
  /// are always reachable and should return normally.
  Future<void> ping();
}

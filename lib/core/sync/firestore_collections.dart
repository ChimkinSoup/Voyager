/// Firestore collection names under `users/{uid}/`.
abstract final class FirestoreCollections {
  static const journals = 'journals';
  static const journalEntries = 'journal_entries';
  static const dreamEntries = 'dream_entries';
  static const todoLists = 'todo_lists';
  static const todoTasks = 'todo_tasks';
  static const leetcodeProblems = 'leetcode_problems';
  static const studyFolders = 'study_folders';
  static const studyDecks = 'study_decks';
  static const studyCards = 'study_cards';
  static const studyReviewLog = 'study_review_log';
  static const exercises = 'exercises';
  static const workoutPlans = 'workout_plans';
  static const workoutPlanEntries = 'workout_plan_entries';
  static const workoutSessions = 'workout_sessions';
  static const workoutSetLogs = 'workout_set_logs';
  static const customQuotes = 'custom_quotes';
  static const calendars = 'calendars';
  static const calendarEvents = 'calendar_events';
  static const trackers = 'trackers';
  static const trackerValues = 'tracker_values';
  static const transactions = 'transactions';
  static const subscriptions = 'subscriptions';
  static const budgets = 'budgets';
  static const financeCategories = 'finance_categories';
  static const assets = 'assets';
  static const assetValuations = 'asset_valuations';
  static const savingsGoals = 'savings_goals';
  static const goalAllocations = 'goal_allocations';
  static const pinnedNotes = 'pinned_notes';
  static const dismissedNotifications = 'dismissed_notifications';
  static const bucketListItems = 'bucket_list_items';
  static const jobApplications = 'job_applications';
  static const jobStatusEvents = 'job_status_events';
  static const jobStages = 'job_stages';
  static const jobCompanies = 'job_companies';
  static const jobCategories = 'job_categories';
  static const jobSeasons = 'job_seasons';
  static const tagColors = 'tag_colors';
  static const customWords = 'custom_words';
  static const syncOperations = 'sync_operations';

  /// Not a collection of records but a single document — `settings/app`, the
  /// one the weather service already keeps the saved location in. Used as a
  /// collection name wherever the sync layer dispatches on one.
  static const settings = 'settings';
  static const settingsDocumentId = 'app';

  /// Every collection of records under `users/{uid}/`.
  ///
  /// [settings] is absent because it is a single document rather than a
  /// collection, and [syncOperations] because it is the character-level CRDT
  /// log rather than a collection of user records. Anything added here must
  /// also be added to the backup registry — `backup_collections_test` fails
  /// until it is.
  static const records = {
    journals,
    journalEntries,
    dreamEntries,
    todoLists,
    todoTasks,
    leetcodeProblems,
    studyFolders,
    studyDecks,
    studyCards,
    studyReviewLog,
    exercises,
    workoutPlans,
    workoutPlanEntries,
    workoutSessions,
    workoutSetLogs,
    customQuotes,
    calendars,
    calendarEvents,
    trackers,
    trackerValues,
    transactions,
    subscriptions,
    budgets,
    financeCategories,
    assets,
    assetValuations,
    savingsGoals,
    goalAllocations,
    pinnedNotes,
    dismissedNotifications,
    bucketListItems,
    jobApplications,
    jobStatusEvents,
    jobStages,
    jobCompanies,
    jobCategories,
    jobSeasons,
    tagColors,
    customWords,
  };

  /// The only collections whose documents carry text two devices can edit at
  /// the same character position, and so the only ones an operation log buys
  /// anything for.
  ///
  /// A journal entry's body, a dream entry's body and a todo task's notes are
  /// long-form fields someone can be halfway through typing on one device while
  /// another device saves. Everything else is a plain record whose fields are
  /// replaced wholesale, and [snapshotOnly] covers it.
  static const crdtBacked = {journalEntries, dreamEntries, todoTasks};

  /// Collections whose documents are plain records — no collaborative text, so
  /// nothing for the character-level CRDT in `sync_operations` to merge.
  ///
  /// Writes to these skip the operation log entirely (one document write per
  /// save instead of two) and pulls skip the per-document `listOperations`
  /// query that would otherwise cost one indexed read per document on every
  /// full pull. Conflicts resolve by version-then-updatedAt, which is what
  /// their merge functions already do.
  ///
  /// Derived from [records] rather than listed by hand: a collection added to
  /// the app is snapshot-only unless it is deliberately named in [crdtBacked],
  /// so the cheap path is the one you get by default and a new collection
  /// cannot quietly start writing an operation log nobody reads.
  static final Set<String> snapshotOnly = records.difference(crdtBacked);
}

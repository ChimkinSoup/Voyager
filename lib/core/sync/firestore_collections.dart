/// Firestore collection names under `users/{uid}/`.
abstract final class FirestoreCollections {
  static const journals = 'journals';
  static const journalEntries = 'journal_entries';
  static const dreamEntries = 'dream_entries';
  static const todoLists = 'todo_lists';
  static const todoTasks = 'todo_tasks';
  static const leetcodeProblems = 'leetcode_problems';
  static const leetcodeReviewLog = 'leetcode_review_log';

  /// The LeetCode cheat sheet's three levels. One record per tab, per section
  /// and per entry: two devices editing different commands then never conflict
  /// at all, which is what lets the sheet stay [snapshotOnly].
  static const leetcodeCheatTabs = 'leetcode_cheat_tabs';
  static const leetcodeCheatSections = 'leetcode_cheat_sections';
  static const leetcodeCheatEntries = 'leetcode_cheat_entries';
  static const studyFolders = 'study_folders';
  static const studyDecks = 'study_decks';
  static const studyCards = 'study_cards';
  static const studyReviewLog = 'study_review_log';
  static const studyDeckLinks = 'study_deck_links';
  static const exercises = 'exercises';
  static const workoutPlans = 'workout_plans';
  static const workoutPlanEntries = 'workout_plan_entries';
  static const workoutSessions = 'workout_sessions';
  static const workoutSetLogs = 'workout_set_logs';
  static const customQuotes = 'custom_quotes';

  /// Text-expansion snippets and the Jobs header's experience snippets. Lists
  /// inside the settings document until they became records of their own —
  /// see `SyncedListItem`.
  static const snippets = 'snippets';
  static const jobExperienceSnippets = 'job_experience_snippets';
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
  static const contributionRooms = 'contribution_rooms';
  static const assetRoomEvents = 'asset_room_events';
  static const savingsGoals = 'savings_goals';
  static const goalAllocations = 'goal_allocations';
  static const pinnedNotes = 'pinned_notes';
  static const dismissedNotifications = 'dismissed_notifications';
  static const deviceRegistrations = 'device_registrations';
  static const scheduledReminderRules = 'scheduled_reminder_rules';

  /// The bell on a todo or calendar event. Its own collection rather than
  /// fields on the task or event: a task is CRDT-backed, and toggling a bell
  /// should neither bump its version against a notes edit on another device
  /// nor ride through that merge.
  static const entityReminders = 'entity_reminders';
  static const reminderDeliveryStates = 'reminder_delivery_states';
  static const reminderDeliveryLogs = 'reminder_delivery_logs';
  static const bucketListItems = 'bucket_list_items';
  static const jobApplications = 'job_applications';
  static const jobStatusEvents = 'job_status_events';
  static const jobStages = 'job_stages';
  static const jobCompanies = 'job_companies';
  static const jobCategories = 'job_categories';
  static const jobSeasons = 'job_seasons';
  static const rankingCategories = 'ranking_categories';
  static const rankingParents = 'ranking_parents';
  static const rankingChildren = 'ranking_children';

  /// The owner tag rankings' images carry on their [MediaReference]s, per
  /// `MEDIA.md`. Not a collection of records — a picture hangs off either a
  /// parent or a child, and one tag over both is what lets the page ask "does
  /// this entry have images" in a single pass.
  static const rankings = 'rankings';
  static const mediaAssets = 'media_assets';
  static const mediaReferences = 'media_references';
  static const tagColors = 'tag_colors';
  static const customWords = 'custom_words';

  /// Words the user has flagged as wrong for them (`FLAGGED_WORDS.md`).
  /// Separate from [customWords]: a row there means "allow", and there is no
  /// way to say "deny a bundled word" in that vocabulary.
  static const flaggedWords = 'flagged_words';
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
    leetcodeReviewLog,
    leetcodeCheatTabs,
    leetcodeCheatSections,
    leetcodeCheatEntries,
    studyFolders,
    studyDecks,
    studyCards,
    studyReviewLog,
    studyDeckLinks,
    exercises,
    workoutPlans,
    workoutPlanEntries,
    workoutSessions,
    workoutSetLogs,
    customQuotes,
    snippets,
    jobExperienceSnippets,
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
    contributionRooms,
    assetRoomEvents,
    savingsGoals,
    goalAllocations,
    pinnedNotes,
    dismissedNotifications,
    deviceRegistrations,
    scheduledReminderRules,
    entityReminders,
    reminderDeliveryStates,
    reminderDeliveryLogs,
    bucketListItems,
    jobApplications,
    jobStatusEvents,
    jobStages,
    jobCompanies,
    jobCategories,
    jobSeasons,
    rankingCategories,
    rankingParents,
    rankingChildren,
    mediaAssets,
    mediaReferences,
    tagColors,
    customWords,
    flaggedWords,
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

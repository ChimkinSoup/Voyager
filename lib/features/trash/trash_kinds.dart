import 'package:voyager/core/constants/calendar_constants.dart';
import 'package:voyager/core/constants/journal_constants.dart';
import 'package:voyager/core/constants/todo_constants.dart';
import 'package:voyager/core/sync/firestore_collections.dart';
import 'package:voyager/core/text/prose_markup.dart';

/// The page a deleted item came from — the trash's filter chips.
enum TrashFeature {
  journal('Journal'),
  dreams('Dreams'),
  todo('To-Do'),
  calendar('Calendar'),
  study('Study'),
  leetcode('LeetCode'),
  rankings('Rankings'),
  jobs('Jobs'),
  finance('Finance'),
  analytics('Analytics'),
  workout('Workout'),
  life('Life');

  const TrashFeature(this.label);

  final String label;
}

/// Rows of [collection] a delete took along with the row that owns them.
///
/// A child belongs to the delete when [keys] point at the owner *and* it
/// carries the owner's exact `deletedAt` — every cascade stamps the container
/// and what it takes with one instant, which is what tells those apart from a
/// child the user deleted on its own before.
class TrashChild {
  const TrashChild(this.collection, this.keys, {this.counted});

  final String collection;
  final List<String> keys;

  /// Singular and plural, when these rows are counted in the trash row's
  /// summary ("14 tasks").
  final (String, String)? counted;
}

/// Where a row lives, for restoring it on its own after its container was
/// deleted too.
class TrashParent {
  /// A container the row can't be restored without.
  const TrashParent(this.collection, this.key)
    : hasFallback = false,
      fallbackId = null,
      fallbackName = null,
      localId = _sameId;

  /// A container whose feature has a default one to restore into instead.
  /// [fallbackId] null means the top level.
  const TrashParent.orDefault(
    this.collection,
    this.key, {
    required this.fallbackId,
    required String this.fallbackName,
    this.localId = _sameId,
  }) : hasFallback = true;

  final String collection;
  final String key;

  /// The local id of the container a payload's [key] names. The default
  /// containers go by a different id in Firestore.
  final String Function(String storedId) localId;
  final bool hasFallback;
  final String? fallbackId;
  final String? fallbackName;
}

/// How one synced collection appears in the trash.
class TrashKind {
  const TrashKind({
    required this.collection,
    required this.feature,
    required this.noun,
    this.containerLabel,
    this.title = _name,
    this.wipe = const [],
    this.children = const [],
    this.parents = const [],
    this.erasedWith = const [],
    this.mediaOwner,
    this.listed = true,
  });

  final String collection;
  final TrashFeature feature;

  /// What an untitled row is called — 'entry', 'task'.
  final String noun;

  /// Leads a container's row — `To-do list "Groceries"`.
  final String? containerLabel;

  final String? Function(Map<String, dynamic> data) title;

  /// Fields "Delete forever" empties. Only what the user wrote: ids, dates and
  /// settings stay, so the tombstone still reads as a well-formed row.
  final List<String> wipe;

  final List<TrashChild> children;
  final List<TrashParent> parents;

  /// Rows that point at this one and go when it is deleted forever, whatever
  /// their own state. Unlike [children], a delete doesn't take them, so a
  /// restore has nothing to bring back — a task's completions keep counting
  /// while it sits in the trash, and stop only when it is erased.
  final List<TrashChild> erasedWith;

  /// The collection media references name this row's documents under, for
  /// the images a delete detached from it.
  final String? mediaOwner;

  /// False for rows that are only ever part of another row's delete.
  final bool listed;
}

String _sameId(String id) => id;

String? _name(Map<String, dynamic> data) => data['name'] as String?;

String? _field(Map<String, dynamic> data, String key) => data[key] as String?;

/// A title, or the first line of a prose body for a row never titled.
String? _titleOrBody(Map<String, dynamic> data, {String body = 'body'}) {
  final title = (data['title'] as String?)?.trim();
  if (title != null && title.isNotEmpty) return title;
  final text = data[body] as String?;
  if (text == null) return null;
  return proseStrip(text).trim().split('\n').first.trim();
}

/// Every collection the trash reads, keyed by name. Listed kinds are what the
/// trash shows; the rest only ride along in a cascade.
final Map<String, TrashKind> trashKinds = {
  for (final kind in _kinds) kind.collection: kind,
};

const _studyRoot = TrashParent.orDefault(
  FirestoreCollections.studyFolders,
  'parentFolderId',
  fallbackId: null,
  fallbackName: 'Study',
);

final _kinds = <TrashKind>[
  const TrashKind(
    collection: FirestoreCollections.journals,
    feature: TrashFeature.journal,
    noun: 'journal',
    containerLabel: 'Journal',
    wipe: ['name'],
    children: [
      TrashChild(
        FirestoreCollections.journalEntries,
        ['journalId'],
        counted: ('entry', 'entries'),
      ),
    ],
  ),
  const TrashKind(
    collection: FirestoreCollections.journalEntries,
    feature: TrashFeature.journal,
    noun: 'entry',
    title: _titleOrBody,
    wipe: ['title', 'body', 'richBodyJson', 'tags', 'customQuote'],
    parents: [
      TrashParent.orDefault(
        FirestoreCollections.journals,
        'journalId',
        fallbackId: legacyJournalId,
        fallbackName: 'Journal',
        localId: journalReferenceIdFromFirestore,
      ),
    ],
    mediaOwner: FirestoreCollections.journalEntries,
  ),
  const TrashKind(
    collection: FirestoreCollections.dreamEntries,
    feature: TrashFeature.dreams,
    noun: 'dream',
    title: _titleOrBody,
    wipe: ['title', 'body', 'notes', 'tags'],
  ),
  const TrashKind(
    collection: FirestoreCollections.todoLists,
    feature: TrashFeature.todo,
    noun: 'list',
    containerLabel: 'To-do list',
    wipe: ['name'],
    children: [
      TrashChild(
        FirestoreCollections.todoTasks,
        ['listId'],
        counted: ('task', 'tasks'),
      ),
    ],
  ),
  TrashKind(
    collection: FirestoreCollections.todoTasks,
    feature: TrashFeature.todo,
    noun: 'task',
    title: (data) => _field(data, 'title'),
    wipe: const ['title', 'notes'],
    children: const [
      TrashChild(
        FirestoreCollections.todoTasks,
        ['parentTaskId'],
        counted: ('subtask', 'subtasks'),
      ),
    ],
    parents: const [
      TrashParent.orDefault(
        FirestoreCollections.todoLists,
        'listId',
        fallbackId: legacyTodoListId,
        fallbackName: 'To-do',
        localId: todoListDocumentIdFromFirestore,
      ),
      TrashParent(FirestoreCollections.todoTasks, 'parentTaskId'),
    ],
    erasedWith: const [
      TrashChild(FirestoreCollections.todoTaskCompletions, ['taskId']),
    ],
    mediaOwner: FirestoreCollections.todoTasks,
  ),
  const TrashKind(
    collection: FirestoreCollections.todoTaskCompletions,
    feature: TrashFeature.todo,
    noun: 'completion',
    listed: false,
  ),
  const TrashKind(
    collection: FirestoreCollections.calendars,
    feature: TrashFeature.calendar,
    noun: 'calendar',
    containerLabel: 'Calendar',
    wipe: ['name'],
    children: [
      TrashChild(
        FirestoreCollections.calendarEvents,
        ['calendarId'],
        counted: ('event', 'events'),
      ),
    ],
  ),
  TrashKind(
    collection: FirestoreCollections.calendarEvents,
    feature: TrashFeature.calendar,
    noun: 'event',
    title: (data) => _field(data, 'title'),
    wipe: const ['title', 'notes'],
    // A series takes the occurrences it had split off with it.
    children: const [
      TrashChild(FirestoreCollections.calendarEvents, ['recurrenceParentId']),
    ],
    parents: const [
      TrashParent.orDefault(
        FirestoreCollections.calendars,
        'calendarId',
        fallbackId: legacyCalendarId,
        fallbackName: 'Calendar',
        localId: calendarReferenceIdFromFirestore,
      ),
      TrashParent(FirestoreCollections.calendarEvents, 'recurrenceParentId'),
    ],
  ),
  const TrashKind(
    collection: FirestoreCollections.studyFolders,
    feature: TrashFeature.study,
    noun: 'folder',
    containerLabel: 'Folder',
    wipe: ['name'],
    children: [
      TrashChild(
        FirestoreCollections.studyFolders,
        ['parentFolderId'],
        counted: ('folder', 'folders'),
      ),
      TrashChild(
        FirestoreCollections.studyDecks,
        ['parentFolderId'],
        counted: ('deck', 'decks'),
      ),
    ],
    parents: [_studyRoot],
  ),
  const TrashKind(
    collection: FirestoreCollections.studyDecks,
    feature: TrashFeature.study,
    noun: 'deck',
    containerLabel: 'Deck',
    wipe: ['name'],
    children: [
      TrashChild(
        FirestoreCollections.studyCards,
        ['deckId'],
        counted: ('card', 'cards'),
      ),
      TrashChild(FirestoreCollections.studyDeckLinks, [
        'parentDeckId',
        'childDeckId',
      ]),
    ],
    parents: [_studyRoot],
  ),
  TrashKind(
    collection: FirestoreCollections.studyCards,
    feature: TrashFeature.study,
    noun: 'card',
    title: (data) => _titleOrBody(data, body: 'frontText'),
    wipe: const ['frontText', 'backText'],
    parents: const [TrashParent(FirestoreCollections.studyDecks, 'deckId')],
    mediaOwner: FirestoreCollections.studyCards,
  ),
  const TrashKind(
    collection: FirestoreCollections.studyDeckLinks,
    feature: TrashFeature.study,
    noun: 'link',
    parents: [
      TrashParent(FirestoreCollections.studyDecks, 'parentDeckId'),
      TrashParent(FirestoreCollections.studyDecks, 'childDeckId'),
    ],
    listed: false,
  ),
  TrashKind(
    collection: FirestoreCollections.leetcodeProblems,
    feature: TrashFeature.leetcode,
    noun: 'problem',
    title: (data) => _field(data, 'title'),
    wipe: const ['title', 'description', 'examples', 'solutions', 'tags'],
  ),
  const TrashKind(
    collection: FirestoreCollections.leetcodeCheatTabs,
    feature: TrashFeature.leetcode,
    noun: 'tab',
    containerLabel: 'Cheat-sheet tab',
    wipe: ['name'],
    children: [
      TrashChild(
        FirestoreCollections.leetcodeCheatSections,
        ['tabId'],
        counted: ('section', 'sections'),
      ),
    ],
  ),
  const TrashKind(
    collection: FirestoreCollections.leetcodeCheatSections,
    feature: TrashFeature.leetcode,
    noun: 'section',
    containerLabel: 'Cheat-sheet section',
    wipe: ['name'],
    children: [
      TrashChild(
        FirestoreCollections.leetcodeCheatEntries,
        ['sectionId'],
        counted: ('command', 'commands'),
      ),
    ],
    parents: [TrashParent(FirestoreCollections.leetcodeCheatTabs, 'tabId')],
  ),
  TrashKind(
    collection: FirestoreCollections.leetcodeCheatEntries,
    feature: TrashFeature.leetcode,
    noun: 'command',
    title: (data) {
      final label = (data['label'] as String?)?.trim();
      return label == null || label.isEmpty ? _field(data, 'command') : label;
    },
    wipe: const ['command', 'label', 'description'],
    parents: const [
      TrashParent(FirestoreCollections.leetcodeCheatSections, 'sectionId'),
    ],
  ),
  const TrashKind(
    collection: FirestoreCollections.rankingCategories,
    feature: TrashFeature.rankings,
    noun: 'category',
    containerLabel: 'Category',
    wipe: ['name'],
    children: [
      TrashChild(
        FirestoreCollections.rankingParents,
        ['categoryId'],
        counted: ('entry', 'entries'),
      ),
    ],
  ),
  TrashKind(
    collection: FirestoreCollections.rankingParents,
    feature: TrashFeature.rankings,
    noun: 'entry',
    title: (data) => _field(data, 'title'),
    wipe: const ['title', 'notes', 'tags', 'fieldValues'],
    children: const [
      TrashChild(
        FirestoreCollections.rankingChildren,
        ['parentId'],
        counted: ('unit', 'units'),
      ),
    ],
    parents: const [
      TrashParent(FirestoreCollections.rankingCategories, 'categoryId'),
    ],
    mediaOwner: FirestoreCollections.rankings,
  ),
  const TrashKind(
    collection: FirestoreCollections.rankingChildren,
    feature: TrashFeature.rankings,
    noun: 'unit',
    wipe: ['name', 'notes', 'fieldValues'],
    parents: [TrashParent(FirestoreCollections.rankingParents, 'parentId')],
    mediaOwner: FirestoreCollections.rankings,
  ),
  TrashKind(
    collection: FirestoreCollections.jobApplications,
    feature: TrashFeature.jobs,
    noun: 'application',
    title: (data) {
      final title = (data['title'] as String?)?.trim() ?? '';
      final company = (data['company'] as String?)?.trim() ?? '';
      if (title.isEmpty) return company.isEmpty ? null : company;
      return company.isEmpty ? title : '$title at $company';
    },
    wipe: const [
      'company',
      'title',
      'status',
      'applicationUrl',
      'notes',
      'seasonIds',
    ],
    children: const [
      TrashChild(FirestoreCollections.jobStatusEvents, ['applicationId']),
    ],
  ),
  const TrashKind(
    collection: FirestoreCollections.jobStatusEvents,
    feature: TrashFeature.jobs,
    noun: 'status change',
    listed: false,
  ),
  TrashKind(
    collection: FirestoreCollections.transactions,
    feature: TrashFeature.finance,
    noun: 'transaction',
    title: (data) => _field(data, 'note'),
    wipe: const ['note', 'tags', 'amountCents'],
  ),
  const TrashKind(
    collection: FirestoreCollections.subscriptions,
    feature: TrashFeature.finance,
    noun: 'subscription',
    wipe: ['name', 'note', 'amountCents'],
  ),
  TrashKind(
    collection: FirestoreCollections.budgets,
    feature: TrashFeature.finance,
    noun: 'budget',
    title: (data) => _field(data, 'tag'),
    wipe: const ['tag', 'limitCents'],
  ),
  const TrashKind(
    collection: FirestoreCollections.financeCategories,
    feature: TrashFeature.finance,
    noun: 'category',
    wipe: ['name', 'tags'],
  ),
  const TrashKind(
    collection: FirestoreCollections.assets,
    feature: TrashFeature.finance,
    noun: 'asset',
    wipe: ['name', 'note'],
    children: [
      TrashChild(
        FirestoreCollections.assetValuations,
        ['assetId'],
        counted: ('valuation', 'valuations'),
      ),
    ],
  ),
  const TrashKind(
    collection: FirestoreCollections.assetValuations,
    feature: TrashFeature.finance,
    noun: 'valuation',
    wipe: ['valueCents'],
    listed: false,
  ),
  const TrashKind(
    collection: FirestoreCollections.savingsGoals,
    feature: TrashFeature.finance,
    noun: 'goal',
    wipe: ['name', 'note', 'targetCents'],
    children: [
      TrashChild(
        FirestoreCollections.goalAllocations,
        ['goalId'],
        counted: ('allocation', 'allocations'),
      ),
    ],
  ),
  const TrashKind(
    collection: FirestoreCollections.goalAllocations,
    feature: TrashFeature.finance,
    noun: 'allocation',
    wipe: ['note', 'amountCents'],
    listed: false,
  ),
  // A tracker's logged values are never tombstoned with it — they are hidden
  // by the tracker being gone — so it restores and erases on its own.
  const TrashKind(
    collection: FirestoreCollections.trackers,
    feature: TrashFeature.analytics,
    noun: 'statistic',
    wipe: ['name', 'enumOptions'],
  ),
  const TrashKind(
    collection: FirestoreCollections.exercises,
    feature: TrashFeature.workout,
    noun: 'exercise',
    wipe: ['name', 'formCues'],
    children: [
      TrashChild(FirestoreCollections.workoutPlanEntries, ['exerciseId']),
    ],
  ),
  const TrashKind(
    collection: FirestoreCollections.workoutPlanEntries,
    feature: TrashFeature.workout,
    noun: 'plan entry',
    listed: false,
  ),
  TrashKind(
    collection: FirestoreCollections.bucketListItems,
    feature: TrashFeature.life,
    noun: 'bucket-list item',
    title: (data) => _field(data, 'title'),
    wipe: const ['title', 'note'],
  ),
];

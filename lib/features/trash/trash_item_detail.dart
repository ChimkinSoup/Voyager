import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/sync/firestore_collections.dart';
import 'package:voyager/core/sync/firestore_document_mapper.dart';
import 'package:voyager/core/theme/app_fonts.dart';
import 'package:voyager/core/utils/time_format.dart';
import 'package:voyager/core/widgets/glass_button.dart';
import 'package:voyager/core/widgets/tag_chip.dart';
import 'package:voyager/core/widgets/voyager_dialog.dart';
import 'package:voyager/core/widgets/voyager_prose_text.dart';
import 'package:voyager/domain/models/analytics_models.dart';
import 'package:voyager/domain/models/calendar_models.dart';
import 'package:voyager/domain/models/dream_models.dart';
import 'package:voyager/domain/models/enums.dart';
import 'package:voyager/domain/models/finance_models.dart';
import 'package:voyager/domain/models/job_models.dart';
import 'package:voyager/domain/models/journal_models.dart';
import 'package:voyager/domain/models/leetcode_cheat_models.dart';
import 'package:voyager/domain/models/leetcode_models.dart';
import 'package:voyager/domain/models/life_tracker_models.dart';
import 'package:voyager/domain/models/ranking_models.dart';
import 'package:voyager/domain/models/study_models.dart';
import 'package:voyager/domain/models/todo_models.dart';
import 'package:voyager/domain/models/workout_models.dart';
import 'package:voyager/domain/services/recurrence_engine.dart';
import 'package:voyager/features/leetcode/leetcode_examples.dart';
import 'package:voyager/features/rankings/rankings_score_stars.dart';
import 'package:voyager/features/study/study_rich_text.dart';
import 'package:voyager/features/trash/trash_kinds.dart';
import 'package:voyager/features/trash/trash_labels.dart';
import 'package:voyager/features/trash/trash_service.dart';
import 'package:voyager/features/workout/workout_units.dart';

/// A deleted item shown the way its own page shows it, read-only.
///
/// [onRestore] and [onErase] are null for a row that only went with another
/// row's delete — it comes back or goes with that one, not on its own.
Future<void> showTrashItemDetail(
  BuildContext context,
  TrashItem item, {
  VoidCallback? onRestore,
  VoidCallback? onErase,
}) {
  final group = _TrashGroup(item);
  return showVoyagerDialog<void>(
    context: context,
    builder: (_) => _TrashItemDetail(
      item: item,
      group: group,
      onRestore: onRestore,
      onErase: onErase,
    ),
  );
}

/// A row [group]'s delete took with it, opened [depth] dialogs above the
/// root's.
Future<void> _showMember(
  BuildContext context,
  TrashItem item, {
  required _TrashGroup group,
  required int depth,
}) {
  return showVoyagerDialog<void>(
    context: context,
    builder: (_) => _TrashItemDetail(item: item, group: group, depth: depth),
  );
}

/// The live ranking entry a deleted unit belongs to.
final _liveRankingParentProvider = FutureProvider.autoDispose
    .family<RankingParent?, String>(
      (ref, id) => ref.watch(rankingRepositoryProvider).getParent(id),
    );

/// For each collection, the fields its rows name an owner by in some
/// [TrashChild.keys].
final Map<String, Set<String>> _ownerKeys = () {
  final keys = <String, Set<String>>{};
  for (final kind in trashKinds.values) {
    for (final child in kind.children) {
      keys.putIfAbsent(child.collection, () => {}).addAll(child.keys);
    }
  }
  return keys;
}();

/// Everything one delete took, indexed once for every dialog opened on it.
///
/// Each row hangs under its closest owner only. A subtask points at its list
/// as well as its parent task, and a split-off occurrence at its calendar as
/// well as its series; they belong under the task and the series.
class _TrashGroup {
  _TrashGroup(this.root) {
    final rows = [root.row, ...root.members];
    final pointingAt = <String, List<TrashRow>>{};
    for (final row in rows) {
      _byKey[_key(row.kind.collection, row.id)] = row;
      for (final key in _ownerKeys[row.kind.collection] ?? const <String>{}) {
        if (row.data[key] case final String ownerId) {
          pointingAt
              .putIfAbsent('${row.kind.collection}|$key|$ownerId', () => [])
              .add(row);
        }
      }
    }
    final owners = <TrashRow, List<TrashRow>>{};
    for (final owner in rows) {
      for (final child in owner.kind.children) {
        for (final key in child.keys) {
          for (final row
              in pointingAt['${child.collection}|$key|${owner.id}'] ??
                  const <TrashRow>[]) {
            if (row != owner) owners.putIfAbsent(row, () => []).add(owner);
          }
        }
      }
    }
    // How far below the root each row sits by its longest chain of owners.
    final depths = <TrashRow, int>{root.row: 0};
    int depthOf(TrashRow row) => depths[row] ??= [
      for (final owner in owners[row] ?? const <TrashRow>[]) depthOf(owner) + 1,
    ].fold(0, (a, b) => a > b ? a : b);
    for (final row in root.members) {
      final candidates = owners[row];
      if (candidates == null || candidates.isEmpty) continue;
      final parent = candidates.reduce(
        (a, b) => depthOf(a) >= depthOf(b) ? a : b,
      );
      _children.putIfAbsent(parent, () => []).add(row);
    }
  }

  final TrashItem root;
  final _byKey = <String, TrashRow>{};
  final _children = <TrashRow, List<TrashRow>>{};

  static String _key(String collection, String id) => '$collection/$id';

  TrashRow? find(String collection, String id) => _byKey[_key(collection, id)];

  List<TrashRow> childrenOf(TrashRow row) => _children[row] ?? const [];

  /// [row] as the trash would list it, with everything below it.
  TrashItem itemFor(TrashRow row) {
    final members = <TrashRow>[];
    void collect(TrashRow owner) {
      for (final child in childrenOf(owner)) {
        members.add(child);
        collect(child);
      }
    }

    collect(row);
    return TrashItem(row: row, deletedAt: root.deletedAt, members: members);
  }
}

class _TrashItemDetail extends ConsumerWidget {
  const _TrashItemDetail({
    required this.item,
    required this.group,
    this.onRestore,
    this.onErase,
    this.depth = 0,
  });

  final TrashItem item;
  final _TrashGroup group;
  final VoidCallback? onRestore;
  final VoidCallback? onErase;

  /// How many member dialogs sit on top of the root's, this one included. 0
  /// for the root itself.
  final int depth;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final body = _body(context, ref);
    // What went with it that the trash would list on its own, each openable.
    final children = [
      for (final row in group.childrenOf(item.row))
        if (row.kind.listed) group.itemFor(row),
    ];

    return AlertDialog(
      title: Row(
        children: [
          Icon(trashFeatureIcon(item.kind.feature)),
          const SizedBox(width: 12),
          Expanded(child: Text(trashItemLabel(item))),
        ],
      ),
      contentPadding: const EdgeInsets.fromLTRB(24, 12, 24, 0),
      // Breathing room between the content and the buttons.
      actionsPadding: const EdgeInsets.fromLTRB(24, 20, 24, 24),
      content: SizedBox(
        width: 720,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                trashItemDetail(item, DateTime.now().toUtc()),
                style: _labelStyle(context),
              ),
              if (depth > 0) ...[
                const SizedBox(height: 16),
                Text('Deleted as part of', style: theme.textTheme.titleSmall),
                const SizedBox(height: 4),
                // Back down to the delete itself, where it can be undone.
                _linkTile(
                  group.root,
                  onTap: () {
                    final navigator = Navigator.of(context);
                    for (var i = 0; i < depth; i++) {
                      navigator.pop();
                    }
                  },
                ),
              ],
              if (body.isNotEmpty) ...[const SizedBox(height: 16), ...body],
              if (children.isNotEmpty) ...[
                const SizedBox(height: 16),
                Text('Deleted with it', style: theme.textTheme.titleSmall),
                const SizedBox(height: 4),
                for (final child in children)
                  _linkTile(
                    child,
                    onTap: () => _showMember(
                      context,
                      child,
                      group: group,
                      depth: depth + 1,
                    ),
                  ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        if (onErase case final erase?)
          GlassButton(
            dense: true,
            onPressed: () {
              Navigator.of(context).pop();
              erase();
            },
            label: 'Delete forever…',
            color: theme.colorScheme.error,
          ),
        if (onRestore case final restore?)
          GlassButton(
            dense: true,
            onPressed: () {
              Navigator.of(context).pop();
              restore();
            },
            label: 'Restore',
          ),
        GlassButton(
          dense: true,
          onPressed: () => Navigator.of(context).pop(),
          label: 'Close',
        ),
      ],
    );
  }

  Widget _linkTile(TrashItem target, {required VoidCallback onTap}) {
    return ListTile(
      key: ValueKey('trash-detail-${target.id}'),
      contentPadding: EdgeInsets.zero,
      dense: true,
      leading: Icon(trashFeatureIcon(target.kind.feature)),
      title: Text(
        trashItemLabel(target),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: switch (target.summary) {
        final summary? => Text(summary),
        null => null,
      },
      trailing: const Icon(PhosphorIconsRegular.caretRight),
      onTap: onTap,
    );
  }

  List<Widget> _body(BuildContext context, WidgetRef ref) {
    final data = item.row.data;
    final id = item.id;
    return switch (item.kind.collection) {
      FirestoreCollections.journalEntries => _journalEntry(
        context,
        mergeJournalEntryFromRemote(data, id),
      ),
      FirestoreCollections.dreamEntries => _dream(
        context,
        mergeDreamEntryFromRemote(data, id),
      ),
      FirestoreCollections.todoTasks => _task(
        context,
        mergeTodoTaskFromRemote(data, id),
      ),
      FirestoreCollections.calendarEvents => _event(
        context,
        mergeCalendarEventFromRemote(data, id),
      ),
      FirestoreCollections.studyCards => _card(
        context,
        mergeStudyCardFromRemote(data, id),
      ),
      FirestoreCollections.leetcodeProblems => _problem(
        context,
        mergeLeetCodeProblemFromRemote(data, id),
      ),
      FirestoreCollections.leetcodeCheatEntries => _cheatEntry(
        context,
        mergeLeetCodeCheatEntryFromRemote(data, id),
      ),
      FirestoreCollections.rankingParents => _ranking(
        context,
        ref,
        mergeRankingParentFromRemote(data, id),
      ),
      FirestoreCollections.rankingChildren => _rankingUnit(
        context,
        ref,
        mergeRankingChildFromRemote(data, id),
      ),
      FirestoreCollections.jobApplications => _job(
        context,
        mergeJobApplicationFromRemote(data, id),
      ),
      FirestoreCollections.transactions => _transaction(
        context,
        mergeTransactionFromRemote(data, id),
      ),
      FirestoreCollections.subscriptions => _subscription(
        context,
        mergeSubscriptionFromRemote(data, id),
      ),
      FirestoreCollections.budgets => _budget(
        context,
        mergeBudgetFromRemote(data, id),
      ),
      FirestoreCollections.financeCategories => _financeCategory(
        mergeFinanceCategoryFromRemote(data, id),
      ),
      FirestoreCollections.assets => _section(
        context,
        'Note',
        mergeAssetFromRemote(data, id).note,
      ),
      FirestoreCollections.savingsGoals => _goal(
        context,
        mergeSavingsGoalFromRemote(data, id),
      ),
      FirestoreCollections.trackers => _tracker(
        context,
        mergeTrackerFromRemote(data, id),
      ),
      FirestoreCollections.exercises => _exercise(
        context,
        ref,
        mergeExerciseFromRemote(data, id),
      ),
      FirestoreCollections.workoutSessions => _workout(
        context,
        ref,
        mergeWorkoutSessionFromRemote(data, id),
      ),
      FirestoreCollections.bucketListItems => _bucketItem(
        context,
        mergeBucketListItemFromRemote(data, id),
      ),
      // Containers: what they held is listed under "Deleted with it".
      _ => const [],
    };
  }

  // --- Per-feature bodies ---------------------------------------------------

  List<Widget> _journalEntry(BuildContext context, JournalEntry entry) {
    final local = entry.entryDate.toLocal();
    final mood = entry.mood;
    final prompt = entry.guidedPrompt?.trim() ?? '';
    final quote = entry.customQuote?.trim() ?? '';
    return [
      _meta(context, [
        (
          PhosphorIconsRegular.calendarBlank,
          '${DateFormat.yMMMMEEEEd().format(local)} · '
              '${formatTime12Hour(local)}',
        ),
        if (mood != null) (PhosphorIconsRegular.smiley, 'Mood $mood/10'),
      ]),
      if (prompt.isNotEmpty) ...[
        const SizedBox(height: 12),
        _italic(context, prompt),
      ],
      ..._prose(context, entry.body),
      if (quote.isNotEmpty) ...[
        const SizedBox(height: 12),
        _italic(context, '“$quote”'),
      ],
      ..._tags(entry.tags),
    ];
  }

  List<Widget> _dream(BuildContext context, DreamEntry dream) => [
    _meta(context, [
      (
        PhosphorIconsRegular.moonStars,
        DateFormat.yMMMMEEEEd().format(dream.entryDate.toLocal()),
      ),
    ]),
    ..._prose(context, dream.body),
    ..._section(context, 'Notes', dream.notes),
    ..._tags(dream.tags),
  ];

  List<Widget> _task(BuildContext context, TodoTask task) {
    final due = task.dueDate;
    return [
      _meta(context, [
        if (task.completed)
          (PhosphorIconsRegular.checkCircle, 'Completed')
        else
          (PhosphorIconsRegular.circle, 'Not completed'),
        if (task.starred) (PhosphorIconsRegular.star, 'Starred'),
        if (due != null) (PhosphorIconsRegular.calendarBlank, _dueLabel(due)),
        if (task.recurrence.repeats)
          (
            PhosphorIconsRegular.repeat,
            recurrenceRuleLabel(task.recurrence, anchor: task.recurrenceAnchor),
          ),
      ]),
      ..._section(context, 'Notes', task.notes),
    ];
  }

  List<Widget> _event(BuildContext context, CalendarEvent event) {
    final start = event.start.toLocal();
    final end = event.end.toLocal();
    final sameDay =
        start.year == end.year &&
        start.month == end.month &&
        start.day == end.day;
    final String when;
    if (event.isFullDay) {
      when = sameDay
          ? '${DateFormat.yMMMMEEEEd().format(start)} · All day'
          : '${DateFormat.yMMMd().format(start)} – '
                '${DateFormat.yMMMd().format(end)} · All day';
    } else {
      when = sameDay
          ? '${DateFormat.yMMMMEEEEd().format(start)} · '
                '${formatTime12Hour(start)} – ${formatTime12Hour(end)}'
          : '${DateFormat.yMMMd().format(start)} ${formatTime12Hour(start)} '
                '– ${DateFormat.yMMMd().format(end)} ${formatTime12Hour(end)}';
    }
    return [
      Row(
        children: [
          Container(
            width: 12,
            height: 12,
            decoration: BoxDecoration(
              color: Color(event.colorValue),
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(child: Text(when)),
        ],
      ),
      if (event.recurrence.repeats) ...[
        const SizedBox(height: 6),
        _meta(context, [
          (
            PhosphorIconsRegular.repeat,
            recurrenceRuleLabel(event.recurrence, anchor: event.start),
          ),
        ]),
      ],
      ..._section(context, 'Notes', event.notes),
    ];
  }

  List<Widget> _card(BuildContext context, StudyCard card) {
    final theme = Theme.of(context);
    Widget face(String label, String text) => Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: _labelStyle(context)),
          const SizedBox(height: 8),
          StudyRichText(text, style: theme.textTheme.bodyLarge),
        ],
      ),
    );
    return [
      face('Front', card.frontText),
      const SizedBox(height: 12),
      face('Back', card.backText),
    ];
  }

  List<Widget> _problem(BuildContext context, LeetCodeProblem problem) {
    final theme = Theme.of(context);
    final description = problem.description?.trim() ?? '';
    return [
      _meta(context, [
        (PhosphorIconsRegular.gauge, _capitalized(problem.difficulty.name)),
        (
          PhosphorIconsRegular.checkCircle,
          'Solved ${DateFormat.yMMMd().format(problem.solvedAt.toLocal())}',
        ),
      ]),
      ..._tags(problem.tags),
      if (description.isNotEmpty) ...[
        const SizedBox(height: 12),
        StudyRichText(description, style: theme.textTheme.bodyMedium),
      ],
      if (problem.examples.isNotEmpty) ...[
        const SizedBox(height: 16),
        LeetCodeExamplesView(examples: problem.examples),
      ],
      for (final solution in problem.solutions) ...[
        const SizedBox(height: 16),
        Text(
          solution.algorithm.isEmpty ? 'Solution' : solution.algorithm,
          style: theme.textTheme.titleSmall,
        ),
        if (solution.timeComplexity != null || solution.spaceComplexity != null)
          Text(
            [
              if (solution.timeComplexity case final time?) 'Time $time',
              if (solution.spaceComplexity case final space?) 'Space $space',
            ].join(' · '),
            style: _labelStyle(context),
          ),
        if (solution.explanation.trim().isNotEmpty) ...[
          const SizedBox(height: 6),
          StudyRichText(
            solution.explanation,
            style: theme.textTheme.bodyMedium,
          ),
        ],
        if (solution.code.trim().isNotEmpty) ...[
          const SizedBox(height: 8),
          _code(context, solution.code),
        ],
      ],
    ];
  }

  List<Widget> _cheatEntry(BuildContext context, LeetCodeCheatEntry entry) {
    final complexity = entry.complexity?.trim() ?? '';
    return [
      _code(context, entry.command),
      if (complexity.isNotEmpty) ...[
        const SizedBox(height: 8),
        Text(complexity, style: _labelStyle(context)),
      ],
      ..._section(context, 'Description', entry.description),
    ];
  }

  List<Widget> _ranking(
    BuildContext context,
    WidgetRef ref,
    RankingParent parent,
  ) {
    final category = _rankingCategory(ref, parent.categoryId);
    final accent = category == null ? null : Color(category.colorValue);
    return [
      if (category != null)
        _meta(context, [(PhosphorIconsRegular.ranking, category.name)]),
      const SizedBox(height: 8),
      RankingStars(
        value: parent.overallScore,
        scoreMax: category?.parentScoreMax ?? 5,
        size: 20,
        accentColor: accent,
      ),
      ..._fieldValues(
        context,
        category?.activeParentTemplate ?? const [],
        parent.fieldValues,
        accent,
      ),
      ..._tags(parent.tags),
      ..._section(context, 'Notes', parent.notes),
    ];
  }

  List<Widget> _rankingUnit(
    BuildContext context,
    WidgetRef ref,
    RankingChild child,
  ) {
    // The entry this unit belongs to, deleted or live, and through it the
    // category's scale.
    final categoryId = switch (_findDeleted(
      ref,
      FirestoreCollections.rankingParents,
      child.parentId,
    )) {
      final row? => row.data['categoryId'] as String?,
      null =>
        ref
            .watch(_liveRankingParentProvider(child.parentId))
            .valueOrNull
            ?.categoryId,
    };
    final category = categoryId == null
        ? null
        : _rankingCategory(ref, categoryId);
    final accent = category == null ? null : Color(category.colorValue);
    return [
      RankingStars(
        value: child.overallScore,
        scoreMax: category?.childScoreMax ?? 5,
        size: 20,
        accentColor: accent,
      ),
      ..._fieldValues(
        context,
        category?.activeChildTemplate ?? const [],
        child.fieldValues,
        accent,
      ),
      ..._section(context, 'Notes', child.notes),
    ];
  }

  /// The category a ranking row sits in, deleted or live.
  RankingCategory? _rankingCategory(WidgetRef ref, String categoryId) {
    final deleted = _findDeleted(
      ref,
      FirestoreCollections.rankingCategories,
      categoryId,
    );
    if (deleted != null) {
      return mergeRankingCategoryFromRemote(deleted.data, deleted.id);
    }
    return ref
        .watch(rankingCategoriesProvider)
        .valueOrNull
        ?.where((c) => c.id == categoryId)
        .firstOrNull;
  }

  List<Widget> _fieldValues(
    BuildContext context,
    List<RankingTemplateField> fields,
    Map<String, RankingFieldValue> values,
    Color? accent,
  ) {
    final theme = Theme.of(context);
    return [
      for (final field in fields)
        if (values[field.id] case final value?)
          if (value.score != null || value.notes.trim().isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          field.label,
                          style: theme.textTheme.labelLarge,
                        ),
                      ),
                      RankingStars(
                        value: value.score,
                        scoreMax: field.scoreMax,
                        accentColor: accent,
                      ),
                    ],
                  ),
                  if (value.notes.trim().isNotEmpty)
                    VoyagerProseText(
                      value.notes,
                      style: theme.textTheme.bodySmall,
                    ),
                ],
              ),
            ),
    ];
  }

  List<Widget> _job(BuildContext context, JobApplication job) {
    final url = job.applicationUrl?.trim() ?? '';
    return [
      _meta(context, [
        if (job.company.trim().isNotEmpty)
          (PhosphorIconsRegular.buildings, job.company),
        if (job.status.trim().isNotEmpty)
          (PhosphorIconsRegular.flag, job.status),
        (
          PhosphorIconsRegular.calendarBlank,
          'Applied ${DateFormat.yMMMd().format(job.dateApplied.toLocal())}',
        ),
        if (url.isNotEmpty) (PhosphorIconsRegular.link, url),
      ]),
      ..._section(context, 'Notes', job.notes),
    ];
  }

  List<Widget> _transaction(
    BuildContext context,
    FinancialTransaction transaction,
  ) {
    final theme = Theme.of(context);
    final deposit = transaction.type == TransactionType.deposit;
    final cents = transaction.amountCents.abs();
    final origin = transaction.origin?.trim() ?? '';
    return [
      Text(
        formatCents(deposit ? cents : -cents, signed: true),
        style: theme.textTheme.headlineSmall?.copyWith(
          color: deposit ? Colors.green : theme.colorScheme.primary,
        ),
      ),
      const SizedBox(height: 8),
      _meta(context, [
        (
          PhosphorIconsRegular.calendarBlank,
          DateFormat.yMMMMEEEEd().format(transaction.occurredAt.toLocal()),
        ),
        if (origin.isNotEmpty) (PhosphorIconsRegular.storefront, origin),
      ]),
      ..._tags(transaction.tags),
      ..._section(context, 'Note', transaction.note),
    ];
  }

  List<Widget> _subscription(BuildContext context, Subscription subscription) {
    return [
      Text(
        '${formatCents(subscription.amountCents)} ${subscription.period.name}',
        style: Theme.of(context).textTheme.headlineSmall?.copyWith(
          color: Color(subscription.colorValue),
        ),
      ),
      const SizedBox(height: 8),
      _meta(context, [
        (
          PhosphorIconsRegular.calendarBlank,
          'Due from '
              '${DateFormat.yMMMd().format(subscription.anchorDueDate.toLocal())}',
        ),
      ]),
      ..._section(context, 'Note', subscription.note),
    ];
  }

  List<Widget> _budget(BuildContext context, Budget budget) => [
    Text(
      '${formatCents(budget.limitCents)} limit',
      style: Theme.of(context).textTheme.headlineSmall,
    ),
    ..._tags([budget.tag]),
  ];

  List<Widget> _financeCategory(FinanceCategory category) => [
    Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [
        for (final tag in category.tags)
          TagChip(tag: tag, colorValue: category.colorValue),
      ],
    ),
  ];

  List<Widget> _goal(BuildContext context, SavingsGoal goal) {
    final target = goal.targetDate;
    return [
      Text(
        '${formatCents(goal.targetCents)} goal',
        style: Theme.of(
          context,
        ).textTheme.headlineSmall?.copyWith(color: Color(goal.colorValue)),
      ),
      if (target != null) ...[
        const SizedBox(height: 8),
        _meta(context, [
          (
            PhosphorIconsRegular.flagCheckered,
            'By ${DateFormat.yMMMd().format(target.toLocal())}',
          ),
        ]),
      ],
      ..._section(context, 'Note', goal.note),
    ];
  }

  List<Widget> _tracker(BuildContext context, StatisticTracker tracker) {
    final type = switch (tracker.type) {
      TrackerType.integer => 'Number',
      TrackerType.boolean => 'Yes / no',
      TrackerType.enumType => 'Choice',
    };
    return [
      _meta(context, [
        (PhosphorIconsRegular.chartLine, type),
        (PhosphorIconsRegular.clock, _capitalized(tracker.cadence.name)),
      ]),
      if (tracker.enumOptions.isNotEmpty) ...[
        const SizedBox(height: 12),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final option in tracker.enumOptions)
              TagChip(tag: option, colorValue: tracker.colorValue),
          ],
        ),
      ],
    ];
  }

  List<Widget> _exercise(
    BuildContext context,
    WidgetRef ref,
    Exercise exercise,
  ) {
    final unit = _weightUnit(ref);
    final weight = unit.formatDisplay(
      unit.fromKilograms(exercise.targetWeightKg),
    );
    return [
      _meta(context, [
        (
          PhosphorIconsRegular.barbell,
          '${exercise.targetSets} × ${exercise.targetReps} @ '
              '$weight ${unit.label}',
        ),
      ]),
      ..._section(context, 'Form cues', exercise.formCues),
    ];
  }

  List<Widget> _workout(
    BuildContext context,
    WidgetRef ref,
    WorkoutSession session,
  ) {
    final theme = Theme.of(context);
    final unit = _weightUnit(ref);
    final live = {
      for (final exercise
          in ref.watch(exercisesProvider).valueOrNull ?? const <Exercise>[])
        exercise.id: exercise.name,
    };
    // An exercise deleted since is still named by its row in the trash.
    String? nameOf(String id) =>
        live[id] ??
        _findDeleted(ref, FirestoreCollections.exercises, id)?.data['name']
            as String?;
    final logs = [
      for (final row in item.members)
        if (row.kind.collection == FirestoreCollections.workoutSetLogs)
          mergeWorkoutSetLogFromRemote(row.data, row.id),
    ];
    logs.sort((a, b) {
      final byExercise = a.exerciseOrder.compareTo(b.exerciseOrder);
      return byExercise != 0 ? byExercise : a.setIndex.compareTo(b.setIndex);
    });
    final byExercise = <String, List<WorkoutSetLog>>{};
    for (final log in logs) {
      byExercise.putIfAbsent(log.exerciseId, () => []).add(log);
    }
    final started = session.startedAt.toLocal();
    final ended = session.endedAt?.toLocal();
    return [
      _meta(context, [
        (
          PhosphorIconsRegular.clock,
          ended == null
              ? 'Started ${formatTime12Hour(started)}'
              : '${formatTime12Hour(started)} – ${formatTime12Hour(ended)}',
        ),
      ]),
      for (final MapEntry(key: exerciseId, value: sets)
          in byExercise.entries) ...[
        const SizedBox(height: 12),
        Text(
          nameOf(exerciseId) ?? 'Exercise',
          style: theme.textTheme.titleSmall,
        ),
        for (final log in sets)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Row(
              children: [
                Icon(
                  log.completed
                      ? PhosphorIconsRegular.checkCircle
                      : PhosphorIconsRegular.circle,
                  size: 16,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: 8),
                Text(
                  'Set ${log.setIndex + 1} · '
                  '${unit.formatDisplay(unit.fromKilograms(log.weightKg))} '
                  '${unit.label} × ${log.reps}',
                ),
              ],
            ),
          ),
      ],
    ];
  }

  List<Widget> _bucketItem(BuildContext context, BucketListItem bucket) {
    final completedAt = bucket.completedAt;
    return [
      _meta(context, [
        if (!bucket.completed)
          (PhosphorIconsRegular.circle, 'Not done yet')
        else if (completedAt == null)
          (PhosphorIconsRegular.checkCircle, 'Done')
        else
          (
            PhosphorIconsRegular.checkCircle,
            'Done ${DateFormat.yMMMd().format(completedAt.toLocal())}',
          ),
      ]),
      ..._section(context, 'Note', bucket.note),
    ];
  }

  // --- Shared pieces --------------------------------------------------------

  /// A row in the trash: one this delete took, or any other deleted row.
  TrashRow? _findDeleted(WidgetRef ref, String collection, String id) {
    if (group.find(collection, id) case final row?) return row;
    for (final other
        in ref.watch(trashItemsProvider).valueOrNull ?? const <TrashItem>[]) {
      for (final row in other.members.followedBy([other.row])) {
        if (row.kind.collection == collection && row.id == id) return row;
      }
    }
    return null;
  }

  WeightUnit _weightUnit(WidgetRef ref) =>
      ref.watch(settingsProvider).valueOrNull?.weightUnit ?? WeightUnit.lb;

  TextStyle? _labelStyle(BuildContext context) {
    final theme = Theme.of(context);
    return theme.textTheme.labelMedium?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
  }

  Widget _meta(BuildContext context, List<(IconData, String)> lines) {
    final theme = Theme.of(context);
    final style = theme.textTheme.bodyMedium?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    return Wrap(
      spacing: 16,
      runSpacing: 6,
      children: [
        for (final (icon, text) in lines)
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 16, color: style?.color),
              const SizedBox(width: 6),
              Flexible(child: Text(text, style: style)),
            ],
          ),
      ],
    );
  }

  Widget _italic(BuildContext context, String text) {
    final theme = Theme.of(context);
    return Text(
      text,
      style: theme.textTheme.bodyMedium?.copyWith(
        fontStyle: FontStyle.italic,
        color: theme.colorScheme.onSurfaceVariant,
      ),
    );
  }

  List<Widget> _prose(BuildContext context, String text) => [
    if (text.trim().isNotEmpty) ...[
      const SizedBox(height: 12),
      VoyagerProseText(text, style: Theme.of(context).textTheme.bodyLarge),
    ],
  ];

  List<Widget> _section(BuildContext context, String label, String? text) => [
    if (text != null && text.trim().isNotEmpty) ...[
      const SizedBox(height: 16),
      Text(label, style: _labelStyle(context)),
      const SizedBox(height: 4),
      VoyagerProseText(text, style: Theme.of(context).textTheme.bodyMedium),
    ],
  ];

  List<Widget> _tags(List<String> tags) => [
    if (tags.isNotEmpty) ...[
      const SizedBox(height: 12),
      Wrap(
        spacing: 6,
        runSpacing: 6,
        children: [for (final tag in tags) TagChip(tag: tag)],
      ),
    ],
  ];

  Widget _code(BuildContext context, String code) {
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(8),
      ),
      child: SelectableText(
        code,
        style: theme.textTheme.bodySmall?.copyWith(
          fontFamily: AppFonts.monoFamily,
        ),
      ),
    );
  }

  String _dueLabel(DateTime due) {
    final local = due.toLocal();
    // Midnight is the app-wide "date only" sentinel.
    if (local.hour == 0 && local.minute == 0) {
      return 'Due ${DateFormat.yMMMd().format(local)}';
    }
    return 'Due ${DateFormat.yMMMd().format(local)} · ${formatTime12Hour(due)}';
  }

  String _capitalized(String s) =>
      s.isEmpty ? s : '${s[0].toUpperCase()}${s.substring(1)}';
}

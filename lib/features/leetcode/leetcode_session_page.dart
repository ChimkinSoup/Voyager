import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/session_resume/session_checkpoint.dart';
import 'package:voyager/core/session_resume/session_checkpoint_controller.dart';
import 'package:voyager/core/session_resume/session_checkpoint_store.dart';
import 'package:voyager/core/session_resume/session_resume_toast.dart';
import 'package:voyager/core/utils/live_snapshot.dart';
import 'package:voyager/core/widgets/context_menu.dart';
import 'package:voyager/core/widgets/glass_button.dart';
import 'package:voyager/domain/models/leetcode_models.dart';
import 'package:voyager/domain/models/study_models.dart';
import 'package:voyager/domain/services/leetcode_srs_engine.dart';
import 'package:voyager/features/leetcode/leetcode_actions.dart';
import 'package:voyager/features/leetcode/leetcode_detail_view.dart';
import 'package:voyager/features/leetcode/leetcode_flashcard.dart';
import 'package:voyager/features/leetcode/leetcode_cheat_entry.dart';
import 'package:voyager/features/leetcode/leetcode_cheat_providers.dart';
import 'package:voyager/features/leetcode/leetcode_scratch_draft.dart';
import 'package:voyager/features/leetcode/leetcode_scratch_host.dart';
import 'package:voyager/features/study/study_flip_card.dart';
import 'package:voyager/features/study/study_grading_row.dart';
import 'package:voyager/features/study/study_history_controls.dart';
import 'package:voyager/features/study/study_keyboard_shortcuts.dart';

/// Distraction-free SRS review of the problems that are due: just the active
/// flashcard and its grading buttons. Grading persists the problem's new
/// interval/ease; a problem graded back to a same-day interval (Fail, or Hard
/// while still new) re-queues to the end of this session so it can be tried
/// again before the session ends.
///
/// Same shape as the Study page's session, minus the review log — a problem
/// carries its schedule on its own row, so there's no separate history to
/// write.
class LeetCodeSessionPage extends ConsumerStatefulWidget {
  const LeetCodeSessionPage({super.key, required this.problemIds});

  /// The problems the Review Deck was showing when the session started, so a
  /// filtered deck studies exactly what it had on screen.
  final Set<String> problemIds;

  @override
  ConsumerState<LeetCodeSessionPage> createState() =>
      _LeetCodeSessionPageState();
}

/// One graded problem, kept so the session can walk back to it.
///
/// The whole queue is snapshotted either side of the grade rather than just
/// the problem: that is what makes a failed problem's re-queue undoable — the
/// copy appended to the end of the round goes away with the arrangement it
/// arrived in, and comes back with it on a redo.
class _GradeStep {
  const _GradeStep({
    required this.before,
    required this.after,
    required this.log,
    required this.queueBefore,
    required this.queueAfter,
  });

  /// The problem's SRS state on either side of the grade.
  final LeetCodeProblem before;
  final LeetCodeProblem after;

  /// The row the grade appended to the review log, taken back on an undo and
  /// revived on a redo — so a grade given, taken back and then abandoned stops
  /// being counted on the activity chart.
  final LeetCodeReviewLog log;

  final List<LeetCodeProblem> queueBefore;
  final List<LeetCodeProblem> queueAfter;
}

class _LeetCodeSessionPageState extends ConsumerState<LeetCodeSessionPage>
    with LeetCodeScratchHost {
  final _flipController = StudyFlipController();

  @override
  Set<String> get scratchProblemIds => widget.problemIds;

  @override
  LeetCodeProblem? get scratchCurrentProblem {
    final queue = _queue;
    return queue == null || queue.isEmpty ? null : queue.first;
  }

  /// The card's on-screen rect, so the detail view can grow out of it the way
  /// it grows out of a tapped tile in the deck.
  final _cardKey = GlobalKey();

  List<LeetCodeProblem>? _queue;
  bool _showingBack = false;
  bool _grading = false;

  /// Grades given this session, and the ones taken back off it. Redo only ever
  /// replays a grade out of [_undone], so the session can never run ahead of
  /// the furthest problem it has actually reached.
  final _graded = <_GradeStep>[];
  final _undone = <_GradeStep>[];

  late final SessionCheckpointController _checkpoint;

  @override
  SessionCheckpointController get sessionCheckpoint => _checkpoint;

  /// The problems in scope the last time the round was built. What is due now
  /// and missing from here came due while the session was away, and joins the
  /// tail of the round rather than its middle.
  final _sourceIds = <String>{};

  /// The unfinished run the slot was holding when the page opened, kept until
  /// the problems arrive and it can be hydrated.
  SessionCheckpoint? _restored;

  /// Whether the slot has been read. The queue waits for it: building a fresh
  /// round first and replacing it a frame later would put a card up in front
  /// of the user and then take it away again.
  bool _checkpointRead = false;

  @override
  void initState() {
    super.initState();
    _checkpoint = SessionCheckpointController(
      store: ref.read(sessionCheckpointStoreProvider),
      kind: SessionCheckpointKind.leetcodeStudy,
      // One slot for Study, whatever the Review Deck was filtered to: the
      // filter decides what is eligible, not which session this is.
      scopeKey: '',
      build: _buildCheckpoint,
    );
    _checkpoint.load().then((restored) {
      if (!mounted) return;
      setState(() {
        _restored = restored;
        _checkpointRead = true;
      });
    });
  }

  @override
  void dispose() {
    // Disposal is every incomplete exit there is: the X button, Back to deck,
    // a route pop, the app being closed. Fired rather than awaited — the
    // store chains its writes, so this lands even though the page is gone.
    _checkpoint.flush();
    _checkpoint.dispose();
    super.dispose();
  }

  /// The session as it stands, or null when there is nothing to come back to.
  ///
  /// An empty queue is the completion screen, and a session that reached it is
  /// finished: the slot is cleared rather than written, which is what takes
  /// the scratch pads with it. Undoing back off that screen re-queues a
  /// problem, so the very next write puts the checkpoint back.
  SessionCheckpoint? _buildCheckpoint() {
    final queue = _queue;
    if (queue == null || queue.isEmpty) return null;
    return _checkpoint.envelope(
      sourceIds: _sourceIds,
      remainingQueue: [for (final problem in queue) problem.id],
      graded: [for (final step in _graded) _dtoFor(step)],
      undone: [for (final step in _undone) _dtoFor(step)],
      scratch: scratchSnapshot?.toJson(),
    );
  }

  GradeStepDto _dtoFor(_GradeStep step) => GradeStepDto(
    before: step.before.toJson(),
    after: step.after.toJson(),
    log: step.log.toJson(),
    // Ids, not rows: the arrangement a step steps back into is resolved
    // against live problems on the way in, so an edit made while the session
    // was away shows up there too.
    queueBefore: [for (final problem in step.queueBefore) problem.id],
    queueAfter: [for (final problem in step.queueAfter) problem.id],
  );

  /// Opens on everything due within the deck's filter, shuffled — what a
  /// session with no checkpoint behind it does, and what Start over goes back
  /// to.
  void _startFresh(List<LeetCodeProblem> all) {
    final queue = dueLeetCodeProblems(
      all.where((p) => widget.problemIds.contains(p.id)),
      random: ref.read(sessionShuffleRandomProvider),
    );
    _sourceIds
      ..clear()
      ..addAll([for (final problem in queue) problem.id]);
    _queue = queue;
  }

  /// Rebuilds the round the user left, against the problems as they now
  /// stand. False when nothing usable is left in it, which opens a fresh
  /// session instead.
  bool _hydrate(SessionCheckpoint checkpoint, List<LeetCodeProblem> all) {
    // Scoped to the deck's current filter: a problem it is no longer
    // showing is not part of the round it comes back to, whatever the file
    // says. With no overlap at all the round comes back empty, which opens a
    // fresh session instead.
    final byId = {
      for (final problem in all)
        if (widget.problemIds.contains(problem.id)) problem.id: problem,
    };
    final remaining = [for (final id in checkpoint.remainingQueue) ?byId[id]];
    // Every problem the session had left has gone. The grades it made are
    // already on disk, so there is no run here to come back to — only a file.
    if (remaining.isEmpty) {
      _checkpoint.discard();
      return false;
    }

    final known = {...checkpoint.sourceIds, ...checkpoint.remainingQueue};
    final due = dueLeetCodeProblems(
      all.where((p) => widget.problemIds.contains(p.id)),
      random: ref.read(sessionShuffleRandomProvider),
    );
    final newcomers = [
      for (final problem in due)
        if (!known.contains(problem.id)) problem,
    ];

    List<LeetCodeProblem> resolve(List<String> ids) => [
      for (final id in ids) ?byId[id],
      // Problems that came due while the session was away belong to the tail
      // of every arrangement it can step back into, not only the current one:
      // a snapshot without them would drop them again on the first undo.
      ...newcomers,
    ];

    List<_GradeStep> steps(List<GradeStepDto> dtos) => [
      for (final dto in dtos)
        // A step whose problem has been deleted has nothing left to put a
        // rating back on, so it is not a step this session can take.
        if (byId.containsKey(dto.id))
          _GradeStep(
            before: LeetCodeProblem.fromJson(dto.before),
            after: LeetCodeProblem.fromJson(dto.after),
            log: LeetCodeReviewLog.fromJson(dto.log),
            queueBefore: resolve(dto.queueBefore),
            queueAfter: resolve(dto.queueAfter),
          ),
    ];

    _queue = [...remaining, ...newcomers];
    _graded
      ..clear()
      ..addAll(steps(checkpoint.graded));
    _undone
      ..clear()
      ..addAll(steps(checkpoint.undone));
    _sourceIds
      ..clear()
      ..addAll(checkpoint.sourceIds)
      ..addAll([for (final problem in due) problem.id])
      ..addAll([for (final problem in _queue!) problem.id]);
    if (checkpoint.scratch case final scratch?) {
      primeScratch(LeetCodeScratchSession.fromJson(scratch));
    }
    // The reconciled round, written back before the user touches it.
    _checkpoint.flush();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      showSessionResumeToast(
        context,
        remaining: _queue?.length ?? 0,
        onStartOver: _startOver,
      );
    });
    return true;
  }

  /// Throws the restored run away and opens the session the user would have
  /// had without it: everything due under live SRS, newcomers included,
  /// freshly shuffled, with empty pads. Grades already committed stay
  /// committed.
  Future<void> _startOver() async {
    await _checkpoint.discard();
    if (!mounted) return;
    resetScratch();
    setState(() {
      _clearHistory();
      _startFresh(ref.read(leetcodeProblemsProvider).valueOrNull ?? const []);
      _showingBack = false;
    });
    _flipController.showFront();
    _checkpoint.persist();
  }

  void _syncQueue(List<LeetCodeProblem> all) {
    final queue = _queue;
    if (queue == null) {
      if (!_checkpointRead) return;
      final restored = _restored;
      _restored = null;
      if (restored != null && _hydrate(restored, all)) return;
      _startFresh(all);
      return;
    }
    // The queue is a snapshot taken when the session opened. An edit made
    // from the card's own menu — or from the detail view behind its title —
    // lands in the provider, so re-read the queue from there instead of
    // going on showing the pre-edit copy.
    _queue = refreshFromLive(queue, all);
    retainScratch({for (final problem in all) problem.id});
  }

  void _handleFlip() => _flipController.flip();

  void _openDetail(LeetCodeProblem problem) {
    final box = _cardKey.currentContext?.findRenderObject() as RenderBox?;
    final rect = box == null
        ? Offset.zero & MediaQuery.sizeOf(context)
        : box.localToGlobal(Offset.zero) & box.size;
    openLeetCodeDetailView(context, problem, rect);
  }

  /// Forgets the problem's schedule and moves the session on. The reset
  /// problem is due immediately, so it goes to the back of the queue rather
  /// than out of the session — the same place a failed grade puts it.
  Future<void> _resetAndAdvance() async {
    final queue = _queue;
    if (queue == null || queue.isEmpty || _grading) return;
    final current = queue.first;
    setState(() => _grading = true);

    final reset = await resetLeetCodeProgress(ref, current);
    if (!mounted) return;

    setState(() {
      final next = [...?_queue]..removeWhere((p) => p.id == current.id);
      _queue = [...next, reset];
      _showingBack = false;
      _grading = false;
      _clearHistory();
    });
    _flipController.showFront();
    _checkpoint.persist();
  }

  /// Forgetting a problem's schedule, or removing it outright, rearranges the
  /// round underneath every step already taken — so those steps stop being
  /// replayable and the history starts again from here.
  void _clearHistory() {
    _graded.clear();
    _undone.clear();
  }

  /// Deleting the problem takes it out of the session too — there is nothing
  /// left to grade.
  Future<void> _deleteAndAdvance() async {
    final queue = _queue;
    if (queue == null || queue.isEmpty || _grading) return;
    final current = queue.first;

    final deleted = await deleteLeetCodeProblem(context, ref, current);
    if (!mounted || !deleted) return;

    setState(() {
      _queue = [...?_queue]..removeWhere((p) => p.id == current.id);
      _showingBack = false;
      _clearHistory();
    });
    _flipController.showFront();
    _checkpoint.persist();
  }

  Future<void> _grade(StudyGrade grade) async {
    final queue = _queue;
    if (queue == null || queue.isEmpty || _grading) return;
    setState(() => _grading = true);

    final current = queue.first;
    flushScratch();
    final result = await gradeAndSaveLeetCodeProblem(ref, current, grade);
    final graded = result.problem;
    if (!mounted) return;

    setState(() {
      final next = [...queue]..removeAt(0);
      if (graded.interval <= 0) next.add(graded);
      _queue = next;
      _showingBack = false;
      _grading = false;
      _graded.add(
        _GradeStep(
          before: current,
          after: graded,
          log: result.log,
          queueBefore: queue,
          queueAfter: next,
        ),
      );
      // Grading a problem the user had stepped back to is a new answer, and
      // the old one it replaces is no longer anywhere the session can return
      // to.
      _undone.clear();
    });
    _flipController.showFront();
    _checkpoint.persist();
  }

  bool get _canUndo => _graded.isNotEmpty && !_grading;
  bool get _canRedo => _undone.isNotEmpty && !_grading;

  /// Steps back to the problem graded last, putting its schedule back exactly
  /// as it stood before the grade — and taking back the [LeetCodeReviewLog]
  /// row that grade wrote, so the activity chart and the schedule agree even
  /// for a grade that is undone and then abandoned by leaving the session.
  Future<void> _undo() => _replay(_graded, _undone, forward: false);

  /// Steps forward again into a grade that was taken back, restoring the very
  /// rating that was given rather than asking for a new one.
  Future<void> _redo() => _replay(_undone, _graded, forward: true);

  Future<void> _replay(
    List<_GradeStep> from,
    List<_GradeStep> to, {
    required bool forward,
  }) async {
    if (from.isEmpty || _grading) return;
    final step = from.last;

    final live = _liveProblem(step.after.id);
    if (live == null) {
      // Deleted since it was graded: there is no problem left to put the
      // rating back on, so the step is dropped rather than replayed.
      setState(() => from.removeLast());
      return;
    }

    setState(() => _grading = true);
    final restored = restoreLeetCodeProblemSrs(
      live,
      forward ? step.after : step.before,
    );
    await ref.read(leetCodeRepositoryProvider).upsertProblem(restored);
    ref.read(remoteSyncServiceProvider).pushLeetCodeProblem(restored);
    await replayLeetCodeReviewLog(ref, step.log, forward: forward);
    if (!mounted) return;

    setState(() {
      to.add(from.removeLast());
      _queue = forward ? step.queueAfter : step.queueBefore;
      _showingBack = false;
      _grading = false;
    });
    _flipController.showFront();
    _checkpoint.persist();

    ref.invalidate(leetcodeProblemsProvider);
  }

  /// The repository's current copy of [id], or null once the problem has been
  /// deleted out from under the session.
  LeetCodeProblem? _liveProblem(String id) {
    for (final problem
        in ref.read(leetcodeProblemsProvider).valueOrNull ?? const []) {
      if (problem.id == id) return problem;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    syncScratch();
    final problems = ref.watch(leetcodeProblemsProvider).valueOrNull;
    if (problems != null) _syncQueue(problems);
    final queue = _queue;

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: SafeArea(
        child: queue == null
            ? const Center(child: CircularProgressIndicator())
            // Wrapped even once the queue empties, so the last problem graded
            // can still be taken back from the completion screen — which is
            // where a misgrade on the final card is noticed.
            : StudyKeyboardShortcuts(
                onSpace: _handleFlip,
                showingBack: _showingBack,
                onGrade: queue.isEmpty ? null : _grade,
                onUndo: _canUndo ? _undo : null,
                onRedo: _canRedo ? _redo : null,
                onFocusScratch: scratchEnabled ? focusScratch : null,
                arrowsNavigateHistory: true,
                // Watched, not read: the sheet's route sits above this one on
                // the root navigator, so nothing else here rebuilds when it
                // opens — and the grading row below has to dim with it.
                suppressed: ref.watch(leetCodeCheatSheetOpenProvider),
                child: queue.isEmpty
                    ? _SessionComplete(
                        onDone: () => Navigator.of(context).pop(),
                        onUndo: _canUndo ? _undo : null,
                      )
                    : Padding(
                        padding: const EdgeInsets.all(24),
                        child: Column(
                          children: [
                            Row(
                              children: [
                                IconButton(
                                  onPressed: () => Navigator.of(context).pop(),
                                  icon: const Icon(PhosphorIconsRegular.x),
                                ),
                                // Balances the three buttons on the right, so
                                // the counter stays centred.
                                const SizedBox(width: 96),
                                const Spacer(),
                                _SessionCounter(queue: queue),
                                const Spacer(),
                                const LeetCodeCheatSheetIconButton(),
                                StudyHistoryControls(
                                  onUndo: _canUndo ? _undo : null,
                                  onRedo: _canRedo ? _redo : null,
                                ),
                              ],
                            ),
                            Expanded(
                              // The card takes the whole space the session
                              // frees up, capped so a very large or very tall
                              // window does not stretch it out of card
                              // proportions — and shares that space with the
                              // scratch pad when the session has one.
                              child: buildScratchArea(
                                cardKey: _cardKey,
                                // The same menu a tile in the deck gives, so a
                                // problem is the same object here as it is
                                // there — only Reset progress differs, moving
                                // the session on as well.
                                card: ContextMenuRegion(
                                  itemsBuilder: () => leetCodeProblemMenuItems(
                                    context: context,
                                    ref: ref,
                                    problem: queue.first,
                                    onOpenDetail: () =>
                                        _openDetail(queue.first),
                                    onResetProgress: _resetAndAdvance,
                                    onDelete: _deleteAndAdvance,
                                  ),
                                  child: LeetCodeFlashcard(
                                    // Keyed by problem so the next card comes
                                    // up as its own card rather than the
                                    // previous card's content swapped
                                    // underneath.
                                    key: ValueKey(queue.first.id),
                                    problem: queue.first,
                                    controller: _flipController,
                                    // Grading is allowed the moment the card
                                    // starts turning, so a key pressed during
                                    // the flip animation still registers.
                                    notifyFlipOnStart: true,
                                    onFlipChanged: (back) =>
                                        setState(() => _showingBack = back),
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(height: 24),
                            StudyGradingRow(
                              interval: queue.first.interval,
                              ease: queue.first.ease,
                              enabled:
                                  _showingBack &&
                                  !_grading &&
                                  !scratchHasSessionInput,
                              // A graded card snaps to its front instead of
                              // turning, so the buttons snap dim with it; flipping
                              // back animates, so they fade out alongside it.
                              snapDim: _grading,
                              onGrade: _grade,
                            ),
                          ],
                        ),
                      ),
              ),
      ),
    );
  }
}

class _SessionCounter extends StatelessWidget {
  const _SessionCounter({required this.queue});

  final List<LeetCodeProblem> queue;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final newCount = queue.where((p) => p.isNew).length;
    final learning = queue.where((p) => !p.isNew && p.isLearning).length;
    final review = queue.length - newCount - learning;

    Widget chip(String label, int count, Color color) => Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6),
      child: Text(
        '$label $count',
        style: theme.textTheme.labelMedium?.copyWith(
          color: color,
          fontWeight: FontWeight.w600,
        ),
      ),
    );

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        chip(
          'New',
          newCount,
          theme.colorScheme.onSurface.withValues(alpha: 0.5),
        ),
        chip('Learning', learning, const Color(0xFFE0A63A)),
        chip('Review', review, const Color(0xFF5C8BE0)),
      ],
    );
  }
}

class _SessionComplete extends StatelessWidget {
  const _SessionComplete({required this.onDone, this.onUndo});

  final VoidCallback onDone;

  /// Steps back into the session for the problem graded last — null when
  /// there is nothing to step back to.
  final VoidCallback? onUndo;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final onUndo = this.onUndo;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            PhosphorIconsRegular.checkCircle,
            size: 48,
            color: theme.colorScheme.primary,
          ),
          const SizedBox(height: 16),
          Text('Session complete', style: theme.textTheme.titleLarge),
          const SizedBox(height: 20),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (onUndo != null) ...[
                GlassButton(onPressed: onUndo, label: 'Previous card'),
                const SizedBox(width: 12),
              ],
              GlassButton(onPressed: onDone, label: 'Back to deck'),
            ],
          ),
        ],
      ),
    );
  }
}

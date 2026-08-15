import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/utils/live_snapshot.dart';
import 'package:voyager/core/widgets/context_menu.dart';
import 'package:voyager/core/widgets/glass_button.dart';
import 'package:voyager/domain/models/leetcode_models.dart';
import 'package:voyager/domain/models/study_models.dart';
import 'package:voyager/domain/services/leetcode_srs_engine.dart';
import 'package:voyager/features/leetcode/leetcode_actions.dart';
import 'package:voyager/features/leetcode/leetcode_detail_view.dart';
import 'package:voyager/features/leetcode/leetcode_flashcard.dart';
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
    required this.queueBefore,
    required this.queueAfter,
  });

  /// The problem's SRS state on either side of the grade.
  final LeetCodeProblem before;
  final LeetCodeProblem after;

  final List<LeetCodeProblem> queueBefore;
  final List<LeetCodeProblem> queueAfter;
}

class _LeetCodeSessionPageState extends ConsumerState<LeetCodeSessionPage> {
  final _flipController = StudyFlipController();

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

  void _syncQueue(List<LeetCodeProblem> all) {
    final queue = _queue;
    if (queue == null) {
      _queue = dueLeetCodeProblems(
        all.where((p) => widget.problemIds.contains(p.id)),
      );
      return;
    }
    // The queue is a snapshot taken when the session opened. An edit made
    // from the card's own menu — or from the detail view behind its title —
    // lands in the provider, so re-read the queue from there instead of
    // going on showing the pre-edit copy.
    _queue = refreshFromLive(queue, all);
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
  }

  Future<void> _grade(StudyGrade grade) async {
    final queue = _queue;
    if (queue == null || queue.isEmpty || _grading) return;
    setState(() => _grading = true);

    final current = queue.first;
    final graded = await gradeAndSaveLeetCodeProblem(ref, current, grade);
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
  }

  bool get _canUndo => _graded.isNotEmpty && !_grading;
  bool get _canRedo => _undone.isNotEmpty && !_grading;

  /// Steps back to the problem graded last, putting its schedule back exactly
  /// as it stood before the grade.
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
    if (!mounted) return;

    setState(() {
      to.add(from.removeLast());
      _queue = forward ? step.queueAfter : step.queueBefore;
      _showingBack = false;
      _grading = false;
    });
    _flipController.showFront();

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
                arrowsNavigateHistory: true,
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
                                // Balances the two history buttons on the right, so
                                // the counter stays centred.
                                const SizedBox(width: 48),
                                const Spacer(),
                                _SessionCounter(queue: queue),
                                const Spacer(),
                                StudyHistoryControls(
                                  onUndo: _canUndo ? _undo : null,
                                  onRedo: _canRedo ? _redo : null,
                                ),
                              ],
                            ),
                            Expanded(
                              child: Center(
                                child: LayoutBuilder(
                                  // The card takes the whole space the session frees
                                  // up, capped so a very large or very tall window
                                  // does not stretch it out of card proportions.
                                  builder: (context, constraints) => SizedBox(
                                    key: _cardKey,
                                    width: math.min(constraints.maxWidth, 760),
                                    height: math.min(
                                      constraints.maxHeight,
                                      720,
                                    ),
                                    // The same menu a tile in the deck gives, so a
                                    // problem is the same object here as it is
                                    // there — only Reset progress differs, moving
                                    // the session on as well.
                                    child: ContextMenuRegion(
                                      itemsBuilder: () =>
                                          leetCodeProblemMenuItems(
                                            context: context,
                                            ref: ref,
                                            problem: queue.first,
                                            onOpenDetail: () =>
                                                _openDetail(queue.first),
                                            onResetProgress: _resetAndAdvance,
                                            onDelete: _deleteAndAdvance,
                                          ),
                                      child: LeetCodeFlashcard(
                                        // Keyed by problem so the next card comes up
                                        // as its own card rather than the previous
                                        // one's content swapped underneath.
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
                              ),
                            ),
                            const SizedBox(height: 24),
                            StudyGradingRow(
                              interval: queue.first.interval,
                              ease: queue.first.ease,
                              enabled: _showingBack && !_grading,
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

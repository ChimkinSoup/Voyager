import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/theme/voyager_theme.dart';
import 'package:voyager/core/utils/ids.dart';
import 'package:voyager/core/utils/live_snapshot.dart';
import 'package:voyager/core/widgets/context_menu.dart';
import 'package:voyager/core/widgets/glass_button.dart';
import 'package:voyager/core/widgets/voyager_scroll_view.dart';
import 'package:voyager/domain/models/study_models.dart';
import 'package:voyager/domain/services/study_srs_engine.dart';
import 'package:voyager/features/study/study_actions.dart';
import 'package:voyager/features/study/study_card_editor_modal.dart';
import 'package:voyager/features/study/study_flip_card.dart';
import 'package:voyager/features/study/study_grading_row.dart';
import 'package:voyager/features/study/study_history_controls.dart';
import 'package:voyager/features/study/study_keyboard_shortcuts.dart';
import 'package:voyager/features/study/study_rich_text.dart';

/// Distraction-free full-screen SRS review: only the active flashcard and
/// its grading buttons — no roster, no admin chrome. Grading a card
/// persists its new interval/ease and logs a real review event; a card
/// re-graded back to a same-day interval (Fail, or Hard while still new)
/// re-queues to the end of this session so it can be tried again before
/// the session ends.
/// Sessions are built from a set of card ids rather than a deck so the Hub
/// can review everything due across the whole library in one sitting; a deck
/// opens one by handing over its own roster.
class StudySessionPage extends ConsumerStatefulWidget {
  const StudySessionPage({super.key, required this.cardIds});

  /// The cards in scope for this session. Which of them are actually due is
  /// decided when the queue is built.
  final Set<String> cardIds;

  @override
  ConsumerState<StudySessionPage> createState() => _StudySessionPageState();
}

/// One graded card, kept so the session can walk back to it.
///
/// The whole queue is snapshotted either side of the grade rather than just
/// the card: that is what makes a failed card's re-queue undoable — the copy
/// appended to the end of the round goes away with the arrangement it arrived
/// in, and comes back with it on a redo.
class _GradeStep {
  const _GradeStep({
    required this.before,
    required this.after,
    required this.queueBefore,
    required this.queueAfter,
  });

  /// The card's SRS state on either side of the grade.
  final StudyCard before;
  final StudyCard after;

  final List<StudyCard> queueBefore;
  final List<StudyCard> queueAfter;
}

class _StudySessionPageState extends ConsumerState<StudySessionPage> {
  final _flipController = StudyFlipController();
  List<StudyCard>? _queue;
  bool _showingBack = false;
  bool _grading = false;

  /// Grades given this session, and the ones taken back off it. Redo only ever
  /// replays a grade out of [_undone], so the session can never run ahead of
  /// the furthest card it has actually reached.
  final _graded = <_GradeStep>[];
  final _undone = <_GradeStep>[];

  void _syncQueue(List<StudyCard> allCards) {
    final queue = _queue;
    if (queue == null) {
      final now = DateTime.now().toUtc();
      _queue =
          allCards
              .where(
                (c) => widget.cardIds.contains(c.id) && !c.dueAt.isAfter(now),
              )
              .toList()
            ..sort((a, b) => a.dueAt.compareTo(b.dueAt));
      return;
    }
    // The queue is a snapshot taken when the session opened. An edit, reverse
    // or delete made from the card's own menu lands in the provider, so
    // re-read the queue from there instead of going on showing the pre-edit
    // copy.
    _queue = refreshFromLive(queue, allCards);
  }

  void _handleFlip() {
    _flipController.flip();
  }

  StudyCard? get _current {
    final queue = _queue;
    return queue == null || queue.isEmpty ? null : queue.first;
  }

  /// Back to the question side, the way a graded card lands — after a reverse
  /// or a reset, whichever face was showing is no longer the one the user
  /// asked to see.
  void _showFront() {
    setState(() => _showingBack = false);
    _flipController.showFront();
  }

  /// The repository's current copy of [id], or null once the card has been
  /// deleted out from under the session.
  StudyCard? _liveCard(String id) {
    for (final card
        in ref.read(studyAllCardsProvider).valueOrNull ?? const []) {
      if (card.id == id) return card;
    }
    return null;
  }

  /// Keyed off the graded card rather than the session, since a Hub session
  /// can span decks and only the one this card belongs to went stale.
  void _invalidateFor(StudyCard card) {
    ref.invalidate(studyCardsProvider(card.deckId));
    ref.invalidate(studyDeckStatsProvider(card.deckId));
    ref.invalidate(studyAllCardsProvider);
    ref.invalidate(studyStatsProvider);
  }

  Future<void> _editCurrent() async {
    final card = _current;
    if (card == null) return;
    await showStudyCardEditorModal(
      context,
      ref,
      deckId: card.deckId,
      existing: card,
    );
  }

  Future<void> _reverseCurrent() async {
    final card = _current;
    if (card == null) return;
    await reverseStudyCard(ref, card);
    if (mounted) _showFront();
  }

  /// Forgets the card's schedule and moves the session on. The reset card is
  /// due immediately, so it goes to the back of the queue rather than out of
  /// the session — the same place a failed grade puts it.
  Future<void> _resetAndAdvance() async {
    final card = _current;
    if (card == null || _grading) return;
    setState(() => _grading = true);

    final reset = await resetStudyCardProgress(ref, card);
    if (!mounted) return;

    setState(() {
      final next = [...?_queue]..removeWhere((c) => c.id == card.id);
      _queue = [...next, reset];
      _showingBack = false;
      _grading = false;
      _clearHistory();
    });
    _flipController.showFront();
  }

  /// Forgetting a card's schedule, or removing it outright, rearranges the
  /// round underneath every step already taken — so those steps stop being
  /// replayable and the history starts again from here.
  void _clearHistory() {
    _graded.clear();
    _undone.clear();
  }

  /// Deleting the card takes it out of the session too — there is nothing
  /// left to grade.
  Future<void> _deleteAndAdvance() async {
    final card = _current;
    if (card == null || _grading) return;

    final deleted = await deleteStudyCard(context, ref, card);
    if (!mounted || !deleted) return;

    setState(() {
      _queue = [...?_queue]..removeWhere((c) => c.id == card.id);
      _clearHistory();
    });
    _showFront();
  }

  Future<void> _grade(StudyGrade grade) async {
    final queue = _queue;
    if (queue == null || queue.isEmpty || _grading) return;
    setState(() => _grading = true);

    final current = queue.first;
    final graded = gradeStudyCard(current, grade);
    final repo = ref.read(studyRepositoryProvider);
    final remoteSync = ref.read(remoteSyncServiceProvider);
    await repo.upsertCard(graded);
    remoteSync.pushStudyCard(graded);
    final log = StudyReviewLog(
      id: newId(),
      cardId: graded.id,
      grade: grade,
      reviewedAt: DateTime.now().toUtc(),
    );
    await repo.logReview(log);
    remoteSync.pushStudyReviewLog(log);

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
      // Grading a card the user had stepped back to is a new answer, and the
      // old one it replaces is no longer anywhere the session can return to.
      _undone.clear();
    });
    _flipController.showFront();

    _invalidateFor(graded);
  }

  bool get _canUndo => _graded.isNotEmpty && !_grading;
  bool get _canRedo => _undone.isNotEmpty && !_grading;

  /// Steps back to the card graded last, putting its schedule back exactly as
  /// it stood before the grade.
  ///
  /// The [StudyReviewLog] row that grade wrote stays: the log is append-only
  /// and has no delete path through sync, so a redo re-writes the same row
  /// rather than a second one, and only a grade taken back and then abandoned
  /// leaves a review counted that the schedule no longer shows.
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

    final live = _liveCard(step.after.id);
    if (live == null) {
      // Deleted since it was graded: there is no card left to put the rating
      // back on, so the step is dropped rather than replayed.
      setState(() => from.removeLast());
      return;
    }

    setState(() => _grading = true);
    final restored = restoreStudyCardSrs(
      live,
      forward ? step.after : step.before,
    );
    await ref.read(studyRepositoryProvider).upsertCard(restored);
    ref.read(remoteSyncServiceProvider).pushStudyCard(restored);
    if (!mounted) return;

    setState(() {
      to.add(from.removeLast());
      _queue = forward ? step.queueAfter : step.queueBefore;
      _showingBack = false;
      _grading = false;
    });
    _flipController.showFront();

    _invalidateFor(restored);
  }

  @override
  Widget build(BuildContext context) {
    final cardsAsync = ref.watch(studyAllCardsProvider);
    final cards = cardsAsync.valueOrNull;
    if (cards != null) _syncQueue(cards);
    final queue = _queue;

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: SafeArea(
        child: queue == null
            ? const Center(child: CircularProgressIndicator())
            // Wrapped even once the queue empties, so the last card graded can
            // still be taken back from the completion screen — which is where
            // a misgrade on the final card is noticed.
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
                                    width: math.min(constraints.maxWidth, 760),
                                    height: math.min(
                                      constraints.maxHeight,
                                      720,
                                    ),
                                    // The same menu a tile in the deck grid gives,
                                    // so a card is the same object here as it is
                                    // there — only Reset progress differs, moving
                                    // the session on as well.
                                    child: ContextMenuRegion(
                                      itemsBuilder: () => studyCardMenuItems(
                                        card: queue.first,
                                        onEdit: _editCurrent,
                                        onReverse: _reverseCurrent,
                                        onResetProgress: _resetAndAdvance,
                                        onDelete: _deleteAndAdvance,
                                      ),
                                      child: StudyFlipCard(
                                        controller: _flipController,
                                        // Grading is allowed the moment the card
                                        // starts turning, so a key pressed during
                                        // the flip animation still registers.
                                        notifyFlipOnStart: true,
                                        onFlipChanged: (back) =>
                                            setState(() => _showingBack = back),
                                        front: _SessionCardFace(
                                          text: queue.first.frontText,
                                          onTap: _handleFlip,
                                        ),
                                        back: _SessionCardFace(
                                          text: queue.first.backText,
                                          accent: true,
                                          onTap: _handleFlip,
                                        ),
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

class _SessionCardFace extends StatelessWidget {
  const _SessionCardFace({
    required this.text,
    required this.onTap,
    this.accent = false,
  });

  final String text;
  final VoidCallback onTap;
  final bool accent;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final vc = VoyagerColors.of(context);
    return Container(
      // Infinities collapse to whatever the session lays out for the card, so
      // the face fills its slot instead of shrink-wrapping short text.
      width: double.infinity,
      height: double.infinity,
      padding: const EdgeInsets.all(36),
      decoration: BoxDecoration(
        color: theme.cardTheme.color ?? theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: vc.strongHairline),
        boxShadow: vc.surfaceShadow(),
      ),
      child: Center(
        child: VoyagerScrollView(
          child: StudyRichText(
            text,
            textAlign: TextAlign.center,
            style: theme.textTheme.headlineMedium?.copyWith(
              color: accent
                  ? theme.colorScheme.primary
                  : theme.colorScheme.onSurface,
            ),
          ),
        ),
      ),
    );
  }
}

class _SessionCounter extends StatelessWidget {
  const _SessionCounter({required this.queue});

  final List<StudyCard> queue;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final newCount = queue.where((c) => c.isNew).length;
    final learning = queue.where((c) => !c.isNew && c.isLearning).length;
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

  /// Steps back into the session for the card graded last — null when there
  /// is nothing to step back to.
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
              // Not "back to deck" — a Hub session spans the whole library and
              // has no single deck to go back to.
              GlassButton(onPressed: onDone, label: 'Done'),
            ],
          ),
        ],
      ),
    );
  }
}

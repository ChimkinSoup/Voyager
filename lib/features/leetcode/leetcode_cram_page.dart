import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/motion/motion.dart';
import 'package:voyager/core/session_resume/session_checkpoint.dart';
import 'package:voyager/core/session_resume/session_checkpoint_controller.dart';
import 'package:voyager/core/session_resume/session_checkpoint_store.dart';
import 'package:voyager/core/session_resume/session_resume_toast.dart';
import 'package:voyager/core/utils/keyboard_focus_utils.dart';
import 'package:voyager/core/utils/live_snapshot.dart';
import 'package:voyager/core/widgets/context_menu.dart';
import 'package:voyager/core/widgets/glass_button.dart';
import 'package:voyager/domain/models/leetcode_models.dart';
import 'package:voyager/domain/services/leetcode_srs_engine.dart';
import 'package:voyager/features/leetcode/leetcode_actions.dart';
import 'package:voyager/features/leetcode/leetcode_detail_view.dart';
import 'package:voyager/features/leetcode/leetcode_flashcard.dart';
import 'package:voyager/features/leetcode/leetcode_cheat_entry.dart';
import 'package:voyager/features/leetcode/leetcode_cheat_providers.dart';
import 'package:voyager/features/leetcode/leetcode_scratch_draft.dart';
import 'package:voyager/features/leetcode/leetcode_scratch_host.dart';
import 'package:voyager/features/study/study_flip_card.dart';
import 'package:voyager/features/study/study_history_controls.dart';
import 'package:voyager/features/study/study_keyboard_shortcuts.dart';

const _kBucketFailColor = Color(0xFFE0714A);
const _kBucketMidColor = Color(0xFFE0A63A);
const _kBucketDoneColor = Color(0xFF4CAF7D);

/// Cram mode for tracked problems: every problem starts in bucket 0
/// (unseen/failed), passing moves it up a bucket, failing drops it back to
/// bucket 0, and the session ends once every problem reaches bucket 2.
/// Purely in-memory — it never touches the problems' persisted SRS state, the
/// same contract the Study page's cram mode keeps.
class LeetCodeCramPage extends ConsumerStatefulWidget {
  const LeetCodeCramPage({super.key, required this.problemIds});

  /// The problems the Review Deck was showing when cram started, so a
  /// filtered deck drills exactly what it had on screen.
  final Set<String> problemIds;

  @override
  ConsumerState<LeetCodeCramPage> createState() => _LeetCodeCramPageState();
}

/// The three buckets as they stood before one decision. Cram writes nothing
/// down, so a decision *is* this arrangement — stepping back to the previous
/// card is putting the arrangement back.
class _CramStep {
  _CramStep(this.bucket0, this.bucket1, this.bucket2);

  final List<String> bucket0;
  final List<String> bucket1;
  final List<String> bucket2;

  /// Drops problems that have been deleted since the step was taken, so a
  /// snapshot can never bring one back.
  void retainOnly(Set<String> ids) {
    for (final bucket in [bucket0, bucket1, bucket2]) {
      bucket.removeWhere((id) => !ids.contains(id));
    }
  }
}

class _LeetCodeCramPageState extends ConsumerState<LeetCodeCramPage>
    with SingleTickerProviderStateMixin, LeetCodeScratchHost {
  @override
  Set<String> get scratchProblemIds => widget.problemIds;

  @override
  LeetCodeProblem? get scratchCurrentProblem => _current;

  /// How far the card's *projected* resting place has to be off centre for
  /// the swipe to count as a decision rather than a nudge.
  static const _commitThreshold = 120.0;

  /// Covers the fade/shrink of the outgoing card, and gates how soon the next
  /// one takes its place.
  static const _exitDuration = Duration(milliseconds: 220);

  final _flipController = StudyFlipController();

  /// The card's on-screen rect, so the detail view can grow out of it the way
  /// it grows out of a tapped tile in the deck.
  final _cardKey = GlobalKey();

  Map<String, LeetCodeProblem>? _problemsById;
  List<String> _bucket0 = [];
  final List<String> _bucket1 = [];
  final List<String> _bucket2 = [];
  bool _showingBack = false;

  /// Decisions made this session, and the ones stepped back off. Redo only
  /// ever replays out of [_undone], so the session can never step forward past
  /// the furthest card it has actually reached.
  final _decided = <_CramStep>[];
  final _undone = <_CramStep>[];

  /// The card's horizontal offset, as a spring rather than a plain double, so
  /// a card that is still travelling can be grabbed and redirected: the drag
  /// picks it up at its live position and a release re-targets from there.
  late final SpringMotion _cardX = SpringMotion(
    vsync: this,
    spring: VoyagerSpring.momentum,
  );
  bool _exiting = false;

  late final SessionCheckpointController _checkpoint;

  @override
  SessionCheckpointController get sessionCheckpoint => _checkpoint;

  /// The problems in scope when the buckets were last built. One that arrived
  /// while the run was away is missing from here, and joins bucket 0 rather
  /// than the bucket its neighbours are in.
  final _sourceIds = <String>{};

  /// The unfinished run the slot was holding when the page opened, kept until
  /// the problems arrive and it can be hydrated.
  SessionCheckpoint? _restored;

  /// Whether the slot has been read. The buckets wait for it rather than
  /// being filled and then replaced a frame later.
  bool _checkpointRead = false;

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_handleArrowKey);
    _checkpoint = SessionCheckpointController(
      store: ref.read(sessionCheckpointStoreProvider),
      kind: SessionCheckpointKind.leetcodeCram,
      // One slot for Cram, whatever the Review Deck was filtered to — and
      // never the one Study left behind.
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
    HardwareKeyboard.instance.removeHandler(_handleArrowKey);
    _cardX.dispose();
    // Disposal is every incomplete exit there is. Fired rather than awaited —
    // the store chains its writes, so this lands even though the page is gone.
    _checkpoint.flush();
    _checkpoint.dispose();
    super.dispose();
  }

  /// The run as it stands, or null when there is nothing to come back to: a
  /// deck emptied out from under it, or every problem mastered. Clearing the
  /// slot is what takes the scratch pads with it.
  SessionCheckpoint? _buildCheckpoint() {
    final held = _problemsById;
    if (held == null || held.isEmpty || _complete) return null;
    return _checkpoint.envelope(
      sourceIds: _sourceIds,
      buckets: _bucketsNow(),
      decided: [for (final step in _decided) _dtoFor(step)],
      undoneCram: [for (final step in _undone) _dtoFor(step)],
      scratch: scratchSnapshot?.toJson(),
    );
  }

  CramBucketsDto _bucketsNow() => CramBucketsDto(
    bucket0: [..._bucket0],
    bucket1: [..._bucket1],
    bucket2: [..._bucket2],
  );

  CramBucketsDto _dtoFor(_CramStep step) => CramBucketsDto(
    bucket0: [...step.bucket0],
    bucket1: [...step.bucket1],
    bucket2: [...step.bucket2],
  );

  /// This run's share of the deck, as the Review Deck had it filtered.
  List<LeetCodeProblem> _pool(List<LeetCodeProblem> problems) => [
    for (final p in problems)
      if (widget.problemIds.contains(p.id)) p,
  ];

  /// Every problem in bucket 0, shuffled — what a run with no checkpoint
  /// behind it does, and what Start over goes back to.
  void _startFresh(List<LeetCodeProblem> problems) {
    final included = orderLeetCodeCramQueue(
      _pool(problems),
      random: ref.read(sessionShuffleRandomProvider),
    );
    _problemsById = {for (final p in included) p.id: p};
    _bucket0 = [for (final p in included) p.id];
    _bucket1.clear();
    _bucket2.clear();
    _sourceIds
      ..clear()
      ..addAll(_bucket0);
  }

  /// Puts the buckets back as the user left them, against the problems as
  /// they now stand. False when there is nothing usable left, which opens a
  /// fresh run instead.
  bool _hydrate(SessionCheckpoint checkpoint, List<LeetCodeProblem> problems) {
    final byId = {for (final p in _pool(problems)) p.id: p};
    final buckets = checkpoint.buckets;
    List<String> surviving(List<String> ids) => [
      for (final id in ids)
        if (byId.containsKey(id)) id,
    ];

    final held0 = surviving(buckets?.bucket0 ?? const []);
    final held1 = surviving(buckets?.bucket1 ?? const []);
    final held2 = surviving(buckets?.bucket2 ?? const []);
    final known = {...checkpoint.sourceIds, ...held0, ...held1, ...held2};
    final newcomers = [
      for (final id in byId.keys)
        if (!known.contains(id)) id,
    ]..shuffle(ref.read(sessionShuffleRandomProvider));

    // Nothing left to decide: the run either finished or lost its deck, and
    // either way there is no round here to come back to.
    if (held0.isEmpty && held1.isEmpty && newcomers.isEmpty) {
      _checkpoint.discard();
      return false;
    }

    // A problem that arrived while the run was away is unseen, which is what
    // bucket 0 means — including in the arrangements an undo steps back into,
    // which would otherwise drop it again.
    _bucket0 = [...held0, ...newcomers];
    _bucket1
      ..clear()
      ..addAll(held1);
    _bucket2
      ..clear()
      ..addAll(held2);
    _problemsById = {
      for (final id in [..._bucket0, ..._bucket1, ..._bucket2]) id: byId[id]!,
    };

    _CramStep restore(CramBucketsDto step) => _CramStep(
      [...surviving(step.bucket0), ...newcomers],
      surviving(step.bucket1),
      surviving(step.bucket2),
    );

    _decided
      ..clear()
      ..addAll([for (final step in checkpoint.decided) restore(step)]);
    _undone
      ..clear()
      ..addAll([for (final step in checkpoint.undoneCram) restore(step)]);
    _sourceIds
      ..clear()
      ..addAll(_problemsById!.keys);
    if (checkpoint.scratch case final scratch?) {
      primeScratch(LeetCodeScratchSession.fromJson(scratch));
    }
    // The reconciled round, written back before the user touches it.
    _checkpoint.flush();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      showSessionResumeToast(
        context,
        remaining: _bucket0.length + _bucket1.length,
        onStartOver: _startOver,
      );
    });
    return true;
  }

  /// Throws the restored run away and drills the deck as it stands now, every
  /// problem back in bucket 0 and the pads empty.
  Future<void> _startOver() async {
    await _checkpoint.discard();
    if (!mounted) return;
    resetScratch();
    setState(() {
      _decided.clear();
      _undone.clear();
      _startFresh(ref.read(leetcodeProblemsProvider).valueOrNull ?? const []);
      _showingBack = false;
    });
    _flipController.showFront();
    _checkpoint.persist();
  }

  /// Far enough that the card is fully clear of the window, whatever its size.
  double get _exitDistance => MediaQuery.sizeOf(context).width;

  /// Overshoot on the way back to centre reads as playful when the user threw
  /// the card and it bounced; under reduced motion it just reads as wobble.
  SpringDescription get _snapBackSpring => VoyagerMotion.reduced(context)
      ? VoyagerSpring.dampen(VoyagerSpring.momentum)
      : VoyagerSpring.momentum;

  void _syncProblems(List<LeetCodeProblem> problems) {
    final held = _problemsById;
    if (held == null) {
      if (!_checkpointRead) return;
      final restored = _restored;
      _restored = null;
      if (restored != null && _hydrate(restored, problems)) return;
      _startFresh(problems);
      return;
    }
    // Same reason a review session re-reads its queue: these problems are a
    // snapshot taken when cram opened, and an edit made from the card's own
    // menu — or from the detail view behind its title — has to show up on the
    // card itself. A deleted problem leaves the buckets with it.
    final fresh = refreshFromLive(held.values, problems);
    _problemsById = {for (final p in fresh) p.id: p};
    final live = _problemsById!.keys.toSet();
    for (final bucket in [_bucket0, _bucket1, _bucket2]) {
      bucket.removeWhere((id) => !live.contains(id));
    }
    for (final step in [..._decided, ..._undone]) {
      step.retainOnly(live);
    }
    retainScratch(live);
  }

  LeetCodeProblem? get _current {
    final id = _bucket0.isNotEmpty
        ? _bucket0.first
        : (_bucket1.isNotEmpty ? _bucket1.first : null);
    return id == null ? null : _problemsById![id];
  }

  bool get _complete =>
      _bucket0.isEmpty && _bucket1.isEmpty && _problemsById != null;

  bool _handleArrowKey(KeyEvent event) {
    if (!mounted) return false;
    final route = ModalRoute.of(context);
    if (route?.isCurrent != true) return false;
    if (isTextInputFocused() || !subtreeIsVisible(context)) return false;
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) return false;

    if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
      _decide(true);
      return true;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
      _decide(false);
      return true;
    }
    return false;
  }

  void _applyDecision(bool passed) {
    final problem = _current;
    if (problem == null) return;
    final id = problem.id;
    if (_bucket0.remove(id)) {
      (passed ? _bucket1 : _bucket0).add(id);
    } else if (_bucket1.remove(id)) {
      (passed ? _bucket2 : _bucket0).add(id);
    }
  }

  /// [velocity] is the release velocity of the swipe that triggered this, in
  /// px/s, so the card leaves at exactly the speed the finger let go at
  /// instead of restarting from a standstill. Zero for the arrow keys and the
  /// pass/fail buttons, which carry no momentum of their own.
  void _decide(bool passed, {double velocity = 0}) {
    if (_current == null || _exiting || scratchHasSessionInput) return;
    flushScratch();
    setState(() => _exiting = true);
    if (VoyagerMotion.reduced(context)) {
      // A card flying the full width of the window is exactly the kind of
      // large travel reduced motion asks us to drop — fade it out in place.
      _cardX.jumpTo(0);
    } else {
      _cardX.animateTo(
        passed ? _exitDistance : -_exitDistance,
        velocity: velocity,
      );
    }
    Future.delayed(_exitDuration, () {
      if (!mounted) return;
      _cardX.jumpTo(0);
      setState(() {
        _decided.add(_snapshot());
        // Deciding a card the user had stepped back to replaces whatever came
        // after it — there is no longer a forward to step into.
        _undone.clear();
        _applyDecision(passed);
        _exiting = false;
        _showingBack = false;
      });
      _flipController.showFront();
      _checkpoint.persist();
    });
  }

  _CramStep _snapshot() =>
      _CramStep([..._bucket0], [..._bucket1], [..._bucket2]);

  void _restore(_CramStep step) {
    _bucket0 = [...step.bucket0];
    _bucket1
      ..clear()
      ..addAll(step.bucket1);
    _bucket2
      ..clear()
      ..addAll(step.bucket2);
  }

  bool get _canUndo => _decided.isNotEmpty && !_exiting;
  bool get _canRedo => _undone.isNotEmpty && !_exiting;

  /// Steps back to the card decided last. Cram holds no rating to put back —
  /// the card simply comes round again, and whatever is done with it this time
  /// is the decision that counts.
  void _undo() => _step(_decided, _undone);

  /// Steps forward again into a decision that was stepped back off, with the
  /// bucket move it made.
  void _redo() => _step(_undone, _decided);

  void _step(List<_CramStep> from, List<_CramStep> to) {
    if (from.isEmpty || _exiting) return;
    setState(() {
      to.add(_snapshot());
      _restore(from.removeLast());
      _showingBack = false;
    });
    _flipController.showFront();
    _checkpoint.persist();
  }

  void _handleFlip() => _flipController.flip();

  void _openDetail(LeetCodeProblem problem) {
    final box = _cardKey.currentContext?.findRenderObject() as RenderBox?;
    final rect = box == null
        ? Offset.zero & MediaQuery.sizeOf(context)
        : box.localToGlobal(Offset.zero) & box.size;
    openLeetCodeDetailView(context, problem, rect);
  }

  /// Cram never writes SRS state of its own, so resetting is purely a write
  /// to the problem's schedule — the card then moves on the way a failed one
  /// does, back to the end of bucket 0.
  Future<void> _resetAndAdvance() async {
    final problem = _current;
    if (problem == null || _exiting) return;
    await resetLeetCodeProgress(ref, problem);
    if (!mounted) return;
    _decide(false);
  }

  Future<void> _deleteCurrent() async {
    final problem = _current;
    if (problem == null || _exiting) return;

    final deleted = await deleteLeetCodeProblem(context, ref, problem);
    if (!mounted || !deleted) return;

    setState(() {
      _problemsById!.remove(problem.id);
      for (final bucket in [_bucket0, _bucket1, _bucket2]) {
        bucket.remove(problem.id);
      }
      _showingBack = false;
    });
    _flipController.showFront();
    _checkpoint.persist();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    syncScratch();
    final problems = ref.watch(leetcodeProblemsProvider).valueOrNull;
    if (problems != null) _syncProblems(problems);

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: SafeArea(
        child: _problemsById == null
            ? const Center(child: CircularProgressIndicator())
            // Wrapped even once every problem is mastered, so the last
            // decision can still be stepped back from the completion screen.
            : StudyKeyboardShortcuts(
                onSpace: _handleFlip,
                showingBack: _showingBack,
                onUndo: _canUndo ? _undo : null,
                onRedo: _canRedo ? _redo : null,
                onFocusScratch: scratchEnabled ? focusScratch : null,
                // See the session page: the sheet's route is above this one on
                // the root navigator, so nothing else rebuilds when it opens.
                suppressed: ref.watch(leetCodeCheatSheetOpenProvider),
                child: _complete
                    ? _CramComplete(
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
                                // the title stays centred.
                                const SizedBox(width: 96),
                                const Spacer(),
                                Text(
                                  'Cram mode',
                                  style: theme.textTheme.titleMedium,
                                ),
                                const Spacer(),
                                const LeetCodeCheatSheetIconButton(),
                                StudyHistoryControls(
                                  onUndo: _canUndo ? _undo : null,
                                  onRedo: _canRedo ? _redo : null,
                                ),
                              ],
                            ),
                            const SizedBox(height: 12),
                            _BucketProgressBar(
                              bucket0: _bucket0.length,
                              bucket1: _bucket1.length,
                              bucket2: _bucket2.length,
                            ),
                            Expanded(
                              // Same sizing as a review session's card: take
                              // the whole free area, capped so a very large or
                              // very tall window keeps card proportions — and
                              // shared with the scratch pad when there is one.
                              child: buildScratchArea(
                                cardKey: _cardKey,
                                card: GestureDetector(
                                  onHorizontalDragUpdate: (details) {
                                    // The pad having the caret means the
                                    // user is typing, not sorting cards —
                                    // and a card that moved under a
                                    // half-written attempt would be a
                                    // decision they never made.
                                    if (_exiting || scratchHasSessionInput) {
                                      return;
                                    }
                                    // Glued to the pointer. Going through the spring
                                    // rather than a plain field means grabbing a card
                                    // that is still springing back picks it up where
                                    // it actually is, with no jump.
                                    _cardX.jumpTo(
                                      _cardX.value + details.delta.dx,
                                    );
                                  },
                                  onHorizontalDragEnd: (details) {
                                    if (_exiting || scratchHasSessionInput) {
                                      return;
                                    }
                                    final velocity =
                                        details.velocity.pixelsPerSecond.dx;
                                    // Decide on where the flick is *heading*, not
                                    // where the finger happened to stop, so a short
                                    // fast throw commits and a long slow drag that
                                    // stalls at the edge does not.
                                    final projected =
                                        _cardX.value +
                                        projectMomentum(velocity);
                                    if (projected.abs() > _commitThreshold) {
                                      _decide(
                                        projected > 0,
                                        velocity: velocity,
                                      );
                                    } else {
                                      _cardX.animateTo(
                                        0,
                                        velocity: velocity,
                                        spring: _snapBackSpring,
                                      );
                                    }
                                  },
                                  child: AnimatedScale(
                                    scale: _exiting ? 0.8 : 1.0,
                                    duration: _exitDuration,
                                    curve: VoyagerSpring.moveCurve,
                                    child: AnimatedOpacity(
                                      opacity: _exiting ? 0.0 : 1.0,
                                      duration: _exitDuration,
                                      child: AnimatedBuilder(
                                        animation: _cardX.controller,
                                        builder: (context, child) =>
                                            Transform.translate(
                                              offset: Offset(_cardX.value, 0),
                                              child: child,
                                            ),
                                        // The same menu a tile in the deck
                                        // gives, so a problem is the same
                                        // object here as it is there.
                                        child: ContextMenuRegion(
                                          itemsBuilder: () =>
                                              leetCodeProblemMenuItems(
                                                context: context,
                                                ref: ref,
                                                problem: _current!,
                                                onOpenDetail: () =>
                                                    _openDetail(_current!),
                                                onResetProgress:
                                                    _resetAndAdvance,
                                                onDelete: _deleteCurrent,
                                              ),
                                          child: LeetCodeFlashcard(
                                            key: ValueKey(_current!.id),
                                            problem: _current!,
                                            controller: _flipController,
                                            onFlipChanged: (back) => setState(
                                              () => _showingBack = back,
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(height: 16),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                GlassButton(
                                  width: 56,
                                  height: 56,
                                  borderRadius: BorderRadius.circular(28),
                                  color: theme.colorScheme.error,
                                  icon: const Icon(
                                    PhosphorIconsRegular.arrowLeft,
                                  ),
                                  onPressed: () => _decide(false),
                                ),
                                const SizedBox(width: 24),
                                GlassButton(
                                  width: 56,
                                  height: 56,
                                  borderRadius: BorderRadius.circular(28),
                                  color: const Color(0xFF4CAF7D),
                                  icon: const Icon(
                                    PhosphorIconsRegular.arrowRight,
                                  ),
                                  onPressed: () => _decide(true),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
              ),
      ),
    );
  }
}

class _BucketProgressBar extends StatelessWidget {
  const _BucketProgressBar({
    required this.bucket0,
    required this.bucket1,
    required this.bucket2,
  });

  final int bucket0;
  final int bucket1;
  final int bucket2;

  @override
  Widget build(BuildContext context) {
    final total = bucket0 + bucket1 + bucket2;
    return ClipRRect(
      borderRadius: BorderRadius.circular(4),
      child: SizedBox(
        height: 8,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final w = constraints.maxWidth;
            double widthFor(int n) => total == 0 ? 0 : w * n / total;
            return Row(
              children: [
                Container(width: widthFor(bucket0), color: _kBucketFailColor),
                Container(width: widthFor(bucket1), color: _kBucketMidColor),
                Container(width: widthFor(bucket2), color: _kBucketDoneColor),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _CramComplete extends StatelessWidget {
  const _CramComplete({required this.onDone, this.onUndo});

  final VoidCallback onDone;

  /// Steps back into the session for the card decided last — null when there
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
          Text('All problems mastered', style: theme.textTheme.titleLarge),
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

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/theme/voyager_theme.dart';
import 'package:voyager/core/widgets/context_menu.dart';
import 'package:voyager/core/widgets/glass_button.dart';
import 'package:voyager/domain/models/study_models.dart';
import 'package:voyager/core/utils/keyboard_focus_utils.dart';
import 'package:voyager/core/utils/live_snapshot.dart';
import 'package:voyager/features/study/study_actions.dart';
import 'package:voyager/features/study/study_card_editor_modal.dart';
import 'package:voyager/features/study/study_flip_card.dart';
import 'package:voyager/features/study/study_history_controls.dart';
import 'package:voyager/features/study/study_keyboard_shortcuts.dart';
import 'package:voyager/features/study/study_rich_text.dart';
import 'dart:math' as math;
import 'package:voyager/core/motion/motion.dart';
import 'package:voyager/core/widgets/voyager_scroll_view.dart';

const _kBucketFailColor = Color(0xFFE0714A);
const _kBucketMidColor = Color(0xFFE0A63A);
const _kBucketDoneColor = Color(0xFF4CAF7D);

/// Cram mode: every card starts in bucket 0 (unseen/failed), passing moves
/// it up a bucket, failing drops it back to bucket 0, and the session ends
/// once every card reaches bucket 2. Purely in-memory — never touches the
/// cards' persisted SRS state (STUDY.md is explicit about this).
class StudyCramPage extends ConsumerStatefulWidget {
  const StudyCramPage({super.key, required this.deckId});

  final String deckId;

  @override
  ConsumerState<StudyCramPage> createState() => _StudyCramPageState();
}

/// The three buckets as they stood before one decision. Cram writes nothing
/// down, so a decision *is* this arrangement — stepping back to the previous
/// card is putting the arrangement back.
class _CramStep {
  _CramStep(this.bucket0, this.bucket1, this.bucket2);

  final List<String> bucket0;
  final List<String> bucket1;
  final List<String> bucket2;

  /// Drops cards that have been deleted since the step was taken, so a
  /// snapshot can never bring one back.
  void retainOnly(Set<String> ids) {
    for (final bucket in [bucket0, bucket1, bucket2]) {
      bucket.removeWhere((id) => !ids.contains(id));
    }
  }
}

class _StudyCramPageState extends ConsumerState<StudyCramPage>
    with SingleTickerProviderStateMixin {
  /// How far the card's *projected* resting place has to be off centre for
  /// the swipe to count as a decision rather than a nudge.
  static const _commitThreshold = 120.0;

  /// Covers the fade/shrink of the outgoing card, and gates how soon the next
  /// one takes its place.
  static const _exitDuration = Duration(milliseconds: 220);

  final _flipController = StudyFlipController();
  Map<String, StudyCard>? _cardsById;
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

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_handleArrowKey);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_handleArrowKey);
    _cardX.dispose();
    super.dispose();
  }

  /// Far enough that the card is fully clear of the window, whatever its size.
  double get _exitDistance => MediaQuery.sizeOf(context).width;

  /// Overshoot on the way back to centre reads as playful when the user threw
  /// the card and it bounced; under reduced motion it just reads as wobble.
  SpringDescription get _snapBackSpring => VoyagerMotion.reduced(context)
      ? VoyagerSpring.dampen(VoyagerSpring.momentum)
      : VoyagerSpring.momentum;

  void _syncCards(List<StudyCard> cards) {
    final held = _cardsById;
    if (held == null) {
      _cardsById = {for (final c in cards) c.id: c};
      _bucket0 = cards.map((c) => c.id).toList();
      return;
    }
    // Same reason a review session re-reads its queue: these cards are a
    // snapshot taken when cram opened, and an edit made from the card's own
    // menu has to show up on the card itself. A deleted card leaves the
    // buckets with it.
    final fresh = refreshFromLive(held.values, cards);
    _cardsById = {for (final c in fresh) c.id: c};
    final live = _cardsById!.keys.toSet();
    for (final bucket in [_bucket0, _bucket1, _bucket2]) {
      bucket.removeWhere((id) => !live.contains(id));
    }
    for (final step in [..._decided, ..._undone]) {
      step.retainOnly(live);
    }
  }

  StudyCard? get _current {
    final id = _bucket0.isNotEmpty
        ? _bucket0.first
        : (_bucket1.isNotEmpty ? _bucket1.first : null);
    return id == null ? null : _cardsById![id];
  }

  bool get _complete =>
      _bucket0.isEmpty && _bucket1.isEmpty && _cardsById != null;

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
    final card = _current;
    if (card == null) return;
    final id = card.id;
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
    if (_current == null || _exiting) return;
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
  }

  void _handleFlip() => _flipController.flip();

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
    if (!mounted) return;
    // Whichever face was showing is no longer the one the user asked to see.
    setState(() => _showingBack = false);
    _flipController.showFront();
  }

  /// Cram never writes SRS state of its own, so resetting is purely a write
  /// to the card's schedule — the card then moves on the way a failed one
  /// does, back to the end of bucket 0.
  Future<void> _resetAndAdvance() async {
    final card = _current;
    if (card == null || _exiting) return;
    await resetStudyCardProgress(ref, card);
    if (!mounted) return;
    _decide(false);
  }

  Future<void> _deleteCurrent() async {
    final card = _current;
    if (card == null || _exiting) return;

    final deleted = await deleteStudyCard(context, ref, card);
    if (!mounted || !deleted) return;

    setState(() {
      _cardsById!.remove(card.id);
      for (final bucket in [_bucket0, _bucket1, _bucket2]) {
        bucket.remove(card.id);
      }
      _showingBack = false;
    });
    _flipController.showFront();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cardsAsync = ref.watch(studyCardsProvider(widget.deckId));
    final cards = cardsAsync.valueOrNull;
    if (cards != null) _syncCards(cards);

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: SafeArea(
        child: _cardsById == null
            ? const Center(child: CircularProgressIndicator())
            // Wrapped even once every card is mastered, so the last decision
            // can still be stepped back from the completion screen.
            : StudyKeyboardShortcuts(
                onSpace: _handleFlip,
                showingBack: _showingBack,
                onUndo: _canUndo ? _undo : null,
                onRedo: _canRedo ? _redo : null,
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
                                // Balances the two history buttons on the right, so
                                // the title stays centred.
                                const SizedBox(width: 48),
                                const Spacer(),
                                Text(
                                  'Cram mode',
                                  style: theme.textTheme.titleMedium,
                                ),
                                const Spacer(),
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
                              child: Center(
                                // Same sizing as a review session's card: take the
                                // whole free area, capped so a very large or very
                                // tall window keeps card proportions.
                                child: LayoutBuilder(
                                  builder: (context, constraints) => SizedBox(
                                    width: math.min(constraints.maxWidth, 760),
                                    height: math.min(
                                      constraints.maxHeight,
                                      720,
                                    ),
                                    child: GestureDetector(
                                      onHorizontalDragUpdate: (details) {
                                        if (_exiting) return;
                                        // Glued to the pointer. Going through the spring
                                        // rather than a plain field means grabbing a card
                                        // that is still springing back picks it up where
                                        // it actually is, with no jump.
                                        _cardX.jumpTo(
                                          _cardX.value + details.delta.dx,
                                        );
                                      },
                                      onHorizontalDragEnd: (details) {
                                        if (_exiting) return;
                                        final velocity =
                                            details.velocity.pixelsPerSecond.dx;
                                        // Decide on where the flick is *heading*, not
                                        // where the finger happened to stop, so a short
                                        // fast throw commits and a long slow drag that
                                        // stalls at the edge does not.
                                        final projected =
                                            _cardX.value +
                                            projectMomentum(velocity);
                                        if (projected.abs() >
                                            _commitThreshold) {
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
                                                  offset: Offset(
                                                    _cardX.value,
                                                    0,
                                                  ),
                                                  child: child,
                                                ),
                                            child: _cramCard(theme),
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

  Widget _cramCard(ThemeData theme) {
    final card = _current!;
    final vc = VoyagerColors.of(context);
    Widget face(String text, {bool accent = false}) => Container(
      // Infinities collapse to whatever the page lays out for the card, so the
      // face fills its slot instead of shrink-wrapping short text.
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
        // The card no longer grows with its text, so long content scrolls
        // inside the face rather than overflowing it.
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

    // The same menu a tile in the deck grid gives, so a card is the same
    // object here as it is there.
    return ContextMenuRegion(
      itemsBuilder: () => studyCardMenuItems(
        card: card,
        onEdit: _editCurrent,
        onReverse: _reverseCurrent,
        onResetProgress: _resetAndAdvance,
        onDelete: _deleteCurrent,
      ),
      child: StudyFlipCard(
        controller: _flipController,
        onFlipChanged: (back) => setState(() => _showingBack = back),
        front: face(card.frontText),
        back: face(card.backText, accent: true),
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
          Text('All cards mastered', style: theme.textTheme.titleLarge),
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

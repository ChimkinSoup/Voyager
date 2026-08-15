import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:voyager/core/motion/motion.dart';

/// Lets a caller trigger a [StudyFlipCard]'s flip programmatically (space
/// bar, "next card" navigation) instead of only via tap.
class StudyFlipController {
  _StudyFlipCardState? _state;

  void _attach(_StudyFlipCardState state) => _state = state;

  void _detach(_StudyFlipCardState state) {
    if (identical(_state, state)) _state = null;
  }

  void flip() => _state?._flip();

  /// Snaps back to the front with no animation — used when swapping in a new
  /// card (cram mode's next card, or leaving/reentering a session).
  void showFront() => _state?._reset();

  bool get isShowingBack => _state?._isShowingBack ?? false;
}

/// The 3D flip flashcard mechanism shared by the deck-row preview and the
/// full-screen study session card. Front/back content, sizing, and chrome
/// are entirely up to the caller — this widget only owns the flip animation.
class StudyFlipCard extends StatefulWidget {
  const StudyFlipCard({
    super.key,
    required this.front,
    required this.back,
    this.controller,
    this.onFlipChanged,
    this.initiallyShowingBack = false,
    this.tapEnabled = true,
    this.notifyFlipOnStart = false,
    this.duration = const Duration(milliseconds: 350),
  });

  final Widget front;
  final Widget back;
  final StudyFlipController? controller;

  /// Whether tapping the card flips it. Off for a card whose tap belongs to
  /// something else — a deck grid in multi-select mode, where a tap checks
  /// the card instead of turning it around.
  final bool tapEnabled;

  /// Which face the card rests on before anyone touches it. Toggling this on
  /// a live card snaps it to the new face, so a search that starts matching
  /// the back can turn the row around; tapping still overrides freely, and
  /// re-typing within the same match doesn't undo that.
  final bool initiallyShowingBack;

  /// Fires with `true` once the flip finishes revealing the back, and with
  /// `false` once it finishes returning to the front. With
  /// [notifyFlipOnStart] it instead fires the moment the flip commits to a
  /// face, while the card is still turning.
  final ValueChanged<bool>? onFlipChanged;

  /// Reports the face the card is heading to as soon as the flip starts,
  /// rather than when it lands — so a session can accept a grading key
  /// pressed during the animation. Leave off for callers that feed the
  /// reported face back in as [initiallyShowingBack]: an early report would
  /// snap the card to that face and cut the animation short.
  final bool notifyFlipOnStart;
  final Duration duration;

  @override
  State<StudyFlipCard> createState() => _StudyFlipCardState();
}

class _StudyFlipCardState extends State<StudyFlipCard>
    with TickerProviderStateMixin {
  late final AnimationController _controller;

  /// Press feedback, on the same scale and timing as [GlassButton] so a card
  /// answers a press like every other pressable surface in the app. It lives
  /// here rather than in a wrapper because this widget already owns the tap
  /// recognizer — a second one outside it would lose the arena and never see
  /// a clean tap-down, and a raw pointer listener would stay pressed while
  /// the grid scrolled out from under the finger.
  late final AnimationController _press = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 120),
    reverseDuration: const Duration(milliseconds: 180),
  );

  bool get _isShowingBack => _controller.value >= 0.5;

  /// A flip asked for while one was already running. Without it the tap is
  /// swallowed outright — the card ignores you and the flip never happens.
  bool _queuedFlip = false;

  /// The face last reported through [StudyFlipCard.onFlipChanged], so a flip
  /// announced at its start isn't announced a second time when it lands.
  late bool _reportedShowingBack;

  @override
  void initState() {
    super.initState();
    _reportedShowingBack = widget.initiallyShowingBack;
    _controller = AnimationController(vsync: this, duration: widget.duration)
      ..addStatusListener(_handleStatus)
      ..value = widget.initiallyShowingBack ? 1 : 0;
    widget.controller?._attach(this);
  }

  @override
  void didUpdateWidget(covariant StudyFlipCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller?._detach(this);
      widget.controller?._attach(this);
    }
    if (oldWidget.initiallyShowingBack != widget.initiallyShowingBack) {
      // Recorded as already reported before the snap: setting `value` fires
      // the status listeners synchronously, and echoing a face the caller
      // just asked for back to that same caller lands a setState in the
      // middle of its own build. Only flips the user performed are news.
      _reportedShowingBack = widget.initiallyShowingBack;
      // A flip queued against the old face means nothing once the caller has
      // named the face itself.
      _queuedFlip = false;
      _controller.value = widget.initiallyShowingBack ? 1 : 0;
    }
  }

  @override
  void dispose() {
    widget.controller?._detach(this);
    _controller.dispose();
    _press.dispose();
    super.dispose();
  }

  void _handleStatus(AnimationStatus status) {
    if (status == AnimationStatus.completed) {
      _report(true);
    } else if (status == AnimationStatus.dismissed) {
      _report(false);
    } else {
      return;
    }
    if (!_queuedFlip) return;
    _queuedFlip = false;
    // Off the status callback rather than straight out of it: starting the
    // next flip from inside the notification of the one that just landed
    // re-enters the controller mid-dispatch. A microtask runs before the
    // next frame, so the queued flip still begins on the very next tick.
    scheduleMicrotask(() {
      if (mounted) _flip();
    });
  }

  void _report(bool showingBack) {
    if (_reportedShowingBack == showingBack) return;
    _reportedShowingBack = showingBack;
    widget.onFlipChanged?.call(showingBack);
  }

  void _flip() {
    if (_controller.isAnimating) {
      // The card can't turn two ways at once, but the tap still counts:
      // it's held and run the moment this flip lands. Toggling rather than
      // latching means a second tap during the same flip cancels the first,
      // which is what those two taps would have done to a resting card.
      _queuedFlip = !_queuedFlip;
      return;
    }
    final toBack = _controller.value == 0;
    if (widget.notifyFlipOnStart) _report(toBack);
    if (toBack) {
      _controller.forward();
    } else {
      _controller.reverse();
    }
  }

  void _reset() {
    _queuedFlip = false;
    _controller.value = 0;
  }

  @override
  Widget build(BuildContext context) {
    final reduced = VoyagerMotion.reduced(context);
    return GestureDetector(
      onTap: widget.tapEnabled ? _flip : null,
      // Feedback starts on the press, not on the release that flips the card.
      onTapDown: widget.tapEnabled ? (_) => _press.forward() : null,
      onTapUp: widget.tapEnabled ? (_) => _press.reverse() : null,
      onTapCancel: widget.tapEnabled ? () => _press.reverse() : null,
      child: _pressScaled(
        reduced,
        AnimatedBuilder(
        animation: _controller,
        builder: (context, child) {
          final v = _controller.value;
          if (reduced) {
            // No 3D rotation under reduced-motion — a plain crossfade instead.
            return Stack(
              alignment: Alignment.center,
              children: [
                Opacity(
                  opacity: 1 - v,
                  child: widget.front,
                ),
                Opacity(
                  opacity: v,
                  child: widget.back,
                ),
              ],
            );
          }
          final t = VoyagerSpring.moveCurve.transform(v);
          final angle = t * math.pi;
          final showBack = t >= 0.5;
          final transform = Matrix4.identity()
            ..setEntry(3, 2, 0.001)
            ..rotateY(angle);
          return Transform(
            alignment: Alignment.center,
            transform: transform,
            child: showBack
                ? Transform(
                    alignment: Alignment.center,
                    transform: Matrix4.identity()..rotateY(math.pi),
                    child: widget.back,
                  )
                : widget.front,
          );
        },
        ),
      ),
    );
  }

  /// Wraps [child] in the press scale, or returns it untouched when the
  /// platform asks for reduced motion — a scale is a transform, so the
  /// reduced-motion equivalent is simply no scale.
  Widget _pressScaled(bool reduced, Widget child) {
    if (reduced || !widget.tapEnabled) return child;
    return ScaleTransition(
      scale: Tween<double>(begin: 1, end: 0.97).animate(
        CurvedAnimation(parent: _press, curve: VoyagerSpring.snappyCurve),
      ),
      child: child,
    );
  }
}

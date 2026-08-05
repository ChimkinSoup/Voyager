import 'dart:math' as math;

import 'package:flutter/material.dart';

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
    this.duration = const Duration(milliseconds: 350),
  });

  final Widget front;
  final Widget back;
  final StudyFlipController? controller;

  /// Fires with `true` once the flip finishes revealing the back, and with
  /// `false` once it finishes returning to the front.
  final ValueChanged<bool>? onFlipChanged;
  final Duration duration;

  @override
  State<StudyFlipCard> createState() => _StudyFlipCardState();
}

class _StudyFlipCardState extends State<StudyFlipCard>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  bool get _isShowingBack => _controller.value >= 0.5;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this, duration: widget.duration)
      ..addStatusListener(_handleStatus);
    widget.controller?._attach(this);
  }

  @override
  void didUpdateWidget(covariant StudyFlipCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller?._detach(this);
      widget.controller?._attach(this);
    }
  }

  @override
  void dispose() {
    widget.controller?._detach(this);
    _controller.dispose();
    super.dispose();
  }

  void _handleStatus(AnimationStatus status) {
    if (status == AnimationStatus.completed) {
      widget.onFlipChanged?.call(true);
    } else if (status == AnimationStatus.dismissed) {
      widget.onFlipChanged?.call(false);
    }
  }

  void _flip() {
    if (_controller.isAnimating) return;
    if (_controller.value == 0) {
      _controller.forward();
    } else {
      _controller.reverse();
    }
  }

  void _reset() {
    _controller.value = 0;
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: _flip,
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, child) {
          final t = Curves.easeInOutCubic.transform(_controller.value);
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
    );
  }
}

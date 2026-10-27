import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:voyager/features/gaia/companion/gaia_vanish.dart';

/// Gaia's text field (after Aceternity UI's signup form input): a dark field
/// in a thin ring, lit by a light in the accent. The light shows while the
/// cursor is over the field or the field has focus, and goes to whichever
/// moved last: the cursor, or the caret. Switching between them, it fades out
/// where it was as it fades in where it's going.
class GaiaTextField extends StatefulWidget {
  const GaiaTextField({
    super.key,
    required this.controller,
    required this.focusNode,
    this.autofocus = false,
    this.minLines,
    this.maxLines = 1,
    this.expands = false,
    this.textAlignVertical,
    this.hintText,
    this.leading,
    this.trailing,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final bool autofocus;
  final int? minLines;
  final int? maxLines;
  final bool expands;
  final TextAlignVertical? textAlignVertical;
  final String? hintText;

  /// Sits inside the field at its bottom left, such as an attach button.
  final Widget? leading;

  /// Sits inside the field at its bottom right, such as a send button.
  final Widget? trailing;

  @override
  State<GaiaTextField> createState() => _GaiaTextFieldState();
}

/// The light's radius once fully shown.
const _radius = 100.0;

/// How fast the light closes on what it follows: the rate it closes the gap
/// at, per second.
const _follow = 18.0;

/// The field's fill and, until the cursor is over it, its edge.
const _fill = Color(0xFF27272A);
const _edge = Color(0xFF404040);

/// What the light follows.
enum _Source { cursor, caret }

class _GaiaTextFieldState extends State<GaiaTextField>
    with TickerProviderStateMixin {
  /// Where the light is, and where it's heading, in this field's
  /// coordinates.
  final _light = ValueNotifier(Offset.zero);
  var _target = Offset.zero;
  late final Ticker _ticker;
  var _lastTick = Duration.zero;

  late final _shown = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 300),
  );
  var _hovered = false;

  /// The light fading out where it was when it last switched what it
  /// follows, and how strong it was then; null once it's gone. [_swap] runs
  /// it out and the new one in.
  (Offset, double)? _outgoing;
  late final _swap =
      AnimationController(
        vsync: this,
        duration: const Duration(milliseconds: 150),
        value: 1,
      )..addStatusListener((status) {
        if (status == AnimationStatus.completed) _outgoing = null;
      });

  /// Set by a switch: the light's next move is a jump to its new spot, not
  /// a glide over to it.
  var _jump = false;

  /// Whichever moved last. Only edits, selection changes and focus make it
  /// the caret, so text scrolling under a resting cursor leaves it alone.
  var _source = _Source.caret;

  /// The cursor, in global coordinates, while it's over the field: the
  /// field can move or resize under a resting cursor.
  Offset? _cursor;

  /// The field's text, found once and found again if it's replaced.
  RenderEditable? _editable;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_tick);
    widget.controller.addListener(_onEdit);
    widget.focusNode.addListener(_onFocus);
    SchedulerBinding.instance.addPostFrameCallback(_afterFrame);
  }

  @override
  void didUpdateWidget(GaiaTextField old) {
    super.didUpdateWidget(old);
    if (old.controller != widget.controller) {
      old.controller.removeListener(_onEdit);
      widget.controller.addListener(_onEdit);
    }
    if (old.focusNode != widget.focusNode) {
      old.focusNode.removeListener(_onFocus);
      widget.focusNode.addListener(_onFocus);
      _onFocus();
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onEdit);
    widget.focusNode.removeListener(_onFocus);
    _ticker.dispose();
    _shown.dispose();
    _swap.dispose();
    _light.dispose();
    super.dispose();
  }

  void _onHover(PointerEvent event) {
    if (!_hovered) setState(() => _hovered = true);
    _cursor = event.position;
    _switchTo(_Source.cursor);
    // Now, not after the frame, so the light is under the cursor in the
    // frame this move draws.
    _aim();
    _showOrHide();
  }

  void _onExit(PointerExitEvent event) {
    setState(() => _hovered = false);
    _cursor = null;
    if (widget.focusNode.hasFocus) {
      _switchTo(_Source.caret);
    } else {
      // Going out with the cursor, not over to a caret.
      _source = _Source.caret;
    }
    _showOrHide();
  }

  /// Text or selection changed, however it was changed: typing, a paste,
  /// an IME, Vim, autocorrect or code. Where the caret lands is read after
  /// the frame that lays it out.
  void _onEdit() {
    if (!widget.focusNode.hasFocus) return;
    _switchTo(_Source.caret);
    SchedulerBinding.instance.ensureVisualUpdate();
  }

  void _onFocus() {
    // Focus leaving under the cursor hands the light back to it; leaving
    // with no cursor over the field, the light goes out on the caret.
    if (widget.focusNode.hasFocus) {
      _switchTo(_Source.caret);
    } else if (_hovered) {
      _switchTo(_Source.cursor);
    }
    _showOrHide();
  }

  /// Follows [source] from now on. While the light shows, it fades across:
  /// out where it is, in at its new spot.
  void _switchTo(_Source source) {
    if (source == _source) return;
    _source = source;
    _jump = true;
    if (_shown.value < 0.1 ||
        (MediaQuery.maybeDisableAnimationsOf(context) ?? false)) {
      _outgoing = null;
      _swap.value = 1;
      return;
    }
    // Mid-fade, the light going out is the one that was coming in, at the
    // strength it had reached.
    _outgoing = (_light.value, _swap.value);
    _swap.forward(from: 0);
  }

  void _showOrHide() {
    if (_hovered || widget.focusNode.hasFocus) {
      _shown.forward();
    } else {
      _shown.reverse();
    }
  }

  /// After every frame drawn, once it's laid out and scrolled, so the light
  /// keeps up with whatever moved the caret or the field: an edit, the field
  /// scrolling to show the caret, growing, reflowing or being resized. Costs
  /// no frames of its own.
  void _afterFrame(Duration _) {
    if (!mounted) return;
    SchedulerBinding.instance.addPostFrameCallback(_afterFrame);
    _aim();
  }

  /// Sends the light to what it follows, held inside the field so a caret
  /// scrolled out of view lights the edge nearest it.
  void _aim() {
    if (!_hovered && !widget.focusNode.hasFocus) return;
    final box = context.findRenderObject() as RenderBox?;
    if (box == null || !box.attached || !box.hasSize) return;
    final point = switch (_source) {
      _Source.cursor => _cursor == null ? null : box.globalToLocal(_cursor!),
      _Source.caret => widget.focusNode.hasFocus ? _caret(box) : null,
    };
    if (point == null) return;
    final target = Offset(
      point.dx.clamp(0, box.size.width),
      point.dy.clamp(0, box.size.height),
    );
    if (target == _target && !_jump) return;
    _moveTo(
      target,
      glide:
          !_jump &&
          _source == _Source.caret &&
          !(MediaQuery.maybeDisableAnimationsOf(context) ?? false),
    );
    _jump = false;
  }

  /// The caret's centre in [box]'s coordinates, scrolling included. Null
  /// when there's no caret, or the text isn't laid out to match it yet.
  Offset? _caret(RenderBox box) {
    var editable = _editable;
    if (editable == null || !editable.attached) {
      editable = _editable = findEditable(box);
    }
    final selection = widget.controller.selection;
    if (editable == null ||
        !editable.hasSize ||
        !selection.isValid ||
        selection.extentOffset > editable.plainText.length) {
      return null;
    }
    final caret = editable.getLocalRectForCaret(selection.extent);
    return editable.localToGlobal(caret.center, ancestor: box);
  }

  /// Puts the light on [target]. The cursor takes it straight there, as the
  /// cursor is already where the eye is; the caret's steps [glide]. Appearing,
  /// it starts there rather than gliding in from wherever it last went out.
  void _moveTo(Offset target, {required bool glide}) {
    _target = target;
    if (!glide || _shown.value < 0.1) {
      _ticker.stop();
      _light.value = target;
      return;
    }
    if (!_ticker.isActive) {
      _lastTick = Duration.zero;
      _ticker.start();
    }
  }

  void _tick(Duration elapsed) {
    final dt = (elapsed - _lastTick).inMicroseconds / 1e6;
    _lastTick = elapsed;
    final gap = _target - _light.value;
    if (gap.distance < 0.5) {
      _light.value = _target;
      _ticker.stop();
      return;
    }
    _light.value += gap * (1 - math.exp(-dt * _follow));
  }

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: _onHover,
      onHover: _onHover,
      onExit: _onExit,
      child: CustomPaint(
        painter: _LightPainter(
          light: _light,
          outgoing: () => _outgoing,
          swap: _swap,
          shown: _shown,
          color: Theme.of(context).colorScheme.primary,
        ),
        // The light shows only in this gap round the field.
        child: Padding(
          padding: const EdgeInsets.all(2),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 400),
            decoration: BoxDecoration(
              color: _fill,
              borderRadius: BorderRadius.circular(6),
              // The light takes over from the edge under the cursor.
              boxShadow: [
                if (!_hovered)
                  const BoxShadow(color: _edge, blurRadius: 1, spreadRadius: 1),
              ],
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                if (widget.leading case final leading?)
                  Padding(
                    padding: const EdgeInsets.all(4),
                    child: TextFieldTapRegion(child: leading),
                  ),
                Expanded(
                  // Long prompts scroll without a bar.
                  child: ScrollConfiguration(
                    behavior: const _NoScrollbars(),
                    child: TextField(
                      controller: widget.controller,
                      focusNode: widget.focusNode,
                      autofocus: widget.autofocus,
                      minLines: widget.minLines,
                      maxLines: widget.maxLines,
                      expands: widget.expands,
                      textAlignVertical: widget.textAlignVertical,
                      decoration: InputDecoration(
                        hintText: widget.hintText,
                        // The field paints its own fill and edge.
                        filled: false,
                        border: InputBorder.none,
                        enabledBorder: InputBorder.none,
                        focusedBorder: InputBorder.none,
                        isDense: true,
                        // Less on the left past a leading button.
                        contentPadding: EdgeInsets.fromLTRB(
                          widget.leading == null ? 12 : 4,
                          13,
                          12,
                          13,
                        ),
                      ),
                    ),
                  ),
                ),
                if (widget.trailing case final trailing?)
                  Padding(
                    padding: const EdgeInsets.all(4),
                    // Part of the field, so clicking it keeps the focus.
                    child: TextFieldTapRegion(child: trailing),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Builds no scrollbar, even for a multiline field, which turns bars back on
/// over a plain `scrollbars: false`.
class _NoScrollbars extends MaterialScrollBehavior {
  const _NoScrollbars();

  @override
  Widget buildScrollbar(
    BuildContext context,
    Widget child,
    ScrollableDetails details,
  ) => child;
}

/// The light: a radial gradient at [light], growing in as [shown] runs, and
/// fading in as [swap] fades out the [outgoing] one.
class _LightPainter extends CustomPainter {
  _LightPainter({
    required this.light,
    required this.outgoing,
    required this.swap,
    required this.shown,
    required this.color,
  }) : super(repaint: Listenable.merge([light, swap, shown]));

  final ValueNotifier<Offset> light;
  final (Offset, double)? Function() outgoing;
  final Animation<double> swap;
  final Animation<double> shown;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final radius = _radius * Curves.easeOut.transform(shown.value);
    if (radius == 0) return;
    canvas.clipRRect(
      RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(8)),
    );
    if (outgoing() case (final at, final from)?) {
      _glow(canvas, at, radius, from * (1 - swap.value));
    }
    _glow(canvas, light.value, radius, swap.value);
  }

  void _glow(Canvas canvas, Offset at, double radius, double strength) {
    if (strength <= 0) return;
    final lit = color.withValues(alpha: color.a * strength);
    canvas.drawPaint(
      Paint()
        ..shader = ui.Gradient.radial(
          at,
          radius,
          [lit, lit.withValues(alpha: 0)],
          [0, 0.8],
        ),
    );
  }

  @override
  bool shouldRepaint(_LightPainter old) => old.color != color;
}

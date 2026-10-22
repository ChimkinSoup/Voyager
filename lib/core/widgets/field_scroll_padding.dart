import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:voyager/core/widgets/spell_check_field_support.dart';

/// Caret reveal inset for Voyager [TextField]s.
///
/// Flutter defaults to 20px. [EditableText] inflates the caret by that
/// padding and asks ancestor scrollables to [Scrollable.ensureVisible]. At
/// the top of a rubber-banding scroll view that extra inset cannot be
/// satisfied, so the view overscrolls and snaps back on every caret tick.
/// Zero still keeps the caret on screen; sheets already pad for the keyboard
/// via [MediaQuery.viewInsets].
const EdgeInsets kVoyagerFieldScrollPadding = EdgeInsets.zero;

/// Scroll physics for Voyager [TextField]s: when the text shrinks under an
/// idle scroll position, the position is clamped into the new range before
/// the frame paints.
///
/// [RangeMaintainingScrollPhysics] means to do that, but it skips the clamp
/// whenever the position differs from the metrics it last recorded, and a
/// [RenderEditable] doesn't keep those current: once one delete has clamped
/// the offset, the recorded position is still the one from before it. A
/// second line deleted at the bottom of a scrolled field — `dd` twice — then
/// painted a frame scrolled a line past the end, the caret and text jumping
/// up before snapping back down.
class VoyagerFieldScrollPhysics extends ScrollPhysics {
  const VoyagerFieldScrollPhysics({super.parent});

  @override
  VoyagerFieldScrollPhysics applyTo(ScrollPhysics? ancestor) =>
      VoyagerFieldScrollPhysics(parent: buildParent(ancestor));

  @override
  double adjustPositionForNewDimensions({
    required ScrollMetrics oldPosition,
    required ScrollMetrics newPosition,
    required bool isScrolling,
    required double velocity,
  }) {
    final adjusted = super.adjustPositionForNewDimensions(
      oldPosition: oldPosition,
      newPosition: newPosition,
      isScrolling: isScrolling,
      velocity: velocity,
    );
    // A drag or fling in progress keeps its overscroll, as the parent has it.
    if (isScrolling || velocity != 0.0) return adjusted;
    return adjusted.clamp(
      newPosition.minScrollExtent,
      newPosition.maxScrollExtent,
    );
  }
}

/// Scroll controller for a multi-line field that can scroll [pastEnd] pixels
/// beyond its last line, so lines under something floating in the field's
/// bottom corner — an image fan — can be brought out from beneath it.
///
/// [RenderEditable] ends the range at the last line; the position adds the
/// extra as the field reports it. The editable is only as tall as its text
/// until the text fills the field, so the room the text has is read off the
/// editable's constraints behind [fieldKey]: short text the corner does not
/// reach stays unscrollable.
///
/// The field passes every change to its text controller to
/// [handleFieldChanged], which keeps the caret clear of the corner while
/// typing. The position lifts it too when the corner gets taller.
class PastEndScrollController extends ScrollController {
  PastEndScrollController({
    required this.fieldKey,
    required this.pastEnd,
    this.startAtEnd = false,
    String text = '',
  }) : _lastText = text;

  final GlobalKey<State<TextField>> fieldKey;
  final double Function() pastEnd;

  /// Whether the first layout lands at the end of the text rather than the
  /// top, for a field opened with its caret after the last line. Otherwise
  /// [EditableText] reveals that caret on focus with a scroll down from the
  /// top.
  final bool startAtEnd;

  /// Whether the first layout has happened. Kept here rather than on the
  /// position, which [Scrollable] replaces when its dependencies change (the
  /// window moving to a screen with another pixel ratio, say), and a
  /// replacement must not jump back to the end.
  var _placed = false;

  String _lastText;
  bool _liftScheduled = false;
  bool _liftOnlyIfOnScreen = false;

  /// The [pastEnd] the range was last laid out with. Read first at the first
  /// layout, so a field built with its corner already up does not lift.
  late double _laidOutPastEnd = pastEnd();

  /// After an edit, once the frame is laid out, lifts the caret above the
  /// bottom [pastEnd] pixels as far as the range allows. [EditableText]
  /// reveals the caret only as far as the field's bottom edge, which leaves
  /// the line being typed at the end of a long entry under the corner. A
  /// selection change alone does nothing, so a click or a drag near the
  /// bottom does not scroll.
  void handleFieldChanged(String text) {
    final edited = text != _lastText;
    _lastText = text;
    if (edited) _scheduleLift(onlyIfOnScreen: false);
  }

  /// The same lift when the range is laid out with a taller [pastEnd] — an
  /// image fan appearing over the line being typed, which comes with no edit
  /// of its own. Unlike an edit, nothing has brought the caret into view
  /// first, so a caret scrolled out of sight is left there rather than
  /// pulling the text to it.
  void _handleLaidOut(double pastEnd) {
    if (pastEnd > _laidOutPastEnd) _scheduleLift(onlyIfOnScreen: true);
    _laidOutPastEnd = pastEnd;
  }

  void _scheduleLift({required bool onlyIfOnScreen}) {
    if (pastEnd() <= 0) return;
    // An edit in the same frame has revealed the caret, so it lifts as one.
    _liftOnlyIfOnScreen = _liftScheduled
        ? _liftOnlyIfOnScreen && onlyIfOnScreen
        : onlyIfOnScreen;
    if (_liftScheduled) return;
    _liftScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _liftScheduled = false;
      _liftCaret();
    });
  }

  void _liftCaret() {
    if (!hasClients) return;
    final editable = editableTextStateOf(fieldKey);
    if (editable == null || !editable.widget.focusNode.hasFocus) return;
    final selection = editable.textEditingValue.selection;
    if (!selection.isValid) return;
    final render = editable.renderEditable;
    final caret = render.getLocalRectForCaret(selection.extent);
    if (_liftOnlyIfOnScreen &&
        (caret.top < 0 || caret.bottom > render.size.height)) {
      return;
    }
    final overlap = caret.bottom - (render.size.height - pastEnd());
    final target = math.min(
      position.pixels + overlap,
      position.maxScrollExtent,
    );
    if (target > position.pixels) jumpTo(target);
  }

  @override
  ScrollPosition createScrollPosition(
    ScrollPhysics physics,
    ScrollContext context,
    ScrollPosition? oldPosition,
  ) => _PastEndScrollPosition(
    this,
    physics: physics,
    context: context,
    initialPixels: initialScrollOffset,
    keepScrollOffset: keepScrollOffset,
    oldPosition: oldPosition,
    debugLabel: debugLabel,
  );

  /// The tallest the field's text area can be, or null when there is no
  /// field or it can grow without bound.
  double? _roomForText() {
    final editable = editableTextStateOf(fieldKey);
    if (editable == null) return null;
    final maxHeight = editable.renderEditable.constraints.maxHeight;
    return maxHeight.isFinite ? maxHeight : null;
  }
}

class _PastEndScrollPosition extends ScrollPositionWithSingleContext {
  _PastEndScrollPosition(
    this._owner, {
    required super.physics,
    required super.context,
    super.initialPixels,
    super.keepScrollOffset,
    super.oldPosition,
    super.debugLabel,
  });

  final PastEndScrollController _owner;

  @override
  bool applyContentDimensions(double minScrollExtent, double maxScrollExtent) {
    final applied = _applyContentDimensions(minScrollExtent, maxScrollExtent);
    // Before the first paint, so the top of the text never shows.
    if (!_owner._placed) {
      _owner._placed = true;
      if (_owner.startAtEnd) correctPixels(this.maxScrollExtent);
    }
    return applied;
  }

  bool _applyContentDimensions(double minScrollExtent, double maxScrollExtent) {
    final pastEnd = _owner.pastEnd();
    _owner._handleLaidOut(pastEnd);
    final room = pastEnd > 0 && hasViewportDimension
        ? _owner._roomForText()
        : null;
    if (room == null) {
      return super.applyContentDimensions(minScrollExtent, maxScrollExtent);
    }
    final textHeight = maxScrollExtent + viewportDimension;
    return super.applyContentDimensions(
      minScrollExtent,
      math.max(maxScrollExtent, textHeight + pastEnd - room),
    );
  }
}

import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:voyager/core/caps_lock/caps_lock_indicator_scope.dart';
import 'package:voyager/core/caps_lock/caps_lock_state.dart';
import 'package:voyager/core/vim/vim_session.dart';
import 'package:voyager/core/vim/vim_text_ops.dart';

/// The mark itself: Phosphor's fat up-arrow over a bar, which is the Caps Lock
/// shape (⇪) in the app's own iconography rather than a copy of Apple's HUD
/// glyph. Bold, because at 12px the regular weight's strokes disappear against
/// body text.
const IconData kCapsLockIndicatorIcon = PhosphorIconsBold.arrowFatLineUp;

/// Gap between the caret's edge and the mark — `xs` from DESIGN.md.
const double kCapsLockIndicatorGap = 4.0;

/// Fade in and out. The bottom of DESIGN.md's 90–150ms state-feedback band:
/// this is chrome appearing beside the caret, and anything slower reads as a
/// second thing arriving rather than the field noting a fact about itself.
const Duration kCapsLockIndicatorFade = Duration(milliseconds: 120);

/// Largest the mark may draw, whatever the field's line height. Past this it
/// stops reading as status beside the text and starts competing with it.
const double kCapsLockIndicatorMaxSize = 14.0;

/// Smallest it may draw, so the app's densest rows still show something
/// legible.
const double kCapsLockIndicatorMinSize = 9.0;

/// Ring of chip around the glyph. Enough to read as a filled shape rather than
/// as ink that has been highlighted, and no more: the chip sits between two
/// words of the user's own text and every pixel of it covers one of theirs.
const double kCapsLockIndicatorChipPadding = 2.0;

/// Corner of the chip. The app's tightest radius — at this size anything
/// rounder reads as a circle and anything squarer as a selection block.
const double kCapsLockIndicatorChipRadius = 3.0;

/// The glyph's colour, knocked out of the accent chip behind it.
///
/// Whichever of the scheme's two ends stands further off the chip, because the
/// chip is the *field's* accent and a field may carry any colour the user put
/// on it — a saturated one wants the paper behind it, a pale one wants the ink.
/// Pure so the choice can be tested against a palette rather than looked at.
Color capsLockMarkInk({required Color chip, required ColorScheme scheme}) {
  return _contrast(chip, scheme.surface) >= _contrast(chip, scheme.onSurface)
      ? scheme.surface
      : scheme.onSurface;
}

double _contrast(Color a, Color b) {
  final x = a.computeLuminance();
  final y = b.computeLuminance();
  return (math.max(x, y) + 0.05) / (math.min(x, y) + 0.05);
}

/// Whether the badge may be on screen, given everything but the field's own
/// geometry.
///
/// Split out and pure so the rule in CAPS_LOCK.md §3 can be tested as a rule.
/// Note what is *not* here: `vimSuitsField`. Snippets and Vim skip obscure,
/// numeric and formatter-constrained boxes; this does not — a password field is
/// exactly where knowing about Caps Lock matters.
bool capsLockBadgeVisible({
  required bool scopeEnabled,
  required bool allowedHere,
  required bool focused,
  required bool readOnly,
  required bool capsLockOn,
  required bool selectionCollapsed,
}) {
  return scopeEnabled &&
      allowedHere &&
      focused &&
      !readOnly &&
      capsLockOn &&
      selectionCollapsed;
}

/// Draws a Caps Lock mark next to the caret of the text field below it.
///
/// Wraps a field rather than being stacked inside one, and takes no style,
/// padding, strut or scroll controller: it measures the caret off the field's
/// own [RenderEditable] at paint time and maps that rect into its own box. That
/// is what lets one widget serve every field in the app — the bare [TextField]s
/// in the composers as much as `VoyagerTextField` — where the spellcheck,
/// selection and Vim layers each have to be handed the field's exact text
/// metrics so they can lay the same paragraph out a second time.
///
/// It is a [RenderProxyBox], not a [Stack]: the child's constraints and size
/// pass straight through, and painting after `super.paint` puts the mark above
/// the text and the selection without a layer or a second layout pass.
///
/// Mounted once inside `VimTextScope`, which every ordinary field in the app
/// goes through, so almost nothing has to opt *in*. What opts out passes
/// `allowed: false`: the LeetCode code editor (CAPS_LOCK.md §2.2 — the same
/// hard opt-out snippets take there) and any future code field.
class CapsLockCaretIndicator extends StatefulWidget {
  const CapsLockCaretIndicator({
    super.key,
    required this.child,
    this.session,
    this.allowed = true,
    this.accentColor,
  });

  final Widget child;

  /// The field's Vim session, when it has one. Only the mode and the caret are
  /// read: in Normal mode the gap is measured from the right edge of the
  /// *block* caret, not from the thin one hiding underneath it.
  final VimSession? session;

  /// Whether this field may draw the badge at all, on top of the user's
  /// setting. The structural opt-out for code editors.
  final bool allowed;

  /// The field's own accent — its caret and focus border — which the chip
  /// borrows so the mark reads as belonging to the box it is standing in.
  /// Null for the fields that take the app's accent, which is most of them.
  final Color? accentColor;

  @override
  State<CapsLockCaretIndicator> createState() => _CapsLockCaretIndicatorState();
}

/// Fired for anything that moves the mark without rebuilding the widget — a
/// caret move, an edit, an internal scroll, a mode change.
class _Repaint extends ChangeNotifier {
  void ping() => notifyListeners();
}

class _CapsLockCaretIndicatorState extends State<CapsLockCaretIndicator>
    with SingleTickerProviderStateMixin {
  /// Sits above the field and never takes focus itself, so [FocusNode.hasFocus]
  /// reads as "the box below me has focus" — the same trick `VimTextScope`
  /// plays with its own scope node.
  ///
  /// Its own rather than the caller's, so this widget is one shape wherever it
  /// is mounted: `VimTextScope` returns a bare builder result on the fields
  /// that have neither Vim nor a snippet session, and there is no scope node in
  /// the tree on that path to borrow.
  late final FocusNode _focusNode = FocusNode(
    debugLabel: 'CapsLockCaretIndicator',
    canRequestFocus: false,
    skipTraversal: true,
  );

  late final AnimationController _fadeController = AnimationController(
    vsync: this,
    duration: kCapsLockIndicatorFade,
  );

  late final CurvedAnimation _fade = CurvedAnimation(
    parent: _fadeController,
    curve: Curves.easeOutCubic,
  );

  final _Repaint _geometry = _Repaint();

  /// The field below, republished rather than rebuilt into: the render object
  /// reads it at paint time, so resolving one never costs a build.
  final ValueNotifier<EditableTextState?> _field =
      ValueNotifier<EditableTextState?>(null);

  /// One stable [Listenable] for the render object, merged once so it is never
  /// swapped under it.
  late final Listenable _repaint = Listenable.merge([_geometry, _fade, _field]);

  /// Whether the app-wide lock-mode watcher is subscribed. Only while the
  /// setting and the platform allow a badge at all, so a field on Android costs
  /// nothing.
  bool _watchingCapsLock = false;

  bool _scopeEnabled = false;

  /// The listenables that belong to the resolved field and have to come off
  /// with it.
  TextEditingController? _watchedController;
  ViewportOffset? _watchedOffset;

  @override
  void initState() {
    super.initState();
    _focusNode.addListener(_handleFocusChanged);
    _listenToSession(widget.session);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final enabled = CapsLockIndicatorScope.of(context) && widget.allowed;
    if (enabled == _scopeEnabled) return;
    _scopeEnabled = enabled;
    _syncCapsLockWatch();
    _evaluate();
  }

  @override
  void didUpdateWidget(covariant CapsLockCaretIndicator oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.session != widget.session) {
      _unlistenToSession(oldWidget.session);
      _listenToSession(widget.session);
    }
    if (oldWidget.allowed != widget.allowed) {
      _scopeEnabled = CapsLockIndicatorScope.of(context) && widget.allowed;
      _syncCapsLockWatch();
    }
    _evaluate();
  }

  @override
  void dispose() {
    _detachField();
    if (_watchingCapsLock) {
      CapsLockState.instance.removeListener(_handleCapsLockChanged);
    }
    _unlistenToSession(widget.session);
    _focusNode
      ..removeListener(_handleFocusChanged)
      ..dispose();
    _fade.dispose();
    _fadeController.dispose();
    _geometry.dispose();
    _field.dispose();
    super.dispose();
  }

  void _listenToSession(VimSession? session) {
    session?.modeListenable.addListener(_handleGeometryChanged);
    session?.caretListenable.addListener(_handleGeometryChanged);
  }

  void _unlistenToSession(VimSession? session) {
    session?.modeListenable.removeListener(_handleGeometryChanged);
    session?.caretListenable.removeListener(_handleGeometryChanged);
  }

  void _syncCapsLockWatch() {
    if (_scopeEnabled == _watchingCapsLock) return;
    _watchingCapsLock = _scopeEnabled;
    if (_scopeEnabled) {
      CapsLockState.instance.addListener(_handleCapsLockChanged);
    } else {
      CapsLockState.instance.removeListener(_handleCapsLockChanged);
    }
  }

  void _handleCapsLockChanged() => _evaluate();

  void _handleFocusChanged() {
    if (!_focusNode.hasFocus) _detachField();
    _evaluate();
  }

  /// Something moved the caret or the text under it. The visibility rule reads
  /// the selection too — a drag that opens a range hides the mark — so this
  /// runs the whole evaluation rather than only dirtying the paint.
  void _handleGeometryChanged() => _evaluate();

  void _handleScrolled() {
    if (mounted) _geometry.ping();
  }

  /// Applies CAPS_LOCK.md §3 and drives the fade.
  void _evaluate() {
    if (!mounted) return;
    final editable = _resolveEditable();
    _field.value = editable;
    final visible = capsLockBadgeVisible(
      scopeEnabled: _scopeEnabled,
      allowedHere: widget.allowed,
      focused: _focusNode.hasFocus,
      readOnly: editable?.widget.readOnly ?? true,
      capsLockOn: _watchingCapsLock && CapsLockState.instance.isOn,
      // Vim's Visual mode needs no case of its own: a highlight *is* a
      // non-collapsed selection, so the one rule covers both (§3.6).
      selectionCollapsed:
          editable?.textEditingValue.selection.isCollapsed ?? false,
    );
    if (visible) {
      _fadeController.forward();
    } else {
      _fadeController.reverse();
    }
    _geometry.ping();
  }

  EditableTextState? _resolveEditable() {
    if (!_scopeEnabled || !_focusNode.hasFocus) return null;
    final cached = _field.value;
    if (cached != null && cached.mounted) {
      // The render object was resolved before the field had been laid out, so
      // its scroll had no offset to subscribe to yet.
      if (_watchedOffset == null) _watchScroll(cached);
      return cached;
    }
    final found = _findEditable();
    if (found == null) return null;
    _watchedController = found.widget.controller
      ..addListener(_handleGeometryChanged);
    _watchScroll(found);
    return found;
  }

  /// The field's own scroll. A multiline box scrolled with the wheel moves the
  /// caret on screen without touching the text or the selection, and the render
  /// object below only repaints when it is told to.
  void _watchScroll(EditableTextState editable) {
    final render = renderEditableOf(editable);
    if (render == null) return;
    _watchedOffset = render.offset..addListener(_handleScrolled);
  }

  EditableTextState? _findEditable() {
    EditableTextState? found;
    void visit(Element child) {
      if (found != null) return;
      if (child is StatefulElement && child.state is EditableTextState) {
        found = child.state as EditableTextState;
        return;
      }
      child.visitChildren(visit);
    }

    (context as Element).visitChildren(visit);
    return found;
  }

  void _detachField() {
    _watchedController?.removeListener(_handleGeometryChanged);
    _watchedController = null;
    _watchedOffset?.removeListener(_handleScrolled);
    _watchedOffset = null;
    _field.value = null;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final chip = widget.accentColor ?? theme.colorScheme.primary;
    // `withExternalFocusNode` and not the plain constructor, which re-asserts
    // its own defaults onto the node it is handed and would put this scope in
    // front of every field as a Tab stop.
    return Focus.withExternalFocusNode(
      focusNode: _focusNode,
      child: _CapsLockCaretPainter(
        repaint: _repaint,
        fade: _fade,
        field: _field,
        session: widget.session,
        chipColor: chip,
        inkColor: capsLockMarkInk(chip: chip, scheme: theme.colorScheme),
        child: widget.child,
      ),
    );
  }
}

/// Where the mark last painted, in the indicator's own coordinates, or null if
/// the last paint drew nothing.
///
/// The mark is drawn straight onto the canvas rather than mounted as a widget,
/// so this is what a widget test has to assert against. Written on every paint,
/// which is why the tests that read it keep to a single field.
@visibleForTesting
Rect? debugCapsLockMarkRect;

/// [EditableTextState.renderEditable] resolves through a [GlobalKey]'s context,
/// which is not there between the field being detached and this widget hearing
/// about it.
@visibleForTesting
RenderEditable? renderEditableOf(EditableTextState editable) {
  if (!editable.mounted) return null;
  try {
    return editable.renderEditable;
  } on Object {
    return null;
  }
}

class _CapsLockCaretPainter extends SingleChildRenderObjectWidget {
  const _CapsLockCaretPainter({
    required this.repaint,
    required this.fade,
    required this.field,
    required this.session,
    required this.chipColor,
    required this.inkColor,
    required super.child,
  });

  final Listenable repaint;
  final Animation<double> fade;
  final ValueListenable<EditableTextState?> field;
  final VimSession? session;
  final Color chipColor;
  final Color inkColor;

  @override
  RenderObject createRenderObject(BuildContext context) {
    return _RenderCapsLockCaret(
      repaint: repaint,
      fade: fade,
      field: field,
      session: session,
      chipColor: chipColor,
      inkColor: inkColor,
    );
  }

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderCapsLockCaret renderObject,
  ) {
    renderObject
      ..session = session
      ..chipColor = chipColor
      ..inkColor = inkColor;
  }
}

class _RenderCapsLockCaret extends RenderProxyBox {
  _RenderCapsLockCaret({
    required Listenable repaint,
    required Animation<double> fade,
    required ValueListenable<EditableTextState?> field,
    required VimSession? session,
    required Color chipColor,
    required Color inkColor,
  }) : _repaint = repaint,
       _fade = fade,
       _field = field,
       _session = session,
       _chipColor = chipColor,
       _inkColor = inkColor;

  final Listenable _repaint;
  final Animation<double> _fade;
  final ValueListenable<EditableTextState?> _field;

  VimSession? _session;
  set session(VimSession? value) {
    if (identical(_session, value)) return;
    _session = value;
    markNeedsPaint();
  }

  Color _chipColor;
  set chipColor(Color value) {
    if (_chipColor == value) return;
    _chipColor = value;
    markNeedsPaint();
  }

  Color _inkColor;
  set inkColor(Color value) {
    if (_inkColor == value) return;
    _inkColor = value;
    markNeedsPaint();
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _repaint.addListener(markNeedsPaint);
  }

  @override
  void detach() {
    _repaint.removeListener(markNeedsPaint);
    super.detach();
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    super.paint(context, offset);
    final mark = _measure();
    if (mark == null) {
      assert(() {
        debugCapsLockMarkRect = null;
        return true;
      }());
      return;
    }
    assert(() {
      debugCapsLockMarkRect = mark.rect;
      return true;
    }());

    final painter = TextPainter(
      text: TextSpan(
        text: String.fromCharCode(kCapsLockIndicatorIcon.codePoint),
        style: TextStyle(
          fontSize: mark.rect.width - kCapsLockIndicatorChipPadding * 2,
          fontFamily: kCapsLockIndicatorIcon.fontFamily,
          package: kCapsLockIndicatorIcon.fontPackage,
          height: 1.0,
          color: _inkColor.withValues(alpha: _inkColor.a * mark.opacity),
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();

    final canvas = context.canvas;
    canvas.save();
    // Clipped to this box, which is the field: a mark that outran it would land
    // on whatever the field is sitting on.
    canvas.clipRect(offset & size);
    // The chip is opaque and the glyph is knocked out of it, so the text it
    // covers goes away rather than showing through the mark.
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        mark.rect.shift(offset),
        const Radius.circular(kCapsLockIndicatorChipRadius),
      ),
      Paint()
        ..color = _chipColor.withValues(alpha: _chipColor.a * mark.opacity),
    );
    painter.paint(
      canvas,
      offset +
          Offset(
            mark.rect.center.dx - painter.width / 2,
            mark.rect.center.dy - painter.height / 2,
          ),
    );
    canvas.restore();
    painter.dispose();
  }

  /// Where the mark goes this frame, or null when it draws nothing.
  ({Rect rect, double opacity})? _measure() {
    final opacity = _fade.value;
    if (opacity <= 0.01) return null;
    final editable = _field.value;
    if (editable == null) return null;
    final render = renderEditableOf(editable);
    if (render == null || !render.attached || !render.hasSize) return null;
    final anchor = _anchor(editable, render);
    if (anchor == null) return null;
    final rect = _place(
      anchor.caret,
      anchor.field,
      _iconSize(render) + kCapsLockIndicatorChipPadding * 2,
    );
    return rect == null ? null : (rect: rect, opacity: opacity);
  }

  /// The caret's painted rect and the field's own box, both in this box's
  /// coordinates. Null when there is nothing measurable to sit beside.
  ({Rect caret, Rect field})? _anchor(
    EditableTextState editable,
    RenderEditable render,
  ) {
    final selection = render.selection;
    if (selection == null || !selection.isValid || !selection.isCollapsed) {
      return null;
    }
    final text = editable.textEditingValue.text;
    final session = _session;
    final normal = session != null && session.mode == VimMode.normal;
    final caretOffset = (normal ? session.caretOffset : selection.baseOffset)
        .clamp(0, text.length);

    // `getLocalRectForCaret` answers in the paragraph's own space;
    // `getBoxesForSelection` has already had the field's scroll folded in. Only
    // the first needs shifting.
    var caret = render
        .getLocalRectForCaret(TextPosition(offset: caretOffset))
        .shift(_scrollShift(render));

    if (normal) {
      // Normal mode's caret is the block `VimTextOverlay` paints — as wide as
      // the glyph it covers — so the gap is measured from *its* right edge, not
      // from the thin caret hiding underneath it (decision 6).
      final block = _blockCaret(render, text, caretOffset);
      if (block != null) {
        caret = Rect.fromLTRB(block.left, caret.top, block.right, caret.bottom);
      }
    }

    final transform = render.getTransformTo(this);
    final field = MatrixUtils.transformRect(
      transform,
      Offset.zero & render.size,
    );
    final local = MatrixUtils.transformRect(transform, caret);
    // Scrolled out of the field's visible strip: the caret is not on screen, so
    // neither is anything anchored to it (§7). Both axes — a single-line field
    // scrolls sideways, and the flip in [_place] only asks which side of the
    // caret has room, not whether the caret is in the box at all.
    if (!local.overlaps(field)) return null;
    return (caret: local, field: field);
  }

  Rect? _blockCaret(RenderEditable render, String text, int offset) {
    if (offset >= vimLineEnd(text, offset)) return null;
    final boxes = render.getBoxesForSelection(
      TextSelection(baseOffset: offset, extentOffset: offset + 1),
    );
    return boxes.isEmpty ? null : boxes.first.toRect();
  }

  static Offset _scrollShift(RenderEditable render) {
    final offset = render.offset;
    if (!offset.hasPixels) return Offset.zero;
    return render.maxLines == 1
        ? Offset(-offset.pixels, 0)
        : Offset(0, -offset.pixels);
  }

  static double _iconSize(RenderEditable render) {
    return (render.preferredLineHeight * 0.8).clamp(
      kCapsLockIndicatorMinSize,
      kCapsLockIndicatorMaxSize,
    );
  }

  /// Right of the caret, or left of it when there is no room (§4.1). Null when
  /// neither side fits, which is a field too narrow to say anything in.
  ///
  /// [size] is the chip's, glyph and padding together: it is the chip that has
  /// to clear the field's edge, and asking about the glyph alone would let the
  /// padding hang over it.
  static Rect? _place(Rect caret, Rect field, double size) {
    // Square, and centred on the caret rather than sharing its box: on a tall
    // line the chip stays a chip instead of stretching into a bar.
    final top = caret.center.dy - size / 2;
    final right = Rect.fromLTWH(
      caret.right + kCapsLockIndicatorGap,
      top,
      size,
      size,
    );
    if (right.right <= field.right) return right;
    final left = Rect.fromLTWH(
      caret.left - kCapsLockIndicatorGap - size,
      top,
      size,
      size,
    );
    if (left.left >= field.left) return left;
    return null;
  }
}

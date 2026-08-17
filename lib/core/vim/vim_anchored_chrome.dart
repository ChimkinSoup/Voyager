import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

/// Everything [target]'s ancestors cut off it, intersected into one rect in
/// global coordinates. Null when nothing clips it at all.
///
/// [RenderObject.describeApproximatePaintClip] is what makes this general — it
/// is the framework's own answer to "what does this parent cut off its child",
/// and every scroll viewport, `ClipRect` and clipping `Stack` implements it —
/// so nested scrollers (the LeetCode code box scrolls inside a page that
/// scrolls) need no special handling.
Rect? vimAncestorClipRect(RenderBox target) {
  if (!target.attached) return null;
  Rect? clip;
  RenderObject child = target;
  RenderObject? parent = target.parent;
  while (parent != null) {
    final local = parent.describeApproximatePaintClip(child);
    if (local != null) {
      final global = MatrixUtils.transformRect(
        parent.getTransformTo(null),
        local,
      );
      clip = clip == null ? global : clip.intersect(global);
    }
    child = parent;
    parent = parent.parent;
  }
  return clip;
}

/// The window [node] is rendered into, in the same global coordinates
/// [vimAncestorClipRect] returns. Null when the tree is not rooted in a
/// [RenderView] (nothing to clamp against, so callers skip it).
///
/// Deliberately [RenderView.size] and not `paintBounds`: the latter is the
/// window in *physical* pixels, while `getTransformTo(null)` stops below the
/// view's own device-pixel-ratio transform and so reports logical ones. Mixing
/// the two silently multiplies the window by the DPR — invisible on a 1.0
/// display and on every widget test.
Rect? vimViewBounds(RenderObject node) {
  if (!node.attached) return null;
  RenderObject root = node;
  while (root.parent != null) {
    root = root.parent!;
  }
  return root is RenderView ? Offset.zero & root.size : null;
}

/// What chrome does when the field it hangs off runs out of room.
enum VimChromeFit {
  /// Nothing at all. It rides the field wherever the field goes, and whatever
  /// clips the field clips it too — so it slides under the edge of the box and
  /// is cut off there, exactly like a line of the text it sits on.
  ///
  /// The mode badge. It is on screen for as long as you stay in Normal mode,
  /// and a readout that repositions itself while you read it is worse than one
  /// that is out of view: you stop trusting where it is.
  clip,

  /// Move back inside the part of the field still on screen, and paint nothing
  /// once none of it is.
  ///
  /// The `/` bar, which is transient and worth keeping in sight for the
  /// second you are typing into it — a search prompt you cannot see is no use
  /// at all, where a mode badge you cannot see costs you one glance.
  clamp,
}

/// Chrome hung off a Vim field's [LayerLink].
///
/// [CompositedTransformFollower] tracks the field wherever it goes, which is
/// exactly what this chrome wants — and it neither clips nor clamps, which is
/// exactly what it doesn't. Nothing stops the follower painting a badge
/// anchored to a code editor's last line over the buttons *below* the box that
/// editor scrolls in, or leaving a bucket-list row's badge drawn across the
/// composer once the row has scrolled out of its list. The follower has no idea
/// the field is inside anything.
///
/// So the follower still does the tracking — no rebuild per frame, and page
/// transitions stay glued — and this adds the one thing it cannot do: at paint
/// time it applies whichever [VimChromeFit] the chrome asked for, worked out
/// from the field's own geometry.
class VimAnchoredChrome extends StatelessWidget {
  const VimAnchoredChrome({
    super.key,
    required this.link,
    required this.fieldKey,
    required this.targetAnchor,
    required this.followerAnchor,
    required this.offset,
    required this.fit,
    required this.child,
    this.onFieldHeight,
  });

  final LayerLink link;

  /// Key on the field [link] leads to. Its render object is where the fit
  /// reads the geometry the follower is about to use.
  final GlobalKey fieldKey;

  final Alignment targetAnchor;
  final Alignment followerAnchor;
  final Offset offset;

  final VimChromeFit fit;

  final Widget child;

  /// Called whenever the field changes height, for chrome that is built
  /// differently depending on how much room it has. Off by default: it costs a
  /// rebuild of whatever listens.
  final ValueChanged<double>? onFieldHeight;

  @override
  Widget build(BuildContext context) {
    // Positioned because this is built into the overlay's [Stack]; the
    // follower does the actual placing.
    return Positioned(
      left: 0,
      top: 0,
      child: CompositedTransformFollower(
        link: link,
        showWhenUnlinked: false,
        targetAnchor: targetAnchor,
        followerAnchor: followerAnchor,
        offset: offset,
        child: _VimAnchoredChrome(
          fieldKey: fieldKey,
          targetAnchor: targetAnchor,
          followerAnchor: followerAnchor,
          anchorOffset: offset,
          fit: fit,
          onFieldHeight: onFieldHeight,
          child: child,
        ),
      ),
    );
  }
}

class _VimAnchoredChrome extends SingleChildRenderObjectWidget {
  const _VimAnchoredChrome({
    required this.fieldKey,
    required this.targetAnchor,
    required this.followerAnchor,
    required this.anchorOffset,
    required this.fit,
    required this.onFieldHeight,
    required Widget super.child,
  });

  final GlobalKey fieldKey;
  final Alignment targetAnchor;
  final Alignment followerAnchor;
  final Offset anchorOffset;
  final VimChromeFit fit;
  final ValueChanged<double>? onFieldHeight;

  @override
  RenderVimAnchoredChrome createRenderObject(BuildContext context) {
    return RenderVimAnchoredChrome(
      fieldKey: fieldKey,
      targetAnchor: targetAnchor,
      followerAnchor: followerAnchor,
      anchorOffset: anchorOffset,
      fit: fit,
      onFieldHeight: onFieldHeight,
    );
  }

  @override
  void updateRenderObject(
    BuildContext context,
    RenderVimAnchoredChrome renderObject,
  ) {
    renderObject
      ..fieldKey = fieldKey
      ..targetAnchor = targetAnchor
      ..followerAnchor = followerAnchor
      ..anchorOffset = anchorOffset
      ..fit = fit
      ..onFieldHeight = onFieldHeight;
  }
}

/// What a paint of this chrome is going to do: [shift] it by that much (null
/// for "paint nothing"), and cut it to [clip], in global coordinates.
@immutable
class VimChromePlacement {
  const VimChromePlacement({required this.shift, this.clip});

  static const VimChromePlacement none = VimChromePlacement(shift: null);
  static const VimChromePlacement asIs = VimChromePlacement(shift: Offset.zero);

  final Offset? shift;
  final Rect? clip;

  @override
  bool operator ==(Object other) =>
      other is VimChromePlacement && other.shift == shift && other.clip == clip;

  @override
  int get hashCode => Object.hash(shift, clip);

  @override
  String toString() => 'VimChromePlacement(shift: $shift, clip: $clip)';
}

/// Applies the chrome's [VimChromeFit] at paint time — see [VimAnchoredChrome].
///
/// Everything is worked out from the *field's* current geometry rather than
/// from this box's own [localToGlobal], which would report where the follower
/// put it last frame (a [FollowerLayer]'s transform is established during
/// compositing, after paint). Reading the field directly is what keeps the
/// chrome in step with the box under it, instead of trailing the content by a
/// frame.
class RenderVimAnchoredChrome extends RenderProxyBox {
  // Named parameters cannot be private, so none of these can be initializing
  // formals.
  RenderVimAnchoredChrome({
    required GlobalKey fieldKey,
    required Alignment targetAnchor,
    required Alignment followerAnchor,
    required Offset anchorOffset,
    required VimChromeFit fit,
    required ValueChanged<double>? onFieldHeight,
    // ignore: prefer_initializing_formals
  }) : _onFieldHeight = onFieldHeight,
       // ignore: prefer_initializing_formals
       _fieldKey = fieldKey,
       // ignore: prefer_initializing_formals
       _targetAnchor = targetAnchor,
       // ignore: prefer_initializing_formals
       _followerAnchor = followerAnchor,
       // ignore: prefer_initializing_formals
       _anchorOffset = anchorOffset,
       // ignore: prefer_initializing_formals
       _fit = fit;

  GlobalKey _fieldKey;
  set fieldKey(GlobalKey value) {
    if (_fieldKey == value) return;
    _fieldKey = value;
    if (attached) _syncScrollPositions();
    markNeedsPaint();
  }

  Alignment _targetAnchor;
  set targetAnchor(Alignment value) {
    if (_targetAnchor == value) return;
    _targetAnchor = value;
    markNeedsPaint();
  }

  Alignment _followerAnchor;
  set followerAnchor(Alignment value) {
    if (_followerAnchor == value) return;
    _followerAnchor = value;
    markNeedsPaint();
  }

  Offset _anchorOffset;
  set anchorOffset(Offset value) {
    if (_anchorOffset == value) return;
    _anchorOffset = value;
    markNeedsPaint();
  }

  VimChromeFit _fit;
  set fit(VimChromeFit value) {
    if (_fit == value) return;
    _fit = value;
    markNeedsPaint();
  }

  /// No repaint on assignment: this reports geometry outwards, and nothing
  /// about this box's own painting depends on who is listening.
  ValueChanged<double>? _onFieldHeight;
  set onFieldHeight(ValueChanged<double>? value) => _onFieldHeight = value;

  double? _reportedHeight;

  VimChromePlacement _placement = VimChromePlacement.asIs;

  Size? _paintedFieldSize;

  /// What the last paint did.
  @visibleForTesting
  VimChromePlacement get lastPlacement => _placement;

  ClipRectLayer? _clipLayer;

  /// Every scrollable between the field and the root. Their positions change
  /// during the frame's animation and gesture phases, so marking this box dirty
  /// from them repaints it in the *same* frame the content moves in.
  List<ScrollPosition> _positions = const <ScrollPosition>[];

  bool _checkScheduled = false;

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _syncScrollPositions();
    _scheduleGeometryCheck();
  }

  @override
  void detach() {
    _unsubscribe();
    super.detach();
  }

  @override
  void dispose() {
    _clipLayer?.dispose();
    _clipLayer = null;
    super.dispose();
  }

  void _unsubscribe() {
    for (final position in _positions) {
      position.removeListener(markNeedsPaint);
    }
    _positions = const <ScrollPosition>[];
  }

  void _syncScrollPositions() {
    final next = <ScrollPosition>[];
    BuildContext? context = _fieldKey.currentContext;
    while (context != null) {
      // findAncestorStateOfType rather than Scrollable.of: this runs from paint
      // and from a frame callback, and only wants to read the positions — not
      // register the field's element as depending on them.
      final scrollable = context.findAncestorStateOfType<ScrollableState>();
      if (scrollable == null) break;
      next.add(scrollable.position);
      context = scrollable.context;
    }
    if (listEquals(next, _positions)) return;
    _unsubscribe();
    _positions = next;
    for (final position in next) {
      position.addListener(markNeedsPaint);
    }
  }

  /// Catches everything a scroll notification does not: the field growing a
  /// line, the window resizing, a sheet settling.
  ///
  /// Only ever runs off a frame that was drawn for some other reason, and only
  /// asks for a new one when something it depends on has actually changed, so
  /// an idle field costs nothing.
  ///
  /// The field's size counts as one of those things even though this box's own
  /// painting rarely turns on it. [CompositedTransformFollower] reads
  /// `LayerLink.leaderSize` when it paints and there is nothing in the
  /// framework to mark a follower dirty when its leader is laid out at a new
  /// size — so a field that grows or shrinks in place, which is every `p` and
  /// every `dd`, leaves the chrome hanging at the corner the field used to
  /// have until something unrelated happens to repaint it.
  void _scheduleGeometryCheck() {
    if (_checkScheduled) return;
    _checkScheduled = true;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _checkScheduled = false;
      if (!attached) return;
      _syncScrollPositions();
      _reportFieldHeight();
      if (_field?.size != _paintedFieldSize || _resolve() != _placement) {
        markNeedsPaint();
      }
      _scheduleGeometryCheck();
    });
  }

  /// The field this chrome hangs off, once it is in a state worth reading.
  RenderBox? get _field {
    final field = _fieldKey.currentContext?.findRenderObject();
    return field is RenderBox && field.attached && field.hasSize ? field : null;
  }

  /// Hands the field's height to [VimAnchoredChrome.onFieldHeight] when it
  /// changes — a line pasted in, a line deleted, a window resized.
  ///
  /// From the frame callback and not from paint, because the answer rebuilds a
  /// widget and paint is no place to mark one dirty.
  void _reportFieldHeight() {
    final report = _onFieldHeight;
    final field = _field;
    if (report == null || field == null) return;
    final height = field.size.height;
    if (height == _reportedHeight) return;
    _reportedHeight = height;
    report(height);
  }

  /// The rect [CompositedTransformFollower] is about to put this chrome in,
  /// given the field's [fieldRect]. Both in global coordinates.
  Rect _followerRect(Rect fieldRect) {
    final anchor =
        fieldRect.topLeft +
        _targetAnchor.alongSize(fieldRect.size) +
        _anchorOffset;
    return (anchor - _followerAnchor.alongSize(size)) & size;
  }

  VimChromePlacement _resolve() {
    final field = _field;
    if (!hasSize || field == null) return VimChromePlacement.asIs;
    final fieldRect = MatrixUtils.transformRect(
      field.getTransformTo(null),
      Offset.zero & field.size,
    );
    final clip = vimAncestorClipRect(field);
    return switch (_fit) {
      VimChromeFit.clip => _resolveClip(fieldRect, clip),
      VimChromeFit.clamp => _resolveClamp(field, fieldRect, clip),
    };
  }

  /// Cut to whatever cuts the field, and no more: the chrome is part of the
  /// field as far as the user is concerned, so it should disappear the way the
  /// field's own last line does — a little at a time, from the edge in.
  VimChromePlacement _resolveClip(Rect fieldRect, Rect? clip) {
    if (clip == null) return VimChromePlacement.asIs;
    final rect = _followerRect(fieldRect);
    final showing = rect.intersect(clip);
    // Nothing left of it — a field scrolled out of its list — so skip the clip
    // layer rather than push an empty one every frame.
    if (showing.isEmpty) return VimChromePlacement.none;
    // Wholly inside: one less clip for the layer tree to walk.
    if (showing == rect) return VimChromePlacement.asIs;
    // Local, because this box's own top-left is exactly where the follower is
    // about to put it.
    return VimChromePlacement(
      shift: Offset.zero,
      clip: clip.shift(-rect.topLeft),
    );
  }

  /// Where to paint the child relative to where the follower will put it, or
  /// nothing when none of the field is on screen.
  VimChromePlacement _resolveClamp(RenderBox field, Rect fieldRect, Rect? clip) {
    // The part of the field the user can actually see.
    final visible = clip == null ? fieldRect : fieldRect.intersect(clip);
    if (visible.width <= 0 || visible.height <= 0) return VimChromePlacement.none;

    final rect = _followerRect(fieldRect);

    // Whatever the follower meant to hang past the field's edges, it may hang
    // past the visible rect's edges too — otherwise the `/` bar, which docks
    // below the box on purpose, would be dragged up onto it.
    var allowed = Rect.fromLTRB(
      visible.left - math.max(0.0, fieldRect.left - rect.left),
      visible.top - math.max(0.0, fieldRect.top - rect.top),
      visible.right + math.max(0.0, rect.right - fieldRect.right),
      visible.bottom + math.max(0.0, rect.bottom - fieldRect.bottom),
    );
    // The window is a hard bound, not one the overhang may reach past: a field
    // flush with the bottom of the screen (the todo page's "Add task" composer)
    // would otherwise drop its chrome clean off the edge.
    final view = vimViewBounds(field);
    if (view != null) allowed = allowed.intersect(view);

    // A sliver of field too short to hold the chrome: better nothing than a
    // bar spilling out of the box it belongs to.
    if (rect.height > allowed.height) return VimChromePlacement.none;

    // Bottom/right first, then top/left, so the leading edge wins when the
    // chrome is wider than the field it hangs under — a narrow field keeps its
    // search bar where it has always been rather than losing it to the clamp.
    var dx = 0.0;
    if (rect.right > allowed.right) dx = allowed.right - rect.right;
    if (rect.left + dx < allowed.left) dx = allowed.left - rect.left;
    var dy = 0.0;
    if (rect.bottom > allowed.bottom) dy = allowed.bottom - rect.bottom;
    if (rect.top + dy < allowed.top) dy = allowed.top - rect.top;
    return VimChromePlacement(shift: Offset(dx, dy));
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    final child = this.child;
    if (child == null) return;
    final placement = _resolve();
    _placement = placement;
    // The size the follower above this box has just worked its own offset out
    // from. See [_scheduleGeometryCheck].
    _paintedFieldSize = _field?.size;
    final shift = placement.shift;
    if (shift == null) {
      _clipLayer?.dispose();
      _clipLayer = null;
      return;
    }
    final clip = placement.clip;
    if (clip == null) {
      _clipLayer?.dispose();
      _clipLayer = null;
      context.paintChild(child, offset + shift);
      return;
    }
    _clipLayer = context.pushClipRect(
      needsCompositing,
      offset + shift,
      clip,
      (context, offset) => context.paintChild(child, offset),
      oldLayer: _clipLayer,
    );
  }

  @override
  void applyPaintTransform(RenderBox child, Matrix4 transform) {
    final shift = _placement.shift ?? Offset.zero;
    transform.translateByDouble(shift.dx, shift.dy, 0, 1);
  }
}

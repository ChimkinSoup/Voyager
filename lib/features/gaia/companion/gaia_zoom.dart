import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:voyager/features/gaia/companion/gaia_button.dart';

/// The zoom levels Ctrl+Plus and Ctrl+Minus step through.
const _steps = [0.5, 0.67, 0.75, 0.8, 0.9, 1.0, 1.1, 1.25, 1.5];

/// How long the zoom indicator stays after a change, or after the cursor
/// leaves it.
const _shownFor = Duration(milliseconds: 1500);
const _hoveredFor = Duration(seconds: 3);

/// How far a pinch spreads, or closes by its inverse, for one step. Enough
/// that the stray scale of a two-finger scroll never gets there.
const _pinchStep = 1.15;

/// Gaia's zoom level: local to this desktop and never synced, like
/// `GaiaSidebar`, kept in a JSON [file]. Null in tests, which keep nothing.
class GaiaZoomLevel extends ValueNotifier<double> {
  GaiaZoomLevel({this.file}) : super(1);

  final File? file;

  Future<void> load() async {
    final file = this.file;
    if (file == null || !await file.exists()) return;
    try {
      final json = jsonDecode(await file.readAsString()) as Map;
      if (json['zoom'] case final num zoom when _steps.contains(zoom)) {
        value = zoom.toDouble();
      }
    } catch (error) {
      debugPrint('[gaia] zoom unreadable, using 100%: $error');
    }
  }

  /// One step in, or out for a negative [by], held at the ends.
  void step(int by) {
    final at = _steps.indexOf(value);
    set(_steps[(at + by).clamp(0, _steps.length - 1)]);
  }

  void set(double zoom) {
    if (zoom == value) return;
    value = zoom;
    // In turn, so an older write never lands after a newer one.
    _saved = _saved.then((_) => _save());
  }

  var _saved = Future<void>.value();

  Future<void> _save() async {
    final file = this.file;
    if (file == null) return;
    try {
      await file.parent.create(recursive: true);
      await file.writeAsString(jsonEncode({'zoom': value}));
    } catch (error) {
      debugPrint('[gaia] zoom not saved: $error');
    }
  }
}

/// Scales [child] by [level], so more or less of the chat fits, with
/// Ctrl+Plus and Ctrl+Minus or Ctrl+scroll, and back to 100% with Ctrl+0. Each press shows
/// the level and a Reset for a
/// moment; hovered, they stay until the cursor leaves. A trackpad pinch
/// steps too, one level per [_pinchStep] of spread.
class GaiaZoom extends StatefulWidget {
  const GaiaZoom({
    super.key,
    required this.level,
    this.pinchable,
    required this.child,
  });

  final GaiaZoomLevel level;

  /// Whether a pinch zooms now; false while something above, like the image
  /// viewer, pinches for itself. Always, when null.
  final bool Function()? pinchable;
  final Widget child;

  @override
  State<GaiaZoom> createState() => _GaiaZoomState();
}

class _GaiaZoomState extends State<GaiaZoom> {
  var _shown = false;
  var _hovered = false;
  Timer? _hide;

  @override
  void dispose() {
    _hide?.cancel();
    super.dispose();
  }

  /// Shown on every press, even one held at the end of the steps.
  void _zoom(VoidCallback change) {
    change();
    setState(() => _shown = true);
    _hideAfter(_shownFor);
  }

  void _reset() => _zoom(() => widget.level.set(1));

  void _hideAfter(Duration delay) {
    _hide?.cancel();
    if (_hovered) return;
    _hide = Timer(delay, () {
      if (mounted) setState(() => _shown = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    void zoomIn() => _zoom(() => widget.level.step(1));
    void zoomOut() => _zoom(() => widget.level.step(-1));
    return CallbackShortcuts(
      bindings: {
        // Plus is Shift+= on most keyboards; either does.
        const SingleActivator(LogicalKeyboardKey.equal, control: true): zoomIn,
        const SingleActivator(
          LogicalKeyboardKey.equal,
          control: true,
          shift: true,
        ): zoomIn,
        // A key of its own on German and Nordic keyboards.
        const SingleActivator(LogicalKeyboardKey.add, control: true): zoomIn,
        const SingleActivator(LogicalKeyboardKey.numpadAdd, control: true):
            zoomIn,
        const SingleActivator(LogicalKeyboardKey.minus, control: true): zoomOut,
        const SingleActivator(LogicalKeyboardKey.numpadSubtract, control: true):
            zoomOut,
        const SingleActivator(LogicalKeyboardKey.digit0, control: true): _reset,
        const SingleActivator(LogicalKeyboardKey.numpad0, control: true):
            _reset,
      },
      child: _ZoomGestures(
        // Wheel up zooms in, as in a browser.
        onScroll: (event) => switch (event.scrollDelta.dy) {
          < 0 => zoomIn(),
          > 0 => zoomOut(),
          _ => null,
        },
        pinchable: widget.pinchable ?? () => true,
        onPinch: (by) => by > 0 ? zoomIn() : zoomOut(),
        child: ValueListenableBuilder(
          valueListenable: widget.level,
          builder: (context, zoom, child) => Stack(
            children: [
              Positioned.fill(child: _scaled(context, zoom, child!)),
              Positioned(
                left: 16,
                right: 16,
                // Below the header, where Gaia's toasts come too.
                top: 64,
                child: Center(
                  child: IgnorePointer(
                    ignoring: !_shown,
                    child: AnimatedOpacity(
                      opacity: _shown ? 1 : 0,
                      duration: Duration(milliseconds: _shown ? 120 : 400),
                      child: MouseRegion(
                        onEnter: (_) {
                          _hovered = true;
                          _hide?.cancel();
                        },
                        onExit: (_) {
                          _hovered = false;
                          _hideAfter(_hoveredFor);
                        },
                        child: _indicator(context, zoom),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
          child: widget.child,
        ),
      ),
    );
  }

  /// [child] laid out in the room it has at [zoom], then scaled to fill
  /// the real room, as a browser zooms a page. The overflow outside the
  /// scale: the other way round, the overflow's own bounds cut off clicks
  /// past the window's unzoomed size, so zoomed out the right and bottom
  /// went dead.
  Widget _scaled(BuildContext context, double zoom, Widget child) {
    final media = MediaQuery.of(context);
    return LayoutBuilder(
      builder: (context, constraints) => OverflowBox(
        alignment: Alignment.topLeft,
        minWidth: constraints.maxWidth / zoom,
        maxWidth: constraints.maxWidth / zoom,
        minHeight: constraints.maxHeight / zoom,
        maxHeight: constraints.maxHeight / zoom,
        child: Transform.scale(
          scale: zoom,
          alignment: Alignment.topLeft,
          child: MediaQuery(
            data: media.copyWith(size: media.size / zoom),
            child: child,
          ),
        ),
      ),
    );
  }

  Widget _indicator(BuildContext context, double zoom) {
    final colors = Theme.of(context).colorScheme;
    return Material(
      type: MaterialType.transparency,
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 4, 4, 4),
        decoration: BoxDecoration(
          color: Color.lerp(colors.surface, Colors.black, 0.5),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: Colors.white.withValues(alpha: 0.12)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.45),
              blurRadius: 18,
              offset: const Offset(0, 6),
            ),
          ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              PhosphorIconsRegular.magnifyingGlass,
              size: 14,
              color: Colors.white70,
            ),
            const SizedBox(width: 6),
            Text(
              '${(zoom * 100).round()}%',
              style: const TextStyle(color: Colors.white, fontSize: 13),
            ),
            const SizedBox(width: 8),
            GaiaButton(
              onPressed: zoom == 1 ? null : _reset,
              label: 'Reset',
              size: 28,
              padding: 10,
              // A pill, so its ends follow the indicator's.
              radius: 14,
            ),
          ],
        ),
      ),
    );
  }
}

/// Hands Ctrl+scroll to [onScroll] instead of the scroll views inside, and
/// each [_pinchStep] of a trackpad pinch to [onPinch]: 1 spread, -1 closed.
class _ZoomGestures extends SingleChildRenderObjectWidget {
  const _ZoomGestures({
    required this.onScroll,
    required this.pinchable,
    required this.onPinch,
    super.child,
  });

  final void Function(PointerScrollEvent event) onScroll;
  final bool Function() pinchable;
  final void Function(int by) onPinch;

  @override
  _RenderZoomGestures createRenderObject(BuildContext context) =>
      _RenderZoomGestures(onScroll, pinchable, onPinch);

  @override
  void updateRenderObject(BuildContext context, _RenderZoomGestures render) =>
      render
        ..onScroll = onScroll
        ..pinchable = pinchable
        ..onPinch = onPinch;
}

class _RenderZoomGestures extends RenderProxyBox {
  _RenderZoomGestures(this.onScroll, this.pinchable, this.onPinch);

  void Function(PointerScrollEvent event) onScroll;
  bool Function() pinchable;
  void Function(int by) onPinch;

  /// The pinch's scale at its last step, by pointer; none for one that
  /// started where it can't zoom.
  final _pinched = <int, double>{};

  /// In the hit test ahead of the children, so it sees a scroll first and
  /// claims it before any scroll view inside can: the first to claim one
  /// gets it.
  @override
  bool hitTest(BoxHitTestResult result, {required Offset position}) {
    if (!size.contains(position)) return false;
    result.add(BoxHitTestEntry(this, position));
    hitTestChildren(result, position: position);
    return true;
  }

  @override
  void handleEvent(PointerEvent event, BoxHitTestEntry entry) {
    // The scroll views take the same events' pan; a pinch keeps no more
    // than a stray scroll, so they are left to it.
    switch (event) {
      case PointerPanZoomStartEvent() when pinchable():
        _pinched[event.pointer] = 1;
        return;
      case PointerPanZoomUpdateEvent():
        final last = _pinched[event.pointer];
        if (last == null) return;
        var at = last;
        // A fast pinch can pass more than one step between updates.
        while (event.scale >= at * _pinchStep) {
          at *= _pinchStep;
          onPinch(1);
        }
        while (event.scale <= at / _pinchStep) {
          at /= _pinchStep;
          onPinch(-1);
        }
        _pinched[event.pointer] = at;
        return;
      case PointerPanZoomEndEvent():
        _pinched.remove(event.pointer);
        return;
    }
    if (event is! PointerScrollEvent) return;
    if (!HardwareKeyboard.instance.isControlPressed) return;
    GestureBinding.instance.pointerSignalResolver.register(
      event,
      (event) => onScroll(event as PointerScrollEvent),
    );
  }
}

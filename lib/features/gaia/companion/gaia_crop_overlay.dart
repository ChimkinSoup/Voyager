import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// The region capture's crop (GAIA_HLD.md §3.2, §15.1 C): the frozen frame
/// of the monitor at 1:1, dimmed outside the region being dragged out.
/// Letting go crops to it; Enter takes the whole monitor; Esc cancels.
/// [onDone] gets the region in the frame's pixels, or null.
class GaiaCropOverlay extends StatefulWidget {
  const GaiaCropOverlay({
    super.key,
    required this.path,
    required this.pixelWidth,
    required this.onDone,
  });

  final String path;

  /// The frame's width in pixels, which the view's maps onto.
  final int pixelWidth;
  final void Function(Rect? region) onDone;

  @override
  State<GaiaCropOverlay> createState() => _GaiaCropOverlayState();
}

class _GaiaCropOverlayState extends State<GaiaCropOverlay> {
  Offset? _start;
  Offset? _end;
  var _done = false;

  Rect? get _region =>
      _start == null || _end == null ? null : Rect.fromPoints(_start!, _end!);

  void _finish(Rect? viewRegion, Size view) {
    if (_done) return;
    _done = true;
    if (viewRegion == null) return widget.onDone(null);
    final scale = widget.pixelWidth / view.width;
    widget.onDone(
      Rect.fromLTRB(
        viewRegion.left * scale,
        viewRegion.top * scale,
        viewRegion.right * scale,
        viewRegion.bottom * scale,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final view = constraints.biggest;
        return CallbackShortcuts(
          bindings: {
            const SingleActivator(LogicalKeyboardKey.escape): () =>
                _finish(null, view),
            const SingleActivator(LogicalKeyboardKey.enter): () =>
                _finish(Offset.zero & view, view),
          },
          child: Focus(
            autofocus: true,
            child: MouseRegion(
              cursor: SystemMouseCursors.precise,
              child: GestureDetector(
                onPanStart: (details) => setState(() {
                  _start = details.localPosition;
                  _end = details.localPosition;
                }),
                onPanUpdate: (details) =>
                    setState(() => _end = details.localPosition),
                onPanEnd: (_) {
                  final region = _region;
                  // A click, not a drag: nothing to crop to yet.
                  if (region == null || region.width < 4 || region.height < 4) {
                    return setState(() => _start = _end = null);
                  }
                  _finish(region, view);
                },
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    Image.file(
                      File(widget.path),
                      fit: BoxFit.fill,
                      filterQuality: FilterQuality.none,
                      gaplessPlayback: true,
                    ),
                    CustomPaint(painter: _Shade(region: _region)),
                    if (_region == null)
                      const Positioned(
                        top: 24,
                        left: 0,
                        right: 0,
                        child: Center(child: _Hint()),
                      ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _Hint extends StatelessWidget {
  const _Hint();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.7),
        borderRadius: BorderRadius.circular(8),
      ),
      child: const Text(
        'Drag to capture a region · Enter for the whole screen · Esc to cancel',
        style: TextStyle(color: Colors.white),
      ),
    );
  }
}

class _Shade extends CustomPainter {
  const _Shade({required this.region});

  final Rect? region;

  @override
  void paint(Canvas canvas, Size size) {
    final shade = Paint()..color = Colors.black.withValues(alpha: 0.45);
    final region = this.region;
    if (region == null) {
      canvas.drawRect(Offset.zero & size, shade);
      return;
    }
    canvas
      ..drawPath(
        Path.combine(
          PathOperation.difference,
          Path()..addRect(Offset.zero & size),
          Path()..addRect(region),
        ),
        shade,
      )
      ..drawRect(
        region,
        Paint()
          ..color = Colors.white
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1,
      );
  }

  @override
  bool shouldRepaint(_Shade old) => old.region != region;
}

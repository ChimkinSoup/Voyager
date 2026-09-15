import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:voyager/core/widgets/resizable_pane_divider.dart';

/// Geometry and caps for the Todo / Jobs / Rankings right-hand editors.
///
/// One shared preference drives all three pages so the family stays synced.
class EditSidePanelMetrics {
  EditSidePanelMetrics._();

  static const defaultWidth = 420.0;
  static const minWidth = 320.0;
  static const maxWidth = 600.0;
  static const maxFraction = 0.45;
  static const duration = Duration(milliseconds: 220);

  /// Remaining list width required to keep push (side-by-side) mode.
  static const todoListMinWidth = 300.0;
  static const rankingsListMinWidth = 300.0;
  static const jobsListMinWidth = 380.0;

  static double maxAllowed(double pageWidth) {
    final fractionCap = pageWidth * maxFraction;
    // On a wide page the fraction is the real cap. On a narrow one it falls
    // below [minWidth]; allowing up to the page itself lets overlay mode keep
    // a usable panel instead of shrinking to 320 and flipping back to push.
    if (fractionCap >= minWidth) {
      return math.min(maxWidth, fractionCap);
    }
    return math.min(maxWidth, pageWidth);
  }

  static double clampWidth(double width, double pageWidth) {
    return width.clamp(minWidth, maxAllowed(pageWidth));
  }

  static double dragClampWidth(double width, double pageWidth) {
    return resizePaneRubberBand(
      width: width,
      totalWidth: pageWidth,
      minWidth: minWidth,
      maxWidth: maxAllowed(pageWidth),
    );
  }

  static double resolveWidth(double? stored, double pageWidth) {
    return clampWidth(stored ?? defaultWidth, pageWidth);
  }

  /// Prefer push while the list would keep at least [listMinWidth]; otherwise
  /// overlay so a half-width window does not crush the rows.
  static bool shouldPush({
    required double pageWidth,
    required double panelWidth,
    required double listMinWidth,
  }) {
    return pageWidth - panelWidth >= listMinWidth;
  }
}

/// Shared host for the right-hand edit panel: push when there is room, overlay
/// when there is not, with a capped resizable width.
///
/// Panel *contents* stay feature-specific. This widget only owns open/close
/// geometry, the reveal animation, and the resize divider.
class EditSidePanelHost extends StatefulWidget {
  const EditSidePanelHost({
    super.key,
    required this.animation,
    required this.listMinWidth,
    required this.storedWidth,
    required this.onWidthCommitted,
    required this.list,
    required this.panel,
  });

  final Animation<double> animation;

  /// Minimum list width that must remain for push mode (see
  /// [EditSidePanelMetrics]).
  final double listMinWidth;

  /// Persisted width from settings, or null for the default.
  final double? storedWidth;

  /// Called when a drag ends or the divider is double-tapped to reset.
  /// Pass null to clear the stored preference back to the default.
  final ValueChanged<double?> onWidthCommitted;

  final Widget list;

  /// The open editor, or null when nothing is selected. The host still paints
  /// the sliding chrome while [animation] is non-zero so close can finish.
  final Widget? panel;

  @override
  State<EditSidePanelHost> createState() => _EditSidePanelHostState();
}

class _EditSidePanelHostState extends State<EditSidePanelHost> {
  double? _liveWidth;
  double? _dragStartWidth;
  var _dragging = false;

  @override
  void didUpdateWidget(EditSidePanelHost oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_dragging && oldWidget.storedWidth != widget.storedWidth) {
      _liveWidth = null;
    }
  }

  void _onDragStart(double pageWidth) {
    _dragStartWidth = _liveWidth ??
        EditSidePanelMetrics.resolveWidth(widget.storedWidth, pageWidth);
    setState(() => _dragging = true);
  }

  void _onDragUpdate(double totalDelta, double pageWidth) {
    final start = _dragStartWidth;
    if (start == null) return;
    // Divider is on the panel's left edge: drag left (negative delta) widens.
    setState(() {
      _liveWidth = EditSidePanelMetrics.dragClampWidth(
        start - totalDelta,
        pageWidth,
      );
    });
  }

  void _onDragEnd(double pageWidth) {
    final settled = EditSidePanelMetrics.clampWidth(
      _liveWidth ??
          EditSidePanelMetrics.resolveWidth(widget.storedWidth, pageWidth),
      pageWidth,
    );
    setState(() {
      _liveWidth = settled;
      _dragging = false;
      _dragStartWidth = null;
    });
    final stored = widget.storedWidth;
    if (stored != null && (settled - stored).abs() < 0.5) return;
    if (stored == null &&
        (settled - EditSidePanelMetrics.defaultWidth).abs() < 0.5) {
      return;
    }
    widget.onWidthCommitted(settled);
  }

  void _onReset() {
    setState(() {
      _liveWidth = null;
      _dragging = false;
      _dragStartWidth = null;
    });
    widget.onWidthCommitted(null);
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final pageWidth = constraints.maxWidth;
        final panelWidth = _liveWidth ??
            EditSidePanelMetrics.resolveWidth(widget.storedWidth, pageWidth);
        final push = EditSidePanelMetrics.shouldPush(
          pageWidth: pageWidth,
          panelWidth: panelWidth,
          listMinWidth: widget.listMinWidth,
        );

        return Stack(
          children: [
            AnimatedBuilder(
              animation: widget.animation,
              builder: (context, child) {
                final t = widget.animation.value.clamp(0.0, 1.0);
                final inset = push ? panelWidth * t : 0.0;
                return Positioned(
                  left: 0,
                  top: 0,
                  bottom: 0,
                  right: inset,
                  child: child!,
                );
              },
              child: widget.list,
            ),
            Positioned(
              top: 0,
              bottom: 0,
              right: 0,
              child: ClipRect(
                child: AnimatedBuilder(
                  animation: widget.animation,
                  builder: (context, child) {
                    return Align(
                      alignment: Alignment.centerRight,
                      widthFactor: widget.animation.value.clamp(0.0, 1.0),
                      child: child,
                    );
                  },
                  child: SizedBox(
                    width: panelWidth,
                    child: Stack(
                      children: [
                        Positioned.fill(
                          child: widget.panel ?? const SizedBox.shrink(),
                        ),
                        Positioned(
                          left: 0,
                          top: 0,
                          bottom: 0,
                          child: ResizablePaneDivider(
                            onDragStart: () => _onDragStart(pageWidth),
                            onDragUpdate: (delta) =>
                                _onDragUpdate(delta, pageWidth),
                            onDragEnd: () => _onDragEnd(pageWidth),
                            onDoubleTapReset: _onReset,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

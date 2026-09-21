import 'package:flutter/material.dart';

class ResizablePaneDivider extends StatefulWidget {
  const ResizablePaneDivider({
    super.key,
    this.onDragStart,
    required this.onDragUpdate,
    this.onDragEnd,
    this.onDoubleTapReset,
    this.width = 12,
    this.showLine = true,
  });

  final VoidCallback? onDragStart;
  final ValueChanged<double> onDragUpdate;
  final VoidCallback? onDragEnd;
  final VoidCallback? onDoubleTapReset;
  final double width;

  /// Whether to draw the grab line. False where the pane beside it already
  /// draws its own edge, so the two do not read as a double rule — the resize
  /// cursor is then the only affordance.
  final bool showLine;

  @override
  State<ResizablePaneDivider> createState() => _ResizablePaneDividerState();
}

class _ResizablePaneDividerState extends State<ResizablePaneDivider> {
  var _dragging = false;
  var _hovering = false;
  double? _dragStartGlobalX;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final lineColor = _dragging
        ? theme.colorScheme.primary
        : _hovering
        ? theme.colorScheme.onSurface.withValues(alpha: 0.35)
        : theme.dividerColor;

    return MouseRegion(
      cursor: SystemMouseCursors.resizeColumn,
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onHorizontalDragStart: (details) {
          _dragStartGlobalX = details.globalPosition.dx;
          setState(() => _dragging = true);
          widget.onDragStart?.call();
        },
        onHorizontalDragUpdate: (details) {
          final startX = _dragStartGlobalX;
          if (startX == null) return;
          widget.onDragUpdate(details.globalPosition.dx - startX);
        },
        onHorizontalDragEnd: (_) {
          _dragStartGlobalX = null;
          setState(() => _dragging = false);
          widget.onDragEnd?.call();
        },
        onHorizontalDragCancel: () {
          _dragStartGlobalX = null;
          setState(() => _dragging = false);
          widget.onDragEnd?.call();
        },
        onDoubleTap: widget.onDoubleTapReset,
        child: SizedBox(
          width: widget.width,
          child: widget.showLine
              ? Center(
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 120),
                    width: _dragging || _hovering ? 3 : 1,
                    margin: const EdgeInsets.symmetric(vertical: 8),
                    decoration: BoxDecoration(
                      color: lineColor,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                )
              : null,
        ),
      ),
    );
  }
}

class JournalEntryListLayout {
  JournalEntryListLayout._();

  static const dividerWidth = 12.0;
  static const minListWidth = 180.0;
  static const maxListWidth = 520.0;

  /// The editor's metadata controls — weather, a date pill that never
  /// truncates, trash, plus the dev remote-pull button — need ~335px inside
  /// [editorPadding] even with the mood bar moved to a line of its own. At
  /// 360 a wide stored list overflowed them in a minimum-size window; 432 is
  /// what that window leaves beside a [minListWidth] list.
  static const minEditorWidth = 432.0;

  static double defaultListWidth(double totalWidth) {
    return (totalWidth * 0.22).clamp(minListWidth, 320.0);
  }

  static double _maxAllowed(double totalWidth) =>
      (totalWidth - minEditorWidth - dividerWidth).clamp(
        minListWidth,
        maxListWidth,
      );

  /// A hard cap, applied during the drag as well as after it: the divider
  /// stops at the bound rather than stretching past and snapping back, so the
  /// editor is never squeezed narrower than it can be read at.
  static double clampListWidth(double width, double totalWidth) {
    return width.clamp(minListWidth, _maxAllowed(totalWidth));
  }

  static const editorPadding = EdgeInsets.fromLTRB(24, 40, 24, 24);
}

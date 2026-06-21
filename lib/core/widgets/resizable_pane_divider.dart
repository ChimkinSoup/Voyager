import 'package:flutter/material.dart';

class ResizablePaneDivider extends StatefulWidget {
  const ResizablePaneDivider({
    super.key,
    this.onDragStart,
    required this.onDragUpdate,
    this.onDragEnd,
    this.onDoubleTapReset,
    this.width = 12,
  });

  final VoidCallback? onDragStart;
  final ValueChanged<double> onDragUpdate;
  final VoidCallback? onDragEnd;
  final VoidCallback? onDoubleTapReset;
  final double width;

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
          child: Center(
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 120),
              width: _dragging || _hovering ? 3 : 1,
              margin: const EdgeInsets.symmetric(vertical: 8),
              decoration: BoxDecoration(
                color: lineColor,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
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
  static const minEditorWidth = 360.0;

  static double defaultListWidth(double totalWidth) {
    return (totalWidth * 0.22).clamp(minListWidth, 320.0);
  }

  static double clampListWidth(double width, double totalWidth) {
    final maxAllowed = (totalWidth - minEditorWidth - dividerWidth).clamp(
      minListWidth,
      maxListWidth,
    );
    return width.clamp(minListWidth, maxAllowed);
  }

  static const editorPadding = EdgeInsets.fromLTRB(24, 40, 24, 24);
}

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:voyager/core/theme/voyager_menu_theme.dart';

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/// A single item in a [ContextMenuRegion].
class ContextMenuItem {
  const ContextMenuItem({
    required this.label,
    this.icon,
    this.isDestructive = false,
    this.onTap,
    this.enabled = true,
  });

  final String label;
  final IconData? icon;
  final bool isDestructive;
  final bool enabled;

  /// Called when the item is tapped. If null, the item is rendered as disabled.
  final VoidCallback? onTap;
}

/// Wraps [child] so that right-clicking anywhere inside it opens a context
/// menu anchored to the pointer position.
///
/// The menu is inserted directly into the nearest [Overlay] — it does NOT
/// use [showMenu] or the Navigator, so it cannot cause the modal-barrier focus
/// lock that occurs on Windows.
///
/// Example:
/// ```dart
/// ContextMenuRegion(
///   items: [
///     ContextMenuItem(label: 'Edit', icon: PhosphorIconsRegular.pencil, onTap: _edit),
///     ContextMenuItem(label: 'Delete', icon: PhosphorIconsRegular.trash,
///                     isDestructive: true, onTap: _delete),
///   ],
///   child: MyWidget(),
/// )
/// ```
class ContextMenuRegion extends StatefulWidget {
  const ContextMenuRegion({
    super.key,
    required this.child,
    required this.items,
    this.dismissDistance = 220.0,
  });

  final Widget child;
  final List<ContextMenuItem> items;
  final double dismissDistance;

  @override
  State<ContextMenuRegion> createState() => _ContextMenuRegionState();
}

class _ContextMenuRegionState extends State<ContextMenuRegion> {
  OverlayEntry? _menuEntry;

  void _openMenu(Offset globalPosition) {
    _closeMenu();
    final entry = OverlayEntry(
      builder: (ctx) => _ContextMenuOverlay(
        anchor: globalPosition,
        items: widget.items,
        dismissDistance: widget.dismissDistance,
        onDismiss: _closeMenu,
        capturedThemes: InheritedTheme.capture(
          from: context,
          to: Overlay.of(context, rootOverlay: true).context,
        ),
      ),
    );
    _menuEntry = entry;
    Overlay.of(context, rootOverlay: true).insert(entry);
  }

  void _closeMenu() {
    final entry = _menuEntry;
    _menuEntry = null;
    entry?.remove();
  }

  @override
  void dispose() {
    _closeMenu();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onSecondaryTapUp: (details) => _openMenu(details.globalPosition),
      behavior: HitTestBehavior.translucent,
      child: widget.child,
    );
  }
}

// ---------------------------------------------------------------------------
// Internal overlay widget
// ---------------------------------------------------------------------------

class _ContextMenuOverlay extends StatefulWidget {
  const _ContextMenuOverlay({
    required this.anchor,
    required this.items,
    required this.dismissDistance,
    required this.onDismiss,
    required this.capturedThemes,
  });

  final Offset anchor;
  final List<ContextMenuItem> items;
  final double dismissDistance;

  /// Called SYNCHRONOUSLY when the menu should be removed from the overlay.
  final VoidCallback onDismiss;
  final CapturedThemes capturedThemes;

  @override
  State<_ContextMenuOverlay> createState() => _ContextMenuOverlayState();
}

class _ContextMenuOverlayState extends State<_ContextMenuOverlay>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _anim;
  final GlobalKey _menuKey = GlobalKey();

  // FocusNode stored in state so it is created ONCE and disposed properly.
  // Creating it inside build() leaked nodes and caused focus churn on hover.
  late final FocusNode _focusNode;

  int? _hoveredIndex;

  static const double _minWidth = 190.0;
  static const double _radius = 12.0;
  static const double _verticalPadding = 6.0;

  @override
  void initState() {
    super.initState();
    _focusNode = FocusNode();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 150),
    );
    _anim = CurvedAnimation(parent: _controller, curve: Curves.easeOutCubic);
    _controller.forward();
  }

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  /// Dismiss the menu SYNCHRONOUSLY — removes the overlay entry immediately
  /// so no click-blocking barrier lingers.  The entrance animation plays but
  /// there is no exit animation; instant removal feels snappy.
  void _dismiss() {
    widget.onDismiss();
  }

  void _handlePointerMove(PointerEvent event) {
    if ((event.position - widget.anchor).distance > widget.dismissDistance) {
      _dismiss();
    }
  }

  void _handlePointerDown(PointerDownEvent event) {
    final renderBox = _menuKey.currentContext?.findRenderObject() as RenderBox?;
    if (renderBox != null) {
      final localOffset = renderBox.globalToLocal(event.position);
      final isInside = renderBox.paintBounds.contains(localOffset);
      if (!isInside) {
        _dismiss();
      }
    } else {
      _dismiss();
    }
  }

  void _handleItemTap(ContextMenuItem item) {
    if (!item.enabled || item.onTap == null) return;
    _dismiss(); // Remove overlay immediately.
    // Microtask so the overlay teardown finishes before the action runs.
    Future.microtask(item.onTap!);
  }

  BorderRadius _itemRadius(int index, int count) {
    if (count == 1) return BorderRadius.circular(_radius);
    if (index == 0) {
      return const BorderRadius.vertical(top: Radius.circular(_radius));
    }
    if (index == count - 1) {
      return const BorderRadius.vertical(bottom: Radius.circular(_radius));
    }
    return BorderRadius.zero;
  }

  @override
  Widget build(BuildContext context) {
    return widget.capturedThemes.wrap(
      KeyboardListener(
        focusNode: _focusNode,
        autofocus: true,
        onKeyEvent: (event) {
          if (event is KeyDownEvent &&
              event.logicalKey == LogicalKeyboardKey.escape) {
            _dismiss();
          }
        },
        child: Listener(
          onPointerMove: _handlePointerMove,
          behavior: HitTestBehavior.translucent,
          child: Stack(
            fit: StackFit.expand,
            children: [
              // Transparent full-screen barrier.
              // We use Listener with onPointerDown so any click anywhere (even if absorbed by
              // a child widget's gesture recognizer) will dismiss the menu immediately.
              Listener(
                onPointerDown: _handlePointerDown,
                behavior: HitTestBehavior.translucent,
                child: const SizedBox.expand(),
              ),
              // The positioned, animated menu.
              CustomSingleChildLayout(
                delegate: _ContextMenuLayoutDelegate(
                  anchor: widget.anchor,
                  minWidth: _minWidth,
                ),
                child: FadeTransition(
                  opacity: _anim,
                  child: ScaleTransition(
                    scale: Tween<double>(begin: 0.93, end: 1.0).animate(_anim),
                    alignment: Alignment.topLeft,
                    child: _buildMenu(context),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildMenu(BuildContext context) {
    final theme = Theme.of(context);
    final items = widget.items;
    return Material(
      key: _menuKey,
      color: Colors.transparent,
      child: Container(
        constraints: const BoxConstraints(minWidth: _minWidth),
        decoration: BoxDecoration(
          color: VoyagerMenuTheme.menuColor,
          borderRadius: BorderRadius.circular(_radius),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.40),
              blurRadius: 20,
              offset: const Offset(0, 8),
            ),
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.18),
              blurRadius: 4,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(_radius),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (var i = 0; i < items.length; i++) ...[
                if (i > 0 &&
                    items[i].isDestructive &&
                    !items[i - 1].isDestructive)
                  Divider(
                    height: 1,
                    thickness: 1,
                    color: theme.colorScheme.onSurface
                        .withValues(alpha: 0.10),
                    indent: 14,
                    endIndent: 14,
                  ),
                _ContextMenuItemTile(
                  item: items[i],
                  isHovered: _hoveredIndex == i,
                  borderRadius: _itemRadius(i, items.length),
                  padding: EdgeInsets.only(
                    left: 14,
                    right: 14,
                    top: i == 0 ? 10 + _verticalPadding : 10,
                    bottom: i == items.length - 1 ? 10 + _verticalPadding : 10,
                  ),
                  onHover: (v) =>
                      setState(() => _hoveredIndex = v ? i : null),
                  onTap: () => _handleItemTap(items[i]),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Item tile
// ---------------------------------------------------------------------------

class _ContextMenuItemTile extends StatelessWidget {
  const _ContextMenuItemTile({
    required this.item,
    required this.isHovered,
    required this.borderRadius,
    required this.padding,
    required this.onHover,
    required this.onTap,
  });

  final ContextMenuItem item;
  final bool isHovered;
  final BorderRadius borderRadius;
  final EdgeInsetsGeometry padding;
  final void Function(bool) onHover;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isEnabled = item.enabled && item.onTap != null;
    final double opacity = isEnabled ? 1.0 : 0.38;

    final Color textColor = item.isDestructive
        ? Colors.red.shade400.withValues(alpha: opacity)
        : theme.colorScheme.onSurface.withValues(alpha: opacity);
    final Color iconColor = item.isDestructive
        ? Colors.red.shade400.withValues(alpha: opacity)
        : theme.colorScheme.onSurface.withValues(alpha: opacity * 0.85);
    final Color hoverColor = item.isDestructive
        ? Colors.red.withValues(alpha: 0.12)
        : theme.colorScheme.onSurface.withValues(alpha: 0.08);

    return MouseRegion(
      onEnter: (_) => onHover(true),
      onExit: (_) => onHover(false),
      cursor: isEnabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
      child: GestureDetector(
        onTap: isEnabled ? onTap : null,
        behavior: HitTestBehavior.opaque,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 80),
          decoration: BoxDecoration(
            color: isHovered && isEnabled ? hoverColor : Colors.transparent,
            borderRadius: borderRadius,
          ),
          padding: padding,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (item.icon != null) ...[
                Icon(item.icon, size: 16, color: iconColor),
                const SizedBox(width: 10),
              ] else
                const SizedBox(width: 2),
              Flexible(
                child: Text(
                  item.label,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: textColor,
                    fontWeight: FontWeight.w500,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Layout delegate
// ---------------------------------------------------------------------------

class _ContextMenuLayoutDelegate extends SingleChildLayoutDelegate {
  _ContextMenuLayoutDelegate({
    required this.anchor,
    required this.minWidth,
  });

  final Offset anchor;
  final double minWidth;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) {
    return BoxConstraints(
      minWidth: minWidth,
      maxWidth: math.min(280.0, constraints.maxWidth - 16),
      minHeight: 0,
      maxHeight: constraints.maxHeight * 0.85,
    );
  }

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    const margin = 8.0;
    double x = anchor.dx;
    double y = anchor.dy;

    if (x + childSize.width > size.width - margin) {
      x = anchor.dx - childSize.width;
    }
    x = x.clamp(margin, size.width - childSize.width - margin);

    if (y + childSize.height > size.height - margin) {
      y = anchor.dy - childSize.height;
    }
    y = y.clamp(margin, size.height - childSize.height - margin);

    return Offset(x, y);
  }

  @override
  bool shouldRelayout(_ContextMenuLayoutDelegate oldDelegate) =>
      anchor != oldDelegate.anchor;
}

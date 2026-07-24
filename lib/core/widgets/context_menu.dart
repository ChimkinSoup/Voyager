import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:voyager/core/theme/voyager_menu_theme.dart';
import 'package:voyager/core/theme/voyager_theme.dart';

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/// A single item in a [ContextMenuRegion].
///
/// Provide [children] to turn the item into a submenu parent: hovering (or
/// clicking) it opens a flyout listing the children to the side.
class ContextMenuItem {
  const ContextMenuItem({
    required this.label,
    this.icon,
    this.leading,
    this.trailing,
    this.isDestructive = false,
    this.onTap,
    this.enabled = true,
    this.children,
  });

  final String label;
  final IconData? icon;

  /// Optional widget rendered in the leading (icon) slot. Overrides [icon].
  final Widget? leading;

  /// Optional widget rendered on the trailing edge (e.g. a checkmark). When the
  /// item [hasChildren] and no [trailing] is given, a submenu caret is shown.
  final Widget? trailing;

  final bool isDestructive;
  final bool enabled;

  /// Called when the item is tapped. If null (and the item has no [children]),
  /// the item is rendered as disabled.
  final VoidCallback? onTap;

  /// Submenu items. When non-empty this item becomes a submenu parent and its
  /// own [onTap] is ignored (tapping/hovering opens the flyout instead).
  final List<ContextMenuItem>? children;

  bool get hasChildren => children != null && children!.isNotEmpty;
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
///     ContextMenuItem(
///       label: 'Move to',
///       icon: PhosphorIconsRegular.folder,
///       children: [
///         ContextMenuItem(label: 'Work', onTap: () => _move('work')),
///         ContextMenuItem(label: 'Personal', onTap: () => _move('personal')),
///       ],
///     ),
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
  final GlobalKey _submenuKey = GlobalKey();

  // FocusNode stored in state so it is created ONCE and disposed properly.
  // Creating it inside build() leaked nodes and caused focus churn on hover.
  late final FocusNode _focusNode;

  int? _hoveredIndex;
  int? _hoveredSubIndex;

  // Which root item's submenu is currently open (null = none) and the global
  // rect of that parent tile, used to anchor the flyout.
  int? _openSubmenuIndex;
  Rect? _submenuAnchor;

  // GlobalKeys for the root tiles so their on-screen rect can be measured when
  // a submenu opens.
  final Map<int, GlobalKey> _itemKeys = {};

  GlobalKey _keyFor(int index) =>
      _itemKeys.putIfAbsent(index, () => GlobalKey());

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

  Rect? _rectForKey(GlobalKey key) {
    final box = key.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return null;
    return box.localToGlobal(Offset.zero) & box.size;
  }

  double _distanceToRect(GlobalKey key, Offset point) {
    final rect = _rectForKey(key);
    if (rect == null) return double.infinity;
    final dx = point.dx < rect.left
        ? rect.left - point.dx
        : (point.dx > rect.right ? point.dx - rect.right : 0.0);
    final dy = point.dy < rect.top
        ? rect.top - point.dy
        : (point.dy > rect.bottom ? point.dy - rect.bottom : 0.0);
    return math.sqrt(dx * dx + dy * dy);
  }

  void _handlePointerMove(PointerEvent event) {
    // Dismiss only when the pointer strays far from BOTH menu panels — measured
    // from the panel edges (not the original anchor) so tall/wide menus and
    // open submenus don't dismiss while the pointer is still traversing them.
    final gap = math.min(
      _distanceToRect(_menuKey, event.position),
      _distanceToRect(_submenuKey, event.position),
    );
    if (gap > widget.dismissDistance) {
      _dismiss();
    }
  }

  bool _isInsideKey(GlobalKey key, Offset globalPosition) {
    final box = key.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return false;
    final localOffset = box.globalToLocal(globalPosition);
    return box.paintBounds.contains(localOffset);
  }

  void _handlePointerDown(PointerDownEvent event) {
    if (_isInsideKey(_menuKey, event.position) ||
        _isInsideKey(_submenuKey, event.position)) {
      return;
    }
    _dismiss();
  }

  void _handleRootHover(int index, bool hovering) {
    setState(() {
      if (hovering) {
        _hoveredIndex = index;
        final item = widget.items[index];
        if (item.enabled && item.hasChildren) {
          _openSubmenuIndex = index;
          _hoveredSubIndex = null;
          _submenuAnchor = _rectForKey(_keyFor(index));
        } else {
          // Hovering a leaf item closes any open submenu.
          _openSubmenuIndex = null;
          _submenuAnchor = null;
        }
      } else if (_hoveredIndex == index) {
        _hoveredIndex = null;
      }
    });
  }

  void _handleItemTap(ContextMenuItem item) {
    if (!item.enabled) return;
    // Submenu parents don't act on tap; the flyout is already shown on hover.
    if (item.hasChildren) return;
    if (item.onTap == null) return;
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
                    child: _buildRootMenu(context),
                  ),
                ),
              ),
              // The submenu flyout (if any) anchored to the parent tile.
              if (_openSubmenuIndex != null && _submenuAnchor != null)
                _buildSubmenu(context),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildRootMenu(BuildContext context) {
    return _MenuPanel(
      panelKey: _menuKey,
      items: widget.items,
      radius: _radius,
      verticalPadding: _verticalPadding,
      minWidth: _minWidth,
      itemRadius: _itemRadius,
      isHovered: (i) => _hoveredIndex == i || _openSubmenuIndex == i,
      onHover: _handleRootHover,
      onTap: _handleItemTap,
      itemKeyFor: _keyFor,
    );
  }

  Widget _buildSubmenu(BuildContext context) {
    final children = widget.items[_openSubmenuIndex!].children!;
    return CustomSingleChildLayout(
      delegate: _SubmenuLayoutDelegate(anchor: _submenuAnchor!),
      child: FadeTransition(
        opacity: _anim,
        child: _MenuPanel(
          panelKey: _submenuKey,
          items: children,
          radius: _radius,
          verticalPadding: _verticalPadding,
          minWidth: _minWidth,
          itemRadius: _itemRadius,
          isHovered: (i) => _hoveredSubIndex == i,
          onHover: (i, hovering) => setState(() {
            if (hovering) {
              _hoveredSubIndex = i;
            } else if (_hoveredSubIndex == i) {
              _hoveredSubIndex = null;
            }
          }),
          onTap: _handleItemTap,
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Menu panel (shared by the root menu and submenu flyouts)
// ---------------------------------------------------------------------------

class _MenuPanel extends StatelessWidget {
  const _MenuPanel({
    required this.panelKey,
    required this.items,
    required this.radius,
    required this.verticalPadding,
    required this.minWidth,
    required this.itemRadius,
    required this.isHovered,
    required this.onHover,
    required this.onTap,
    this.itemKeyFor,
  });

  final GlobalKey panelKey;
  final List<ContextMenuItem> items;
  final double radius;
  final double verticalPadding;
  final double minWidth;
  final BorderRadius Function(int index, int count) itemRadius;
  final bool Function(int index) isHovered;
  final void Function(int index, bool hovering) onHover;
  final void Function(ContextMenuItem item) onTap;
  final GlobalKey Function(int index)? itemKeyFor;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final vc = VoyagerColors.of(context);
    return Material(
      key: panelKey,
      color: Colors.transparent,
      child: Container(
        constraints: BoxConstraints(minWidth: minWidth),
        decoration: BoxDecoration(
          color: VoyagerMenuTheme.menuColorOf(context),
          borderRadius: BorderRadius.circular(radius),
          boxShadow: [
            BoxShadow(
              color: vc.shadow.withValues(alpha: vc.strongShadowAlpha),
              blurRadius: 20 * vc.shadowBlurScale,
              offset: const Offset(0, 8),
            ),
            BoxShadow(
              color: vc.shadow.withValues(alpha: vc.subtleShadowAlpha),
              blurRadius: 4 * vc.shadowBlurScale,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(radius),
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
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.10),
                    indent: 14,
                    endIndent: 14,
                  ),
                _ContextMenuItemTile(
                  key: itemKeyFor?.call(i),
                  item: items[i],
                  isHovered: isHovered(i),
                  borderRadius: itemRadius(i, items.length),
                  padding: EdgeInsets.only(
                    left: 14,
                    right: 14,
                    top: i == 0 ? 10 + verticalPadding : 10,
                    bottom: i == items.length - 1 ? 10 + verticalPadding : 10,
                  ),
                  onHover: (v) => onHover(i, v),
                  onTap: () => onTap(items[i]),
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
    super.key,
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
    // Submenu parents are always interactive even without an onTap.
    final isEnabled = item.enabled && (item.onTap != null || item.hasChildren);
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

    final Widget? leading = item.leading ??
        (item.icon != null
            ? Icon(item.icon, size: 16, color: iconColor)
            : null);

    final Widget? trailing = item.trailing ??
        (item.hasChildren
            ? Icon(PhosphorIconsRegular.caretRight, size: 14, color: iconColor)
            : null);

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
            children: [
              if (leading != null) ...[
                leading,
                const SizedBox(width: 10),
              ] else
                const SizedBox(width: 2),
              Expanded(
                child: Text(
                  item.label,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: textColor,
                    fontWeight: FontWeight.w500,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (trailing != null) ...[
                const SizedBox(width: 10),
                trailing,
              ],
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Layout delegates
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

/// Positions a submenu flyout beside its parent tile [anchor] (a global rect),
/// preferring the right side and flipping to the left when there isn't room.
class _SubmenuLayoutDelegate extends SingleChildLayoutDelegate {
  _SubmenuLayoutDelegate({required this.anchor});

  final Rect anchor;

  static const double _gap = 3.0;
  static const double _margin = 8.0;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) {
    return BoxConstraints(
      minWidth: 180,
      maxWidth: math.min(280.0, constraints.maxWidth - 16),
      minHeight: 0,
      maxHeight: constraints.maxHeight * 0.85,
    );
  }

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    // Prefer to the right of the parent; flip left if it would overflow.
    double x = anchor.right + _gap;
    if (x + childSize.width > size.width - _margin) {
      x = anchor.left - _gap - childSize.width;
    }
    x = x.clamp(_margin, size.width - childSize.width - _margin);

    // Align the flyout's top with the parent tile's top, then clamp on screen.
    double y = anchor.top - _gap;
    if (y + childSize.height > size.height - _margin) {
      y = size.height - _margin - childSize.height;
    }
    y = y.clamp(_margin, size.height - childSize.height - _margin);

    return Offset(x, y);
  }

  @override
  bool shouldRelayout(_SubmenuLayoutDelegate oldDelegate) =>
      anchor != oldDelegate.anchor;
}

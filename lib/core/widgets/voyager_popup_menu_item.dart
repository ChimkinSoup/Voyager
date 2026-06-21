import 'package:flutter/material.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:voyager/core/theme/voyager_menu_theme.dart';

/// Opens a Voyager-styled popup menu with no outer padding.
Future<T?> showVoyagerMenu<T>({
  required BuildContext context,
  required RelativeRect position,
  required List<PopupMenuEntry<T>> items,
  BoxConstraints? constraints,
}) {
  final menuStyle = VoyagerMenuTheme.showMenuStyle(Theme.of(context));
  return showMenu<T>(
    context: context,
    position: position,
    constraints: constraints,
    shape: menuStyle.shape,
    color: menuStyle.color,
    elevation: menuStyle.elevation,
    shadowColor: menuStyle.shadowColor,
    surfaceTintColor: menuStyle.surfaceTintColor,
    menuPadding: EdgeInsets.zero,
    clipBehavior: Clip.antiAlias,
    items: items,
  );
}

/// Builds popup menu entries with position-aware rounded hover highlights.
List<PopupMenuEntry<T>> voyagerPopupMenuEntries<T>(
  List<({T value, Widget child})> items,
) {
  return [
    for (var i = 0; i < items.length; i++)
      VoyagerPopupMenuItem<T>(
        value: items[i].value,
        position: VoyagerMenuTheme.positionFor(i, items.length),
        child: items[i].child,
      ),
  ];
}

/// Select-style menu entries with a checkmark on the active value.
List<PopupMenuEntry<T>> voyagerSelectMenuEntries<T>({
  required BuildContext context,
  required List<({T value, String label})> items,
  required T selected,
}) {
  final checkColor = Theme.of(context).colorScheme.primary;
  return [
    for (var i = 0; i < items.length; i++)
      VoyagerPopupMenuItem<T>(
        value: items[i].value,
        position: VoyagerMenuTheme.positionFor(i, items.length),
        child: Row(
          children: [
            Expanded(
              child: Text(
                items[i].label,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (items[i].value == selected) ...[
              const SizedBox(width: 8),
              Icon(
                PhosphorIconsRegular.check,
                size: 18,
                color: checkColor,
              ),
            ],
          ],
        ),
      ),
  ];
}

/// Popup menu item whose hover/focus highlight respects menu corner radius.
class VoyagerPopupMenuItem<T> extends PopupMenuItem<T> {
  const VoyagerPopupMenuItem({
    super.key,
    required super.value,
    required super.child,
    required this.position,
    super.enabled = true,
    super.height = kMinInteractiveDimension,
    super.padding,
    super.onTap,
  });

  final VoyagerMenuItemPosition position;

  @override
  PopupMenuItemState<T, VoyagerPopupMenuItem<T>> createState() =>
      _VoyagerPopupMenuItemState<T>();
}

class _VoyagerPopupMenuItemState<T>
    extends PopupMenuItemState<T, VoyagerPopupMenuItem<T>> {
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final popupMenuTheme = PopupMenuTheme.of(context);
    final states = <WidgetState>{if (!widget.enabled) WidgetState.disabled};
    final style =
        widget.labelTextStyle?.resolve(states) ??
        popupMenuTheme.labelTextStyle?.resolve(states) ??
        theme.textTheme.labelLarge?.copyWith(color: theme.colorScheme.onSurface);
    final padding = widget.padding ?? VoyagerMenuTheme.itemPadding(theme);
    final highlightRadius = VoyagerMenuTheme.itemHighlightRadius(
      widget.position,
    );

    Widget item = AnimatedDefaultTextStyle(
      style: style!,
      duration: kThemeChangeDuration,
      child: ConstrainedBox(
        constraints: BoxConstraints(minHeight: widget.height),
        child: Padding(
          padding: padding,
          child: Align(
            alignment: AlignmentDirectional.centerStart,
            child: buildChild(),
          ),
        ),
      ),
    );

    if (!widget.enabled) {
      item = IconTheme.merge(
        data: IconThemeData(
          opacity: theme.brightness == Brightness.dark ? 0.5 : 0.38,
        ),
        child: item,
      );
    }

    return MergeSemantics(
      child: buildSemantics(
        child: ClipRRect(
          borderRadius: highlightRadius,
          child: InkWell(
            onTap: widget.enabled ? handleTap : null,
            canRequestFocus: widget.enabled,
            borderRadius: highlightRadius,
            child: item,
          ),
        ),
      ),
    );
  }
}

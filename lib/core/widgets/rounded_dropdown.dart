import 'dart:async';

import 'package:flutter/material.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:voyager/core/theme/voyager_menu_theme.dart';
import 'package:voyager/core/widgets/voyager_menu_catalog.dart';
import 'package:voyager/core/widgets/voyager_popup_menu_item.dart';

class RoundedDropdownItem<T> {
  const RoundedDropdownItem({
    required this.value,
    required this.label,
    this.subtitle,
    this.leading,
    this.manageable = true,
  });

  final T value;
  final String label;
  final String? subtitle;
  final Widget? leading;

  /// When false, the row can be selected but has no ⋮ menu (e.g. "All journals").
  final bool manageable;
}

/// Toggle to restore the bordered dropdown style from before feedback changes.
const useBorderedDropdowns = false;

enum RoundedDropdownVariant { bordered, flat }

class RoundedDropdown<T> extends StatelessWidget {
  const RoundedDropdown({
    super.key,
    required this.value,
    required this.items,
    required this.onChanged,
    this.onManage,
    this.manageMenuEntriesFor,
    this.variant = useBorderedDropdowns
        ? RoundedDropdownVariant.bordered
        : RoundedDropdownVariant.flat,
    this.labelColor,
    this.labelStyle,
    this.displayLabel,
  });

  static const menuTopPadding = 8.0;
  static const subtitleFontSize = 10.0;

  final T value;
  final List<RoundedDropdownItem<T>> items;
  final ValueChanged<T>? onChanged;
  final Future<void> Function(T value, VoyagerMenuCatalogEntry action)? onManage;
  final Iterable<VoyagerMenuCatalogEntry> Function(T value)?
      manageMenuEntriesFor;
  final RoundedDropdownVariant variant;
  final Color? labelColor;
  final TextStyle? labelStyle;

  /// Overrides the closed-state label without adding a menu item.
  final String? displayLabel;

  Iterable<VoyagerMenuCatalogEntry> _manageEntriesFor(T itemValue) {
    return manageMenuEntriesFor?.call(itemValue) ?? entityManageMenuEntries;
  }

  bool _showsManageButton(RoundedDropdownItem<T> item) {
    return onManage != null &&
        item.manageable &&
        _manageEntriesFor(item.value).isNotEmpty;
  }

  TextStyle _subtitleStyle(ThemeData theme) {
    return theme.textTheme.labelSmall?.copyWith(
          fontSize: subtitleFontSize,
          color: theme.colorScheme.onSurface.withValues(alpha: 0.58),
        ) ??
        TextStyle(
          fontSize: subtitleFontSize,
          color: theme.colorScheme.onSurface.withValues(alpha: 0.58),
        );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final selected = items.where((item) => item.value == value).firstOrNull;
    final enabled = onChanged != null && items.isNotEmpty;
    final flat = variant == RoundedDropdownVariant.flat;
    final titleStyle = (labelStyle ?? theme.textTheme.titleMedium)?.copyWith(
      color: labelColor ?? labelStyle?.color ?? theme.colorScheme.onSurface,
      fontWeight: FontWeight.bold,
    );
    final subtitleStyle = _subtitleStyle(theme);
    final hasSubtitle = selected?.subtitle != null;
    final closedLabel = displayLabel ?? selected?.label ?? '';

    return Builder(
      builder: (context) {
        return Material(
          color: flat
              ? Colors.transparent
              : theme.inputDecorationTheme.fillColor,
          borderRadius: BorderRadius.circular(18),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: enabled ? () => _openMenu(context) : null,
            borderRadius: BorderRadius.circular(18),
            child: Container(
              height: hasSubtitle ? 52 : 48,
              padding: const EdgeInsets.symmetric(horizontal: 14),
              decoration: BoxDecoration(
                color: flat ? Colors.transparent : null,
                border: flat
                    ? null
                    : Border.all(color: theme.colorScheme.outline),
                borderRadius: BorderRadius.circular(18),
              ),
              child: Row(
                children: [
                  if (displayLabel == null && selected?.leading != null) ...[
                    selected!.leading!,
                    const SizedBox(width: 8),
                  ],
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(
                          closedLabel,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: titleStyle,
                        ),
                        if (hasSubtitle) ...[
                          const SizedBox(height: 1),
                          Text(
                            selected!.subtitle!,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: subtitleStyle,
                          ),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  Icon(
                    PhosphorIconsRegular.caretDown,
                    color: theme.colorScheme.onSurface.withValues(
                      alpha: enabled ? 0.8 : 0.38,
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Future<void> _openMenu(BuildContext context) async {
    final button = context.findRenderObject()! as RenderBox;
    final overlay =
        Navigator.of(context).overlay!.context.findRenderObject()! as RenderBox;
    final topLeft = button.localToGlobal(Offset.zero, ancestor: overlay);
    final buttonRect = topLeft & button.size;
    final menuRect = Rect.fromLTWH(
      buttonRect.left,
      buttonRect.bottom + 8,
      buttonRect.width,
      0,
    );
    final theme = Theme.of(context);
    final subtitleStyle = _subtitleStyle(theme);

    final menuItems = <PopupMenuEntry<T>>[
      for (var i = 0; i < items.length; i++)
        _RoundedDropdownMenuItem<T>(
          itemValue: items[i].value,
          position: VoyagerMenuTheme.positionFor(i, items.length),
          item: items[i],
          selected: items[i].value == value,
          subtitleStyle: subtitleStyle,
          showManageButton: _showsManageButton(items[i]),
          onSelect: () => Navigator.pop<T>(context, items[i].value),
          onManagePressed: _showsManageButton(items[i])
              ? (buttonContext) => _openItemManageMenu(
                    buttonContext,
                    items[i].value,
                    _manageEntriesFor(items[i].value),
                  )
              : null,
        ),
    ];

    final picked = await showVoyagerMenu<T>(
      context: context,
      position: RelativeRect.fromRect(menuRect, Offset.zero & overlay.size),
      constraints: BoxConstraints(
        minWidth: buttonRect.width,
        maxWidth: buttonRect.width,
      ),
      items: menuItems,
    );
    if (picked != null) onChanged?.call(picked);
  }

  Future<void> _openItemManageMenu(
    BuildContext context,
    T itemValue,
    Iterable<VoyagerMenuCatalogEntry> entries,
  ) async {
    final onManage = this.onManage;
    if (onManage == null) return;

    final button = context.findRenderObject()! as RenderBox;
    final overlay =
        Navigator.of(context).overlay!.context.findRenderObject()! as RenderBox;
    final topLeft = button.localToGlobal(Offset.zero, ancestor: overlay);
    final buttonRect = topLeft & button.size;
    final menuRect = Rect.fromLTWH(
      buttonRect.right - 180,
      buttonRect.bottom + 4,
      180,
      0,
    );

    final action = await showVoyagerMenu<VoyagerMenuCatalogEntry>(
      context: context,
      position: RelativeRect.fromRect(menuRect, Offset.zero & overlay.size),
      items: buildCatalogMenu(context, from: entries),
    );
    if (action == null) return;
    await onManage(itemValue, action);
  }
}

class _RoundedDropdownMenuItem<T> extends PopupMenuEntry<T> {
  const _RoundedDropdownMenuItem({
    required this.itemValue,
    required this.position,
    required this.item,
    required this.selected,
    required this.subtitleStyle,
    required this.showManageButton,
    required this.onSelect,
    required this.onManagePressed,
  });

  final T itemValue;
  final VoyagerMenuItemPosition position;
  final RoundedDropdownItem<T> item;
  final bool selected;
  final TextStyle subtitleStyle;
  final bool showManageButton;
  final VoidCallback onSelect;
  final Future<void> Function(BuildContext buttonContext)? onManagePressed;

  bool get _isFirst =>
      position == VoyagerMenuItemPosition.first ||
      position == VoyagerMenuItemPosition.only;

  @override
  double get height {
    final base = item.subtitle == null ? 44.0 : 52.0;
    return _isFirst ? base + RoundedDropdown.menuTopPadding : base;
  }

  @override
  bool represents(T? value) => value == itemValue;

  @override
  State<_RoundedDropdownMenuItem<T>> createState() =>
      _RoundedDropdownMenuItemState<T>();
}

class _RoundedDropdownMenuItemState<T>
    extends State<_RoundedDropdownMenuItem<T>> {
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final itemPadding = VoyagerMenuTheme.itemPadding(theme);
    const highlightRadius = BorderRadius.all(
      Radius.circular(VoyagerMenuTheme.radius),
    );
    final topInset =
        widget._isFirst ? RoundedDropdown.menuTopPadding : 0.0;

    return SizedBox(
      height: widget.height,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: ClipRRect(
              borderRadius: highlightRadius,
              child: InkWell(
                onTap: widget.onSelect,
                borderRadius: highlightRadius,
                child: Padding(
                  padding: EdgeInsets.fromLTRB(
                    itemPadding.left,
                    topInset + 6,
                    widget.showManageButton ? 4 : itemPadding.right,
                    6,
                  ),
                  child: Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: _RoundedDropdownRow(
                      item: widget.item,
                      selected: widget.selected,
                      subtitleStyle: widget.subtitleStyle,
                    ),
                  ),
                ),
              ),
            ),
          ),
          if (widget.showManageButton && widget.onManagePressed != null)
            Padding(
              padding: EdgeInsets.only(
                right: itemPadding.right,
                top: topInset,
              ),
              child: Builder(
                builder: (buttonContext) => Material(
                  type: MaterialType.transparency,
                  child: InkWell(
                    customBorder: const CircleBorder(),
                    onTap: () {
                      unawaited(widget.onManagePressed!(buttonContext));
                    },
                    child: SizedBox(
                      width: 32,
                      height: 32,
                      child: Center(
                        child: Icon(
                          PhosphorIconsBold.dotsThreeVertical,
                          size: 18,
                          color: theme.colorScheme.onSurface.withValues(
                            alpha: 0.72,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _RoundedDropdownRow<T> extends StatelessWidget {
  const _RoundedDropdownRow({
    required this.item,
    required this.selected,
    required this.subtitleStyle,
  });

  final RoundedDropdownItem<T> item;
  final bool selected;
  final TextStyle subtitleStyle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Row(
      children: [
        if (item.leading != null) ...[
          item.leading!,
          const SizedBox(width: 8),
        ],
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                item.label,
                overflow: TextOverflow.ellipsis,
              ),
              if (item.subtitle != null) ...[
                const SizedBox(height: 1),
                Text(
                  item.subtitle!,
                  overflow: TextOverflow.ellipsis,
                  style: subtitleStyle,
                ),
              ],
            ],
          ),
        ),
        if (selected) ...[
          const SizedBox(width: 8),
          Icon(
            PhosphorIconsRegular.check,
            size: 18,
            color: theme.colorScheme.primary,
          ),
        ],
      ],
    );
  }
}

/// Previous bordered dropdown styling kept for easy rollback.
class BorderedRoundedDropdown<T> extends RoundedDropdown<T> {
  const BorderedRoundedDropdown({
    super.key,
    required super.value,
    required super.items,
    required super.onChanged,
    super.onManage,
    super.manageMenuEntriesFor,
  }) : super(variant: RoundedDropdownVariant.bordered);
}

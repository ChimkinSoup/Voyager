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
    this.trailing,
    this.manageable = true,
  });

  final T value;
  final String label;
  final String? subtitle;
  final Widget? leading;

  /// Minimal count shown on the right (e.g. entry count or "3 | 5").
  final String? trailing;

  /// When false, the row can be selected but has no ⋮ menu (e.g. "All journals").
  final bool manageable;
}

/// Toggle to restore the bordered dropdown style from before feedback changes.
const useBorderedDropdowns = false;

enum RoundedDropdownVariant { bordered, flat }

/// Sentinel value for the accent "Add list" row in [RoundedDropdown].
class AddListDropdownValue {
  const AddListDropdownValue();
}

const _addListSentinel = AddListDropdownValue();

class RoundedDropdown<T> extends StatefulWidget {
  const RoundedDropdown({
    super.key,
    required this.value,
    required this.items,
    required this.onChanged,
    this.onManage,
    this.manageMenuEntriesFor,
    this.onAddList,
    this.addListLabel = 'Add list',
    this.variant = useBorderedDropdowns
        ? RoundedDropdownVariant.bordered
        : RoundedDropdownVariant.flat,
    this.labelColor,
    this.labelStyle,
    this.displayLabel,
    this.closedTrailing,
  });

  static const menuTopPadding = 8.0;
  static const subtitleFontSize = 10.0;

  final T value;
  final List<RoundedDropdownItem<T>> items;
  final ValueChanged<T>? onChanged;
  final Future<void> Function(T value, VoyagerMenuCatalogEntry action)? onManage;
  final Iterable<VoyagerMenuCatalogEntry> Function(T value)?
      manageMenuEntriesFor;
  final VoidCallback? onAddList;
  final String addListLabel;
  final RoundedDropdownVariant variant;
  final Color? labelColor;
  final TextStyle? labelStyle;

  /// Overrides the closed-state label without adding a menu item.
  final String? displayLabel;

  /// Count shown in the closed selector (to the left of the caret).
  final String? closedTrailing;

  @override
  State<RoundedDropdown<T>> createState() => _RoundedDropdownState<T>();
}

class _RoundedDropdownState<T> extends State<RoundedDropdown<T>> {
  var _menuDepth = 0;

  Iterable<VoyagerMenuCatalogEntry> _manageEntriesFor(T itemValue) {
    return widget.manageMenuEntriesFor?.call(itemValue) ??
        entityManageMenuEntries;
  }

  bool _showsManageButton(RoundedDropdownItem<T> item) {
    return widget.onManage != null &&
        item.manageable &&
        _manageEntriesFor(item.value).isNotEmpty;
  }

  TextStyle _subtitleStyle(ThemeData theme) {
    return theme.textTheme.labelSmall?.copyWith(
          fontSize: RoundedDropdown.subtitleFontSize,
          color: theme.colorScheme.onSurface.withValues(alpha: 0.58),
        ) ??
        TextStyle(
          fontSize: RoundedDropdown.subtitleFontSize,
          color: theme.colorScheme.onSurface.withValues(alpha: 0.58),
        );
  }

  TextStyle _trailingStyle(ThemeData theme) {
    return theme.textTheme.labelSmall?.copyWith(
          fontSize: RoundedDropdown.subtitleFontSize,
          color: theme.colorScheme.onSurface.withValues(alpha: 0.52),
        ) ??
        TextStyle(
          fontSize: RoundedDropdown.subtitleFontSize,
          color: theme.colorScheme.onSurface.withValues(alpha: 0.52),
        );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!TickerMode.valuesOf(context).enabled && _menuDepth > 0) {
      _popOpenMenus();
    }
  }

  void _popOpenMenus({int? count}) {
    if (!mounted) return;
    final navigator = Navigator.of(context);
    final pops = count ?? _menuDepth;
    for (var i = 0; i < pops && navigator.canPop(); i++) {
      navigator.pop();
    }
    _menuDepth = 0;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final selected =
        widget.items.where((item) => item.value == widget.value).firstOrNull;
    final enabled = widget.onChanged != null && widget.items.isNotEmpty;
    final flat = widget.variant == RoundedDropdownVariant.flat;
    final titleStyle = (widget.labelStyle ?? theme.textTheme.titleMedium)
        ?.copyWith(
      color:
          widget.labelColor ??
          widget.labelStyle?.color ??
          theme.colorScheme.onSurface,
      fontWeight: FontWeight.bold,
    );
    final subtitleStyle = _subtitleStyle(theme);
    final trailingStyle = _trailingStyle(theme);
    final hasSubtitle = selected?.subtitle != null;
    final closedLabel = widget.displayLabel ?? selected?.label ?? '';
    final closedTrailing =
        widget.closedTrailing ?? selected?.trailing;

    return Material(
      color: flat ? Colors.transparent : theme.inputDecorationTheme.fillColor,
      borderRadius: BorderRadius.circular(18),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: enabled ? _openMenu : null,
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
              if (widget.displayLabel == null && selected?.leading != null) ...[
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
              if (closedTrailing != null) ...[
                const SizedBox(width: 8),
                Text(closedTrailing, style: trailingStyle),
              ],
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
  }

  Future<void> _openMenu() async {
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
    final trailingStyle = _trailingStyle(theme);
    final addList = widget.onAddList;

    final menuItems = <PopupMenuEntry<Object?>>[
      for (var i = 0; i < widget.items.length; i++)
        _RoundedDropdownMenuItem<T>(
          itemValue: widget.items[i].value,
          position: VoyagerMenuTheme.positionFor(i, widget.items.length),
          item: widget.items[i],
          selected: widget.items[i].value == widget.value,
          subtitleStyle: subtitleStyle,
          trailingStyle: trailingStyle,
          showManageButton: _showsManageButton(widget.items[i]),
          onSelect: () => Navigator.pop<Object?>(context, widget.items[i].value),
          onManagePressed: _showsManageButton(widget.items[i])
              ? (buttonContext) => _openItemManageMenu(
                    buttonContext,
                    widget.items[i].value,
                    _manageEntriesFor(widget.items[i].value),
                  )
              : null,
        ),
      if (addList != null)
        _AddListMenuItem(
          label: widget.addListLabel,
          position: VoyagerMenuItemPosition.last,
          onSelect: () {
            Navigator.pop<Object?>(context);
            addList();
          },
        ),
    ];

    _menuDepth = 1;
    final picked = await showVoyagerMenu<Object?>(
      context: context,
      position: RelativeRect.fromRect(menuRect, Offset.zero & overlay.size),
      constraints: BoxConstraints(
        minWidth: buttonRect.width,
        maxWidth: buttonRect.width,
      ),
      items: menuItems,
    );
    _menuDepth = 0;
    if (picked is T) {
      widget.onChanged?.call(picked);
    }
  }

  Future<void> _openItemManageMenu(
    BuildContext context,
    T itemValue,
    Iterable<VoyagerMenuCatalogEntry> entries,
  ) async {
    final onManage = widget.onManage;
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

    _menuDepth = 2;
    final action = await showVoyagerMenu<VoyagerMenuCatalogEntry>(
      context: context,
      position: RelativeRect.fromRect(menuRect, Offset.zero & overlay.size),
      items: buildCatalogMenu(context, from: entries),
    );
    if (action != null) {
      await onManage(itemValue, action);
    }
    if (mounted) {
      _popOpenMenus(count: 2);
    }
  }
}

class _AddListMenuItem extends PopupMenuEntry<Object?> {
  const _AddListMenuItem({
    required this.label,
    required this.position,
    required this.onSelect,
  });

  final String label;
  final VoyagerMenuItemPosition position;
  final VoidCallback onSelect;

  @override
  double get height => 48 + RoundedDropdown.menuTopPadding;

  @override
  bool represents(Object? value) => identical(value, _addListSentinel);

  @override
  State<_AddListMenuItem> createState() => _AddListMenuItemState();
}

class _AddListMenuItemState extends State<_AddListMenuItem> {
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent = theme.colorScheme.primary;
    final itemPadding = VoyagerMenuTheme.itemPadding(theme);

    return Padding(
      padding: EdgeInsets.fromLTRB(
        itemPadding.left,
        RoundedDropdown.menuTopPadding,
        itemPadding.right,
        4,
      ),
      child: Material(
        color: accent,
        borderRadius: BorderRadius.circular(VoyagerMenuTheme.radius),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: widget.onSelect,
          child: SizedBox(
            height: 40,
            child: Center(
              child: Text(
                widget.label,
                style: theme.textTheme.labelLarge?.copyWith(
                  color: theme.colorScheme.onPrimary,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _RoundedDropdownMenuItem<T> extends PopupMenuEntry<Object?> {
  const _RoundedDropdownMenuItem({
    required this.itemValue,
    required this.position,
    required this.item,
    required this.selected,
    required this.subtitleStyle,
    required this.trailingStyle,
    required this.showManageButton,
    required this.onSelect,
    this.onManagePressed,
  });

  final T itemValue;
  final VoyagerMenuItemPosition position;
  final RoundedDropdownItem<T> item;
  final bool selected;
  final TextStyle subtitleStyle;
  final TextStyle trailingStyle;
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
  bool represents(Object? value) => value == itemValue;

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
                    4,
                    6,
                  ),
                  child: Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: _RoundedDropdownRow(
                      item: widget.item,
                      selected: widget.selected,
                      subtitleStyle: widget.subtitleStyle,
                      trailingStyle: widget.trailingStyle,
                    ),
                  ),
                ),
              ),
            ),
          ),
          if (widget.item.trailing != null)
            Padding(
              padding: EdgeInsets.only(top: topInset + 6, right: 4),
              child: Align(
                alignment: Alignment.center,
                child: Text(
                  widget.item.trailing!,
                  style: widget.trailingStyle,
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
    required this.trailingStyle,
  });

  final RoundedDropdownItem<T> item;
  final bool selected;
  final TextStyle subtitleStyle;
  final TextStyle trailingStyle;

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
    super.onAddList,
  }) : super(variant: RoundedDropdownVariant.bordered);
}

import 'package:flutter/material.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';

class RoundedDropdownItem<T> {
  const RoundedDropdownItem({required this.value, required this.label});

  final T value;
  final String label;
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
    this.variant = useBorderedDropdowns
        ? RoundedDropdownVariant.bordered
        : RoundedDropdownVariant.flat,
    this.menuBottomSpacing = 0,
  });

  final T value;
  final List<RoundedDropdownItem<T>> items;
  final ValueChanged<T>? onChanged;
  final RoundedDropdownVariant variant;
  final double menuBottomSpacing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final selected = items.where((item) => item.value == value).firstOrNull;
    final enabled = onChanged != null && items.isNotEmpty;
    final flat = variant == RoundedDropdownVariant.flat;

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
              height: 48,
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
                  Expanded(
                    child: Text(
                      selected?.label ?? '',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
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

    final picked = await showMenu<T>(
      context: context,
      position: RelativeRect.fromRect(menuRect, Offset.zero & overlay.size),
      constraints: BoxConstraints(
        minWidth: buttonRect.width,
        maxWidth: buttonRect.width,
      ),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      color: variant == RoundedDropdownVariant.flat
          ? Theme.of(context).scaffoldBackgroundColor
          : Theme.of(context).colorScheme.surface,
      items: [
        for (final item in items)
          PopupMenuItem<T>(
            enabled: false,
            padding: EdgeInsets.fromLTRB(
              6,
              2,
              6,
              item == items.last ? menuBottomSpacing : 2,
            ),
            child: _RoundedDropdownMenuItem(
              value: item.value,
              label: item.label,
              selected: item.value == value,
            ),
          ),
      ],
    );
    if (picked != null) onChanged?.call(picked);
  }
}

class _RoundedDropdownMenuItem extends StatelessWidget {
  const _RoundedDropdownMenuItem({
    required this.value,
    required this.label,
    required this.selected,
  });

  final Object? value;
  final String label;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: selected
          ? theme.colorScheme.primary.withValues(alpha: 0.14)
          : Colors.transparent,
      borderRadius: BorderRadius.circular(14),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => Navigator.pop(context, value),
        borderRadius: BorderRadius.circular(14),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          child: Row(
            children: [
              Expanded(child: Text(label, overflow: TextOverflow.ellipsis)),
              if (selected) ...[
                const SizedBox(width: 8),
                Icon(
                  PhosphorIconsRegular.check,
                  size: 18,
                  color: theme.colorScheme.primary,
                ),
              ],
            ],
          ),
        ),
      ),
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
    super.menuBottomSpacing,
  }) : super(variant: RoundedDropdownVariant.bordered);
}

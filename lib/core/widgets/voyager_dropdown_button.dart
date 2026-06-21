import 'package:flutter/material.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:voyager/core/theme/voyager_menu_theme.dart';
import 'package:voyager/core/widgets/voyager_popup_menu_item.dart';

/// Form-field dropdown that uses Voyager-styled popup menus.
class VoyagerDropdownButtonFormField<T> extends FormField<T> {
  VoyagerDropdownButtonFormField({
    super.key,
    required this.items,
    super.initialValue,
    this.onChanged,
    this.decoration = const InputDecoration(),
    super.validator,
    super.onSaved,
    super.enabled = true,
    this.isExpanded = false,
  }) : assert(items.isNotEmpty),
       super(
         builder: (field) {
           final dropdown = field.widget as VoyagerDropdownButtonFormField<T>;
           return InputDecorator(
             decoration: decoration.applyDefaults(
               Theme.of(field.context).inputDecorationTheme,
             ).copyWith(
               enabled: dropdown.enabled,
               errorText: field.errorText,
             ),
             isEmpty: field.value == null,
             child: _VoyagerDropdownFieldControl<T>(
               field: field,
               items: items,
               enabled: dropdown.enabled,
               isExpanded: isExpanded,
               onChanged: (value) {
                 field.didChange(value);
                 onChanged?.call(value);
               },
             ),
           );
         },
       );

  final List<DropdownMenuItem<T>> items;
  final InputDecoration decoration;
  final ValueChanged<T?>? onChanged;
  final bool isExpanded;
}

class _VoyagerDropdownFieldControl<T> extends StatefulWidget {
  const _VoyagerDropdownFieldControl({
    required this.field,
    required this.items,
    required this.enabled,
    required this.isExpanded,
    required this.onChanged,
  });

  final FormFieldState<T> field;
  final List<DropdownMenuItem<T>> items;
  final bool enabled;
  final bool isExpanded;
  final ValueChanged<T?> onChanged;

  @override
  State<_VoyagerDropdownFieldControl<T>> createState() =>
      _VoyagerDropdownFieldControlState<T>();
}

class _VoyagerDropdownFieldControlState<T>
    extends State<_VoyagerDropdownFieldControl<T>> {
  DropdownMenuItem<T>? _selectedItem() {
    final value = widget.field.value;
    for (final item in widget.items) {
      if (item.value == value) return item;
    }
    return null;
  }

  Future<void> _openMenu() async {
    if (!widget.enabled) return;

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
    final enabledItems = widget.items.where((item) => item.enabled).toList();

    final picked = await showVoyagerMenu<T>(
      context: context,
      position: RelativeRect.fromRect(menuRect, Offset.zero & overlay.size),
      constraints: BoxConstraints(
        minWidth: buttonRect.width,
        maxWidth: buttonRect.width,
      ),
      items: [
        for (var i = 0; i < enabledItems.length; i++)
          VoyagerPopupMenuItem<T>(
            value: enabledItems[i].value,
            position: VoyagerMenuTheme.positionFor(i, enabledItems.length),
            child: enabledItems[i].child,
          ),
      ],
    );

    if (picked != null) {
      widget.onChanged(picked);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final selected = _selectedItem();
    final labelStyle = theme.textTheme.bodyLarge;

    return Focus(
      canRequestFocus: widget.enabled,
      child: InkWell(
        onTap: widget.enabled ? _openMenu : null,
        child: Row(
          children: [
            Expanded(
              child: DefaultTextStyle(
                style: labelStyle!,
                overflow: TextOverflow.ellipsis,
                child: selected?.child ?? const SizedBox.shrink(),
              ),
            ),
            Icon(
              PhosphorIconsRegular.caretDown,
              size: 18,
              color: theme.colorScheme.onSurface.withValues(
                alpha: widget.enabled ? 0.8 : 0.38,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

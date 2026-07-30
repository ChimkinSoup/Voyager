import 'package:flutter/material.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:voyager/core/theme/voyager_menu_theme.dart';
import 'package:voyager/core/widgets/voyager_popup_menu_item.dart';

/// How long to keep [VoyagerDropdownButtonFormField.onMenuStateChanged] held at
/// `true` after the menu is dismissed. [showMenu]'s future resolves at
/// pop-start — before the menu plays its close animation — so it can't mark
/// "fully closed" on its own. This is the popup route's own transition duration
/// (`_kMenuDuration`, 300ms) plus a small buffer so the gate lifts only after
/// the menu has animated away and left the overlay.
const Duration _kMenuCloseSettleDuration = Duration(milliseconds: 340);

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
    this.showCaret = true,
    this.accentColor,
    this.onMenuStateChanged,
  }) : assert(items.isNotEmpty),
       super(
         builder: (field) {
           final dropdown = field.widget as VoyagerDropdownButtonFormField<T>;
           final state = field as _VoyagerDropdownFormFieldState<T>;
           final accent = dropdown.accentColor;
           var fieldDecoration = decoration.applyDefaults(
             Theme.of(field.context).inputDecorationTheme,
           ).copyWith(
             enabled: dropdown.enabled,
             errorText: field.errorText,
           );
           if (accent != null) {
             fieldDecoration = fieldDecoration.copyWith(
               floatingLabelStyle: Theme.of(field.context)
                   .textTheme
                   .labelLarge
                   ?.copyWith(color: accent),
               focusedBorder: OutlineInputBorder(
                 borderRadius: BorderRadius.circular(14),
                 borderSide: BorderSide(
                   color: accent.withValues(alpha: 0.95),
                   width: 1.8,
                 ),
               ),
             );
           }
           return InputDecorator(
             key: state.decoratorKey,
             decoration: fieldDecoration,
             isEmpty: field.value == null,
             child: _VoyagerDropdownFieldControl<T>(
               field: field,
               items: items,
               enabled: dropdown.enabled,
               isExpanded: isExpanded,
               showCaret: dropdown.showCaret,
               accentColor: dropdown.accentColor,
               onMenuStateChanged: dropdown.onMenuStateChanged,
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
  final bool showCaret;
  final Color? accentColor;

  /// Called with `true` when the popup menu opens and `false` once it has
  /// fully closed (after its exit animation completes). Lets callers gate
  /// other overlays — e.g. hover tooltips — so nothing paints over the menu
  /// while it animates.
  final ValueChanged<bool>? onMenuStateChanged;

  @override
  FormFieldState<T> createState() => _VoyagerDropdownFormFieldState<T>();
}

/// Owns a [GlobalKey] on the built [InputDecorator] so the menu can anchor to
/// its exact rendered box (border included) instead of re-deriving it via
/// [BuildContext.findRenderObject] on the [FormFieldState]'s own context,
/// which — through the extra `Semantics`/[InputDecorator] indirection — could
/// resolve to a differently-sized box and throw off the popup's position.
class _VoyagerDropdownFormFieldState<T> extends FormFieldState<T> {
  final decoratorKey = GlobalKey();
}

class _VoyagerDropdownFieldControl<T> extends StatefulWidget {
  const _VoyagerDropdownFieldControl({
    required this.field,
    required this.items,
    required this.enabled,
    required this.isExpanded,
    required this.showCaret,
    required this.onChanged,
    this.accentColor,
    this.onMenuStateChanged,
  });

  final FormFieldState<T> field;
  final List<DropdownMenuItem<T>> items;
  final bool enabled;
  final bool isExpanded;
  final bool showCaret;
  final ValueChanged<T?> onChanged;
  final Color? accentColor;
  final ValueChanged<bool>? onMenuStateChanged;

  @override
  State<_VoyagerDropdownFieldControl<T>> createState() =>
      _VoyagerDropdownFieldControlState<T>();
}

class _VoyagerDropdownFieldControlState<T>
    extends State<_VoyagerDropdownFieldControl<T>> {
  /// Bumped each time the menu opens so a delayed "menu closed" callback from a
  /// previous open is discarded if the menu is reopened before it fires.
  int _menuGeneration = 0;

  DropdownMenuItem<T>? _selectedItem() {
    final value = widget.field.value;
    for (final item in widget.items) {
      if (item.value == value) return item;
    }
    return null;
  }

  Future<void> _openMenu() async {
    if (!widget.enabled) return;

    final decoratorKey =
        (widget.field as _VoyagerDropdownFormFieldState<T>).decoratorKey;
    final buttonBox =
        decoratorKey.currentContext?.findRenderObject() as RenderBox?;
    if (buttonBox == null) return;
    final overlay =
        Navigator.of(context).overlay!.context.findRenderObject()! as RenderBox;
    final topLeft = buttonBox.localToGlobal(Offset.zero, ancestor: overlay);
    final buttonRect = topLeft & buttonBox.size;
    final menuRect = Rect.fromLTWH(
      buttonRect.left,
      buttonRect.bottom,
      buttonRect.width,
      0,
    );
    final enabledItems = widget.items.where((item) => item.enabled).toList();

    // Held true for the whole menu lifecycle. [showVoyagerMenu]'s future
    // resolves at pop-start, before the menu's close animation runs, so the
    // `false` is scheduled a transition-length later (see
    // [_kMenuCloseSettleDuration]) rather than fired the instant the future
    // completes — otherwise it lifts while the menu is still animating away.
    final generation = ++_menuGeneration;
    widget.onMenuStateChanged?.call(true);
    T? picked;
    try {
      picked = await showVoyagerMenu<T>(
        context: context,
        position: RelativeRect.fromRect(menuRect, Offset.zero & overlay.size),
        constraints: BoxConstraints(
          minWidth: buttonRect.width,
          maxWidth: buttonRect.width,
        ),
        accentColor: widget.accentColor,
        items: [
          for (var i = 0; i < enabledItems.length; i++)
            VoyagerPopupMenuItem<T>(
              value: enabledItems[i].value,
              position: VoyagerMenuTheme.positionFor(i, enabledItems.length),
              child: enabledItems[i].child,
            ),
        ],
      );
    } finally {
      final callback = widget.onMenuStateChanged;
      if (callback != null) {
        Future<void>.delayed(_kMenuCloseSettleDuration, () {
          // Skip if the menu was reopened in the meantime — that newer open
          // owns the gate now.
          if (_menuGeneration == generation) callback(false);
        });
      }
    }

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
            if (widget.showCaret)
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

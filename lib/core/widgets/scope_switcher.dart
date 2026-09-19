import 'package:flutter/material.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:voyager/core/widgets/contextual_popover.dart';

/// One scope a page can be pointed at: a single list/journal/calendar, or the
/// all-scope row that stands at the top of the popover.
class ScopeSwitcherItem<T> {
  const ScopeSwitcherItem({
    required this.value,
    required this.label,
    this.count,
    this.color,
  });

  final T value;
  final String label;

  /// Quiet count beside the name — `active | completed` on Todo, an entry
  /// count on Journal, absent on Calendar.
  final String? count;

  /// The entity's colour. Null on the all-scope row, which has no colour of
  /// its own and takes the app accent instead.
  final Color? color;
}

/// The page's scope, worn as a title rather than a form control.
///
/// A filled 48px capsule spanning the column read as a Material select — a
/// thing to fill in — when what it actually names is which list the page is
/// showing. This is the Rankings category trigger (`RANKINGS_UI.md` §2.2):
/// the name in the scope's own colour, a small caret, and a
/// [ContextualPopover] that does nothing but switch. Creating and
/// administering the entities lives behind the Manage gear beside it.
class ScopeSwitcher<T> extends StatelessWidget {
  const ScopeSwitcher({
    super.key,
    required this.items,
    required this.selectedValue,
    required this.onSelected,
    required this.accent,
    this.popoverWidth = 260,
    this.maxWidth = 260,
  });

  /// The all-scope row first, then one row per entity.
  final List<ScopeSwitcherItem<T>> items;

  final T selectedValue;
  final ValueChanged<T> onSelected;

  /// Entity colour when a specific scope is selected, app accent when the
  /// all-scope row is.
  final Color accent;

  final double popoverWidth;

  /// Caps the closed trigger, and — because a [Row] hands its non-flex
  /// children unbounded width — is also what makes the name below shrinkable
  /// at all when the page's own chrome puts no bound on it.
  final double maxWidth;

  ScopeSwitcherItem<T>? get _selected =>
      items.where((item) => item.value == selectedValue).firstOrNull;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final selected = _selected;
    final label = selected?.label ?? '';
    final count = selected?.count;

    return Builder(
      builder: (buttonContext) => ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: items.isEmpty
                ? null
                : () => showContextualPopover<void>(
                      context: context,
                      buttonContext: buttonContext,
                      accentColor: accent,
                      width: popoverWidth,
                      builder: (context) => _ScopeMenu<T>(
                        items: items,
                        selectedValue: selectedValue,
                        onSelected: onSelected,
                        // Resolved here, outside the popover: inside it the
                        // theme's primary is re-tinted to [accent], so the
                        // all-scope row would wear the open scope's colour.
                        appAccent: theme.colorScheme.primary,
                      ),
                    ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // The count and the caret keep their natural width; the
                  // name gives way first, because it is the only part that
                  // still reads once it is clipped.
                  Flexible(
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleSmall?.copyWith(
                        color: accent,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  if (count != null) ...[
                    const SizedBox(width: 8),
                    Text(
                      count,
                      style: theme.textTheme.labelSmall?.copyWith(
                        fontSize: 11,
                        color: theme.colorScheme.onSurface.withValues(
                          alpha: 0.55,
                        ),
                      ),
                    ),
                  ],
                  const SizedBox(width: 4),
                  Icon(
                    PhosphorIconsRegular.caretDown,
                    size: 12,
                    color: accent.withValues(alpha: 0.8),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ScopeMenu<T> extends StatelessWidget {
  const _ScopeMenu({
    required this.items,
    required this.selectedValue,
    required this.onSelected,
    required this.appAccent,
  });

  final List<ScopeSwitcherItem<T>> items;
  final T selectedValue;
  final ValueChanged<T> onSelected;
  final Color appAccent;

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(maxHeight: 320),
      child: ListView(
        shrinkWrap: true,
        padding: EdgeInsets.zero,
        children: [
          for (final item in items)
            _ScopeMenuRow(
              label: item.label,
              count: item.count,
              color: item.color ?? appAccent,
              selected: item.value == selectedValue,
              onTap: () {
                Navigator.of(context).pop();
                onSelected(item.value);
              },
            ),
        ],
      ),
    );
  }
}

class _ScopeMenuRow extends StatelessWidget {
  const _ScopeMenuRow({
    required this.label,
    required this.count,
    required this.color,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final String? count;
  final Color color;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
        child: Row(
          children: [
            Expanded(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: color,
                  fontWeight: selected ? FontWeight.w700 : null,
                ),
              ),
            ),
            if (count != null) ...[
              const SizedBox(width: 8),
              Text(
                count!,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.55),
                ),
              ),
            ],
            const SizedBox(width: 6),
            SizedBox(
              width: 14,
              child: selected
                  ? Icon(PhosphorIconsRegular.check, size: 14, color: color)
                  : null,
            ),
          ],
        ),
      ),
    );
  }
}

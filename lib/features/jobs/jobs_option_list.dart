import 'package:flutter/material.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:voyager/core/widgets/voyager_scroll_view.dart';

/// One row of a [JobsOptionList]: what it reads as, and what picking it means.
typedef JobsOption = ({String value, String label});

/// The pick-one list every Jobs popover puts inside a
/// `showContextualPopover` — status, season, and the status capsule's
/// in-table editor all offer the same thing, so they all render it the same
/// way. Pops [JobsOption.value] off the enclosing route.
class JobsOptionList extends StatelessWidget {
  const JobsOptionList({
    super.key,
    required this.options,
    required this.selected,
  });

  final List<JobsOption> options;
  final String selected;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ConstrainedBox(
      constraints: const BoxConstraints(maxHeight: 280),
      child: VoyagerScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final option in options)
              InkWell(
                onTap: () => Navigator.of(context).pop(option.value),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 9,
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          option.label,
                          style: theme.textTheme.bodySmall,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (option.value == selected)
                        Icon(
                          PhosphorIconsRegular.check,
                          size: 13,
                          color: theme.colorScheme.primary,
                        ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// The pick-many variant, for seasons: an application may sit in more than one
/// cycle at once, so the list stays open and each row toggles.
///
/// Nothing is popped off the route — [onChanged] fires with the whole new set
/// on every tap and the caller saves it, so the picker reads as a set of
/// checkboxes rather than as a menu that closes the moment it is touched. The
/// user closes it themselves when the set looks right.
///
/// [emptyLabel] heads the list as the row that clears every selection ("No
/// season"), checked precisely when nothing else is.
class JobsMultiOptionList extends StatefulWidget {
  const JobsMultiOptionList({
    super.key,
    required this.options,
    required this.selected,
    required this.onChanged,
    this.emptyLabel,
  });

  final List<JobsOption> options;
  final Set<String> selected;
  final ValueChanged<Set<String>> onChanged;
  final String? emptyLabel;

  @override
  State<JobsMultiOptionList> createState() => _JobsMultiOptionListState();
}

class _JobsMultiOptionListState extends State<JobsMultiOptionList> {
  late Set<String> _selected = {...widget.selected};

  void _apply(Set<String> next) {
    setState(() => _selected = next);
    widget.onChanged(next);
  }

  void _toggle(String value) {
    final next = {..._selected};
    if (!next.remove(value)) next.add(value);
    _apply(next);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ConstrainedBox(
      constraints: const BoxConstraints(maxHeight: 280),
      child: VoyagerScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (widget.emptyLabel case final label?)
              _row(
                theme,
                label: label,
                checked: _selected.isEmpty,
                // Clearing, not toggling: the empty row is the absence of
                // every other one, so tapping it when it is already checked
                // has nothing left to do.
                onTap: _selected.isEmpty ? null : () => _apply(const {}),
              ),
            for (final option in widget.options)
              _row(
                theme,
                label: option.label,
                checked: _selected.contains(option.value),
                onTap: () => _toggle(option.value),
              ),
          ],
        ),
      ),
    );
  }

  Widget _row(
    ThemeData theme, {
    required String label,
    required bool checked,
    required VoidCallback? onTap,
  }) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
        child: Row(
          children: [
            Icon(
              checked
                  ? PhosphorIconsRegular.checkSquare
                  : PhosphorIconsRegular.square,
              size: 14,
              color: checked
                  ? theme.colorScheme.primary
                  : theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                label,
                style: theme.textTheme.bodySmall,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

import 'package:flutter/material.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:voyager/core/widgets/field_hint_style.dart';
import 'package:voyager/core/widgets/glass_surface.dart';

/// The height the bar occupies, and — while a filter is actually applied — the
/// space the task list reserves at its top for it (see the spacer sliver in
/// `_TodoPageState.build`).
///
/// Exactly the height of the row inside it (a compact [IconButton] is its
/// tallest child), so the bar is as tall as what it holds and no taller. It
/// used to be 48 with the row sized to its own 40 — and, because [GlassSurface]
/// lays its child out in a [Stack], that row was pinned to the *top*, putting
/// the whole 8px difference in one band under the text.
const double todoListSearchBarHeight = 40;

/// The ephemeral in-page search bar for the Todo page
/// (TODO_LIST_SEARCH_HLD.md).
///
/// Floats over the top of the task list rather than sitting in the page's
/// chrome: it is opened for a few seconds at a time (Ctrl+F, or the composer's
/// `/search`) and closed again, and a permanent field would cost the page a row
/// of height it needs the rest of the time.
///
/// Deliberately a plain [TextField] rather than the `LabeledTextField` the
/// composer uses: this is a query box, so the snippet expansion, autocorrect
/// and emphasis that field brings would all be wrong here, and its outline
/// would double up with the surface's own.
class TodoListSearchBar extends StatelessWidget {
  const TodoListSearchBar({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.accentColor,
    required this.matchCount,
    required this.showMatchCount,
    required this.onChanged,
    required this.onClose,
  });

  final TextEditingController controller;
  final FocusNode focusNode;

  /// The list's colour, so the bar reads as belonging to what it filters.
  final Color accentColor;
  final int matchCount;

  /// False while the query is empty — there is no filter yet, so "N matches"
  /// would be counting the whole list.
  final bool showMatchCount;
  final ValueChanged<String> onChanged;
  final VoidCallback onClose;

  static String matchLabel(int count) =>
      count == 1 ? '1 match' : '$count matches';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final textStyle = theme.textTheme.bodyMedium?.copyWith(
      color: theme.colorScheme.onSurface,
    );
    return GlassSurface(
      weight: GlassWeight.heavy,
      accentBorder: accentColor.withValues(alpha: 0.5),
      // Inside the surface, not around it: [GlassSurface] stacks its child, so
      // a height set on the outside would leave the row loose and top-aligned
      // within it rather than filling it.
      child: SizedBox(
        height: todoListSearchBarHeight,
        child: Row(
          children: [
            const SizedBox(width: 12),
            Icon(
              PhosphorIconsRegular.magnifyingGlass,
              size: 16,
              color: theme.colorScheme.onSurface.withValues(alpha: 0.7),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: TextField(
                controller: controller,
                focusNode: focusNode,
                autofocus: true,
                maxLines: 1,
                style: textStyle,
                cursorColor: accentColor,
                onChanged: onChanged,
                // No textInputAction: Enter never submits here, it walks to
                // the next match — handled on [focusNode] by the page, which
                // consumes the key before the field ever sees it.
                decoration: InputDecoration(
                  isDense: true,
                  hintText: 'Search this list',
                  hintStyle: fieldHintStyle(context, textStyle),
                  contentPadding: EdgeInsets.zero,
                  filled: false,
                  border: InputBorder.none,
                  enabledBorder: InputBorder.none,
                  focusedBorder: InputBorder.none,
                ),
              ),
            ),
            if (showMatchCount) ...[
              const SizedBox(width: 8),
              Text(
                matchLabel(matchCount),
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
                ),
              ),
            ],
            IconButton(
              tooltip: 'Close search',
              iconSize: 16,
              visualDensity: VisualDensity.compact,
              onPressed: onClose,
              icon: const Icon(PhosphorIconsRegular.x),
            ),
          ],
        ),
      ),
    );
  }
}

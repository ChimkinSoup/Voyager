import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:voyager/core/constants/app_constants.dart';
import 'package:voyager/core/theme/voyager_spacing.dart';
import 'package:voyager/features/shell/shell_destinations.dart';
import 'package:voyager/features/shell/shell_nav_theme.dart';

/// How many destinations sit in the bar itself. The rest live behind "More".
///
/// Four plus the More slot fills a 360dp phone at exactly the 68px item width
/// the rail uses, so a destination is the same size in both shells.
const int _pinnedDestinationCount = 4;

/// The phone shell's navigation.
///
/// The first four entries of the user's saved nav order are pinned; the
/// remainder open in a sheet. That is deliberate reuse: reordering the rail on
/// the desktop is already a supported gesture, and it now decides what the
/// phone keeps within thumb reach — no second preference to set, and no way
/// for the two to disagree.
class ShellBottomNav extends StatelessWidget {
  const ShellBottomNav({
    super.key,
    required this.selectedIndex,
    required this.accent,
    required this.onDestinationSelected,
    required this.orderedDestinations,
  });

  final int selectedIndex;
  final Color accent;
  final ValueChanged<int> onDestinationSelected;
  final List<OrderedDestination> orderedDestinations;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final pinnedCount = math.min(
      _pinnedDestinationCount,
      orderedDestinations.length,
    );
    final pinned = orderedDestinations.take(pinnedCount).toList();
    final overflow = orderedDestinations.skip(pinnedCount).toList();
    final overflowHoldsSelection = overflow.any(
      (item) => item.originalIndex == selectedIndex,
    );

    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: theme.dividerColor)),
      ),
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: shellNavItemHeight + VoyagerSpacing.sm,
          child: Row(
            children: [
              for (final item in pinned)
                Expanded(
                  child: ShellNavItem(
                    icon: item.dest.icon,
                    label: item.dest.label,
                    selected: item.originalIndex == selectedIndex,
                    accent: accent,
                    onTap: () => onDestinationSelected(item.originalIndex),
                  ),
                ),
              if (overflow.isNotEmpty)
                Expanded(
                  child: ShellNavItem(
                    icon: PhosphorIconsRegular.dotsThreeOutline,
                    label: 'More',
                    selected: overflowHoldsSelection,
                    accent: accent,
                    onTap: () => _showMoreSheet(
                      context,
                      overflow: overflow,
                      selectedIndex: selectedIndex,
                      accent: accent,
                      onDestinationSelected: onDestinationSelected,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

Future<void> _showMoreSheet(
  BuildContext context, {
  required List<OrderedDestination> overflow,
  required int selectedIndex,
  required Color accent,
  required ValueChanged<int> onDestinationSelected,
}) {
  final theme = Theme.of(context);
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: theme.colorScheme.surface,
    // The paper texture is painted behind the whole app, so the sheet stays
    // just shy of opaque for the same reason every other surface does.
    barrierColor: theme.colorScheme.scrim.withValues(alpha: 0.32),
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
    ),
    builder: (sheetContext) => SafeArea(
      top: false,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(vertical: VoyagerSpacing.md),
            child: Container(
              width: 32,
              height: 4,
              decoration: BoxDecoration(
                color: theme.dividerColor,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          for (final item in overflow)
            _MoreSheetRow(
              destination: item.dest,
              selected: item.originalIndex == selectedIndex,
              accent: accent,
              onTap: () {
                Navigator.of(sheetContext).pop();
                onDestinationSelected(item.originalIndex);
              },
            ),
          const SizedBox(height: VoyagerSpacing.sm),
        ],
      ),
    ),
  );
}

class _MoreSheetRow extends StatelessWidget {
  const _MoreSheetRow({
    required this.destination,
    required this.selected,
    required this.accent,
    required this.onTap,
  });

  final ShellDestination destination;
  final bool selected;
  final Color accent;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final foreground = selected ? accent : theme.colorScheme.onSurface;

    return Semantics(
      button: true,
      selected: selected,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          child: Container(
            constraints: const BoxConstraints(minHeight: 56),
            padding: const EdgeInsets.symmetric(
              horizontal: VoyagerSpacing.xl,
              vertical: VoyagerSpacing.md,
            ),
            child: Row(
              children: [
                Icon(destination.icon, size: 24, color: foreground),
                const SizedBox(width: VoyagerSpacing.lg),
                Expanded(
                  child: Text(
                    destination.label,
                    style: theme.textTheme.bodyLarge?.copyWith(
                      color: foreground,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// One destination in the bottom bar, matching the rail item exactly: 68x56
/// box, 18px radius, hairline accent border when selected.
class ShellNavItem extends StatefulWidget {
  const ShellNavItem({
    super.key,
    required this.icon,
    required this.label,
    required this.selected,
    required this.accent,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final bool selected;
  final Color accent;
  final VoidCallback onTap;

  @override
  State<ShellNavItem> createState() => _ShellNavItemState();
}

class _ShellNavItemState extends State<ShellNavItem> {
  var _hovered = false;

  /// One [AnimatedContainer] carries both fills, but they want different
  /// clocks — selection settles with the page it summons, hover has to answer
  /// the pointer immediately. Whichever changed last sets the duration.
  Duration _fillDuration = shellNavHoverDuration;

  @override
  void didUpdateWidget(covariant ShellNavItem oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.selected != widget.selected) {
      _fillDuration = shellNavSelectionDuration(context);
    }
  }

  void _setHovered(bool hovered) {
    if (_hovered == hovered) return;
    setState(() {
      _hovered = hovered;
      _fillDuration = shellNavHoverDuration;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final selectionDuration = shellNavSelectionDuration(context);
    final foreground = widget.selected
        ? widget.accent
        : theme.colorScheme.onSurface;
    final backgroundColor = widget.selected
        ? shellNavSelectedFill(theme)
        : _hovered
        ? shellNavHoverFill(theme)
        : Colors.transparent;

    return Semantics(
      button: true,
      selected: widget.selected,
      label: widget.label,
      child: Center(
        child: Material(
          color: Colors.transparent,
          borderRadius: BorderRadius.circular(18),
          child: InkWell(
            onTap: widget.onTap,
            onHover: _setHovered,
            borderRadius: BorderRadius.circular(18),
            hoverColor: Colors.transparent,
            splashColor: Colors.transparent,
            highlightColor: Colors.transparent,
            child: AnimatedContainer(
              duration: _fillDuration,
              curve: Curves.easeOut,
              width: shellNavItemWidth,
              height: shellNavItemHeight,
              decoration: BoxDecoration(
                color: backgroundColor,
                borderRadius: BorderRadius.circular(18),
                border: widget.selected
                    ? Border.all(
                        color: widget.accent.withValues(
                          alpha: accentBorderAlpha,
                        ),
                        width: 1.0,
                      )
                    : null,
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  // Icon and label carry the accent, so they are as much the
                  // selection indicator as the fill is and settle on its clock.
                  TweenAnimationBuilder<Color?>(
                    tween: ColorTween(end: foreground),
                    duration: selectionDuration,
                    curve: Curves.easeOut,
                    builder: (context, color, _) =>
                        Icon(widget.icon, size: 24, color: color),
                  ),
                  const SizedBox(height: 3),
                  AnimatedDefaultTextStyle(
                    duration: selectionDuration,
                    curve: Curves.easeOut,
                    style:
                        theme.textTheme.labelSmall?.copyWith(
                          color: foreground,
                          fontSize: 10,
                        ) ??
                        const TextStyle(),
                    child: Text(
                      widget.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
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

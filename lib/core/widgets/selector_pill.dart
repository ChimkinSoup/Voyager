import 'package:flutter/material.dart';

class SelectorPill extends StatelessWidget {
  const SelectorPill({
    super.key,
    this.label,
    this.child,
    required this.onTap,
    this.isActive = false,
    this.icon,
  }) : assert(label != null || child != null);

  final String? label;
  final Widget? child;
  final VoidCallback onTap;
  final bool isActive;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Negative Space Pill design when active
    final backgroundColor = isActive
        ? theme.colorScheme.primary
        : theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5);
    final foregroundColor =
        isActive ? theme.colorScheme.onPrimary : theme.colorScheme.onSurface;

    return Material(
      color: backgroundColor,
      borderRadius: BorderRadius.circular(12),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (icon != null) ...[
                Icon(icon, size: 16, color: foregroundColor),
                const SizedBox(width: 6),
              ],
              child ?? Text(
                label ?? '',
                style: theme.textTheme.labelLarge?.copyWith(
                  color: foregroundColor,
                  fontWeight: isActive ? FontWeight.bold : FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

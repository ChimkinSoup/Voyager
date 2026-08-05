import 'package:flutter/material.dart';

class SelectorPill extends StatelessWidget {
  const SelectorPill({
    super.key,
    this.label,
    this.child,
    required this.onTap,
    this.isActive = false,
    this.icon,
    this.dense = false,
    this.accentColor,
    this.ellipsize = true,
    this.fillWhenActive = false,
  }) : assert(label != null || child != null);

  final String? label;
  final Widget? child;
  final VoidCallback onTap;
  final bool isActive;
  final IconData? icon;

  /// Tighter padding and smaller label text for compact toolbars.
  final bool dense;

  /// Active border color — defaults to [ColorScheme.primary]. Also the fill
  /// color when [fillWhenActive] is set.
  final Color? accentColor;

  /// When false, label text is never truncated with an ellipsis.
  final bool ellipsize;

  /// When active, fills the whole capsule with [accentColor] instead of just
  /// drawing a border around it.
  final bool fillWhenActive;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent = accentColor ?? theme.colorScheme.primary;
    final filled = fillWhenActive && isActive;
    final backgroundColor = filled
        ? accent
        : theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5);
    final foregroundColor = filled
        ? (ThemeData.estimateBrightnessForColor(accent) == Brightness.light
              ? Colors.black
              : Colors.white)
        : theme.colorScheme.onSurface;

    return Material(
      color: backgroundColor,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: isActive && !filled
            ? BorderSide(color: accent, width: 1)
            : BorderSide.none,
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: dense ? 4 : 8,
            vertical: dense ? 4 : 6,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (icon != null) ...[
                Icon(icon, size: dense ? 14 : 16, color: foregroundColor),
                SizedBox(width: dense ? 4 : 6),
              ],
              if (ellipsize)
                Flexible(
                  child: child ??
                      Text(
                        label ?? '',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: (dense
                                ? theme.textTheme.labelMedium
                                : theme.textTheme.labelLarge)
                            ?.copyWith(
                          color: foregroundColor,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                )
              else
                child ??
                    Text(
                      label ?? '',
                      maxLines: 1,
                      style: (dense
                              ? theme.textTheme.labelMedium
                              : theme.textTheme.labelLarge)
                          ?.copyWith(
                        color: foregroundColor,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
            ],
          ),
        ),
      ),
    );
  }
}

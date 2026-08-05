import 'package:flutter/material.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:voyager/core/layout/touch_target.dart';
import 'package:voyager/core/theme/voyager_spacing.dart';

/// The way back from a phone sub-view to the list it came from.
///
/// The system Back gesture does the same thing, but a gesture leaves no trace
/// on screen: without this the editor arrives full-bleed with nothing to say
/// what it replaced or how to get out. Names its destination rather than
/// showing a bare chevron, because on this shell "back" could mean the list,
/// the previous section, or the home screen.
class CompactBackBar extends StatelessWidget {
  const CompactBackBar({super.key, required this.label, required this.onBack});

  /// Where this goes back to, e.g. `Entries`.
  final String label;

  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Align(
      alignment: Alignment.centerLeft,
      child: Semantics(
        button: true,
        label: 'Back to $label',
        child: Material(
          color: Colors.transparent,
          borderRadius: BorderRadius.circular(12),
          child: InkWell(
            onTap: onBack,
            borderRadius: BorderRadius.circular(12),
            child: ConstrainedBox(
              constraints: kMinTouchTarget,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: VoyagerSpacing.sm,
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      PhosphorIconsRegular.caretLeft,
                      size: 18,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: VoyagerSpacing.xs),
                    Text(
                      label,
                      style: theme.textTheme.labelLarge?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

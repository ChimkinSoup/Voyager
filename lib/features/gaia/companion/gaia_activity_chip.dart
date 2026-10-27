import 'package:flutter/material.dart';
import 'package:voyager/features/gaia/companion/gaia_orb_materials.dart';

/// The tools a reply used between its text blocks, in the orb's gold so it
/// doesn't read as part of what Gaia said.
class GaiaActivityChip extends StatelessWidget {
  const GaiaActivityChip({super.key, required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.build_outlined, size: 12, color: kGaiaAstralGold),
        const SizedBox(width: 6),
        Flexible(
          child: Text(
            label,
            style: theme.textTheme.labelSmall?.copyWith(color: kGaiaAstralGold),
          ),
        ),
      ],
    );
  }
}

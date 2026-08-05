import 'package:flutter/material.dart';

/// A small colored pill for a single tag, shared across features that let
/// the user tag entries (finance transactions, LeetCode problems, etc.).
class TagChip extends StatelessWidget {
  const TagChip({super.key, required this.tag, this.colorValue});

  final String tag;
  final int? colorValue;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = colorValue != null
        ? Color(colorValue!)
        : theme.colorScheme.onSurfaceVariant;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        '#$tag',
        style: theme.textTheme.labelSmall?.copyWith(color: color),
      ),
    );
  }
}

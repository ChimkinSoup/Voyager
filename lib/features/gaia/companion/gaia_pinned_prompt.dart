import 'package:flutter/material.dart';

/// The user's messages' bubbles and their prompt pinned over the chat:
/// Gaia's accent through the raised surface, to stand off the starfield.
Color gaiaPromptColor(ThemeData theme) => Color.alphaBlend(
  theme.colorScheme.primary.withValues(alpha: 0.22),
  theme.colorScheme.surfaceContainerHighest,
);

/// The prompt of the turn being read, once scrolled off above, as in
/// Claude Code: its first line, clicked to go back to it. Slim, with an
/// accent rail down its left.
class GaiaPinnedPrompt extends StatelessWidget {
  const GaiaPinnedPrompt({
    super.key,
    required this.id,
    required this.text,
    required this.onTap,
  });

  /// The prompt's message's.
  final String id;
  final String text;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent = theme.colorScheme.primary;
    final shape = BorderRadius.circular(6);
    return Material(
      color: gaiaPromptColor(theme),
      borderRadius: shape,
      child: InkWell(
        borderRadius: shape,
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(6, 6, 10, 6),
          child: Row(
            children: [
              Container(
                width: 3,
                height: 18,
                decoration: BoxDecoration(
                  color: accent,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(width: 8),
              Icon(
                Icons.keyboard_double_arrow_up_rounded,
                size: 14,
                color: accent,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _Text(
                  id: id,
                  text: text,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
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

/// The prompt's text: from one prompt to the next, only it crossfades;
/// the box stays.
class _Text extends StatelessWidget {
  const _Text({required this.id, required this.text, required this.style});

  final String id;
  final String text;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) => AnimatedSwitcher(
    duration: const Duration(milliseconds: 150),
    layoutBuilder: (current, previous) => Stack(
      alignment: Alignment.centerLeft,
      children: [...previous, ?current],
    ),
    child: Text(
      text,
      key: ValueKey(id),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: style,
    ),
  );
}

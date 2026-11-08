import 'package:flutter/material.dart';

/// The user's messages' bubbles and their prompt pinned over the chat:
/// Gaia's accent through the raised surface, to stand off the starfield.
Color gaiaPromptColor(ThemeData theme) => Color.alphaBlend(
  theme.colorScheme.primary.withValues(alpha: 0.22),
  theme.colorScheme.surfaceContainerHighest,
);

/// The prompt of the turn being read, once scrolled off above, as in
/// Claude Code: its first line, clicked to go back to it. Slim, with an
/// accent rail down its left. Led by the title of the chapter being read,
/// in the accent, once its divider has scrolled off above
/// (GAIA_CHAPTERS_HLD.md §6.4): each half goes to its own message, and
/// either can be absent.
class GaiaPinnedPrompt extends StatelessWidget {
  const GaiaPinnedPrompt({
    super.key,
    this.id,
    this.text,
    this.onTap,
    this.chapterId,
    this.chapter,
    this.onChapterTap,
  });

  /// The prompt's message's.
  final String? id;
  final String? text;
  final VoidCallback? onTap;

  /// The chapter's message's.
  final String? chapterId;
  final String? chapter;
  final VoidCallback? onChapterTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent = theme.colorScheme.primary;
    final shape = BorderRadius.circular(6);
    final style = theme.textTheme.bodySmall;
    final prompt = text == null
        ? null
        : _Text(
            id: id!,
            text: text!,
            style: style?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          );
    final title = chapter == null
        ? null
        : _Text(
            id: chapterId!,
            text: chapter!,
            style: style?.copyWith(color: accent),
          );
    return Material(
      color: gaiaPromptColor(theme),
      borderRadius: shape,
      child: InkWell(
        borderRadius: shape,
        onTap: onTap ?? onChapterTap,
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
              if (title != null && prompt != null) ...[
                // Its own tap target, over the box's, which goes to the
                // prompt.
                Flexible(
                  child: GestureDetector(onTap: onChapterTap, child: title),
                ),
                Text(' · ', style: style?.copyWith(color: accent)),
                Expanded(child: prompt),
              ] else
                Expanded(child: title ?? prompt!),
            ],
          ),
        ),
      ),
    );
  }
}

/// An [AnimatedSwitcher]'s fade, unkeyed. The default takes its child's key,
/// so scrolling back across a prompt before it's faded out would have two
/// fades with one key.
Widget gaiaPinnedFade(Widget child, Animation<double> animation) =>
    FadeTransition(opacity: animation, child: child);

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
    transitionBuilder: gaiaPinnedFade,
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

import 'package:flutter/material.dart';

/// The Dream Journal's collapsible scratchpad: a corner "sticky note" that
/// peeks from the bottom-right, expands into a small note-taking card on tap,
/// and can be pinned — which hands control to the parent (see
/// [DreamJournalPage]) to swap this floating card out for a docked bottom
/// panel showing the same [controller] text, shrinking the main editor above
/// it. Unpinning swaps back.
class DreamStickyNote extends StatefulWidget {
  const DreamStickyNote({
    super.key,
    required this.controller,
    required this.onChanged,
    required this.onPin,
    this.focusNode,
    this.accentColor,
  });

  final TextEditingController controller;
  final ValueChanged<String> onChanged;
  final VoidCallback onPin;
  final FocusNode? focusNode;
  final Color? accentColor;

  @override
  State<DreamStickyNote> createState() => _DreamStickyNoteState();
}

class _DreamStickyNoteState extends State<DreamStickyNote>
    with SingleTickerProviderStateMixin {
  static const _peekSize = 56.0;
  static const _expandedWidth = 280.0;
  static const _expandedHeight = 220.0;

  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 280),
  );
  var _expanded = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _toggleExpanded() {
    setState(() => _expanded = !_expanded);
    if (_expanded) {
      _controller.forward();
    } else {
      _controller.reverse();
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent = widget.accentColor ?? theme.colorScheme.primary;
    final curved = CurvedAnimation(
      parent: _controller,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInCubic,
    );

    return Positioned(
      right: 20,
      bottom: 20,
      child: AnimatedBuilder(
        animation: curved,
        builder: (context, _) {
          final t = curved.value;
          final width = lerpDouble(_peekSize, _expandedWidth, t);
          final height = lerpDouble(_peekSize, _expandedHeight, t);
          final contentOpacity = ((t - 0.5) / 0.5).clamp(0.0, 1.0);
          return Material(
            elevation: 3 + 5 * t,
            color: Color.lerp(
              theme.colorScheme.surfaceContainerHighest,
              theme.colorScheme.surface,
              t,
            ),
            shadowColor: Colors.black.withValues(alpha: 0.25),
            borderRadius: BorderRadius.circular(14),
            child: InkWell(
              borderRadius: BorderRadius.circular(14),
              onTap: _expanded ? null : _toggleExpanded,
              child: SizedBox(
                width: width,
                height: height,
                child: contentOpacity <= 0
                    ? const _StickyNoteCorner()
                    : Opacity(
                        opacity: contentOpacity,
                        child: _StickyNoteContents(
                          controller: widget.controller,
                          onChanged: widget.onChanged,
                          focusNode: widget.focusNode,
                          accentColor: accent,
                          onPin: widget.onPin,
                          onClose: _toggleExpanded,
                        ),
                      ),
              ),
            ),
          );
        },
      ),
    );
  }

  double lerpDouble(double a, double b, double t) => a + (b - a) * t;
}

/// The peeking corner sliver — a plain fold-style triangle so only a hint of
/// the note reads as "there" before the user taps it.
class _StickyNoteCorner extends StatelessWidget {
  const _StickyNoteCorner();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Icon(
        Icons.sticky_note_2_outlined,
        size: 22,
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
    );
  }
}

class _StickyNoteContents extends StatelessWidget {
  const _StickyNoteContents({
    required this.controller,
    required this.onChanged,
    required this.accentColor,
    required this.onPin,
    required this.onClose,
    this.focusNode,
  });

  final TextEditingController controller;
  final ValueChanged<String> onChanged;
  final Color accentColor;
  final VoidCallback onPin;
  final VoidCallback onClose;
  final FocusNode? focusNode;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 10, 6, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'Dream notes',
                  style: theme.textTheme.labelMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              IconButton(
                tooltip: 'Pin notes',
                icon: const Icon(Icons.push_pin_outlined, size: 18),
                color: accentColor,
                visualDensity: VisualDensity.compact,
                onPressed: onPin,
              ),
              IconButton(
                tooltip: 'Close',
                icon: const Icon(Icons.close, size: 18),
                visualDensity: VisualDensity.compact,
                onPressed: onClose,
              ),
            ],
          ),
          Expanded(
            child: TextField(
              controller: controller,
              focusNode: focusNode,
              onChanged: onChanged,
              maxLines: null,
              expands: true,
              textAlignVertical: TextAlignVertical.top,
              style: theme.textTheme.bodySmall,
              decoration: const InputDecoration(
                isDense: true,
                border: InputBorder.none,
                hintText: 'Jot a quick note to jog your memory later...',
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The docked bottom panel shown while notes are pinned — see
/// [DreamJournalPage], which swaps this in for [DreamStickyNote] and shrinks
/// the main editor above it to make room.
class DreamNotesDockedPanel extends StatelessWidget {
  const DreamNotesDockedPanel({
    super.key,
    required this.controller,
    required this.onChanged,
    required this.onUnpin,
    this.focusNode,
  });

  final TextEditingController controller;
  final ValueChanged<String> onChanged;
  final VoidCallback onUnpin;
  final FocusNode? focusNode;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.surfaceContainerHighest,
      borderRadius: const BorderRadius.vertical(top: Radius.circular(14)),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 8, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Dream notes',
                    style: theme.textTheme.labelMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: 'Unpin notes',
                  icon: const Icon(Icons.push_pin, size: 18),
                  visualDensity: VisualDensity.compact,
                  onPressed: onUnpin,
                ),
              ],
            ),
            SizedBox(
              height: 96,
              child: TextField(
                controller: controller,
                focusNode: focusNode,
                onChanged: onChanged,
                maxLines: null,
                expands: true,
                textAlignVertical: TextAlignVertical.top,
                style: theme.textTheme.bodySmall,
                decoration: const InputDecoration(
                  isDense: true,
                  border: InputBorder.none,
                  hintText: 'Jot a quick note to jog your memory later...',
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

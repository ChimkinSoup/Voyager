import 'package:flutter/material.dart';
import 'package:voyager/domain/models/gaia_models.dart';
import 'package:voyager/features/gaia/companion/gaia_button.dart';
import 'package:voyager/features/gaia/companion/gaia_card_text_field.dart';
import 'package:voyager/features/gaia/companion/gaia_orb_materials.dart';

/// A memory the agent offered (GAIA_HLD.md §11), in its reply. Open, with
/// [onRemember], it's an editor over [text], changed through [onEdit], that
/// [onRemember] saves and [onDismiss] drops; nothing waits on it, so the
/// chat goes on meanwhile. Otherwise it's a record of what came of it.
class GaiaMemoryCard extends StatefulWidget {
  const GaiaMemoryCard({
    super.key,
    required this.memory,
    this.text,
    this.onEdit,
    this.onRemember,
    this.onDismiss,
  });

  final GaiaMemoryPart memory;

  /// What its editor starts with; the memory's own text when null.
  final String? text;
  final ValueChanged<String>? onEdit;
  final VoidCallback? onRemember;
  final VoidCallback? onDismiss;

  @override
  State<GaiaMemoryCard> createState() => _GaiaMemoryCardState();
}

class _GaiaMemoryCardState extends State<GaiaMemoryCard> {
  late String _last = widget.text ?? widget.memory.text;
  late final TextEditingController _text =
      TextEditingController(text: _last)
        ..addListener(() {
          // Caret and selection moves notify too.
          if (_text.text == _last) return;
          _last = _text.text;
          widget.onEdit?.call(_text.text);
          // The Remember button follows whether there's text.
          setState(() {});
        });

  @override
  void didUpdateWidget(GaiaMemoryCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Edited in the memory inbox: it follows, unless typed in here.
    final was = oldWidget.text ?? oldWidget.memory.text;
    final now = widget.text ?? widget.memory.text;
    if (now != was && _text.text == was) {
      _last = now;
      _text.text = now;
    }
  }

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  bool get _answerable => widget.memory.isOpen && widget.onRemember != null;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent = theme.colorScheme.primary;
    final memory = widget.memory;
    return Container(
      constraints: const BoxConstraints(maxWidth: 520),
      margin: const EdgeInsets.symmetric(vertical: 6),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: (_answerable ? accent : theme.colorScheme.outlineVariant)
              .withValues(alpha: _answerable ? 0.7 : 0.4),
        ),
        color: accent.withValues(alpha: _answerable ? 0.08 : 0.03),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.bookmark_add_outlined,
                size: 16,
                color: gaiaAstralGoldFor(theme.brightness),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  memory.project
                      ? 'Remember this for the project?'
                      : 'Remember this?',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (_answerable)
            GaiaCardTextField(
              controller: _text,
              maxLines: 4,
              style: theme.textTheme.bodyMedium,
            )
          else
            Text(memory.text, style: theme.textTheme.bodyMedium),
          const SizedBox(height: 8),
          if (_answerable)
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Also in the memory inbox',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.outline,
                    ),
                  ),
                ),
                if (widget.onDismiss != null)
                  GaiaButton(
                    label: 'Dismiss',
                    onPressed: widget.onDismiss,
                    size: 28,
                    color: theme.colorScheme.error,
                  ),
                const SizedBox(width: 8),
                GaiaButton(
                  label: 'Remember',
                  onPressed: _text.text.trim().isEmpty
                      ? null
                      : widget.onRemember,
                  size: 28,
                ),
              ],
            )
          else
            Text(
              switch (memory.state) {
                GaiaCardState.open => 'Waiting in the memory inbox',
                GaiaCardState.accepted => 'Remembered',
                _ => 'Dismissed',
              },
              style: theme.textTheme.bodySmall?.copyWith(
                color: memory.state == GaiaCardState.rejected
                    ? kGaiaStatusRose
                    : theme.colorScheme.onSurfaceVariant,
              ),
            ),
        ],
      ),
    );
  }
}

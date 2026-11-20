import 'package:flutter/material.dart';
import 'package:voyager/domain/models/gaia_models.dart';
import 'package:voyager/features/gaia/companion/gaia_button.dart';
import 'package:voyager/features/gaia/companion/gaia_card_text_field.dart';
import 'package:voyager/features/gaia/companion/gaia_notch.dart';
import 'package:voyager/features/gaia/companion/gaia_orb_materials.dart';
import 'package:voyager/features/gaia/companion/gaia_style.dart';

/// A memory the agent offered (GAIA_HLD.md §11), in its reply. Open, with
/// [onRemember], it's an editor over [text], changed through [onEdit], that
/// [onRemember] saves, pinned when its pin is on (GAIA_MEMORY_TOPICS_HLD.md
/// §3.3), and [onDismiss] drops; nothing waits on it, so the chat goes on
/// meanwhile. Otherwise it's a record of what came of it.
///
/// Open, it shows the topics in [filing] and the new topic offered, which
/// can be changed before Remember (§3.2): a topic taken out, one of
/// [topicChoices] added ([onTopics]), and the new topic taken or not
/// ([onNewTopic]).
class GaiaMemoryCard extends StatefulWidget {
  const GaiaMemoryCard({
    super.key,
    required this.memory,
    this.text,
    this.onEdit,
    this.onRemember,
    this.onDismiss,
    this.filing,
    this.onTopics,
    this.onNewTopic,
    this.topicChoices,
  });

  final GaiaMemoryPart memory;

  /// What its editor starts with; the memory's own text when null.
  final String? text;
  final ValueChanged<String>? onEdit;

  /// Called with whether to pin it too.
  final ValueChanged<bool>? onRemember;
  final VoidCallback? onDismiss;

  /// Its topics, the new topic offered, and whether that's taken (true),
  /// dropped (false) or left for later (null); null while unknown.
  final ({List<GaiaTopicLine> topics, String? suggested, bool? newTopic})?
  filing;
  final ValueChanged<List<GaiaTopicLine>>? onTopics;
  final ValueChanged<bool?>? onNewTopic;
  final Future<List<GaiaTopicLine>> Function()? topicChoices;

  @override
  State<GaiaMemoryCard> createState() => _GaiaMemoryCardState();
}

class _GaiaMemoryCardState extends State<GaiaMemoryCard> {
  late String _last = widget.text ?? widget.memory.text;
  late final TextEditingController _text = TextEditingController(text: _last)
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
    _menu?.remove();
    super.dispose();
  }

  bool get _answerable => widget.memory.isOpen && widget.onRemember != null;

  /// Pinned as it's remembered.
  var _pin = false;

  final _addKey = GlobalKey();

  /// The + Topic menu, and whether it was open as the button was pressed:
  /// that press closes it, and mustn't open it again.
  ContextMenuController? _menu;
  var _wasOpen = false;

  /// Fetching its choices: another press meanwhile mustn't open a second.
  var _opening = false;

  /// A menu of the topics it isn't in, by [_addKey]'s button; the one
  /// picked is added.
  Future<void> _addTopic(List<GaiaTopicLine> topics) async {
    if (_opening) return;
    _opening = true;
    final List<GaiaTopicLine> choices;
    try {
      choices = [
        for (final topic in await widget.topicChoices!())
          if (!topics.any((had) => had.id == topic.id)) topic,
      ];
    } finally {
      _opening = false;
    }
    final box = _addKey.currentContext?.findRenderObject() as RenderBox?;
    if (choices.isEmpty || box == null || !mounted) return;
    _menu = showGaiaMenu(
      context,
      box.localToGlobal(Offset(0, box.size.height)),
      [
        for (final topic in choices)
          GaiaMenuItem(
            label: topic.path,
            onPressed: () {
              // Its topics now, not as they were when the menu was opened.
              final now = widget.filing?.topics ?? topics;
              if (!mounted || now.any((had) => had.id == topic.id)) return;
              widget.onTopics?.call([...now, topic]);
            },
          ),
      ],
    );
  }

  Widget _topics(ThemeData theme) {
    final filing = widget.filing!;
    final suggested = filing.suggested;
    final taken = filing.newTopic == true;
    final declined = filing.newTopic == false;
    final label = theme.textTheme.labelSmall?.copyWith(
      color: theme.colorScheme.primary,
      fontWeight: FontWeight.bold,
    );
    return Wrap(
      spacing: 4,
      runSpacing: 4,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        for (final topic in filing.topics)
          _TopicChip(
            label: topic.path,
            style: label,
            tooltip: 'Remove',
            removes: true,
            onTap: () => widget.onTopics?.call([
              for (final other in filing.topics)
                if (other.id != topic.id) other,
            ]),
          ),
        if (suggested != null)
          _TopicChip(
            label: 'New topic: $suggested',
            style: label,
            checked: taken,
            filled: taken,
            declined: declined,
            tooltip: taken
                ? "Don't make it"
                : declined
                ? 'Bring it back'
                : 'Make this topic',
            // Offered, taken, declined, and back to offered.
            onTap: () => widget.onNewTopic?.call(
              taken
                  ? false
                  : declined
                  ? null
                  : true,
            ),
          ),
        if (widget.topicChoices != null)
          Listener(
            onPointerDown: (_) => _wasOpen = _menu?.isShown ?? false,
            child: _TopicChip(
              key: _addKey,
              label: '+ Topic',
              style: label,
              onTap: () {
                // Read once: Enter or Space, later, has no press to set it.
                final wasOpen = _wasOpen;
                _wasOpen = false;
                if (!wasOpen) _addTopic(filing.topics);
              },
            ),
          ),
      ],
    );
  }

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
          if (_answerable && widget.filing != null) ...[
            const SizedBox(height: 6),
            _topics(theme),
          ],
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
                IconButton(
                  tooltip: _pin ? "Don't pin it" : 'Pin it to every chat',
                  isSelected: _pin,
                  visualDensity: VisualDensity.compact,
                  icon: Icon(
                    _pin ? Icons.push_pin : Icons.push_pin_outlined,
                    size: 16,
                    color: _pin ? accent : theme.colorScheme.outline,
                  ),
                  onPressed: () => setState(() => _pin = !_pin),
                ),
                const SizedBox(width: 4),
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
                      : () => widget.onRemember!(_pin),
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

/// A topic on the card: squared off with the composer's corners, its edge
/// lit while hovered, as a still [GaiaButton]'s is: in the accent, or in
/// rose when a click [removes] it.
class _TopicChip extends StatefulWidget {
  const _TopicChip({
    super.key,
    required this.label,
    required this.style,
    this.tooltip,
    this.onTap,
    this.removes = false,
    this.filled = false,
    this.declined = false,
    this.checked,
  });

  final String label;
  final TextStyle? style;
  final String? tooltip;
  final VoidCallback? onTap;
  final bool removes;
  final bool filled;

  /// Greyed and struck through: turned down, but still there to undo.
  final bool declined;

  /// A ✓ before the label when true, a + when false; neither when null.
  final bool? checked;

  @override
  State<_TopicChip> createState() => _TopicChipState();
}

class _TopicChipState extends State<_TopicChip> {
  var _hovered = false;
  var _focused = false;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final lit = widget.removes
        ? kGaiaStatusRose
        : HSLColor.fromColor(colors.primary).withSaturation(1).toColor();
    final highlighted = _hovered || _focused;
    final style = highlighted && widget.removes
        ? widget.style?.copyWith(color: kGaiaStatusRose)
        : widget.declined
        ? widget.style?.copyWith(
            color: colors.onSurfaceVariant.withValues(alpha: 0.6),
          )
        : widget.style;
    final label = Text(
      widget.label,
      overflow: TextOverflow.ellipsis,
      style: widget.declined
          ? style?.copyWith(
              decoration: TextDecoration.lineThrough,
              decorationColor: style.color,
            )
          : style,
    );
    final checked = widget.checked;
    final text = checked == null
        ? label
        : Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              // As wide as the wider of the two, so the chip keeps its
              // size as it's ticked.
              IndexedStack(
                alignment: Alignment.center,
                index: checked ? 1 : 0,
                children: [
                  Text('+', style: style),
                  Text('✓', style: style),
                ],
              ),
              const SizedBox(width: 4),
              Flexible(child: label),
            ],
          );
    return FocusableActionDetector(
      mouseCursor: SystemMouseCursors.click,
      actions: {
        ActivateIntent: CallbackAction<ActivateIntent>(
          onInvoke: (_) => widget.onTap?.call(),
        ),
      },
      onShowHoverHighlight: (hovered) => setState(() => _hovered = hovered),
      onShowFocusHighlight: (focused) => setState(() => _focused = focused),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: GaiaMotion.quick,
          constraints: const BoxConstraints(maxWidth: 260),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(GaiaRadius.chip),
            border: Border.all(color: highlighted ? lit : colors.outlineVariant),
            color: widget.filled
                ? colors.primary.withValues(alpha: 0.12)
                : highlighted
                ? lit.withValues(alpha: 0.08)
                : null,
          ),
          child: widget.tooltip == null
              ? text
              : Tooltip(message: widget.tooltip, child: text),
        ),
      ),
    );
  }
}

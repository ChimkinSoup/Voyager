import 'package:flutter/material.dart';
import 'package:voyager/domain/models/gaia_models.dart';
import 'package:voyager/features/gaia/companion/gaia_button.dart';
import 'package:voyager/features/gaia/companion/gaia_card_text_field.dart';
import 'package:voyager/features/gaia/companion/gaia_orb_materials.dart';

/// A memory the agent offered (GAIA_HLD.md §11), in its reply. Open, with
/// [onRemember], it's an editor over [text], changed through [onEdit], that
/// [onRemember] saves, pinned when its pin is on (GAIA_MEMORY_TOPICS_HLD.md
/// §3.3), and [onDismiss] drops; nothing waits on it, so the chat goes on
/// meanwhile. Otherwise it's a record of what came of it.
///
/// Open, it shows the topics in [filing] and the new topic offered, which
/// can be changed before Remember (§3.2): a topic taken out, one of
/// [topicChoices] added ([onTopics]), and the new topic taken or dropped
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
    super.dispose();
  }

  bool get _answerable => widget.memory.isOpen && widget.onRemember != null;

  /// Pinned as it's remembered.
  var _pin = false;

  final _addKey = GlobalKey();

  /// A menu of the topics it isn't in, by [_addKey]'s button; the one
  /// picked is added.
  Future<void> _addTopic(List<GaiaTopicLine> topics) async {
    final choices = [
      for (final topic in await widget.topicChoices!())
        if (!topics.any((had) => had.id == topic.id)) topic,
    ];
    final box = _addKey.currentContext?.findRenderObject() as RenderBox?;
    if (choices.isEmpty || box == null || !mounted) return;
    final at = box.localToGlobal(Offset(0, box.size.height));
    final picked = await showMenu<GaiaTopicLine>(
      context: context,
      position: RelativeRect.fromLTRB(at.dx, at.dy, at.dx, at.dy),
      items: [
        for (final topic in choices)
          PopupMenuItem(value: topic, height: 32, child: Text(topic.path)),
      ],
    );
    // Its topics now, not as they were when the menu was asked for.
    final now = widget.filing?.topics ?? topics;
    if (picked != null && mounted && !now.any((had) => had.id == picked.id)) {
      widget.onTopics?.call([...now, picked]);
    }
  }

  Widget _topics(ThemeData theme) {
    final filing = widget.filing!;
    final suggested = filing.newTopic == false ? null : filing.suggested;
    final taken = filing.newTopic == true;
    final label = theme.textTheme.labelSmall?.copyWith(
      color: theme.colorScheme.primary,
      fontWeight: FontWeight.bold,
    );
    Widget chip(
      Widget text, {
      VoidCallback? onTap,
      VoidCallback? onRemove,
      String? tooltip,
      bool filled = false,
    }) => Container(
      constraints: const BoxConstraints(maxWidth: 260),
      padding: EdgeInsets.only(left: 8, right: onRemove == null ? 8 : 2),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: theme.colorScheme.outlineVariant),
        color: filled
            ? theme.colorScheme.primary.withValues(alpha: 0.12)
            : null,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(
            child: InkWell(
              onTap: onTap,
              child: tooltip == null
                  ? text
                  : Tooltip(message: tooltip, child: text),
            ),
          ),
          if (onRemove != null)
            InkWell(
              onTap: onRemove,
              customBorder: const CircleBorder(),
              child: Padding(
                padding: const EdgeInsets.all(3),
                child: Icon(
                  Icons.close,
                  size: 10,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
        ],
      ),
    );
    return Wrap(
      spacing: 4,
      runSpacing: 4,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        for (final topic in filing.topics)
          chip(
            Text(topic.path, overflow: TextOverflow.ellipsis, style: label),
            onRemove: () => widget.onTopics?.call([
              for (final other in filing.topics)
                if (other.id != topic.id) other,
            ]),
          ),
        if (suggested != null)
          chip(
            Text(
              '${taken ? '✓' : '+'} New topic: $suggested',
              overflow: TextOverflow.ellipsis,
              style: label,
            ),
            filled: taken,
            tooltip: taken ? "Don't make it yet" : 'Make this topic',
            onTap: () => widget.onNewTopic?.call(taken ? null : true),
            onRemove: () => widget.onNewTopic?.call(false),
          ),
        if (widget.topicChoices != null)
          chip(
            Text('+ Topic', key: _addKey, style: label),
            onTap: () => _addTopic(filing.topics),
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

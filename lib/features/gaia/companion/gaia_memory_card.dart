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
///
/// One that updates a kept memory ([GaiaMemoryPart.was]) shows that
/// memory's text struck through above its own, and offers [onUpdate] beside
/// Keep both, which is [onRemember] (GAIA_MEMORY_TOPICS_HLD.md §27.3).
class GaiaMemoryCard extends StatefulWidget {
  const GaiaMemoryCard({
    super.key,
    required this.memory,
    this.text,
    this.onEdit,
    this.onRemember,
    this.onUpdate,
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
  final VoidCallback? onUpdate;
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

  /// "Update this?", with Update offered.
  bool get _updates => widget.memory.was != null && widget.onUpdate != null;

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

  Widget _topics(ThemeData theme, Color background) {
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
          GaiaTopicChip(
            label: topic.path,
            style: label,
            background: background,
            tint: gaiaTopicTint(topic.id, theme.brightness),
            tooltip: 'Remove',
            removes: true,
            onTap: () => widget.onTopics?.call([
              for (final other in filing.topics)
                if (other.id != topic.id) other,
            ]),
          ),
        if (suggested != null)
          GaiaTopicChip(
            label: 'New topic: $suggested',
            style: label,
            background: background,
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
            // After the tap, if there is one: a press dragged off leaves
            // none to clear it, and Enter later would be swallowed.
            onPointerUp: (_) => Future.microtask(() => _wasOpen = false),
            onPointerCancel: (_) => _wasOpen = false,
            child: GaiaTopicChip(
              key: _addKey,
              label: '+ Topic',
              style: label,
              background: background,
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
    final tint = accent.withValues(alpha: _answerable ? 0.08 : 0.03);
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
        color: tint,
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
                  memory.was != null
                      ? 'Update this?'
                      : memory.project
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
          if (memory.was case final was?) ...[
            Text(
              was,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                decoration: TextDecoration.lineThrough,
              ),
            ),
            const SizedBox(height: 4),
          ],
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
            _topics(
              theme,
              Color.alphaBlend(tint, theme.scaffoldBackgroundColor),
            ),
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
                // An update keeps the old memory's pin.
                if (!_updates) ...[
                  GaiaButton(
                    tooltip: _pin ? "Don't pin it" : 'Pin it to every chat',
                    icon: _pin ? Icons.push_pin : Icons.push_pin_outlined,
                    size: 28,
                    iconSize: 16,
                    color: _pin ? accent : null,
                    onPressed: () => setState(() => _pin = !_pin),
                  ),
                  const SizedBox(width: 4),
                ],
                if (widget.onDismiss != null)
                  GaiaButton(
                    label: 'Dismiss',
                    onPressed: widget.onDismiss,
                    size: 28,
                    color: theme.colorScheme.error,
                  ),
                const SizedBox(width: 8),
                GaiaButton(
                  label: _updates ? 'Keep both' : 'Remember',
                  onPressed: _text.text.trim().isEmpty
                      ? null
                      : () => widget.onRemember!(_pin),
                  size: 28,
                ),
                if (_updates) ...[
                  const SizedBox(width: 8),
                  GaiaButton(
                    label: 'Update',
                    onPressed: _text.text.trim().isEmpty
                        ? null
                        : widget.onUpdate,
                    size: 28,
                  ),
                ],
              ],
            )
          else
            Text(
              switch (memory.state) {
                GaiaCardState.open => 'Waiting in the memory inbox',
                GaiaCardState.accepted =>
                  memory.updated ? 'Updated' : 'Remembered',
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

/// A change to a memory the agent offered through `memory_revise`
/// (GAIA_SETTINGS_HLD.md §7.4, §7.5), in its reply, in [GaiaMemoryCard]'s
/// look: when its text changes, what the memory said, struck through, over
/// the rewrite, and a chip per topic change. Open, with [onApply], the
/// rewrite is an editor, a click on a chip leaves that change out, and
/// Apply saves the text and the changes kept while [onDismiss] drops it;
/// nothing waits on it. Otherwise it's a record of what came of it.
class GaiaRevisionCard extends StatefulWidget {
  const GaiaRevisionCard({
    super.key,
    required this.revision,
    this.onApply,
    this.onDismiss,
  });

  final GaiaRevisionPart revision;
  final void Function(String text, List<GaiaTopicChange> topics)? onApply;
  final VoidCallback? onDismiss;

  @override
  State<GaiaRevisionCard> createState() => _GaiaRevisionCardState();
}

class _GaiaRevisionCardState extends State<GaiaRevisionCard> {
  late final _text = TextEditingController(text: widget.revision.text)
    // Apply follows whether there's text.
    ..addListener(() => setState(() {}));

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  bool get _answerable => widget.revision.isOpen && widget.onApply != null;

  /// The topic changes left out, by index.
  final _left = <int>{};

  List<GaiaTopicChange> get _kept => [
    for (final (i, change) in widget.revision.topics.indexed)
      if (!_left.contains(i)) change,
  ];

  Widget _topics(ThemeData theme, Color background) {
    final revision = widget.revision;
    final kept = _kept;
    // With the changes kept, it'd be in no topic (§7.5): its last − chip
    // says so.
    final removes = kept.where((change) => !change.add).length;
    final unsorted =
        revision.had != null &&
        removes > 0 &&
        revision.had! - removes + (kept.length - removes) <= 0;
    final lastRemove = kept.where((change) => !change.add).lastOrNull;
    final label = theme.textTheme.labelSmall?.copyWith(
      color: theme.colorScheme.primary,
      fontWeight: FontWeight.bold,
    );
    return Wrap(
      spacing: 4,
      runSpacing: 4,
      children: [
        for (final (i, change) in revision.topics.indexed)
          GaiaTopicChip(
            label: change.add
                ? '+ ${change.isNew ? 'New topic: ' : ''}${change.path}'
                : '− ${change.path}'
                      '${unsorted && change == lastRemove ? ' · leaves it Unsorted' : ''}',
            style: label,
            background: background,
            removes: !change.add,
            declined: _left.contains(i),
            tooltip: !_answerable
                ? null
                : _left.contains(i)
                ? 'Keep this change'
                : 'Leave this change out',
            onTap: _answerable
                ? () => setState(() {
                    if (!_left.remove(i)) _left.add(i);
                  })
                : null,
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent = theme.colorScheme.primary;
    final revision = widget.revision;
    final muted = theme.colorScheme.onSurfaceVariant;
    final rewrites = revision.text != revision.was;
    final background = Color.alphaBlend(
      accent.withValues(alpha: _answerable ? 0.08 : 0.03),
      theme.scaffoldBackgroundColor,
    );
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
                Icons.edit_note,
                size: 16,
                color: gaiaAstralGoldFor(theme.brightness),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  revision.topics.isEmpty
                      ? 'Rewrite this memory?'
                      : 'Change this memory?',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
          if (revision.why case final why?) ...[
            const SizedBox(height: 4),
            Text(
              why,
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.outline,
              ),
            ),
          ],
          if (rewrites) ...[
            const SizedBox(height: 8),
            Text(
              revision.was,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: muted,
                decoration: TextDecoration.lineThrough,
                decorationColor: muted,
              ),
            ),
            const SizedBox(height: 6),
            if (_answerable)
              GaiaCardTextField(
                controller: _text,
                maxLines: 4,
                style: theme.textTheme.bodyMedium,
              )
            else
              Text(revision.text, style: theme.textTheme.bodyMedium),
          ] else ...[
            const SizedBox(height: 8),
            Text(revision.was, style: theme.textTheme.bodyMedium),
          ],
          if (revision.topics.isNotEmpty) ...[
            const SizedBox(height: 8),
            _topics(theme, background),
          ],
          const SizedBox(height: 8),
          if (_answerable)
            Row(
              children: [
                const Spacer(),
                if (widget.onDismiss != null)
                  GaiaButton(
                    label: 'Dismiss',
                    onPressed: widget.onDismiss,
                    size: 28,
                    color: theme.colorScheme.error,
                  ),
                const SizedBox(width: 8),
                GaiaButton(
                  label: 'Apply',
                  // A topics-only card with every chip left out changes
                  // nothing.
                  onPressed:
                      _text.text.trim().isEmpty ||
                          (!rewrites &&
                              revision.topics.isNotEmpty &&
                              _kept.isEmpty)
                      ? null
                      : () => widget.onApply!(_text.text.trim(), _kept),
                  size: 28,
                ),
              ],
            )
          else
            Text(
              switch (revision.state) {
                GaiaCardState.open => 'Not applied yet',
                GaiaCardState.accepted => 'Applied',
                _ => 'Dismissed',
              },
              style: theme.textTheme.bodySmall?.copyWith(
                color: revision.state == GaiaCardState.rejected
                    ? kGaiaStatusRose
                    : muted,
              ),
            ),
        ],
      ),
    );
  }
}

/// Topic [id]'s own colour on its chips, the same every time, so a topic
/// the memory is in reads apart from + Topic and the new topic offered.
Color gaiaTopicTint(String id, Brightness brightness) {
  var hash = 0;
  for (final unit in id.codeUnits) {
    hash = (hash * 31 + unit) & 0x7fffffff;
  }
  return HSLColor.fromAHSL(
    1,
    // Clear of red, which reads as the rose a removing chip lights in.
    40 + (hash % 10) * 28.0,
    0.55,
    brightness == Brightness.dark ? 0.68 : 0.42,
  ).toColor();
}

/// A topic on the card: squared off with the composer's corners, its edge
/// lit while hovered, as a still [GaiaButton]'s is: in the accent, or in
/// rose when a click [removes] it.
class GaiaTopicChip extends StatefulWidget {
  const GaiaTopicChip({
    super.key,
    required this.label,
    required this.style,
    required this.background,
    this.tooltip,
    this.onTap,
    this.removes = false,
    this.filled = false,
    this.declined = false,
    this.checked,
    this.tint,
  });

  final String label;
  final TextStyle? style;

  /// The card's colour, which the chip is solid over.
  final Color background;
  final String? tooltip;
  final VoidCallback? onTap;
  final bool removes;
  final bool filled;

  /// Greyed and struck through: turned down, but still there to undo.
  final bool declined;

  /// A ✓ before the label when true, a + when false; neither when null.
  final bool? checked;

  /// The topic's colour ([gaiaTopicTint]), for its label, edge and fill;
  /// null for a plain chip.
  final Color? tint;

  @override
  State<GaiaTopicChip> createState() => _GaiaTopicChipState();
}

class _GaiaTopicChipState extends State<GaiaTopicChip> {
  var _hovered = false;
  var _focused = false;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final lit = widget.removes
        ? kGaiaStatusRose
        : HSLColor.fromColor(colors.primary).withSaturation(1).toColor();
    final highlighted = _hovered || _focused;
    final tint = widget.tint;
    final style = highlighted && widget.removes
        ? widget.style?.copyWith(color: kGaiaStatusRose)
        : tint != null
        ? widget.style?.copyWith(color: tint)
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
            border: Border.all(
              color: highlighted
                  ? lit
                  : tint?.withValues(alpha: 0.5) ?? colors.outlineVariant,
            ),
            // Solid, under its shadow.
            color: Color.alphaBlend(
              widget.filled
                  ? colors.primary.withValues(alpha: 0.12)
                  : highlighted
                  ? lit.withValues(alpha: 0.08)
                  : tint?.withValues(alpha: 0.14) ?? Colors.transparent,
              widget.background,
            ),
            boxShadow: const [kGaiaChipShadow],
          ),
          child: widget.tooltip == null
              ? text
              : Tooltip(message: widget.tooltip, child: text),
        ),
      ),
    );
  }
}

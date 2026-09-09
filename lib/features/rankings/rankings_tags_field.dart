import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:voyager/core/widgets/contextual_popover.dart';
import 'package:voyager/core/widgets/field_hint_style.dart';
import 'package:voyager/core/widgets/notched_field_border.dart';
import 'package:voyager/domain/models/ranking_models.dart';

/// The editor panel's structured-tag control (`RANKINGS_PARENT_TAGS_HLD` §5.2).
///
/// A chip field rather than the space-separated text box the finance modal
/// uses: these tags are the row's subtitle and the filter's vocabulary, so
/// what is stored has to be visible as discrete things that can be removed one
/// at a time, not as a string the user has to re-parse by eye.
///
/// The control is uncontrolled between commits: [tags] seeds it and every
/// accepted change is handed straight back through [onChanged], so the panel
/// stays the only thing that owns the list.
class RankingTagsField extends StatefulWidget {
  const RankingTagsField({
    super.key,
    required this.tags,
    required this.suggestions,
    required this.onChanged,
    required this.accentColor,
    this.enabled = true,
  });

  final List<String> tags;

  /// The category's other structured tags, most-used first.
  final List<String> suggestions;

  final ValueChanged<List<String>> onChanged;
  final Color accentColor;
  final bool enabled;

  @override
  State<RankingTagsField> createState() => _RankingTagsFieldState();
}

class _RankingTagsFieldState extends State<RankingTagsField> {
  static const _suggestionWidth = 200.0;
  static const _suggestionHeight = 32.0;
  static const _maxSuggestions = 6;

  final _controller = TextEditingController();
  final _focusNode = FocusNode();
  final _layerLink = LayerLink();
  final _portal = OverlayPortalController();

  List<String> _suggestions = const [];
  var _selected = 0;

  @override
  void initState() {
    super.initState();
    _focusNode.onKeyEvent = _handleKey;
    _focusNode.addListener(_handleFocusChanged);
  }

  @override
  void dispose() {
    _focusNode.removeListener(_handleFocusChanged);
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _handleFocusChanged() {
    if (_focusNode.hasFocus) {
      setState(_refreshSuggestions);
      return;
    }
    // Blur commits whatever is sitting in the box (§5.2): a typed token left
    // behind on the way out of the panel would be lost without a word.
    _portal.hide();
    _commit(_controller.text);
  }

  bool get _full => widget.tags.length >= maxRankingParentTags;

  /// The category's tags the parent does not already carry, narrowed by what
  /// has been typed so far.
  void _refreshSuggestions() {
    final query = _controller.text.trim().toLowerCase();
    final taken = widget.tags.toSet();
    final matches = [
      for (final tag in widget.suggestions)
        if (!taken.contains(tag) && tag.contains(query)) tag,
    ];
    _suggestions = matches.length > _maxSuggestions
        ? matches.sublist(0, _maxSuggestions)
        : matches;
    _selected = 0;
    if (_suggestions.isEmpty || _full || !_focusNode.hasFocus) {
      _portal.hide();
    } else {
      _portal.show();
    }
  }

  /// Adds every legal token in [raw] that fits under the cap.
  void _commit(String raw) {
    if (raw.trim().isEmpty) {
      if (_controller.text.isNotEmpty) _controller.clear();
      return;
    }
    final wanted = normalizeRankingTags([...widget.tags, ...raw.split(',')]);
    _controller.clear();
    setState(_refreshSuggestions);
    if (wanted.length != widget.tags.length) widget.onChanged(wanted);
  }

  void _remove(String tag) {
    widget.onChanged([
      for (final value in widget.tags)
        if (value != tag) value,
    ]);
    setState(_refreshSuggestions);
  }

  KeyEventResult _handleKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    final listOpen = _portal.isShowing && _suggestions.isNotEmpty;

    if (key == LogicalKeyboardKey.escape && listOpen) {
      setState(_portal.hide);
      return KeyEventResult.handled;
    }
    if (listOpen &&
        (key == LogicalKeyboardKey.arrowDown ||
            key == LogicalKeyboardKey.arrowUp)) {
      final delta = key == LogicalKeyboardKey.arrowDown ? 1 : -1;
      setState(
        () => _selected =
            (_selected + delta + _suggestions.length) % _suggestions.length,
      );
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.enter) {
      _commit(listOpen ? _suggestions[_selected] : _controller.text);
      return KeyEventResult.handled;
    }
    // Backspace into the chips, but only from an empty box, so it never eats a
    // chip while there is still typing in front of it to delete.
    if (key == LogicalKeyboardKey.backspace &&
        _controller.text.isEmpty &&
        widget.tags.isNotEmpty) {
      _remove(widget.tags.last);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _handleChanged(String value) {
    // A comma is a commit key rather than a character (§5.2), and a paste can
    // bring several at once — [_commit] splits on them.
    if (value.contains(',')) {
      _commit(value);
      return;
    }
    setState(_refreshSuggestions);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent = widget.accentColor;
    final textStyle = theme.textTheme.bodyMedium?.copyWith(
      color: theme.colorScheme.onSurface,
      height: 1.0,
    );

    final field = TextField(
      controller: _controller,
      focusNode: _focusNode,
      enabled: widget.enabled && !_full,
      style: textStyle,
      cursorColor: accent,
      onChanged: _handleChanged,
      decoration: InputDecoration(
        isDense: true,
        // The box only asks for something while there are no chips: beside
        // them a placeholder is one more thing competing for the same row.
        hintText: widget.tags.isEmpty ? 'Add a tag' : null,
        hintStyle: fieldHintStyle(context, textStyle),
        contentPadding: EdgeInsets.zero,
        filled: false,
        border: InputBorder.none,
        enabledBorder: InputBorder.none,
        focusedBorder: InputBorder.none,
        disabledBorder: InputBorder.none,
      ),
    );

    final content = Wrap(
      spacing: 6,
      runSpacing: 6,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        for (final tag in widget.tags)
          _EditableTagChip(
            tag: tag,
            accent: accent,
            onRemove: widget.enabled ? () => _remove(tag) : null,
          ),
        // A floor rather than a fixed width, so the box keeps a target big
        // enough to click into once the chips have taken most of the row.
        ConstrainedBox(
          constraints: const BoxConstraints(minWidth: 96),
          child: IntrinsicWidth(child: field),
        ),
      ],
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        CompositedTransformTarget(
          link: _layerLink,
          child: OverlayPortal(
            controller: _portal,
            overlayChildBuilder: _buildSuggestions,
            // The border paints around the content and never moves it, so the
            // padding the chips sit on is given to the child as well.
            child: NotchedFieldBorder(
              focusNode: _focusNode,
              accentColor: accent,
              label: 'Tags',
              labelStyle: textStyle,
              hasContent: widget.tags.isNotEmpty || _controller.text.isNotEmpty,
              enabled: widget.enabled,
              borderRadius: 12,
              contentPadding: _contentPadding,
              child: Padding(padding: _contentPadding, child: content),
            ),
          ),
        ),
        // Standing, not fired after a refused keystroke: the box is closed at
        // the cap, so the line under it is what says why nothing types.
        if (_full)
          Padding(
            padding: const EdgeInsets.only(left: 14, top: 4),
            child: Text(
              'Maximum $maxRankingParentTags tags',
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
      ],
    );
  }

  static const _contentPadding = EdgeInsets.symmetric(
    horizontal: 14,
    vertical: 10,
  );

  Widget _buildSuggestions(BuildContext context) {
    final theme = Theme.of(context);
    return Positioned(
      width: _suggestionWidth,
      child: CompositedTransformFollower(
        link: _layerLink,
        targetAnchor: Alignment.bottomLeft,
        followerAnchor: Alignment.topLeft,
        offset: const Offset(0, 4),
        child: ContextualPopover(
          width: _suggestionWidth,
          height: _suggestions.length * _suggestionHeight,
          accentColor: widget.accentColor,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (var i = 0; i < _suggestions.length; i++)
                _SuggestionRow(
                  tag: _suggestions[i],
                  height: _suggestionHeight,
                  selected: i == _selected,
                  accent: widget.accentColor,
                  textStyle: theme.textTheme.bodySmall,
                  onHover: () => setState(() => _selected = i),
                  onTap: () => _commit(_suggestions[i]),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A tag inside the editor, with the × that takes it off.
class _EditableTagChip extends StatelessWidget {
  const _EditableTagChip({
    required this.tag,
    required this.accent,
    required this.onRemove,
  });

  final String tag;
  final Color accent;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.only(left: 8, right: 3, top: 2, bottom: 2),
      decoration: BoxDecoration(
        color: accent.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            tag,
            style: theme.textTheme.labelSmall?.copyWith(color: accent),
          ),
          if (onRemove != null)
            InkWell(
              onTap: onRemove,
              borderRadius: BorderRadius.circular(999),
              child: Padding(
                padding: const EdgeInsets.all(3),
                child: Icon(
                  PhosphorIconsRegular.x,
                  size: 11,
                  color: accent,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _SuggestionRow extends StatelessWidget {
  const _SuggestionRow({
    required this.tag,
    required this.height,
    required this.selected,
    required this.accent,
    required this.textStyle,
    required this.onHover,
    required this.onTap,
  });

  final String tag;
  final double height;
  final bool selected;
  final Color accent;
  final TextStyle? textStyle;
  final VoidCallback onHover;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => onHover(),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: Container(
          height: height,
          alignment: Alignment.centerLeft,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          color: selected ? accent.withValues(alpha: 0.16) : Colors.transparent,
          child: Text(
            tag,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: textStyle,
          ),
        ),
      ),
    );
  }
}

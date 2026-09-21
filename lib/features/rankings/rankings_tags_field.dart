import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:voyager/core/tags/tag_suggestions.dart';
import 'package:voyager/core/theme/voyager_theme.dart';
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
    this.onChipRemoved,
  });

  final List<String> tags;

  /// The category's other structured tags, most-used first.
  final List<String> suggestions;

  final ValueChanged<List<String>> onChanged;

  /// Called after a tap on a chip takes its tag off, with the position the tag
  /// held, so the host can offer it back. The whole chip is the remove button,
  /// which makes a stray click cheap to make. Backspace does not call it: that
  /// one is only reachable from the box, on purpose.
  final void Function(String tag, int index)? onChipRemoved;
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

  /// The list last handed to [RankingTagsField.onChanged], shown until
  /// [widget.tags] reads the same.
  ///
  /// The panel does not rebuild for a tag save of its own; the new list comes
  /// back with the page's re-read a frame or two later. Drawing [widget.tags]
  /// until then would leave a just-added chip missing, and a second Enter in
  /// that gap would build on the list without it.
  List<String>? _pending;

  List<String> get _tags => _pending ?? widget.tags;

  @override
  void initState() {
    super.initState();
    _focusNode.onKeyEvent = _handleKey;
    _focusNode.addListener(_handleFocusChanged);
  }

  @override
  void didUpdateWidget(RankingTagsField oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Held until the saved list arrives rather than dropped on the first new
    // one: two quick adds come back one at a time, and the first alone would
    // take the second chip off for a frame.
    if (_pending != null && listEquals(_pending, widget.tags)) _pending = null;
  }

  @override
  void dispose() {
    _focusNode.removeListener(_handleFocusChanged);
    // What blur would have committed (§5.2). The panel unmounting takes the
    // listener away before the node ever reports losing focus, so a tag typed
    // without Enter vanished with the panel. No setState: this is dispose.
    final typed = _controller.text;
    if (widget.enabled && typed.trim().isNotEmpty) {
      final wanted = normalizeRankingTags([..._tags, ...typed.split(',')]);
      if (wanted.length != _tags.length) widget.onChanged(wanted);
    }
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

  bool get _full => _tags.length >= maxRankingParentTags;

  /// The category's tags the parent does not already carry, narrowed by what
  /// has been typed so far — by prefix, the way `#` completes in the journal
  /// body.
  void _refreshSuggestions() {
    final current = _tags;
    // Commit strips a leading `#`, so the prefix is whatever follows it.
    final query = _controller.text.trim().replaceFirst(RegExp(r'^#+'), '');
    final taken = current.toSet();
    _suggestions = filterTagSuggestions(
      [
        for (final tag in widget.suggestions)
          if (!taken.contains(tag)) tag,
      ],
      query,
      limit: _maxSuggestions,
    );
    _selected = 0;
    if (_suggestions.isEmpty ||
        current.length >= maxRankingParentTags ||
        !_focusNode.hasFocus) {
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
    final current = _tags;
    final wanted = normalizeRankingTags([...current, ...raw.split(',')]);
    _controller.clear();
    final changed = wanted.length != current.length;
    setState(() {
      if (changed) _pending = wanted;
      _refreshSuggestions();
    });
    if (changed) widget.onChanged(wanted);
  }

  void _remove(String tag) {
    final kept = [
      for (final value in _tags)
        if (value != tag) value,
    ];
    widget.onChanged(kept);
    setState(() {
      _pending = kept;
      _refreshSuggestions();
    });
  }

  void _removeByTap(String tag) {
    final index = _tags.indexOf(tag);
    _remove(tag);
    widget.onChipRemoved?.call(tag, index);
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
        _tags.isNotEmpty) {
      _remove(_tags.last);
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
        // Always asked for, now that the box is its own bordered thing beside
        // the chips: an empty box with nothing in it reads as broken.
        hintText: 'Add a tag',
        hintStyle: fieldHintStyle(context, textStyle),
        contentPadding: EdgeInsets.zero,
        filled: false,
        border: InputBorder.none,
        enabledBorder: InputBorder.none,
        focusedBorder: InputBorder.none,
        disabledBorder: InputBorder.none,
      ),
    );

    // The border wraps the box alone: the chips are what the entry already
    // carries, and sitting inside the box they read as text that had been
    // typed there rather than as things already committed.
    final box = CompositedTransformTarget(
      link: _layerLink,
      child: OverlayPortal(
        controller: _portal,
        overlayChildBuilder: _buildSuggestions,
        // The border paints around the content and never moves it, so the
        // padding the text sits on is given to the child as well.
        child: NotchedFieldBorder(
          focusNode: _focusNode,
          accentColor: accent,
          enabled: widget.enabled,
          contentPadding: _contentPadding,
          child: Padding(padding: _contentPadding, child: field),
        ),
      ),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _TagFlow(
          spacing: 6,
          runSpacing: 6,
          minFieldWidth: 110,
          children: [
            for (final tag in _tags)
              _EditableTagChip(
                tag: tag,
                accent: accent,
                onRemove: widget.enabled ? () => _removeByTap(tag) : null,
              ),
            box,
          ],
        ),
        // Standing, not fired after a refused keystroke: the box is closed at
        // the cap, so the line under it is what says why nothing types.
        if (_full)
          Padding(
            padding: const EdgeInsets.only(left: 2, top: 4),
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

/// A tag inside the editor; tapping it takes it off.
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
    final style = theme.textTheme.labelSmall?.copyWith(color: accent);
    return Material(
      type: MaterialType.transparency,
      child: InkWell(
        onTap: onRemove,
        borderRadius: BorderRadius.circular(VoyagerTheme.fieldRadius),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
          decoration: BoxDecoration(
            color: accent.withValues(alpha: 0.14),
            borderRadius: BorderRadius.circular(VoyagerTheme.fieldRadius),
          ),
          // A tag has no length limit, so one wider than the panel is cut
          // short, and only a cut one says the rest on hover — a tooltip
          // repeating a chip that already reads in full is noise.
          child: LayoutBuilder(
            builder: (context, constraints) {
              final text = Text(
                tag,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: style,
              );
              final painter = TextPainter(
                text: TextSpan(text: tag, style: style),
                maxLines: 1,
                textDirection: Directionality.of(context),
                textScaler: MediaQuery.textScalerOf(context),
              )..layout(maxWidth: constraints.maxWidth);
              final cut = painter.didExceedMaxLines;
              painter.dispose();
              return cut ? Tooltip(message: tag, child: text) : text;
            },
          ),
        ),
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

/// Lays the chips out in wrapping lines and gives the last child — the text
/// box — whatever is left of the line the chips ended on.
///
/// A [Wrap] cannot do this: it sizes every child to its intrinsic width, so
/// the box would either jitter with each keystroke or sit at a fixed width
/// with the tail of the row wasted. Here the box is measured last, against
/// the space the chips did not take, and falls to a full-width line of its
/// own when what is left is narrower than [minFieldWidth].
class _TagFlow extends MultiChildRenderObjectWidget {
  const _TagFlow({
    required super.children,
    required this.spacing,
    required this.runSpacing,
    required this.minFieldWidth,
  });

  final double spacing;
  final double runSpacing;
  final double minFieldWidth;

  @override
  _RenderTagFlow createRenderObject(BuildContext context) => _RenderTagFlow(
    spacing: spacing,
    runSpacing: runSpacing,
    minFieldWidth: minFieldWidth,
  );

  @override
  void updateRenderObject(BuildContext context, _RenderTagFlow renderObject) {
    renderObject
      ..spacing = spacing
      ..runSpacing = runSpacing
      ..minFieldWidth = minFieldWidth;
  }
}

class _TagFlowParentData extends ContainerBoxParentData<RenderBox> {}

class _RenderTagFlow extends RenderBox
    with
        ContainerRenderObjectMixin<RenderBox, _TagFlowParentData>,
        RenderBoxContainerDefaultsMixin<RenderBox, _TagFlowParentData> {
  _RenderTagFlow({
    required double spacing,
    required double runSpacing,
    required double minFieldWidth,
  }) : _spacing = spacing,
       _runSpacing = runSpacing,
       _minFieldWidth = minFieldWidth;

  double _spacing;
  set spacing(double value) {
    if (value == _spacing) return;
    _spacing = value;
    markNeedsLayout();
  }

  double _runSpacing;
  set runSpacing(double value) {
    if (value == _runSpacing) return;
    _runSpacing = value;
    markNeedsLayout();
  }

  double _minFieldWidth;
  set minFieldWidth(double value) {
    if (value == _minFieldWidth) return;
    _minFieldWidth = value;
    markNeedsLayout();
  }

  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! _TagFlowParentData) {
      child.parentData = _TagFlowParentData();
    }
  }

  @override
  void performLayout() {
    assert(
      constraints.hasBoundedWidth,
      'The tag row measures the box against the width left over, so it needs '
      'a bounded one to divide up.',
    );
    final width = constraints.maxWidth;
    final children = getChildrenAsList();
    // The box is always the last child; everything before it is a chip.
    final field = children.removeLast();

    // Pass one: the chips, packed into lines at their own widths.
    final lines = <List<RenderBox>>[<RenderBox>[]];
    var lineWidth = 0.0;
    for (final chip in children) {
      chip.layout(BoxConstraints(maxWidth: width), parentUsesSize: true);
      if (lines.last.isNotEmpty &&
          lineWidth + _spacing + chip.size.width > width) {
        lines.add(<RenderBox>[]);
        lineWidth = 0;
      }
      if (lines.last.isNotEmpty) lineWidth += _spacing;
      lines.last.add(chip);
      lineWidth += chip.size.width;
    }

    // Pass two: the box takes the rest of that line, or a line of its own.
    final leading = lines.last.isEmpty ? 0.0 : lineWidth + _spacing;
    final remaining = width - leading;
    if (remaining >= _minFieldWidth) {
      field.layout(
        BoxConstraints(minWidth: remaining, maxWidth: remaining),
        parentUsesSize: true,
      );
      lines.last.add(field);
    } else {
      field.layout(
        BoxConstraints(minWidth: width, maxWidth: width),
        parentUsesSize: true,
      );
      lines.add(<RenderBox>[field]);
    }

    // Pass three: place them, each line's children centred on its tallest —
    // the chips are shorter than the box and would otherwise sit on its top
    // edge.
    var y = 0.0;
    for (final line in lines) {
      var height = 0.0;
      for (final child in line) {
        height = math.max(height, child.size.height);
      }
      var x = 0.0;
      for (final child in line) {
        (child.parentData! as _TagFlowParentData).offset = Offset(
          x,
          y + (height - child.size.height) / 2,
        );
        x += child.size.width + _spacing;
      }
      y += height + _runSpacing;
    }
    size = constraints.constrain(Size(width, y - _runSpacing));
  }

  @override
  void paint(PaintingContext context, Offset offset) =>
      defaultPaint(context, offset);

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) =>
      defaultHitTestChildren(result, position: position);
}

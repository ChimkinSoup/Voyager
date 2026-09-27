import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:voyager/core/theme/voyager_menu_theme.dart';
import 'package:voyager/core/widgets/glass_surface.dart';
import 'package:voyager/core/widgets/voyager_scroll_view.dart';

/// Minimum height of one [SuggestionList] row, before the end padding. Rows
/// grow past it when the text is scaled up.
const double _rowMinHeight = 32;

/// Extra room above the first row and below the last, so the end suggestions
/// don't sit against the popover's edges.
const double _endPadding = 4;

/// The rows of a completion dropdown hung off a text field: one per item, with
/// the highlighted one tinted in [accentColor]. The caller supplies the
/// surface around it — [SuggestionGlassSurface], or a popover of its own.
///
/// Counts as part of the field for taps ([TextFieldTapRegion]). Without that,
/// [TextField]'s default `onTapOutside` unfocuses on pointer-down on desktop,
/// which closes the dropdown before the click's pointer-up can land on a row.
///
/// With [maxHeight] set the rows scroll past it. A highlight moved by the
/// keyboard is scrolled into view, and so is the first row whenever [items]
/// changes; a scroll with the mouse wheel moves the highlight to the row that
/// ends up under the pointer instead.
class SuggestionList<T> extends StatefulWidget {
  const SuggestionList({
    super.key,
    required this.items,
    required this.labelOf,
    required this.selectedIndex,
    required this.accentColor,
    required this.onHighlight,
    required this.onSelect,
    this.dotColorOf,
    this.textStyle,
    this.maxHeight,
  });

  final List<T> items;
  final String Function(T item) labelOf;
  final int selectedIndex;
  final Color accentColor;

  /// The pointer moved onto row `index`.
  final ValueChanged<int> onHighlight;

  /// A row was clicked. Handed the item the row was built from, not an index
  /// into the caller's current list, which may have been refreshed since.
  final ValueChanged<T> onSelect;

  /// A swatch before each label, or null for none. Returning null leaves that
  /// row without one.
  final Color? Function(T item)? dotColorOf;
  final TextStyle? textStyle;
  final double? maxHeight;

  @override
  State<SuggestionList<T>> createState() => _SuggestionListState<T>();
}

class _SuggestionListState<T> extends State<SuggestionList<T>> {
  final _scrollController = ScrollController();
  List<GlobalKey> _rowKeys = const [];

  /// The row the pointer moved onto since the last update, so a highlight
  /// that came from the mouse isn't scrolled away from under it.
  int? _hovered;

  /// Where the last keyboard reveal left the list. A row sliding under a
  /// still pointer takes the highlight — that is how a wheel scroll moves it —
  /// except while the list is still where a reveal put it: that slide came
  /// from the keyboard, and taking the highlight would undo the keypress.
  double? _revealedOffset;

  @override
  void didUpdateWidget(covariant SuggestionList<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.maxHeight != null) {
      // Every refresh hands over a new list, even when it holds the same
      // items, and each one resets the highlight to the top — which a list
      // left scrolled by the wheel would otherwise keep out of sight.
      final refreshed = !identical(widget.items, oldWidget.items);
      final keyboardMove =
          widget.selectedIndex != oldWidget.selectedIndex &&
          widget.selectedIndex != _hovered;
      if (refreshed || keyboardMove) {
        WidgetsBinding.instance.addPostFrameCallback((_) => _reveal());
      }
    }
    // Spent on the update it caused, so a later keyboard move back onto the
    // same row is still revealed.
    _hovered = null;
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  List<GlobalKey> _keysFor(int count) {
    if (_rowKeys.length != count) {
      _rowKeys = [for (var i = 0; i < count; i++) GlobalKey()];
    }
    return _rowKeys;
  }

  void _reveal() {
    if (!mounted || !_scrollController.hasClients) return;
    final index = widget.selectedIndex;
    if (index >= _rowKeys.length) return;
    final row = _rowKeys[index].currentContext?.findRenderObject();
    if (row == null) return;
    final viewport = RenderAbstractViewport.of(row);
    final position = _scrollController.position;
    // The offsets that would put the row at the top of the viewport and at
    // the bottom; anywhere between them it is already fully in view.
    final atTop = viewport.getOffsetToReveal(row, 0).offset;
    final atBottom = viewport.getOffsetToReveal(row, 1).offset;
    final double target;
    if (position.pixels > atTop) {
      target = atTop;
    } else if (position.pixels < atBottom) {
      target = atBottom;
    } else {
      return;
    }
    final clamped = target.clamp(
      position.minScrollExtent,
      position.maxScrollExtent,
    );
    position.jumpTo(clamped);
    _revealedOffset = position.pixels;
  }

  void _pointerMovedOnto(int index) {
    _hovered = index;
    if (index != widget.selectedIndex) widget.onHighlight(index);
  }

  void _rowSlidUnderPointer(int index) {
    if (_scrollController.hasClients &&
        _scrollController.offset == _revealedOffset) {
      return;
    }
    _pointerMovedOnto(index);
  }

  @override
  Widget build(BuildContext context) {
    final items = widget.items;
    final keys = _keysFor(items.length);
    Widget rows = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < items.length; i++)
          _SuggestionRow(
            key: keys[i],
            label: widget.labelOf(items[i]),
            dotColor: widget.dotColorOf?.call(items[i]),
            padding: VoyagerMenuTheme.endRowPadding(
              i,
              items.length,
              horizontal: 10,
              vertical: 0,
              endExtra: _endPadding,
            ),
            selected: i == widget.selectedIndex,
            accentColor: widget.accentColor,
            textStyle: widget.textStyle,
            onEnter: () => _rowSlidUnderPointer(i),
            onHover: () => _pointerMovedOnto(i),
            onTap: () => widget.onSelect(items[i]),
          ),
      ],
    );
    final maxHeight = widget.maxHeight;
    if (maxHeight != null) {
      rows = ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxHeight),
        child: VoyagerScrollView(controller: _scrollController, child: rows),
      );
    }
    return TextFieldTapRegion(child: rows);
  }
}

/// The glass card the text-field dropdowns ([SuggestionList]) that don't sit
/// in a [ContextualPopover] are drawn on.
class SuggestionGlassSurface extends StatelessWidget {
  const SuggestionGlassSurface({super.key, required this.child});

  final Widget child;

  static const _radius = BorderRadius.all(Radius.circular(10));

  @override
  Widget build(BuildContext context) {
    return GlassSurface(
      borderRadius: _radius,
      child: Material(
        type: MaterialType.transparency,
        borderRadius: _radius,
        clipBehavior: Clip.antiAlias,
        child: child,
      ),
    );
  }
}

class _SuggestionRow extends StatelessWidget {
  const _SuggestionRow({
    super.key,
    required this.label,
    required this.dotColor,
    required this.padding,
    required this.selected,
    required this.accentColor,
    required this.textStyle,
    required this.onEnter,
    required this.onHover,
    required this.onTap,
  });

  final String label;
  final Color? dotColor;
  final EdgeInsets padding;
  final bool selected;
  final Color accentColor;
  final TextStyle? textStyle;

  /// The row arrived under the pointer — by the pointer moving, or by the
  /// rows moving under a still one.
  final VoidCallback onEnter;

  /// The pointer moved within the row.
  final VoidCallback onHover;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final dot = dotColor;
    return MouseRegion(
      onEnter: (_) => onEnter(),
      onHover: (_) => onHover(),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: Container(
          constraints: BoxConstraints(
            minHeight: _rowMinHeight + padding.vertical,
          ),
          alignment: Alignment.centerLeft,
          padding: padding,
          color: selected
              ? accentColor.withValues(alpha: 0.16)
              : Colors.transparent,
          child: Row(
            children: [
              if (dot != null) ...[
                Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(color: dot, shape: BoxShape.circle),
                ),
                const SizedBox(width: 8),
              ],
              Expanded(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: textStyle,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

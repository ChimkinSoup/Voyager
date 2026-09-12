import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:voyager/core/widgets/ctrl_enter_to_submit_scope.dart';
import 'package:voyager/core/widgets/glass_surface.dart';
import 'package:voyager/core/widgets/voyager_scroll_view.dart';
import 'package:voyager/core/widgets/voyager_text_field.dart';
import 'package:voyager/domain/services/finance_origins.dart';

/// How many suggestions the list shows at once.
const _maxSuggestions = 8;

/// The transaction sheet's Store / Source combobox: free text plus a typeahead
/// over the origins already on the ledger.
///
/// The same keyboard and pointer contract as `JobsCompanyField` — the list
/// opens on focus with the most recently used origins, arrows move the
/// highlight, Enter or Tab fills the field, a click fills it, Escape closes
/// the list — but built on [VoyagerTextField] so it matches the sheet's other
/// fields. Nothing typed is ever refused: the list is there to find an origin
/// already in use, not to limit what can be entered.
class FinanceOriginField extends StatefulWidget {
  const FinanceOriginField({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.origins,
    required this.label,
    this.hintText,
    this.accentColor,
    this.onSubmitted,
  });

  final TextEditingController controller;

  /// Owned by the caller so it can move focus here. This field installs its
  /// own [FocusNode.onKeyEvent] on it — the list has to see Enter and the
  /// arrows before the text field does.
  final FocusNode focusNode;

  /// From [recentTransactionOrigins], most recent first.
  final List<String> origins;

  final String label;
  final String? hintText;
  final Color? accentColor;

  /// Fired on Enter, but only when the list is closed — with it open, Enter
  /// belongs to the highlighted suggestion. So the first Enter fills the field
  /// and the second moves on.
  final ValueChanged<String>? onSubmitted;

  @override
  State<FinanceOriginField> createState() => _FinanceOriginFieldState();
}

class _FinanceOriginFieldState extends State<FinanceOriginField> {
  final _layerLink = LayerLink();
  final _fieldKey = GlobalKey();
  OverlayEntry? _overlay;
  List<String> _matches = const [];
  int _selected = 0;

  @override
  void initState() {
    super.initState();
    _attach(widget.focusNode);
  }

  @override
  void didUpdateWidget(FinanceOriginField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.focusNode != widget.focusNode) {
      _detach(oldWidget.focusNode);
      _attach(widget.focusNode);
    }
    // The sheet switched between Store and Source: the list was for the other
    // vocabulary, so it closes rather than re-offering under the new label.
    if (oldWidget.label != widget.label) {
      _removeOverlay();
    } else if (_overlay != null &&
        !listEquals(oldWidget.origins, widget.origins)) {
      // The ledger changed underneath an open list. Refreshed after the frame,
      // not here: this runs during build, and the refresh rebuilds or inserts
      // the overlay. Only an open list is refreshed: one the user closed with
      // Escape stays closed.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _overlay != null) _refreshMatches();
      });
    }
  }

  void _attach(FocusNode node) {
    node.addListener(_handleFocusChanged);
    node.onKeyEvent = _handleKeyEvent;
  }

  void _detach(FocusNode node) {
    node.removeListener(_handleFocusChanged);
    // Only our own handler: a replacement field may already have installed
    // its handler on a node the two share.
    if (node.onKeyEvent == _handleKeyEvent) node.onKeyEvent = null;
  }

  @override
  void dispose() {
    _removeOverlay();
    _detach(widget.focusNode);
    super.dispose();
  }

  void _handleFocusChanged() {
    if (widget.focusNode.hasFocus) {
      _refreshMatches();
    } else {
      // One frame of grace: tapping a suggestion moves focus out of the field
      // before the tap resolves, and removing the list synchronously would
      // cancel the very tap that is choosing an origin.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && !widget.focusNode.hasFocus) _removeOverlay();
      });
    }
  }

  void _refreshMatches() {
    final text = widget.controller.text;
    final matches = filterTransactionOrigins(widget.origins, text);
    // Exact, case and all: `walmart` typed still offers `Walmart`, since
    // picking it is how the two stay one origin.
    final exhausted = matches.length == 1 && matches.first == text.trim();
    _matches = exhausted ? const [] : matches.take(_maxSuggestions).toList();
    _selected = 0;
    if (_matches.isEmpty) {
      _removeOverlay();
    } else if (_overlay == null) {
      _showOverlay();
    } else {
      _overlay!.markNeedsBuild();
    }
  }

  void _showOverlay() {
    final overlayState = Overlay.maybeOf(context);
    if (overlayState == null) return;
    final box = _fieldKey.currentContext?.findRenderObject() as RenderBox?;
    final width = box?.size.width ?? 240;
    final accent = widget.accentColor ?? Theme.of(context).colorScheme.primary;
    _overlay = OverlayEntry(
      builder: (context) => Positioned(
        width: width,
        child: CompositedTransformFollower(
          link: _layerLink,
          targetAnchor: Alignment.bottomLeft,
          followerAnchor: Alignment.topLeft,
          offset: const Offset(0, 4),
          // Same tap group as the field's [EditableText], so a click on a
          // suggestion isn't a tap outside the field — which unfocuses on
          // pointer-down and would tear the list away before the click lands.
          child: TapRegion(
            groupId: EditableText,
            child: _SuggestionList(
              matches: _matches,
              selectedIndex: _selected,
              accentColor: accent,
              onHover: _highlight,
              onSelected: _select,
            ),
          ),
        ),
      ),
    );
    overlayState.insert(_overlay!);
  }

  void _removeOverlay() {
    _overlay?.remove();
    _overlay = null;
  }

  bool get _isOpen => _overlay != null && _matches.isNotEmpty;

  void _highlight(int index) {
    if (_selected == index) return;
    _selected = index;
    _overlay?.markNeedsBuild();
  }

  void _move(int delta) {
    _highlight((_selected + delta + _matches.length) % _matches.length);
  }

  void _select(String origin) {
    widget.controller.value = TextEditingValue(
      text: origin,
      selection: TextSelection.collapsed(offset: origin.length),
    );
    _removeOverlay();
  }

  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    if (!_isOpen || event is! KeyDownEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.arrowDown) {
      _move(1);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowUp) {
      _move(-1);
      return KeyEventResult.handled;
    }
    // Ctrl/Cmd+Enter bubbles on to the sheet's submit scope with the origin
    // as typed, the same as it does past the tag popup.
    if ((key == LogicalKeyboardKey.enter ||
            key == LogicalKeyboardKey.numpadEnter ||
            key == LogicalKeyboardKey.tab) &&
        !isSubmitChord(event)) {
      _select(_matches[_selected]);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.escape) {
      // Claimed: with the list up, Escape means "close this", not "close the
      // sheet".
      _removeOverlay();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    return CompositedTransformTarget(
      link: _layerLink,
      child: VoyagerTextField(
        key: _fieldKey,
        controller: widget.controller,
        focusNode: widget.focusNode,
        accentColor: widget.accentColor,
        decoration: InputDecoration(
          labelText: widget.label,
          hintText: widget.hintText,
        ),
        onSubmitted: widget.onSubmitted,
        onChanged: (_) => _refreshMatches(),
      ),
    );
  }
}

class _SuggestionList extends StatelessWidget {
  const _SuggestionList({
    required this.matches,
    required this.selectedIndex,
    required this.accentColor,
    required this.onHover,
    required this.onSelected,
  });

  final List<String> matches;
  final int selectedIndex;
  final Color accentColor;
  final ValueChanged<int> onHover;
  final ValueChanged<String> onSelected;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return GlassSurface(
      borderRadius: BorderRadius.circular(10),
      child: Material(
        type: MaterialType.transparency,
        borderRadius: BorderRadius.circular(10),
        clipBehavior: Clip.antiAlias,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 220),
          child: VoyagerScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (var i = 0; i < matches.length; i++)
                  MouseRegion(
                    onEnter: (_) => onHover(i),
                    cursor: SystemMouseCursors.click,
                    child: GestureDetector(
                      onTap: () => onSelected(matches[i]),
                      behavior: HitTestBehavior.opaque,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 8,
                        ),
                        color: i == selectedIndex
                            ? accentColor.withValues(alpha: 0.16)
                            : Colors.transparent,
                        child: Text(
                          matches[i],
                          style: theme.textTheme.bodySmall,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

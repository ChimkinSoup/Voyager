import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/motion/motion_prefs.dart';
import 'package:voyager/core/tags/tag_suggestions.dart';
import 'package:voyager/core/utils/journal_tags.dart';
import 'package:voyager/core/widgets/contextual_popover.dart';
import 'package:voyager/core/widgets/spell_check_field_support.dart';

/// Wraps a text field so typing `#` opens a completion list of tags already
/// used on [scope]'s own page, most-used first.
///
/// The popup is anchored at the `#` rather than under the field: in a
/// full-height prose body (journal, dreams) "under the field" is nowhere near
/// where you're typing. Anchoring at the token's *start* also means the popup
/// holds still while you type the rest of the tag instead of chasing the
/// caret one character at a time.
class TagSuggestionPortal extends ConsumerStatefulWidget {
  const TagSuggestionPortal({
    super.key,
    required this.scope,
    required this.controller,
    required this.focusNode,
    required this.fieldKey,
    required this.child,
    this.accentColor,
    this.enabled = true,
    this.escapeAlsoBubbles = false,
    this.onChanged,
    this.onKeyEvent,
  });

  final TagScope scope;
  final TextEditingController controller;
  final FocusNode focusNode;
  final GlobalKey<State<TextField>> fieldKey;
  final Widget child;
  final Color? accentColor;

  /// Whether the popup may open at all. Fields with Vim enabled pass
  /// `VimFieldBinding.completionsAllowed`, which is false in Normal and Visual
  /// mode: a motion that lands on a tag there is navigation, not an edit.
  /// Clearing this while the popup is up closes it.
  final bool enabled;

  /// Whether Escape should carry on to the rest of the focus chain after
  /// dismissing the popup. Fields with Vim enabled pass
  /// `VimFieldBinding.escapeLeavesInsert`, because `<Esc>` on an open popup
  /// menu means both "close this" and "leave Insert mode".
  ///
  /// Off by default: with nothing else waiting for Escape, bubbling it would
  /// close the dialog the field sits in as a side effect of dismissing a
  /// completion list.
  final bool escapeAlsoBubbles;

  /// The host field's `onChanged`, invoked only on the fallback insertion
  /// path (see [_TagSuggestionPortalState._accept]).
  final ValueChanged<String>? onChanged;

  /// The caller's own key handler, run for every key this widget doesn't
  /// claim. This widget owns [FocusNode.onKeyEvent] for the field's node —
  /// callers that would otherwise assign it directly must route through here
  /// instead, or one of the two assignments silently wins.
  final FocusOnKeyEventCallback? onKeyEvent;

  @override
  ConsumerState<TagSuggestionPortal> createState() =>
      _TagSuggestionPortalState();
}

class _TagSuggestionPortalState extends ConsumerState<TagSuggestionPortal> {
  static const double _width = 200;
  static const double _itemHeight = 32;
  static const double _verticalPadding = 0;
  static const double _caretGap = 4;
  static const double _screenMargin = 8;

  final OverlayPortalController _portal = OverlayPortalController();

  ActiveTagToken? _token;
  List<String> _suggestions = const [];
  int _selected = 0;

  /// Where to hang the popup: the caret slot at the token's `#`, plus the box
  /// it has to stay inside. Both in the enclosing [Overlay]'s coordinate
  /// space, which is what [Positioned] measures against — and which is *not*
  /// the screen: each go_router branch has its own Navigator, so this app's
  /// overlay starts to the right of the shell's navigation rail. Null before
  /// the first post-frame measurement.
  ({Rect caret, Size bounds})? _anchor;
  bool _measureScheduled = false;

  /// The value the last completion pass ran against, so the controller's
  /// selection- and composing-only notifications don't redo it.
  TextEditingValue? _lastValue;

  /// Start offset of a token whose popup the user closed (Escape, or by
  /// accepting a suggestion). Cleared once the caret reaches a different
  /// token, so closing one completion doesn't disable the feature.
  int? _closedTokenStart;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_handleEditingChanged);
    widget.focusNode.addListener(_handleFocusChanged);
    widget.focusNode.onKeyEvent = _handleKeyEvent;
  }

  @override
  void didUpdateWidget(covariant TagSuggestionPortal oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_handleEditingChanged);
      widget.controller.addListener(_handleEditingChanged);
    }
    if (oldWidget.focusNode != widget.focusNode) {
      oldWidget.focusNode.removeListener(_handleFocusChanged);
      oldWidget.focusNode.onKeyEvent = null;
      widget.focusNode.addListener(_handleFocusChanged);
      widget.focusNode.onKeyEvent = _handleKeyEvent;
    }
    if (oldWidget.enabled && !widget.enabled) {
      // Escape already closes the popup on its way to the Vim layer (see
      // [escapeAlsoBubbles]), but `<C-[>` leaves Insert without passing
      // through this widget's key handler at all — so the popup can still be
      // up here. Deferred because closing marks the [OverlayPortal] below
      // dirty, and this runs while the subtree is being rebuilt.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && !widget.enabled) _close();
      });
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_handleEditingChanged);
    widget.focusNode.removeListener(_handleFocusChanged);
    widget.focusNode.onKeyEvent = null;
    super.dispose();
  }

  void _handleFocusChanged() {
    if (!widget.focusNode.hasFocus) _close();
  }

  void _handleEditingChanged() {
    if (!mounted) return;
    // Vim's Normal and Visual modes move the caret constantly; none of that is
    // a request to complete anything.
    if (!widget.enabled) {
      _close();
      return;
    }

    final value = widget.controller.value;
    // A controller also notifies for composing-region churn and for repeated
    // selection writes that land on the same offset; neither can change what
    // the popup shows.
    if (value.text == _lastValue?.text &&
        value.selection == _lastValue?.selection) {
      return;
    }
    _lastValue = value;

    final selection = value.selection;
    // A range selection has no single insertion point to complete at.
    if (!selection.isValid || !selection.isCollapsed) {
      _close();
      return;
    }

    final token = activeTagToken(value.text, selection.baseOffset);
    if (token == null) {
      _closedTokenStart = null;
      _close();
      return;
    }
    if (_closedTokenStart != null && _closedTokenStart != token.start) {
      _closedTokenStart = null;
    }
    if (_closedTokenStart == token.start) {
      _close();
      return;
    }

    final pool = ref.read(tagPoolProvider(widget.scope)).valueOrNull;
    if (pool == null || pool.isEmpty) {
      _close();
      return;
    }

    final suggestions = filterTagSuggestions(pool, token.query);
    if (suggestions.isEmpty) {
      _close();
      return;
    }

    // Only _suggestions and _selected are read while building the popup, so
    // the token itself is assigned outside setState. It advances on every
    // keystroke (its end tracks the caret) while the list under it usually
    // doesn't — treating it as visual state would repaint the popup, and
    // re-run its backdrop blur, for every character of a tag.
    final movedToken = _token?.start != token.start;
    _token = token;

    // Keep the highlighted row put while the list narrows under the same
    // token; start from the top whenever the caret moves to a different tag.
    final selected =
        movedToken ? 0 : _selected.clamp(0, suggestions.length - 1);
    if (selected != _selected || !listEquals(_suggestions, suggestions)) {
      setState(() {
        _suggestions = suggestions;
        _selected = selected;
      });
    }
    _scheduleMeasure();
  }

  /// Reads the caret geometry a frame later, once the edit that triggered this
  /// has actually been laid out — [RenderEditable] is still sized to the
  /// previous text during the controller notification itself.
  void _scheduleMeasure() {
    if (_measureScheduled) return;
    _measureScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _measureScheduled = false;
      if (!mounted) return;
      if (_token == null || _suggestions.isEmpty) return;

      final anchor = _measureAnchor();
      if (anchor == null) {
        _close();
        return;
      }
      if (anchor != _anchor) setState(() => _anchor = anchor);
      if (!_portal.isShowing) _portal.show();
    });
  }

  /// Measures the caret slot at the token's `#` in the enclosing [Overlay]'s
  /// coordinate space — the space the popup is later [Positioned] in.
  ///
  /// Passing the overlay as `ancestor` rather than converting from global
  /// coordinates is what keeps the popup on the `#`: this app nests a
  /// Navigator (and so an Overlay) per go_router branch, inset from the screen
  /// by the shell's navigation rail. Same conversion `showContextualPopoverAt`
  /// makes for the app's other anchored popovers.
  ({Rect caret, Size bounds})? _measureAnchor() {
    final token = _token;
    if (token == null) return null;
    final editable = editableTextStateOf(widget.fieldKey);
    if (editable == null) return null;

    final renderEditable = editable.renderEditable;
    if (!renderEditable.hasSize) return null;
    if (token.start > renderEditable.plainText.length) return null;

    final overlayBox =
        Overlay.maybeOf(context)?.context.findRenderObject() as RenderBox?;
    if (overlayBox == null || !overlayBox.hasSize) return null;

    final local = renderEditable.getLocalRectForCaret(
      TextPosition(offset: token.start),
    );
    final origin = renderEditable.localToGlobal(
      local.topLeft,
      ancestor: overlayBox,
    );
    return (caret: origin & local.size, bounds: overlayBox.size);
  }

  void _close() {
    if (_portal.isShowing) _portal.hide();
    if (!mounted || (_token == null && _suggestions.isEmpty)) return;
    setState(() {
      _token = null;
      _suggestions = const [];
      _selected = 0;
    });
  }

  bool get _isOpen => _portal.isShowing && _suggestions.isNotEmpty;

  void _move(int delta) {
    setState(() {
      _selected = (_selected + delta + _suggestions.length) %
          _suggestions.length;
    });
  }

  void _accept(String tag) {
    final token = _token;
    if (token == null) return;

    final text = widget.controller.text;
    // The token was computed against the text as of the last keystroke; bail
    // rather than corrupt the body if it has shifted underneath us (a remote
    // CRDT merge landing mid-edit, say).
    if (token.end > text.length) {
      _close();
      return;
    }

    final replacement = '#$tag';
    final newValue = TextEditingValue(
      text: text.replaceRange(token.start, token.end, replacement),
      selection: TextSelection.collapsed(
        offset: token.start + replacement.length,
      ),
    );

    // Applying the edit re-enters _handleEditingChanged with the caret still
    // inside the (now complete) tag. Marking it closed first stops the popup
    // from immediately reopening on longer tags that share this prefix.
    _closedTokenStart = token.start;

    final editable = editableTextStateOf(widget.fieldKey);
    if (editable != null) {
      // The same path SpellCheckPopup uses. A direct `controller.value =`
      // write would skip the field's onChanged, which the journal and dream
      // bodies rely on to mark the entry dirty and to feed
      // `recordJournalTextChange` — that CRDT session assumes it sees every
      // edit, so a silent write desyncs the next real diff.
      editable.userUpdateTextEditingValue(
        newValue,
        SelectionChangedCause.keyboard,
      );
    } else {
      widget.controller.value = newValue;
      widget.onChanged?.call(newValue.text);
    }
    _close();
  }

  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    if (_isOpen && event is KeyDownEvent) {
      final key = event.logicalKey;
      if (key == LogicalKeyboardKey.arrowDown) {
        _move(1);
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.arrowUp) {
        _move(-1);
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.enter ||
          key == LogicalKeyboardKey.numpadEnter ||
          key == LogicalKeyboardKey.tab) {
        _accept(_suggestions[_selected]);
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.escape) {
        _closedTokenStart = _token?.start;
        _close();
        // Falling through hands the same press to the Vim layer above, which
        // reads it as "leave Insert" — matching Vim, where one <Esc> both
        // dismisses the popup menu and ends the insert.
        if (!widget.escapeAlsoBubbles) return KeyEventResult.handled;
      }
    }
    return widget.onKeyEvent?.call(node, event) ?? KeyEventResult.ignored;
  }

  /// Sits the popup under the caret, flipping above the current line when the
  /// bottom edge is closer than the list is tall.
  Offset _position(Rect caret, Size bounds, double height) {
    final below = caret.bottom + _caretGap;
    final top = below + height <= bounds.height - _screenMargin
        ? below
        : caret.top - _caretGap - height;
    final maxLeft = bounds.width - _width - _screenMargin;
    return Offset(
      maxLeft <= _screenMargin
          ? _screenMargin
          : caret.left.clamp(_screenMargin, maxLeft),
      top.clamp(_screenMargin, bounds.height - _screenMargin),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Watched (not read) so the pool stays warm and an open list refreshes
    // when a tag is added elsewhere on the page.
    ref.watch(tagPoolProvider(widget.scope));
    final tagColors = ref.watch(tagColorsProvider).valueOrNull ?? const {};
    final theme = Theme.of(context);
    final accent = widget.accentColor ?? theme.colorScheme.primary;

    return OverlayPortal(
      controller: _portal,
      overlayChildBuilder: (overlayContext) {
        final anchor = _anchor;
        if (anchor == null || _suggestions.isEmpty) {
          return const SizedBox.shrink();
        }

        final height = _suggestions.length * _itemHeight + _verticalPadding * 2;
        final origin = _position(anchor.caret, anchor.bounds, height);

        return Positioned(
          left: origin.dx,
          top: origin.dy,
          child: _SuggestionList(
            suggestions: _suggestions,
            selectedIndex: _selected,
            accentColor: accent,
            tagColors: tagColors,
            textStyle: theme.textTheme.bodyMedium,
            width: _width,
            height: height,
            itemHeight: _itemHeight,
            verticalPadding: _verticalPadding,
            onHover: (index) => setState(() => _selected = index),
            onTap: _accept,
          ),
        );
      },
      child: widget.child,
    );
  }
}

class _SuggestionList extends StatelessWidget {
  const _SuggestionList({
    required this.suggestions,
    required this.selectedIndex,
    required this.accentColor,
    required this.tagColors,
    required this.textStyle,
    required this.width,
    required this.height,
    required this.itemHeight,
    required this.verticalPadding,
    required this.onHover,
    required this.onTap,
  });

  final List<String> suggestions;
  final int selectedIndex;
  final Color accentColor;
  final Map<String, int> tagColors;
  final TextStyle? textStyle;
  final double width;
  final double height;
  final double itemHeight;
  final double verticalPadding;
  final ValueChanged<int> onHover;
  final ValueChanged<String> onTap;

  @override
  Widget build(BuildContext context) {
    final reduced = VoyagerMotion.reduced(context);

    final list = ContextualPopover(
      width: width,
      height: height,
      accentColor: accentColor,
      child: Padding(
        padding: EdgeInsets.symmetric(vertical: verticalPadding),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var i = 0; i < suggestions.length; i++)
              _SuggestionRow(
                tag: suggestions[i],
                height: itemHeight,
                selected: i == selectedIndex,
                accentColor: accentColor,
                color: Color(
                  tagColors[suggestions[i]] ?? colorForTag(suggestions[i]),
                ),
                textStyle: textStyle,
                onHover: () => onHover(i),
                onTap: () => onTap(suggestions[i]),
              ),
          ],
        ),
      ),
    );

    // Entrance only — the popup is torn down on close, so there is nothing to
    // animate out. Reduced motion keeps the fade and drops the scale.
    return TweenAnimationBuilder<double>(
      key: const ValueKey('tag-suggestions-entrance'),
      tween: Tween(begin: 0, end: 1),
      duration: VoyagerMotion.crossfade,
      curve: Curves.easeOutCubic,
      builder: (context, t, child) => Opacity(
        opacity: t,
        child: reduced
            ? child
            : Transform.scale(
                scale: 0.96 + 0.04 * t,
                alignment: Alignment.topLeft,
                child: child,
              ),
      ),
      child: list,
    );
  }
}

class _SuggestionRow extends StatelessWidget {
  const _SuggestionRow({
    required this.tag,
    required this.height,
    required this.selected,
    required this.accentColor,
    required this.color,
    required this.textStyle,
    required this.onHover,
    required this.onTap,
  });

  final String tag;
  final double height;
  final bool selected;
  final Color accentColor;
  final Color color;
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
          color: selected
              ? accentColor.withValues(alpha: 0.16)
              : Colors.transparent,
          child: Row(
            children: [
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.85),
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '#$tag',
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

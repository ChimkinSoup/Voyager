import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/widgets/context_menu.dart';
import 'package:voyager/core/widgets/spell_check_field_support.dart';

/// Right-click/long-press popup shown over a misspelled word: lists
/// suggested corrections (tap to replace) plus an "Add to dictionary"
/// action. Styled to match [ContextMenuPanel], the app's existing
/// right-click menu look.
class SpellCheckPopup extends ConsumerStatefulWidget {
  const SpellCheckPopup({
    super.key,
    required this.editableTextState,
    required this.span,
  });

  final EditableTextState editableTextState;
  final SuggestionSpan span;

  @override
  ConsumerState<SpellCheckPopup> createState() => _SpellCheckPopupState();
}

class _SpellCheckPopupState extends ConsumerState<SpellCheckPopup> {
  final GlobalKey _panelKey = GlobalKey();
  int? _hoveredIndex;

  static const double _radius = 12.0;
  static const double _verticalPadding = 6.0;
  static const double _minWidth = 190.0;

  BorderRadius _itemRadius(int index, int count) {
    if (count == 1) return BorderRadius.circular(_radius);
    if (index == 0) {
      return const BorderRadius.vertical(top: Radius.circular(_radius));
    }
    if (index == count - 1) {
      return const BorderRadius.vertical(bottom: Radius.circular(_radius));
    }
    return BorderRadius.zero;
  }

  void _applySuggestion(String replacement) {
    // Goes through userUpdateTextEditingValue rather than writing
    // controller.value directly — the same call Flutter's own built-in
    // spellcheck toolbar makes (MaterialSpellCheckSuggestionsToolbar
    // ._replaceText in spell_check_suggestions_toolbar.dart). A direct
    // controller.value= write bypasses EditableText's normal edit pipeline
    // (_formatAndSetValue): it never runs a fresh spellcheck pass (so the
    // corrected word's squiggle stayed stale until the next keystroke),
    // never fires onChanged (so the correction didn't mark the entry dirty
    // for autosave), and left UndoHistory's internal bookkeeping out of
    // sync with how it expects edits to arrive — surfacing as a
    // 'widget.value.value == nextValue' assertion in undo_history.dart on a
    // later undo. See project_flutter_spellcheck_freeze memory, bug 6.
    final newValue = widget.editableTextState.textEditingValue.replaced(
      widget.span.range,
      replacement,
    );
    widget.editableTextState.userUpdateTextEditingValue(
      newValue,
      SelectionChangedCause.toolbar,
    );
    widget.editableTextState.hideToolbar();
  }

  Future<void> _addToDictionary() async {
    final range = widget.span.range;
    final word = widget.editableTextState.widget.controller.text
        .substring(range.start, range.end)
        .toLowerCase();
    await ref.read(settingsRepositoryProvider).addCustomWord(word);
    ref.invalidate(customWordsProvider);
    await ref.read(customWordsProvider.future);
    if (mounted) {
      paintSpellCheckResultsNow(context, widget.editableTextState);
    }
    widget.editableTextState.hideToolbar();
  }

  @override
  Widget build(BuildContext context) {
    final anchor = widget.editableTextState.contextMenuAnchors.primaryAnchor;
    final items = <ContextMenuItem>[
      for (final suggestion in widget.span.suggestions)
        ContextMenuItem(label: suggestion, onTap: () => _applySuggestion(suggestion)),
      ContextMenuItem(
        label: 'Add to dictionary',
        icon: PhosphorIconsRegular.plusCircle,
        onTap: _addToDictionary,
      ),
    ];

    return CustomSingleChildLayout(
      delegate: _SpellCheckPopupLayoutDelegate(
        anchor: anchor,
        minWidth: _minWidth,
      ),
      child: ContextMenuPanel(
        panelKey: _panelKey,
        items: items,
        radius: _radius,
        verticalPadding: _verticalPadding,
        minWidth: _minWidth,
        itemRadius: _itemRadius,
        isHovered: (i) => _hoveredIndex == i,
        onHover: (i, hovering) => setState(() {
          if (hovering) {
            _hoveredIndex = i;
          } else if (_hoveredIndex == i) {
            _hoveredIndex = null;
          }
        }),
        onTap: (item) => item.onTap?.call(),
      ),
    );
  }
}

class _SpellCheckPopupLayoutDelegate extends SingleChildLayoutDelegate {
  _SpellCheckPopupLayoutDelegate({required this.anchor, required this.minWidth});

  final Offset anchor;
  final double minWidth;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) {
    return BoxConstraints(
      minWidth: minWidth,
      maxWidth: math.min(280.0, constraints.maxWidth - 16),
      minHeight: 0,
      maxHeight: constraints.maxHeight * 0.85,
    );
  }

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    const margin = 8.0;
    double x = anchor.dx;
    double y = anchor.dy;

    if (x + childSize.width > size.width - margin) {
      x = anchor.dx - childSize.width;
    }
    x = x.clamp(margin, size.width - childSize.width - margin);

    if (y + childSize.height > size.height - margin) {
      y = anchor.dy - childSize.height;
    }
    y = y.clamp(margin, size.height - childSize.height - margin);

    return Offset(x, y);
  }

  @override
  bool shouldRelayout(_SpellCheckPopupLayoutDelegate oldDelegate) =>
      anchor != oldDelegate.anchor;
}

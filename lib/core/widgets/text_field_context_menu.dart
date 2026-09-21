import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/spellcheck/autocorrect_session.dart';
import 'package:voyager/core/widgets/context_menu.dart';
import 'package:voyager/core/widgets/flag_word_popover.dart';
import 'package:voyager/core/widgets/quick_add_snippet.dart';
import 'package:voyager/core/widgets/spell_check_field_support.dart';

/// Right-click/long-press menu for a Voyager text field.
///
/// Carries three independent groups, any of which can be absent:
///
///  * over a misspelled word ([span]), the suggested corrections (tap to
///    replace) followed by "Add to dictionary" — or, when that word is one the
///    user flagged, the stored replacement pinned first and "Stop flagging"
///    (`FLAGGED_WORDS.md` §8);
///  * over a word the checker *accepts* ([flaggableWord]), "Flag as
///    misspelling…", which opens the flag popover;
///  * "Add snippet" ([snippetTrigger]), always last, which opens the
///    quick-add popover on the clicked word or the current selection.
///
/// Styled to match [ContextMenuPanel], the app's existing right-click menu
/// look. Built by [voyagerTextContextMenuBuilder], which is also where the
/// decision to show nothing at all is made.
class TextFieldContextMenu extends ConsumerStatefulWidget {
  const TextFieldContextMenu({
    super.key,
    required this.editableTextState,
    required this.span,
    required this.snippetTrigger,
    this.flaggableWord,
    this.spellcheckAllowed = false,
    this.autocorrectSession,
  }) : assert(
         span != null || snippetTrigger != null || flaggableWord != null,
         'An empty menu should not be built at all — see '
         'voyagerTextContextMenuBuilder.',
       );

  final EditableTextState editableTextState;

  /// The misspelling under the cursor, hydrated with suggestions. Null when
  /// the word is spelled correctly (or the field is not spellchecked). A
  /// flagged word arrives here too — the checker has subtracted it from the
  /// known set, so it is a misspelling like any other.
  final SuggestionSpan? span;

  /// The accepted word under the cursor, for "Flag as misspelling…". Null
  /// unless the field is spellchecked and the cursor is on a single known
  /// word.
  final ({TextRange range, String word})? flaggableWord;

  /// Whether this field shows squiggles at all. Gates the flag items only:
  /// suggestions and "Add to dictionary" are offered as they always were
  /// (`FLAGGED_WORDS.md` §8).
  final bool spellcheckAllowed;

  /// The field's live autocorrect runtime, so "Replace this one" can go
  /// through the apply path that flashes (§5.4).
  final AutocorrectSession? autocorrectSession;

  /// The text "Add snippet" would prefill as the trigger. Null when the item
  /// should not be offered — snippets switched off, a field that opts out, or
  /// nothing usable under the pointer.
  final String? snippetTrigger;

  @override
  ConsumerState<TextFieldContextMenu> createState() =>
      _TextFieldContextMenuState();
}

class _TextFieldContextMenuState extends ConsumerState<TextFieldContextMenu> {
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
      widget.span!.range,
      replacement,
    );
    widget.editableTextState.userUpdateTextEditingValue(
      newValue,
      SelectionChangedCause.toolbar,
    );
    widget.editableTextState.hideToolbar();
  }

  /// The flagged word under the cursor, lowercased, or null.
  String? get _flaggedWord {
    final range = widget.span?.range;
    if (range == null) return null;
    final word = widget.editableTextState.widget.controller.text
        .substring(range.start, range.end)
        .toLowerCase();
    return ref.read(voyagerSpellCheckServiceProvider).isFlagged(word)
        ? word
        : null;
  }

  /// Allow wins (`FLAGGED_WORDS.md` §4): whichever label the item carries,
  /// the flag and its replacement go, and a word the bundled list already has
  /// stops there rather than gaining a redundant custom row.
  Future<void> _addToDictionary() async {
    final range = widget.span!.range;
    final word = widget.editableTextState.widget.controller.text
        .substring(range.start, range.end)
        .toLowerCase();
    final repo = ref.read(settingsRepositoryProvider);
    final wasFlagged = _flaggedWord != null;
    if (wasFlagged) await repo.unflagWord(word);
    final bundled =
        ref.read(dictionaryProvider).valueOrNull ?? const <String>{};
    if (!bundled.contains(word)) await repo.addCustomWord(word);
    ref.invalidate(customWordsProvider);
    if (wasFlagged) ref.invalidate(flaggedWordsProvider);
    await ref.read(customWordsProvider.future);
    if (wasFlagged) await ref.read(flaggedWordsProvider.future);
    // No repaint call here: the squiggles are SpellCheckSquiggleLayer's, and
    // it wakes itself on VoyagerSpellCheckService.knownWordsChanged.
    widget.editableTextState.hideToolbar();
  }

  /// Opens the flag popover against the *field's* context, for the same
  /// reason [_addSnippet] does: this toolbar is gone by the time the popover
  /// and its toast need somewhere to live.
  void _flagWord() {
    final found = widget.flaggableWord!;
    final state = widget.editableTextState;
    final anchor = state.contextMenuAnchors.primaryAnchor;
    state.hideToolbar();
    showFlagWordPopover(
      context: state.context,
      anchor: anchor,
      word: found.word,
      range: found.range,
      session: widget.autocorrectSession,
      restoreFocus: state.widget.focusNode,
    );
  }

  /// Opens the quick-add popover against the *field's* context, not this
  /// menu's: the toolbar is torn down by [hideToolbar] on the way out, and
  /// the popover route, its toast and the settings dialog all outlive it.
  void _addSnippet() {
    final state = widget.editableTextState;
    final anchor = state.contextMenuAnchors.primaryAnchor;
    state.hideToolbar();
    showQuickAddSnippet(
      context: state.context,
      anchor: anchor,
      trigger: widget.snippetTrigger!,
      restoreFocus: state.widget.focusNode,
    );
  }

  /// The corrections to offer, with a flagged word's stored replacement
  /// pinned first and not repeated below it (`FLAGGED_WORDS.md` §6).
  List<String> _suggestionsFor(SuggestionSpan span, String? flagged) {
    if (flagged == null) return span.suggestions;
    final pair = ref
        .read(voyagerSpellCheckServiceProvider)
        .replacementFor(flagged);
    if (pair == null) return span.suggestions;
    return [pair, ...span.suggestions.where((s) => s != pair)];
  }

  @override
  Widget build(BuildContext context) {
    final anchor = widget.editableTextState.contextMenuAnchors.primaryAnchor;
    final span = widget.span;
    final flagged = span == null ? null : _flaggedWord;
    // "Stop flagging" is the same clear as "Add to dictionary", but it is the
    // only sentence that is true of a word the bundled list already has (§6).
    final showStopFlagging = widget.spellcheckAllowed && flagged != null;
    final items = <ContextMenuItem>[
      if (span != null) ...[
        for (final suggestion in _suggestionsFor(span, flagged))
          ContextMenuItem(
            label: suggestion,
            onTap: () => _applySuggestion(suggestion),
          ),
        ContextMenuItem(
          label: showStopFlagging ? 'Stop flagging' : 'Add to dictionary',
          icon: showStopFlagging
              ? PhosphorIconsRegular.flag
              : PhosphorIconsRegular.plusCircle,
          onTap: _addToDictionary,
        ),
      ],
      if (span == null && widget.flaggableWord != null)
        ContextMenuItem(
          label: 'Flag as misspelling…',
          icon: PhosphorIconsRegular.flag,
          onTap: _flagWord,
        ),
      // Always last, below everything the spellchecker offers.
      if (widget.snippetTrigger != null)
        ContextMenuItem(
          label: 'Add snippet',
          icon: PhosphorIconsRegular.textAa,
          onTap: _addSnippet,
        ),
    ];

    return CustomSingleChildLayout(
      delegate: _TextFieldContextMenuLayoutDelegate(
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

class _TextFieldContextMenuLayoutDelegate extends SingleChildLayoutDelegate {
  _TextFieldContextMenuLayoutDelegate({
    required this.anchor,
    required this.minWidth,
  });

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
  bool shouldRelayout(_TextFieldContextMenuLayoutDelegate oldDelegate) =>
      anchor != oldDelegate.anchor;
}

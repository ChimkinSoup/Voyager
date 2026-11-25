import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:voyager/core/spellcheck/autocorrect_enabled_scope.dart';
import 'package:voyager/core/text/list_text_editing.dart';
import 'package:voyager/core/text/merge_aware_undo.dart';
import 'package:voyager/core/text/newline_normalization.dart';
import 'package:voyager/core/vim/vim_enabled_scope.dart';
import 'package:voyager/core/vim/vim_text_overlay.dart';
import 'package:voyager/core/vim/vim_text_scope.dart';
import 'package:voyager/core/widgets/autocorrect_flash_layer.dart';
import 'package:voyager/core/widgets/field_hint_style.dart';
import 'package:voyager/core/widgets/field_scroll_padding.dart';
import 'package:voyager/core/widgets/selection_highlight_layer.dart';
import 'package:voyager/core/widgets/spell_check_field_support.dart';
import 'package:voyager/core/widgets/spell_check_squiggle_layer.dart';
import 'package:voyager/features/gaia/companion/gaia_aurora_edge.dart';
import 'package:voyager/features/gaia/companion/gaia_notch.dart';
import 'package:voyager/features/gaia/companion/gaia_style.dart';
import 'package:voyager/features/gaia/companion/gaia_vanish.dart';

/// Gaia's text field: a dark field in a dim edge that, while it has focus,
/// takes on soft lights in hues around the accent drifting along it, with a
/// faint glow and shimmer (the debug menu's Aurora edge v6).
class GaiaTextField extends StatefulWidget {
  const GaiaTextField({
    super.key,
    required this.controller,
    required this.focusNode,
    this.autofocus = false,
    this.minLines,
    this.maxLines = 1,
    this.expands = false,
    this.textAlignVertical,
    this.hintText,
    this.leading,
    this.trailing,
    this.onPaste,
    this.onAddWord,
    this.undoController,
    this.lists = false,
    this.style,
    this.fill,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final bool autofocus;
  final int? minLines;
  final int? maxLines;
  final bool expands;
  final TextAlignVertical? textAlignVertical;
  final String? hintText;

  /// Sits inside the field at its bottom left, such as an attach button.
  final Widget? leading;

  /// Sits inside the field at its bottom right, such as a send button.
  final Widget? trailing;

  /// Paste from the right-click menu, in place of plain text paste.
  final VoidCallback? onPaste;

  /// "Add to dictionary" on a misspelled word's right-click menu; not
  /// offered without it.
  final void Function(String word)? onAddWord;

  /// An undo history its owner can start over; null for the field's own.
  final MergeAwareUndoController? undoController;

  /// `-` and `1.` lists as in Voyager's notes: Enter continues one and
  /// numbers follow every edit. Tab and Backspace are the owner's to wire,
  /// on its focus node.
  final bool lists;

  /// Over the theme's body text, such as a smaller size.
  final TextStyle? style;

  /// In place of [gaiaFieldFill].
  final Color? fill;

  @override
  State<GaiaTextField> createState() => _GaiaTextFieldState();
}

/// The field's fill.
const gaiaFieldFill = Color(0xFF27272A);

class _GaiaTextFieldState extends State<GaiaTextField>
    with TickerProviderStateMixin {
  /// Whether the caret is hidden while sent text vanishes, as of the last
  /// build, and it fading back in once the text has gone.
  var _caretHidden = false;
  late final _caretIn = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 200),
    value: 1,
  )..addListener(() => setState(() {}));

  /// The field's text, found once and found again if it's replaced.
  RenderEditable? _editable;

  /// The text [_onEdit] last saw, to tell an edit from a caret move.
  late String _lastText;

  /// The text before the edit [_lastText] holds, for the list editing.
  late String _beforeEdit;

  @override
  void initState() {
    super.initState();
    _lastText = _beforeEdit = widget.controller.text;
    widget.controller.addListener(_onEdit);
    SchedulerBinding.instance.addPostFrameCallback(_afterFrame);
  }

  @override
  void didUpdateWidget(GaiaTextField old) {
    super.didUpdateWidget(old);
    if (old.controller != widget.controller) {
      old.controller.removeListener(_onEdit);
      widget.controller.addListener(_onEdit);
      _lastText = _beforeEdit = widget.controller.text;
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onEdit);
    _caretIn.dispose();
    _scroll.dispose();
    super.dispose();
  }

  /// The text changed, however it was changed: typing, a paste, an IME,
  /// Vim, autocorrect or code.
  void _onEdit() {
    if (widget.controller.text == _lastText) return;
    _beforeEdit = _lastText;
    _lastText = widget.controller.text;
    // Only typing scrolls the caret into view by itself: not a draft put
    // here from code, as switching chat, Edit & resend or the palette do.
    SchedulerBinding.instance.addPostFrameCallback((_) {
      if (mounted) bringCursorIntoView(fieldKey: _fieldKey);
    });
    SchedulerBinding.instance.ensureVisualUpdate();
  }

  /// After every frame drawn, once it's laid out, to keep the caret in view
  /// as the field is resized. Costs no frames of its own.
  void _afterFrame(Duration _) {
    if (!mounted) return;
    SchedulerBinding.instance.addPostFrameCallback(_afterFrame);
    _keepCaretInView();
  }

  /// The text's size when [_keepCaretInView] last looked.
  Size? _textSize;

  /// Resized, as when the window snaps to half the screen, the text reflows
  /// under a scroll offset that no longer shows the caret: Flutter scrolls
  /// to it only on an edit or a caret move. Not while the text is sent and
  /// sweeping away.
  void _keepCaretInView() {
    final box = context.findRenderObject();
    if (box == null || !box.attached) return;
    var editable = _editable;
    if (editable == null || !editable.attached) {
      editable = _editable = findEditable(box);
    }
    if (editable == null || !editable.hasSize) return;
    final was = _textSize;
    _textSize = editable.size;
    if (was == null || was == editable.size) return;
    if (context.findAncestorStateOfType<GaiaVanishState>()?.sweep != null) {
      return;
    }
    bringCursorIntoView(fieldKey: _fieldKey);
  }

  final _fieldKey = GlobalKey<State<TextField>>();
  final _scroll = ScrollController();

  /// The same function every build: a different one makes the field build
  /// its open menu afresh, replaying its entrance, as on every hover. Over a
  /// misspelled word, its corrections first, then "Add to dictionary".
  Widget _contextMenu(BuildContext context, EditableTextState state) {
    final value = state.textEditingValue;
    final misspelt = AutocorrectEnabledScope.of(context).service == null
        ? null
        : misspellingAtCursor(
            context,
            value.text,
            value.selection.extentOffset,
          );
    return gaiaTextMenu(
      context,
      state,
      onPaste: widget.onPaste,
      first: misspelt == null
          ? const []
          : [
              for (final suggestion in misspelt.suggestions.take(5))
                GaiaMenuItem(
                  label: suggestion,
                  icon: Icons.spellcheck,
                  onPressed: () {
                    state.userUpdateTextEditingValue(
                      value.replaced(misspelt.range, suggestion),
                      SelectionChangedCause.toolbar,
                    );
                    state.hideToolbar();
                  },
                ),
              if (widget.onAddWord case final add?)
                GaiaMenuItem(
                  label: 'Add to dictionary',
                  icon: Icons.library_add_outlined,
                  onPressed: () {
                    add(misspelt.range.textInside(value.text));
                    state.hideToolbar();
                  },
                ),
            ],
    );
  }

  /// The text itself, and over it what Voyager draws on its fields: the
  /// squiggles, autocorrect's flash, and Vim's caret and selection.
  Widget _field(BuildContext context, VimFieldBinding vim) {
    final theme = Theme.of(context);
    final accent = theme.colorScheme.primary;
    final style = withSquiggleRoom(
      theme.textTheme.bodyLarge!
          .merge(widget.style)
          .copyWith(color: theme.colorScheme.onSurface),
    );
    // None beside a button: its own padding is the gap, as wide as the one
    // between it and the field's edge.
    final padding = EdgeInsets.fromLTRB(
      widget.leading == null ? 12 : 0,
      13,
      widget.trailing == null ? 12 : 0,
      13,
    );
    // Borderless and unfilled, so no input gap: only the density's shift
    // and the strip kept for the caret.
    final overlay = withCaretMargin(
      withDensityShift(padding, theme.visualDensity),
      cursorWidth: vim.overlayCaretWidth,
    );
    final session = vim.session;
    final snippets = vim.snippetSession;
    final autocorrect = vim.autocorrectSession;
    final hideCaret = _caretHidden;
    final caretColor = vim.overlayCaretColor(accent);
    // A wrapped paragraph gets [SelectionHighlightLayer]'s highlight in place
    // of Flutter's, which runs short lines out to the widest and leaves seams
    // between rows. Vim's overlay draws it itself in Visual mode.
    final ownSelection = widget.maxLines != 1 && !vim.overlayPaintsSelection;
    // Resolved above the TextSelectionTheme that blanks the field's own.
    final selectionColor = resolveSelectionColor(context);
    Widget layer(Widget child) => Positioned.fill(
      child: IgnorePointer(
        child: Padding(padding: overlay, child: child),
      ),
    );
    final field = Stack(
      fit: StackFit.passthrough,
      children: [
        if (autocorrect != null)
          layer(
            AutocorrectFlashLayer(
              session: autocorrect,
              controller: widget.controller,
              style: style,
              color: accent,
              scrollController: _scroll,
            ),
          ),
        // The app above provides the checker, as the companion's does.
        if (AutocorrectEnabledScope.of(context).service != null)
          layer(
            SpellCheckSquiggleLayer(
              controller: widget.controller,
              focusNode: widget.focusNode,
              style: style,
              scrollController: _scroll,
              suppressActiveWord: vim.suppressSpellcheckActiveWord,
            ),
          ),
        // Directly beneath the text: the fill is translucent.
        if (ownSelection)
          layer(
            SelectionHighlightLayer(
              controller: widget.controller,
              focusNode: widget.focusNode,
              style: style,
              // The strut EditableText falls back to without one of its own.
              strutStyle: StrutStyle.fromTextStyle(
                style,
                forceStrutHeight: true,
              ),
              color: selectionColor,
              scrollController: _scroll,
            ),
          ),
        wrapWithSecondaryTapWordSelect(
          fieldKey: _fieldKey,
          child: TextField(
            key: _fieldKey,
            controller: widget.controller,
            focusNode: widget.focusNode,
            // Typed edits only: a draft put here from code is left as it is.
            onChanged: widget.lists
                ? (_) => applyListEditing(
                    controller: widget.controller,
                    previousText: _beforeEdit,
                  )
                : null,
            scrollController: _scroll,
            autofocus: widget.autofocus,
            minLines: widget.minLines,
            maxLines: widget.maxLines,
            expands: widget.expands,
            style: style,
            textAlignVertical: widget.textAlignVertical,
            contextMenuBuilder: _contextMenu,
            inputFormatters: [newlineFormatterFor(widget.maxLines)],
            // Long text paints on through the padding, for the clip below to
            // cut off at the border along with what's over it.
            clipBehavior: Clip.none,
            scrollPhysics: const VoyagerFieldScrollPhysics(),
            // The squiggles are the layer's: results of the field's own
            // would have it drop the controller's text span.
            spellCheckConfiguration: const SpellCheckConfiguration.disabled(),
            showCursor: !hideCaret,
            // Held back for Vim's overlay, which draws the caret.
            cursorColor: caretColor.withValues(
              alpha: caretColor.a * _caretIn.value,
            ),
            cursorWidth: vim.overlayCaretWidth,
            undoController: vim.undoController,
            decoration: InputDecoration(
              hintText: widget.hintText,
              // In the text's own metrics, so Vim's block caret repaints the
              // hint's first letter at the size it was drawn.
              hintStyle: fieldHintStyle(context, style),
              // The field paints its own fill and edge.
              filled: false,
              border: InputBorder.none,
              enabledBorder: InputBorder.none,
              focusedBorder: InputBorder.none,
              isDense: true,
              // None past a leading or trailing button.
              contentPadding: padding,
            ),
          ),
        ),
        // The field is empty while it hides: only Vim's block caret to lose.
        if ((session != null || snippets != null) && !hideCaret)
          layer(
            Opacity(
              opacity: _caretIn.value,
              child: VimTextOverlay(
                session: session,
                snippetSession: snippets,
                controller: widget.controller,
                focusNode: widget.focusNode,
                style: style,
                accentColor: accent,
                scrollController: _scroll,
                hintText: widget.hintText,
              ),
            ),
          ),
      ],
    );
    // The one clip for the text and every layer: they don't clip themselves.
    Widget clipped = ClipRect(child: field);
    if (widget.undoController case final undo?) {
      clipped = MergeAwareUndoScope(controller: undo, child: clipped);
    } else if (widget.lists) {
      // Flutter's own undo then restores the text, which list editing
      // mustn't rewrite mid-restore; see [ListEditingUndoGuard].
      clipped = ListEditingUndoGuard(child: clipped);
    }
    return session == null && !ownSelection
        ? clipped
        : vimSelectionTheme(
            context: context,
            hideNativeSelection: vim.overlayPaintsSelection || ownSelection,
            child: clipped,
          );
  }

  @override
  Widget build(BuildContext context) {
    // While sent text vanishes the caret hides. It fades in once the text
    // has gone, but comes back at once to typing.
    final hideCaret =
        context.findAncestorStateOfType<GaiaVanishState>()?.hidesCaret ?? false;
    if (_caretHidden &&
        !hideCaret &&
        widget.controller.text.isEmpty &&
        !(MediaQuery.maybeDisableAnimationsOf(context) ?? false)) {
      _caretIn.forward(from: 0);
    }
    _caretHidden = hideCaret;
    // Room its glow spreads into.
    return Padding(
      padding: const EdgeInsets.all(2),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 400),
        decoration: BoxDecoration(
          color: widget.fill ?? gaiaFieldFill,
          borderRadius: BorderRadius.circular(GaiaRadius.row),
        ),
        child: GaiaAuroraEdge(
          focusNode: widget.focusNode,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              if (widget.leading case final leading?)
                Padding(
                  padding: const EdgeInsets.all(4),
                  child: TextFieldTapRegion(child: leading),
                ),
              Expanded(
                // Long prompts scroll without a bar.
                child: ScrollConfiguration(
                  behavior: const _NoScrollbars(),
                  // Voyager's Vim, snippets and autocorrect (§9.5), as its
                  // own fields have them.
                  child: VimTextScope(
                    enabled: VimEnabledScope.of(context),
                    controller: widget.controller,
                    undoController: widget.undoController,
                    multiline: true,
                    builder: _field,
                  ),
                ),
              ),
              if (widget.trailing case final trailing?)
                Padding(
                  // None on its left: the text already keeps a strip
                  // there for the caret.
                  padding: const EdgeInsets.fromLTRB(0, 4, 4, 4),
                  // Part of the field, so clicking it keeps the focus.
                  child: TextFieldTapRegion(child: trailing),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Builds no scrollbar, even for a multiline field, which turns bars back on
/// over a plain `scrollbars: false`.
class _NoScrollbars extends MaterialScrollBehavior {
  const _NoScrollbars();

  @override
  Widget buildScrollbar(
    BuildContext context,
    Widget child,
    ScrollableDetails details,
  ) => child;
}

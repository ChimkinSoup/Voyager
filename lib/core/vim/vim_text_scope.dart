import 'package:flutter/material.dart';
import 'package:voyager/core/platform/window_focus_watcher.dart';
import 'package:voyager/core/snippets/snippet_enabled_scope.dart';
import 'package:voyager/core/snippets/snippet_session.dart';
import 'package:voyager/core/vim/vim_anchored_chrome.dart';
import 'package:voyager/core/vim/vim_session.dart';

/// What the host field needs to know about its Vim session while building.
///
/// Deliberately tiny: a field's build method only has to change two things
/// when the mode changes — the caret shape and which undo stack it uses — so
/// that's all this carries. Everything else (the mode badge, the search bar,
/// every text mutation) is handled by [VimTextScope] itself, above the field.
@immutable
class VimFieldBinding {
  const VimFieldBinding({
    this.mode,
    this.undoController,
    this.session,
    this.snippetSession,
    this.snippetsAllowed = false,
  });

  /// The current mode, or null when Vim is switched off for this field — in
  /// which case every getter below returns the field's ordinary defaults.
  final VimMode? mode;

  final UndoHistoryController? undoController;

  /// The live session, for fields that stack a `VimTextOverlay` and so need
  /// the caret offset, Visual selection and search matches to paint. Null when
  /// Vim is off for this field.
  final VimSession? session;

  /// The field's text-snippet runtime, or null when snippets are off, the
  /// field opted out, or the user has not written a snippet yet.
  ///
  /// Independent of [session]: snippets work with Vim switched off. Fields that
  /// stack a `VimTextOverlay` pass this to it so the dotted tabstop marks get
  /// drawn — and must mount that overlay when *either* session is live.
  final SnippetSession? snippetSession;

  /// Whether a *new* snippet could be written from this field — the field's
  /// own opt-in narrowed by the suitability rule, and the user's global
  /// switch. Unlike [snippetSession] it does not go false on an empty snippet
  /// list, since writing the first one is exactly what it gates: the
  /// right-click "Add snippet" item (see `voyagerTextContextMenuBuilder`).
  final bool snippetsAllowed;

  /// Normal and Visual mode draw a block caret sitting *on* a character,
  /// rather than the thin bar that sits between two.
  bool get blockCaret => mode != null && mode != VimMode.insert;

  /// Width of the caret for a field rendering [style].
  ///
  /// 0.55em is close to the advance width of a lowercase glyph in the
  /// proportional faces this app uses — near enough that the block reads as
  /// "covering one character" without measuring the glyph under the caret on
  /// every mode change. That approximation also covers the placeholder's first
  /// letter on an empty field, which stays on screen in Normal mode; a field
  /// that needs the block sized to the glyph exactly stacks a
  /// `VimTextOverlay`, which measures it (see `VimTextOverlay.hintText`).
  double caretWidth(TextStyle? style) =>
      blockCaret ? (style?.fontSize ?? 16.0) * 0.55 : 2.0;

  /// Caret color. The block is drawn translucent because Material paints the
  /// caret *beneath* the text on Windows and Android
  /// (`paintCursorAboveText: false`), so a solid fill would still show the
  /// glyph but at poor contrast; 40% keeps both readable.
  Color caretColor(Color accent) =>
      blockCaret ? accent.withValues(alpha: 0.4) : accent;

  /// Caret colour for a field that also stacks a `VimTextOverlay`.
  ///
  /// That layer draws the block itself — glyph-width, unblinking, and still
  /// visible over a Visual selection, none of which [EditableText] can do —
  /// so the field's own caret has to get out of the way. Transparent rather
  /// than zero-width: the caret rect still exists, so `EditableText` keeps
  /// scrolling it into view as the cursor moves.
  Color overlayCaretColor(Color accent) =>
      blockCaret ? Colors.transparent : accent;

  /// Caret *width* for a field that also stacks a `VimTextOverlay`: the
  /// ordinary 2px in every mode, unlike [caretWidth].
  ///
  /// The field's own caret is transparent there (see [overlayCaretColor]), so
  /// widening it buys nothing — and it is not free. `RenderEditable` reserves
  /// `1 + cursorWidth` out of the width it wraps the text at (see
  /// `withCaretMargin`), so a caret that widens on Esc re-wraps the whole
  /// paragraph under the user every time they leave Insert mode.
  double get overlayCaretWidth => 2.0;

  /// Whether a field stacking a `VimTextOverlay` should suppress Flutter's own
  /// selection highlight.
  ///
  /// Only in Visual mode, and only because the overlay is drawing a more
  /// accurate one: outside Visual the selection is the user's own mouse drag
  /// and must render normally.
  bool get overlayPaintsSelection => mode?.isVisual ?? false;

  /// Whether a completion popup (the tag suggestion list) may open.
  ///
  /// Vim's popup menu is an Insert-mode construct — no Normal-mode motion
  /// opens one, because moving the cursor onto a word is navigation, not an
  /// intent to edit it. It would also fight the Vim layer for keys: the popup
  /// claims Escape, Enter and the arrows, all of which mean something else in
  /// Normal mode.
  bool get completionsAllowed => mode == null || mode == VimMode.insert;

  /// Whether Escape has a second owner behind any popup that consumes it.
  ///
  /// In Vim, `<Esc>` on an open popup menu both dismisses it *and* leaves
  /// Insert mode — one press, two effects. Without Vim, Escape is a plain
  /// dismiss and must stop at the popup, or it would go on to close the dialog
  /// the field sits in.
  bool get escapeLeavesInsert => mode == VimMode.insert;

  /// Whether the squiggle layer should hide the word currently being typed.
  ///
  /// False in Normal/Visual: nothing is being typed, so yanking and putting a
  /// misspelling (caret lands inside it) must still underline it. See
  /// [SpellCheckSquiggleLayer.suppressActiveWord].
  bool get suppressSpellcheckActiveWord =>
      mode == null || mode == VimMode.insert;
}

typedef VimFieldBuilder =
    Widget Function(BuildContext context, VimFieldBinding binding);

/// Adds Vim editing to whatever text field [builder] returns.
///
/// ### Where the keys are intercepted
/// This installs a non-focusable [Focus] as an *ancestor* of the field.
/// Flutter dispatches a key to the primary focus node first and then walks up
/// its ancestors, so this sees every key the field itself didn't claim, and
/// sees it before `DefaultTextEditingShortcuts` at the app root. On desktop,
/// returning [KeyEventResult.handled] is also what stops the embedder handing
/// the character to the text input plugin — which is why [VimSession]
/// consumes *every* printable key in Normal mode rather than only the ones it
/// understands.
///
/// Sitting above the field (rather than assigning `focusNode.onKeyEvent`)
/// also leaves that slot free: `TagSuggestionPortal` owns it, and gets first
/// refusal on arrows and Escape while its completion popup is open.
///
/// ### Fields start in Insert
/// Focusing a box types normally; `Esc` opts into Normal mode. Escape never
/// leaves the field once a session is live — not on the transition, and not on
/// the presses after it — so an enclosing dialog or popover can't be dismissed
/// out from under a box that is being typed into. See [VimSession.handleKey].
///
/// ### Mode badge placement
/// The `NORMAL` / `VISUAL` / `V-LINE` capsule sits **inside** the field's
/// bottom-right, `Offset(-10, -8)` from that corner, and is fixed there. It is
/// part of the field: it scrolls with it, and where the field is cut off — by
/// the box it scrolls inside, by the list its row belongs to — the badge is
/// cut off on the same line, exactly like a character typed in that corner.
///
/// It never repositions itself to stay in sight. A readout that moves on its
/// own while you are reading it is worse than one you have to scroll to, and
/// worse again than one that hangs outside the field and lands on whatever is
/// underneath. See [VimChromeFit.clip].
///
/// On a field too short to hold that capsule comfortably — a dense one-line
/// box, which is most of the composers and inline renames in the app — it
/// gives way to a smaller, borderless one on the field's centre-right. See
/// [kVimCompactBadgeField].
///
/// The `/` search bar is the exception, and takes [VimChromeFit.clamp]: it
/// docks below the field and is held to the part of it still on screen, since
/// a prompt you cannot see is no use for the second you are typing into it.
///
/// ### It also hosts text snippets
/// Snippet expansion needs exactly what this widget already owns — an ancestor
/// [Focus] that sees every key the field didn't claim, and a way to rewrite the
/// text through [EditableTextState] — so it lives here rather than in a scope
/// of its own. That keeps the arbitration order unambiguous and costs no extra
/// node: one [Focus] serves both.
///
/// The two are otherwise independent. Snippets do **not** require [enabled];
/// they follow the user's own setting (see `SnippetEnabledScope`) and the same
/// field-suitability rule Vim uses. Keys are offered to the snippet layer
/// first, since the only ones it claims — Tab and the expand key — are keys
/// Vim deliberately passes through. See [_handleKey].
class VimTextScope extends StatefulWidget {
  const VimTextScope({
    super.key,
    required this.enabled,
    required this.controller,
    required this.multiline,
    required this.builder,
    this.accentColor,
    this.snippetsAllowed = true,
  });

  /// Whether this field gets Vim at all. False for password boxes, numeric
  /// and formatter-constrained inputs, and whenever the user has the feature
  /// switched off — see `vimSuitsField`.
  final bool enabled;

  /// The field's controller. Vim needs one to read and rewrite the text, so a
  /// controller-less field silently opts out.
  final TextEditingController? controller;

  /// Whether the wrapped field can hold more than one line, which decides
  /// whether `o`/`O` and a linewise `p` may insert newlines.
  final bool multiline;

  /// Whether this field may run text snippets, on top of the user's own
  /// setting. The hard opt-out for the two places expansion would be wrong:
  /// the LeetCode code editor (SNIPPET.md §2.3) and the snippet editor itself,
  /// where a trigger being typed into a form field must stay literal.
  final bool snippetsAllowed;

  final Color? accentColor;

  final VimFieldBuilder builder;

  @override
  State<VimTextScope> createState() => _VimTextScopeState();
}

class _VimTextScopeState extends State<VimTextScope> {
  final LayerLink _link = LayerLink();
  final OverlayPortalController _portal = OverlayPortalController();

  /// Keeps the field's element alive while its ancestry changes.
  ///
  /// [CompositedTransformTarget] is only in the tree while the badge is up (see
  /// [build]), so entering and leaving Normal mode inserts and removes a widget
  /// directly above the field. Without a [GlobalKey] that is a changed widget
  /// type at that position, which re-inflates everything below it — a brand new
  /// [EditableTextState] on every `Esc` and every `i`. The focus node survives
  /// that, but the platform text input connection does not: the fresh state
  /// never sees a focus *change*, so it never opens one, and the field sits
  /// there looking focused while swallowing every keystroke.
  ///
  /// A [GlobalKey] makes the framework *move* the existing element to its new
  /// parent instead, keeping the state, the caret and the input connection.
  final GlobalKey _fieldKey = GlobalKey(debugLabel: 'VimTextScope field');

  /// The scope's own node. It never takes focus itself; it exists to sit in
  /// the focus tree above the field, where [FocusNode.hasFocus] reports "the
  /// field below me has focus" and [FocusNode.onKeyEvent] sees every key that
  /// field didn't claim.
  ///
  /// Using this instead of the caller's own [FocusNode] is what lets any
  /// field — including bare [TextField]s that never created one — opt in with
  /// nothing but a controller.
  late final FocusNode _scopeNode = FocusNode(
    debugLabel: 'VimTextScope',
    canRequestFocus: false,
    skipTraversal: true,
    onKeyEvent: _handleKey,
  );

  VimSession? _session;
  SnippetSession? _snippetSession;

  /// The snippet settings this field last built against, read in
  /// [didChangeDependencies] rather than [initState] because it comes from an
  /// inherited widget.
  SnippetScopeData _snippetScope = SnippetScopeData.disabled;

  /// Stands in for [VimSession.modeListenable] when Vim is off, so a field with
  /// only snippets running builds through the same [ValueListenableBuilder] as
  /// one with Vim on.
  ///
  /// That is not cosmetic: switching Vim on or off would otherwise change the
  /// widget *type* directly above the field, re-inflating [EditableTextState]
  /// and dropping the platform input connection — the failure [_fieldKey]
  /// exists to prevent. Pinned to Insert and never fired.
  final ValueNotifier<VimMode> _insertOnly = ValueNotifier<VimMode>(
    VimMode.insert,
  );

  /// True while this field's focus is parked by a window switch rather than by
  /// the user leaving the box. See [_handleFocusChanged].
  bool _suspended = false;

  /// The selection Vim had when that happened, put back on the way in — see
  /// [_endSuspension].
  TextSelection? _parkedSelection;

  /// Whether the badge/search-bar overlay is mounted. Also gates the
  /// [CompositedTransformTarget] below — see [build].
  bool _overlayVisible = false;

  /// The field's [EditableTextState], resolved once per editing session and
  /// dropped on focus loss — see [_resolveEditableState].
  EditableTextState? _editableState;

  /// The undo stack for the field below, owned here rather than by
  /// [VimSession] because the snippet layer needs it too and snippets run with
  /// Vim switched off. Handed to the field through [VimFieldBinding], so `u`,
  /// `<C-r>` and a snippet undo all drive the same history the field records
  /// into.
  final UndoHistoryController _undoController = UndoHistoryController();

  bool get _active => widget.enabled && widget.controller != null;

  bool get _snippetsActive =>
      widget.snippetsAllowed &&
      _snippetScope.active &&
      widget.controller != null;

  /// Whether a new snippet may be *written* from this field. Deliberately not
  /// [_snippetsActive]: an empty snippet list has nothing to expand but is
  /// exactly when the right-click "Add snippet" item matters most.
  bool get _canCreateSnippets =>
      widget.snippetsAllowed && _snippetScope.enabled;

  @override
  void initState() {
    super.initState();
    _createSessionIfNeeded();
    _scopeNode.addListener(_handleFocusChanged);
    WindowFocusWatcher.instance.addListener(_handleWindowFocusChanged);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final scope = SnippetEnabledScope.of(context);
    if (scope == _snippetScope) return;
    _snippetScope = scope;
    _syncSnippetSession();
  }

  @override
  void didUpdateWidget(covariant VimTextScope oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.enabled != widget.enabled ||
        oldWidget.controller != widget.controller) {
      _disposeSession();
      _createSessionIfNeeded();
      // Offsets from the old field's text mean nothing in the new one.
      _parkedSelection = null;
      // The host may have handed us a different field along with the new
      // controller, so the cached state is no longer known to be the right one.
      _editableState = null;
      // The fresh session starts in Insert, so any overlay from the old one is
      // stale. Assigned directly rather than through [_syncOverlay]: a rebuild
      // already follows didUpdateWidget, so setState here would be redundant
      // at best and a "called during build" assertion at worst.
      if (_overlayVisible) {
        _overlayVisible = false;
        _portal.hide();
      }
    } else if (oldWidget.snippetsAllowed != widget.snippetsAllowed) {
      _syncSnippetSession();
    }
  }

  @override
  void dispose() {
    WindowFocusWatcher.instance.removeListener(_handleWindowFocusChanged);
    _scopeNode.removeListener(_handleFocusChanged);
    _scopeNode.dispose();
    _disposeSession();
    _insertOnly.dispose();
    _undoController.dispose();
    super.dispose();
  }

  void _createSessionIfNeeded() {
    if (_active) {
      final session = VimSession(
        textController: widget.controller!,
        resolveEditableState: _resolveEditableState,
        isFieldFocused: () => _scopeNode.hasFocus,
        undoController: _undoController,
        isMultiline: () => widget.multiline,
        // Looked up live: settings sync can replace [_snippetSession].
        trySnippetUndo: () =>
            _snippetSession?.undoLastExpansion(
              requireMatchingSelection: false,
            ) ??
            false,
      );
      session.modeListenable.addListener(_syncOverlay);
      session.searchListenable.addListener(_syncOverlay);
      _session = session;
    }
    _syncSnippetSession();
  }

  /// Creates, updates or tears down the snippet runtime to match the current
  /// settings.
  ///
  /// An existing session is *updated* rather than replaced when only the list
  /// or the expand key changed, so editing an unrelated snippet doesn't destroy
  /// live tabstops in some other field.
  void _syncSnippetSession() {
    final existing = _snippetSession;
    if (!_snippetsActive) {
      if (existing == null) return;
      existing.dispose();
      _snippetSession = null;
      return;
    }
    if (existing != null) {
      existing.index = _snippetScope.index;
      existing.expandKey = _snippetScope.expandKey;
      return;
    }
    _snippetSession = SnippetSession(
      textController: widget.controller!,
      resolveEditableState: _resolveEditableState,
      isFieldFocused: () => _scopeNode.hasFocus,
      undoController: _undoController,
      isInsertMode: _isInsertBehaviour,
      index: _snippetScope.index,
      expandKey: _snippetScope.expandKey,
    );
  }

  /// Whether the field is behaving as an insert surface right now.
  ///
  /// Always true with Vim off. With Vim on it means Insert mode and no `/`
  /// prompt open — the two states where a typed character is text rather than
  /// a command (SNIPPET.md §2.3).
  bool _isInsertBehaviour() {
    final session = _session;
    if (session == null) return true;
    return session.mode == VimMode.insert &&
        session.searchListenable.value == null;
  }

  /// Finds *this scope's* field's [EditableTextState], or null when the field
  /// is not the one holding the keyboard.
  ///
  /// Deliberately not resolved from `FocusManager.instance.primaryFocus`: that
  /// answers "whichever field is focused right now", which is only this one
  /// while this one is focused. Two paths ask after focus has already moved on
  /// — [VimSession.reset] from the focus listener, and a `<C-v>` whose
  /// clipboard read resolves late — and a global lookup hands them the state of
  /// the field the user moved *to*, so the write lands there and destroys it.
  ///
  /// Searching down from [_fieldKey] instead keeps the answer tied to the
  /// scope's own subtree, and the [FocusNode.hasFocus] gate keeps it tied to
  /// the editing session it was resolved in. Cached for the length of that
  /// session: the walk is a handful of hops, but it was being paid on every
  /// keystroke.
  EditableTextState? _resolveEditableState() {
    // Not our keyboard any more — see [VimSession.isFieldFocused].
    if (!_scopeNode.hasFocus) return null;
    final cached = _editableState;
    // `mounted` because the host can replace the field under us without focus
    // ever leaving the scope, and a write to a dead state would throw.
    if (cached != null && cached.mounted) return cached;
    return _editableState = _findEditableState();
  }

  EditableTextState? _findEditableState() {
    final context = _fieldKey.currentContext;
    if (context is! Element) return null;
    EditableTextState? found;
    void visit(Element element) {
      if (found != null) return;
      if (element is StatefulElement && element.state is EditableTextState) {
        found = element.state as EditableTextState;
        return;
      }
      element.visitChildren(visit);
    }

    context.visitChildren(visit);
    return found;
  }

  void _disposeSession() {
    _snippetSession?.dispose();
    _snippetSession = null;
    final session = _session;
    if (session == null) return;
    session.modeListenable.removeListener(_syncOverlay);
    session.searchListenable.removeListener(_syncOverlay);
    session.dispose();
    _session = null;
  }

  void _handleFocusChanged() {
    // Resolved lazily on the way in and dropped on the way out, so the cache
    // never outlives the editing session it belongs to.
    if (!_scopeNode.hasFocus) _editableState = null;
    if (_scopeNode.hasFocus) {
      // Focus is back — whether the framework handed it back after a window
      // switch or the user clicked in. Either way there is nothing left to
      // wait for.
      _endSuspension();
    } else if (!WindowFocusWatcher.instance.hasFocus) {
      // Not the user leaving the box: the *window* left. The framework parks
      // the primary focus on both of the paths a switch arrives by (see
      // [WindowFocusWatcher]) and hands it back when the window returns.
      // Resetting here is what used to dump you into Insert on every Alt-Tab,
      // and take the Visual range with it. So the session is left exactly as
      // it stands: mode, pending command, `/` prompt and selection all still
      // there when you come back.
      _beginSuspension();
    } else {
      // A field's Vim state belongs to one editing session: leaving the box
      // drops back to Insert so the next click behaves like an ordinary field.
      // Snippet tabstops are per-session for the same reason (SNIPPET.md §7),
      // and are left alone by the suspension branch above on the same grounds
      // as the Vim mode: a window switch is not the user leaving the box.
      _session?.reset();
      _snippetSession?.reset();
    }
    _syncOverlay();
  }

  void _beginSuspension() {
    if (_suspended) return;
    _suspended = true;
    // Snapshotted now, while it is still the caret Vim put there: nothing has
    // stomped it yet, because `EditableText` re-selects a field when it is
    // *focused*, on the way back.
    _parkedSelection = widget.controller?.selection;
  }

  void _endSuspension() {
    if (!_suspended) return;
    _suspended = false;
    final parked = _parkedSelection;
    _parkedSelection = null;
    final session = _session;
    if (parked == null || session == null || session.mode == VimMode.insert) {
      return;
    }
    // Desktop [EditableText] selects the whole of a single-line field whenever
    // it takes focus (`selectAllOnFocus`), and after a window switch the
    // framework hands that focus back on its own. Left alone, Normal mode
    // comes back with its caret at the end of the field and Visual mode paints
    // its range over everything. Deferred a frame because that select-all can
    // land after this notification.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scopeNode.hasFocus) return;
      session.restoreSelection(parked);
    });
  }

  /// The window came back — or left, in which case there is nothing to do here
  /// and [_handleFocusChanged] will have parked the session already.
  ///
  /// By the next frame the focus has either returned, in which case
  /// [_handleFocusChanged] has already ended the suspension, or it is not
  /// going to: something else took focus while the window was away. That
  /// second case is an abandoned field, and it resets like any other, so a
  /// click into it later still lands in Insert.
  ///
  /// Checked from a frame callback rather than a microtask because the
  /// framework restores the focus it parked from a microtask of *its* own, and
  /// which of the two runs first depends on the order the binding observers
  /// happen to sit in. Both are long done by the time a frame is drawn.
  void _handleWindowFocusChanged() {
    if (!_suspended || !WindowFocusWatcher.instance.hasFocus) return;
    // Nothing about a window regaining focus dirties the tree on its own, so
    // ask for the frame this callback needs.
    WidgetsBinding.instance.ensureVisualUpdate();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_suspended || _scopeNode.hasFocus) return;
      _suspended = false;
      _parkedSelection = null;
      _session?.reset();
      _snippetSession?.reset();
      _syncOverlay();
    });
  }

  /// Shows the overlay only when there is something to show. In Insert mode
  /// with no search bar open — the overwhelmingly common state — nothing is
  /// mounted and the feature costs one extra [Focus] node.
  void _syncOverlay() {
    if (!mounted) return;
    final session = _session;
    final show =
        session != null &&
        _scopeNode.hasFocus &&
        (session.mode != VimMode.insert ||
            session.searchListenable.value != null);
    if (show == _overlayVisible) return;
    setState(() => _overlayVisible = show);
    if (show) {
      _portal.show();
    } else {
      _portal.hide();
    }
  }

  /// Key arbitration for the field below.
  ///
  /// By the time this runs, `TagSuggestionPortal` has already had first refusal
  /// — it owns `focusNode.onKeyEvent`, one level down — so an open completion
  /// popup keeps Tab and Escape for itself.
  ///
  /// Snippets go before Vim because the two never want the same key: the only
  /// keys the snippet layer claims are Tab, the expand key and `Ctrl+Z`, and
  /// [VimSession] passes Tab straight through in every mode (focus traversal
  /// stays available) while Space and `Ctrl+Z` only mean anything to it outside
  /// Insert — which is exactly where the snippet layer declines to act.
  /// Bare `u` stays with Vim: Normal mode asks the snippet session via
  /// [VimSession.trySnippetUndo] rather than claiming the key here.
  KeyEventResult _handleKey(FocusNode node, KeyEvent event) {
    final session = _session;
    final snippets = _snippetSession;
    if (session == null && snippets == null) return KeyEventResult.ignored;
    // Only claim keys destined for a real text field. The scope's subtree can
    // also contain focusable chrome (a suffix icon button, say), and Vim has
    // no business intercepting keys typed at those.
    // Compared against this scope's own field rather than merely tested for
    // "some editable": chrome inside the scope must not be mistaken for it.
    final editable = _resolveEditableState();
    final focused = FocusManager.instance.primaryFocus?.context;
    if (editable == null ||
        focused?.findAncestorStateOfType<EditableTextState>() != editable) {
      return KeyEventResult.ignored;
    }
    // Vim wins Tab while a Visual range is up: advancing a tabstop writes a
    // collapsed selection, which the Vim layer would not see, leaving it in
    // Visual mode with a highlight the next motion jumps back out of. The
    // tabstops stay live and Tab works again the moment Escape drops back to
    // Normal or Insert.
    if (snippets != null && !(session?.mode.isVisual ?? false)) {
      final result = snippets.handleKey(event);
      if (result == KeyEventResult.handled) return result;
    }
    return session?.handleKey(event) ?? KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final session = _session;
    final snippets = _snippetSession;
    if (session == null && snippets == null) {
      return widget.builder(
        context,
        VimFieldBinding(snippetsAllowed: _canCreateSnippets),
      );
    }

    final accent = widget.accentColor ?? Theme.of(context).colorScheme.primary;

    // Only the mode notifier drives this rebuild. The HUD text and the search
    // bar change far more often and are listened to separately, inside the
    // overlay, so typing a command never rebuilds the field. A snippet-only
    // field builds through the same shape against a notifier that never fires
    // — see [_insertOnly].
    Widget field = KeyedSubtree(
      key: _fieldKey,
      child: ValueListenableBuilder<VimMode>(
        valueListenable: session?.modeListenable ?? _insertOnly,
        builder: (context, mode, _) => widget.builder(
          context,
          VimFieldBinding(
            // Null, not Insert, when Vim is off: that is what makes every
            // getter on the binding fall back to the field's own defaults.
            mode: session == null ? null : mode,
            undoController: _undoController,
            session: session,
            snippetSession: snippets,
            snippetsAllowed: _canCreateSnippets,
          ),
        ),
      ),
    );

    // `CompositedTransformTarget` reports `alwaysNeedsCompositing`, so leaving
    // one mounted would hand every text box in the app its own permanent
    // compositing layer just to anchor chrome that is usually not on screen.
    // It goes up in the same build as the overlay it anchors, so the leader is
    // always in place by the time the follower looks for it. Coming and going
    // is only safe because [_fieldKey] carries the field across the change.
    if (_overlayVisible) {
      field = CompositedTransformTarget(link: _link, child: field);
    }

    return Focus.withExternalFocusNode(
      // `withExternalFocusNode` and not the plain constructor: the ordinary
      // `Focus(focusNode: …)` re-asserts *its own* defaults onto the node it
      // is given, which would flip `skipTraversal`/`canRequestFocus` back on
      // and insert this scope as a Tab stop in front of every field.
      focusNode: _scopeNode,
      child: OverlayPortal(
        controller: _portal,
        // Never built without a Vim session: [_syncOverlay] is the only thing
        // that shows this portal and it requires one. Kept mounted (hidden) on
        // a snippet-only field so switching Vim on doesn't change the shape of
        // the tree above the field — see [_insertOnly].
        overlayChildBuilder: (context) => _VimFieldOverlay(
          link: _link,
          fieldKey: _fieldKey,
          session: session!,
          accentColor: accent,
        ),
        child: field,
      ),
    );
  }
}

/// A field shorter than this gets the compact mode badge.
///
/// The full capsule is 16px tall and hangs 8px off the bottom of the field, so
/// on a short one it stops reading as tucked into a corner and starts reading
/// as filling the box — 16px of badge in a 36px field, sitting 4px below the
/// centre line, is what looks crooked in the quick-reminder composer.
///
/// The line is drawn from the app's own fields, measured under
/// [VoyagerTheme]'s compact density: the dense family runs 36px (the
/// quick-reminder box) to 46px (the bucket-list composer), with the bucket-list
/// rows and todo's inline rename at 44, while an ordinary outlined field is 54.
/// 50 splits that gap evenly.
const kVimCompactBadgeField = 50.0;

/// The mode badge and the `/` search bar, both hung off the field's
/// [LayerLink] so they track it through scrolling, dialogs and popovers without
/// any measurement code — and each given the [VimChromeFit] that suits it,
/// since the link alone would follow the field straight out of the box it
/// scrolls inside and keep painting.
class _VimFieldOverlay extends StatefulWidget {
  const _VimFieldOverlay({
    required this.link,
    required this.fieldKey,
    required this.session,
    required this.accentColor,
  });

  final LayerLink link;
  final GlobalKey fieldKey;
  final VimSession session;
  final Color accentColor;

  @override
  State<_VimFieldOverlay> createState() => _VimFieldOverlayState();
}

class _VimFieldOverlayState extends State<_VimFieldOverlay> {
  /// How tall the field is, which decides which badge it gets.
  ///
  /// Seeded here from the render object rather than from `BuildContext.size`,
  /// which refuses to answer during a build: the value is one frame old by
  /// definition, and that is the right one, since this overlay is unmounted
  /// for the whole of Insert mode (see `_syncOverlay`) and so is built afresh
  /// on the field you have just finished typing into. From then on the badge's
  /// own chrome reports every change — a `p` that pastes in three lines, a
  /// `dd` that takes them out again.
  late double? _fieldHeight = _measureField();

  double? _measureField() {
    final field = widget.fieldKey.currentContext?.findRenderObject();
    return field is RenderBox && field.hasSize ? field.size.height : null;
  }

  void _handleFieldHeight(double height) {
    if (height == _fieldHeight || !mounted) return;
    setState(() => _fieldHeight = height);
  }

  @override
  Widget build(BuildContext context) {
    final height = _fieldHeight;
    final compact = height != null && height < kVimCompactBadgeField;
    return Stack(
      children: [
        VimAnchoredChrome(
          link: widget.link,
          fieldKey: widget.fieldKey,
          onFieldHeight: _handleFieldHeight,
          // Centred rather than tucked into the corner, which is most of the
          // fix on a short field: a 13px badge centred on a 40px box comes
          // within a pixel of the border's curve, where the same badge sitting
          // on the bottom edge runs straight into it — so the inset off the
          // right stays 10px either way.
          targetAnchor: compact ? Alignment.centerRight : Alignment.bottomRight,
          followerAnchor: compact
              ? Alignment.centerRight
              : Alignment.bottomRight,
          offset: compact ? const Offset(-10, 0) : const Offset(-10, -8),
          fit: VimChromeFit.clip,
          child: _VimModeBadge(
            session: widget.session,
            accentColor: widget.accentColor,
            compact: compact,
          ),
        ),
        VimAnchoredChrome(
          link: widget.link,
          fieldKey: widget.fieldKey,
          targetAnchor: Alignment.bottomLeft,
          followerAnchor: Alignment.topLeft,
          offset: const Offset(0, 6),
          fit: VimChromeFit.clamp,
          child: _VimSearchBar(
            session: widget.session,
            accentColor: widget.accentColor,
          ),
        ),
      ],
    );
  }
}

/// `NORMAL` / `VISUAL` / `V-LINE`, plus any half-typed command.
///
/// Intentionally not animated: this is a status readout, and a fade would
/// mean the mode you are in is briefly ambiguous at exactly the moment you
/// need to know it.
class _VimModeBadge extends StatelessWidget {
  const _VimModeBadge({
    required this.session,
    required this.accentColor,
    required this.compact,
  });

  final VimSession session;
  final Color accentColor;

  /// The short-field form: same word, a point smaller, with less padding and
  /// no border — around 13px of height against the full badge's 16. The border
  /// is the part that makes the full badge crowd a dense box, two strokes a
  /// few pixels apart with the field's own, so dropping it buys more room than
  /// it costs legibility and the fill carries the badge alone.
  /// See [kVimCompactBadgeField].
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: ValueListenableBuilder<VimMode>(
        valueListenable: session.modeListenable,
        builder: (context, mode, _) {
          if (mode == VimMode.insert) return const SizedBox.shrink();
          return ValueListenableBuilder<String>(
            valueListenable: session.hudListenable,
            builder: (context, pending, _) => _badge(context, mode, pending),
          );
        },
      ),
    );
  }

  Widget _badge(BuildContext context, VimMode mode, String pending) {
    final theme = Theme.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        // A flat translucent fill rather than a GlassSurface: this sits on
        // screen for the whole time you are in Normal mode, and a persistent
        // BackdropFilter would cost a saveLayer every frame for a 60px pill.
        color: Color.alphaBlend(
          // Carrying the badge without a border takes a little more fill.
          accentColor.withValues(alpha: compact ? 0.3 : 0.22),
          theme.colorScheme.surface,
        ),
        borderRadius: BorderRadius.circular(compact ? 4 : 6),
        border: compact
            ? null
            : Border.all(color: accentColor.withValues(alpha: 0.45), width: 1),
      ),
      child: Padding(
        padding: compact
            ? const EdgeInsets.symmetric(horizontal: 5, vertical: 1)
            : const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        child: Text(
          pending.isEmpty ? mode.label : '${mode.label}  $pending',
          style: theme.textTheme.labelSmall?.copyWith(
            // A point under the full badge, which on the densest fields is
            // also a point under the field's own text — the badge reading as
            // large as the note you are writing is much of why it draws the
            // eye there.
            fontSize: compact ? 9 : 10,
            height: 1.2,
            letterSpacing: compact ? 0.6 : 0.8,
            fontFeatures: const [FontFeature.tabularFigures()],
            color: theme.colorScheme.onSurface.withValues(alpha: 0.85),
          ),
        ),
      ),
    );
  }
}

/// Vim's `/` prompt, docked under the field it searches.
///
/// It is not a real text field — it renders [VimSearchPrompt.query] as text
/// and lets [VimSession] absorb the keys, so opening it never moves focus
/// away from the box being edited (which would drop the caret and, in a
/// dialog, could close the thing entirely).
class _VimSearchBar extends StatelessWidget {
  const _VimSearchBar({required this.session, required this.accentColor});

  final VimSession session;
  final Color accentColor;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return IgnorePointer(
      child: ValueListenableBuilder<VimSearchPrompt?>(
        valueListenable: session.searchListenable,
        builder: (context, prompt, _) {
          if (prompt == null) return const SizedBox.shrink();
          // "3|12", not "3/12": a slash next to a `/`-search reads as part of
          // the pattern.
          final counter = prompt.query.isEmpty
              ? ''
              : (prompt.matchCount == 0
                    ? 'no matches'
                    : '${prompt.matchIndex}|${prompt.matchCount}');
          final monospace = theme.textTheme.bodySmall?.copyWith(
            fontSize: 12,
            height: 1.3,
            color: theme.colorScheme.onSurface,
          );
          return ConstrainedBox(
            constraints: const BoxConstraints(minWidth: 200, maxWidth: 420),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: theme.colorScheme.surface,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: accentColor.withValues(alpha: 0.5),
                  width: 1,
                ),
                boxShadow: [
                  BoxShadow(
                    color: theme.shadowColor.withValues(alpha: 0.18),
                    blurRadius: 10,
                    offset: const Offset(0, 3),
                  ),
                ],
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 6,
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      prompt.forward ? '/' : '?',
                      style: monospace?.copyWith(
                        color: accentColor,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(width: 2),
                    Flexible(
                      child: Text(
                        prompt.query,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: monospace,
                      ),
                    ),
                    // A drawn caret, since this bar holds no real focus.
                    Container(
                      width: 1.5,
                      height: 13,
                      margin: const EdgeInsets.symmetric(horizontal: 2),
                      color: accentColor,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      counter,
                      style: monospace?.copyWith(
                        fontSize: 11,
                        fontFeatures: const [FontFeature.tabularFigures()],
                        color: theme.colorScheme.onSurface.withValues(
                          alpha: 0.55,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

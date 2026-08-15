import 'dart:async';

import 'package:flutter/material.dart';
import 'package:voyager/core/vim/vim_session.dart';

/// What the host field needs to know about its Vim session while building.
///
/// Deliberately tiny: a field's build method only has to change two things
/// when the mode changes — the caret shape and which undo stack it uses — so
/// that's all this carries. Everything else (the mode badge, the search bar,
/// every text mutation) is handled by [VimTextScope] itself, above the field.
@immutable
class VimFieldBinding {
  const VimFieldBinding({this.mode, this.undoController, this.session});

  /// The current mode, or null when Vim is switched off for this field — in
  /// which case every getter below returns the field's ordinary defaults.
  final VimMode? mode;

  final UndoHistoryController? undoController;

  /// The live session, for fields that stack a `VimTextOverlay` and so need
  /// the caret offset, Visual selection and search matches to paint. Null when
  /// Vim is off for this field.
  final VimSession? session;

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
/// The `NORMAL` / `VISUAL` / `V-LINE` capsule hangs **inside** the field's
/// bottom-right by default (`Offset(-10, -8)` from that corner). That is
/// the right default: this overlay is a [CompositedTransformFollower] on
/// the root [Overlay], which does not flip or clamp, so hanging the pill
/// *outside* a field flush with the bottom of the screen (the todo page's
/// "Add task" composer) would paint over the bottom nav or off the window.
/// The `/` search bar already docks below and has that problem.
///
/// Opt into [modeBadgeOutside] only when the field is too short for the
/// pill to sit in that interior corner without covering the last characters
/// — it then hangs below-right, same family as the search bar. Do **not**
/// infer this from `multiline == false`; one-line boxes that are tall
/// enough (Add task, settings, dialogs) should keep the interior chip.
/// Pick it per call site.
class VimTextScope extends StatefulWidget {
  const VimTextScope({
    super.key,
    required this.enabled,
    required this.controller,
    required this.multiline,
    required this.builder,
    this.accentColor,
    this.modeBadgeOutside = false,
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

  final Color? accentColor;

  /// Hang the mode capsule below the field instead of inside its
  /// bottom-right. Default false — see the class doc for when to set this.
  final bool modeBadgeOutside;

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

  /// Live only while this field's focus is parked by an app switch — its
  /// presence *is* the "suspended" flag. See [_handleFocusChanged].
  AppLifecycleListener? _resumeListener;

  /// Whether the badge/search-bar overlay is mounted. Also gates the
  /// [CompositedTransformTarget] below — see [build].
  bool _overlayVisible = false;

  bool get _active => widget.enabled && widget.controller != null;

  @override
  void initState() {
    super.initState();
    _createSessionIfNeeded();
    _scopeNode.addListener(_handleFocusChanged);
  }

  @override
  void didUpdateWidget(covariant VimTextScope oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.enabled != widget.enabled ||
        oldWidget.controller != widget.controller) {
      _disposeSession();
      _createSessionIfNeeded();
      // The fresh session starts in Insert, so any overlay from the old one is
      // stale. Assigned directly rather than through [_syncOverlay]: a rebuild
      // already follows didUpdateWidget, so setState here would be redundant
      // at best and a "called during build" assertion at worst.
      if (_overlayVisible) {
        _overlayVisible = false;
        _portal.hide();
      }
    }
  }

  @override
  void dispose() {
    _endSuspension();
    _scopeNode.removeListener(_handleFocusChanged);
    _scopeNode.dispose();
    _disposeSession();
    super.dispose();
  }

  void _createSessionIfNeeded() {
    if (!_active) return;
    final session = VimSession(
      textController: widget.controller!,
      resolveEditableState: _resolveEditableState,
      isMultiline: () => widget.multiline,
    );
    session.modeListenable.addListener(_syncOverlay);
    session.searchListenable.addListener(_syncOverlay);
    _session = session;
  }

  /// Finds the focused field's [EditableTextState].
  ///
  /// `EditableText` builds a `Focus` around its own subtree, so the primary
  /// focus node's context always sits *inside* the `EditableText` element —
  /// making the state one ancestor walk away, with no [GlobalKey] on the
  /// field required. Resolved per mutation rather than cached: it costs a few
  /// parent-pointer hops, and only Normal-mode commands ever ask.
  EditableTextState? _resolveEditableState() {
    final context = FocusManager.instance.primaryFocus?.context;
    return context?.findAncestorStateOfType<EditableTextState>();
  }

  void _disposeSession() {
    final session = _session;
    if (session == null) return;
    session.modeListenable.removeListener(_syncOverlay);
    session.searchListenable.removeListener(_syncOverlay);
    session.dispose();
    _session = null;
  }

  void _handleFocusChanged() {
    if (_scopeNode.hasFocus) {
      // Focus is back — whether the framework handed it back after an app
      // switch or the user clicked in. Either way there is nothing left to
      // wait for.
      _endSuspension();
    } else if (_appIsBackgrounded) {
      // Not the user leaving the box. On desktop the framework parks the
      // primary focus whenever the app itself stops being `resumed` — an
      // Alt-Tab to another window is enough — and hands it back on resume
      // (`FocusManager._appLifecycleChange`). Resetting here is what used to
      // dump you into Insert on every app switch, and take the Visual range
      // with it. So the session is left exactly as it stands: mode, pending
      // command, `/` prompt and selection all still there when you come back.
      _watchForResume();
    } else {
      // A field's Vim state belongs to one editing session: leaving the box
      // drops back to Insert so the next click behaves like an ordinary field.
      _session?.reset();
    }
    _syncOverlay();
  }

  /// Whether the *app* — not just this field — is out of the foreground.
  ///
  /// Null until the first lifecycle message arrives, which reads as
  /// foreground: a focus loss that early is a real one.
  static bool get _appIsBackgrounded {
    final state = WidgetsBinding.instance.lifecycleState;
    return state != null && state != AppLifecycleState.resumed;
  }

  void _watchForResume() {
    _resumeListener ??= AppLifecycleListener(onResume: _handleAppResumed);
  }

  void _endSuspension() {
    _resumeListener?.dispose();
    _resumeListener = null;
  }

  /// The app is back in the foreground.
  ///
  /// [FocusManager] restores the node it suspended from a microtask of its
  /// own, queued ahead of this one — its lifecycle observer is registered when
  /// the binding is created, long before this listener. So by the time this
  /// runs the focus has either returned, in which case [_handleFocusChanged]
  /// has already cleared the suspension, or it is not going to: something else
  /// took focus while the app was away. That second case is an abandoned
  /// field, and it resets like any other, so a click into it later still lands
  /// in Insert.
  void _handleAppResumed() {
    scheduleMicrotask(() {
      if (!mounted || _resumeListener == null || _scopeNode.hasFocus) return;
      _endSuspension();
      _session?.reset();
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

  KeyEventResult _handleKey(FocusNode node, KeyEvent event) {
    final session = _session;
    if (session == null) return KeyEventResult.ignored;
    // Only claim keys destined for a real text field. The scope's subtree can
    // also contain focusable chrome (a suffix icon button, say), and Vim has
    // no business intercepting keys typed at those.
    final focused = FocusManager.instance.primaryFocus?.context;
    if (focused?.findAncestorStateOfType<EditableTextState>() == null) {
      return KeyEventResult.ignored;
    }
    return session.handleKey(event);
  }

  @override
  Widget build(BuildContext context) {
    final session = _session;
    if (session == null) {
      return widget.builder(context, const VimFieldBinding());
    }

    final accent = widget.accentColor ?? Theme.of(context).colorScheme.primary;

    // Only the mode notifier drives this rebuild. The HUD text and the search
    // bar change far more often and are listened to separately, inside the
    // overlay, so typing a command never rebuilds the field.
    Widget field = KeyedSubtree(
      key: _fieldKey,
      child: ValueListenableBuilder<VimMode>(
        valueListenable: session.modeListenable,
        builder: (context, mode, _) => widget.builder(
          context,
          VimFieldBinding(
            mode: mode,
            undoController: session.undoController,
            session: session,
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
        overlayChildBuilder: (context) => _VimFieldOverlay(
          link: _link,
          session: session,
          accentColor: accent,
          modeBadgeOutside: widget.modeBadgeOutside,
        ),
        child: field,
      ),
    );
  }
}

/// The mode badge and the `/` search bar, both hung off the field's
/// [LayerLink] so they track it through scrolling, dialogs and popovers
/// without any measurement code.
class _VimFieldOverlay extends StatelessWidget {
  const _VimFieldOverlay({
    required this.link,
    required this.session,
    required this.accentColor,
    required this.modeBadgeOutside,
  });

  final LayerLink link;
  final VimSession session;
  final Color accentColor;
  final bool modeBadgeOutside;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Positioned(
          left: 0,
          top: 0,
          child: CompositedTransformFollower(
            link: link,
            showWhenUnlinked: false,
            targetAnchor: Alignment.bottomRight,
            followerAnchor: modeBadgeOutside
                ? Alignment.topRight
                : Alignment.bottomRight,
            offset: modeBadgeOutside
                ? const Offset(-10, 6)
                : const Offset(-10, -8),
            child: _VimModeBadge(session: session, accentColor: accentColor),
          ),
        ),
        Positioned(
          left: 0,
          top: 0,
          child: CompositedTransformFollower(
            link: link,
            showWhenUnlinked: false,
            targetAnchor: Alignment.bottomLeft,
            followerAnchor: Alignment.topLeft,
            offset: const Offset(0, 6),
            child: _VimSearchBar(session: session, accentColor: accentColor),
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
  const _VimModeBadge({required this.session, required this.accentColor});

  final VimSession session;
  final Color accentColor;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return IgnorePointer(
      child: ValueListenableBuilder<VimMode>(
        valueListenable: session.modeListenable,
        builder: (context, mode, _) {
          if (mode == VimMode.insert) return const SizedBox.shrink();
          return ValueListenableBuilder<String>(
            valueListenable: session.hudListenable,
            builder: (context, pending, _) {
              return DecoratedBox(
                decoration: BoxDecoration(
                  // A flat translucent fill rather than a GlassSurface: this
                  // sits on screen for the whole time you are in Normal mode,
                  // and a persistent BackdropFilter would cost a saveLayer
                  // every frame for a 60px pill.
                  color: Color.alphaBlend(
                    accentColor.withValues(alpha: 0.22),
                    theme.colorScheme.surface,
                  ),
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(
                    color: accentColor.withValues(alpha: 0.45),
                    width: 1,
                  ),
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 2,
                  ),
                  child: Text(
                    pending.isEmpty ? mode.label : '${mode.label}  $pending',
                    style: theme.textTheme.labelSmall?.copyWith(
                      fontSize: 10,
                      height: 1.2,
                      letterSpacing: 0.8,
                      fontFeatures: const [FontFeature.tabularFigures()],
                      color: theme.colorScheme.onSurface.withValues(
                        alpha: 0.85,
                      ),
                    ),
                  ),
                ),
              );
            },
          );
        },
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

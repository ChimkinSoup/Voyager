// The mutable fields below are private, and a named parameter cannot be, so
// `this._message` is not spellable here.
// ignore_for_file: prefer_initializing_formals

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:voyager/core/motion/motion.dart';
import 'package:voyager/core/widgets/glass_button.dart';
import 'package:voyager/core/widgets/top_chrome_inset.dart';

/// A button on a toast: something the user can do about what the toast just
/// told them, instead of having to go find the control themselves.
class VoyagerToastAction {
  const VoyagerToastAction({required this.label, required this.onPressed});

  final String label;

  /// Runs before the toast dismisses itself.
  final VoidCallback onPressed;
}

/// A toast that is on screen, and the handle to the two things that can still
/// happen to it: it can change what it says, or it can go away.
///
/// [update] exists so a toast that starts as "working" can *become* its own
/// result — the spinner swaps for a tick and the words change, in the one card
/// the user is already looking at. Dismissing and raising a second toast would
/// cross-fade one card out while another slides in over it, which reads as a
/// flicker rather than as an answer.
class VoyagerToast {
  VoyagerToast._({
    required String message,
    required IconData? icon,
    required this.actions,
    required Duration? dwell,
    required this.linger,
  }) : _message = message,
       _icon = icon,
       _dwell = dwell;

  final List<VoyagerToastAction> actions;
  final Duration linger;

  String _message;
  IconData? _icon;
  Duration? _dwell;

  /// How many times this toast has been raised. A repeat of something already
  /// on screen joins the card it is already on rather than opening a second
  /// one, so three quick copies read as one line with a ×3 instead of three
  /// cards the user has to sit through one after another.
  int _count = 1;

  /// Bumped by every [update] so the toast's dwell clock restarts on each one:
  /// words the user has not read yet deserve their own full countdown, not
  /// whatever was left of the previous message's.
  int _generation = 0;

  final _dismissRequested = ValueNotifier<bool>(false);
  late final _ToastStack _stack;
  var _dismissed = false;
  var _removed = false;
  var _built = false;
  final _done = Completer<void>();

  /// Completes once the toast is off screen and its entry is out of the
  /// overlay, however it got there — the dwell ran out, an action dismissed
  /// it, or another toast took its place.
  ///
  /// Exists so a caller holding the toast can drop what it captured for the
  /// toast's sake. [showSoftDeleteUndoToast] is the one that needs it: its
  /// standing offer holds a whole pre-delete snapshot, and without a signal
  /// there is no moment at which to let go of it.
  Future<void> get done => _done.future;

  /// Whether the toast is on its way out — or gone — and so will ignore
  /// [update]. True from the moment it is dismissed, before [done] completes.
  bool get isDismissed => _dismissed;

  void _finish() {
    if (_removed) return;
    _removed = true;
    _stack.remove(this);
    _dismissRequested.dispose();
    _done.complete();
  }

  /// Guards the window between construction and [_insertInto], where [_stack]
  /// is still unassigned. [showVoyagerToastIn] closes it immediately, and the
  /// constructor is private so nothing else can open it — but the class hands
  /// out a mutable handle, and a `late final` read would fail as a
  /// `LateInitializationError` rather than as the contract violation it is.
  var _inserted = false;

  void _insertInto(_ToastStack stack) {
    _inserted = true;
    _stack = stack;
    stack.add(this);
  }

  /// Counts another raise of what this card already says: it gains a ×N and
  /// its dwell restarts, so the repeat gets its own full countdown rather than
  /// whatever was left of the one the user has already been watching.
  void _repeat() {
    _count++;
    _generation++;
    _stack.rebuild();
  }

  /// Rewrites what the toast says without disturbing the card it says it in.
  ///
  /// Passing [icon] is what turns "still working" into "done": the spinner is
  /// only shown while there is no icon. A no-op once the toast is dismissed,
  /// so a result arriving after the user waved the toast away is dropped
  /// rather than resurrecting it.
  void update({String? message, IconData? icon, Duration? dwell}) {
    assert(_inserted, 'update() before the toast was inserted into an overlay');
    if (_dismissed) return;
    if (message != null) _message = message;
    if (icon != null) _icon = icon;
    if (dwell != null) _dwell = dwell;
    _generation++;
    _stack.rebuild();
  }

  /// Fades the toast out, then removes the overlay entry.
  void dismiss() {
    assert(
      _inserted,
      'dismiss() before the toast was inserted into an overlay',
    );
    if (_dismissed) return;
    _dismissed = true;
    // Dismissed before the toast ever built — the stack builds on the next
    // frame, and a fetch that fails on a host lookup settles well inside that
    // gap. There is no State yet to hear the notifier, so nothing would ever
    // take the toast back out of the stack and it would be pinned on screen
    // for the life of the app. Drop it directly instead of animating.
    if (!_built) {
      _finish();
      return;
    }
    _dismissRequested.value = true;
  }
}

/// Shows a sleek, non-intrusive toast at the top of the screen — while a piece
/// of work is in flight, or to confirm a one-shot action.
///
/// Leads with a spinner unless [icon] is given, which is what separates
/// "still working" from "done".
///
/// [actions] turn the toast into something the pointer can reach: without them
/// it stays click-through, so a toast over a form never eats a click meant for
/// the field behind it.
///
/// [dwell] auto-dismisses the toast after that long. The countdown is held
/// while the pointer is over the toast — an offer the user is still reading is
/// not one to take away — and restarts with [linger] once they move off, which
/// is deliberately long enough to finish the sentence they were on rather than
/// a token grace period.
VoyagerToast showVoyagerToast(
  BuildContext context, {
  required String message,
  IconData? icon,
  List<VoyagerToastAction> actions = const [],
  Duration? dwell,
  Duration linger = const Duration(seconds: 4),
}) => showVoyagerToastIn(
  Overlay.of(context, rootOverlay: true),
  message: message,
  icon: icon,
  actions: actions,
  dwell: dwell,
  linger: linger,
);

/// [showVoyagerToast] for a caller that resolved its overlay earlier.
///
/// Work that reports on itself has usually already awaited something by the
/// time it has news, and the [BuildContext] it started from may be gone. The
/// root overlay is not: it belongs to the app rather than to the surface that
/// raised the toast, so resolving it up front — next to the
/// [ScaffoldMessengerState] such callers already capture — is what makes a
/// toast safe to finish later.
VoyagerToast showVoyagerToastIn(
  OverlayState overlay, {
  required String message,
  IconData? icon,
  List<VoyagerToastAction> actions = const [],
  Duration? dwell,
  Duration linger = const Duration(seconds: 4),
}) {
  final stack = _ToastStack.of(overlay);
  final twin = stack.twinOf(
    message: message,
    icon: icon,
    dwell: dwell,
    actions: actions,
  );
  if (twin != null) {
    twin._repeat();
    return twin;
  }

  final toast = VoyagerToast._(
    message: message,
    icon: icon,
    actions: actions,
    dwell: dwell,
    linger: linger,
  );
  toast._insertInto(stack);
  return toast;
}

/// The toasts standing in one overlay, oldest first, and the single entry that
/// draws them as a column.
///
/// One entry for the lot rather than one each: a toast used to position itself
/// absolutely at the top of the window, so a second one simply painted over
/// the first — two cards, at most one of them legible, and a click that could
/// land on the hidden one's button. Laid out in a column they sit under each
/// other instead, and the column reflows on its own as cards come and go.
class _ToastStack {
  _ToastStack._(this._overlay);

  static _ToastStack of(OverlayState overlay) =>
      _stacks[overlay] ??= _ToastStack._(overlay);

  final OverlayState _overlay;
  final _toasts = <VoyagerToast>[];
  OverlayEntry? _entry;

  /// The card a repeat of [message] should join, or null when this is news.
  ///
  /// Only a plain notice coalesces. Something with a button is an offer about
  /// one particular thing and cannot stand for two of them, and a toast that
  /// is still spinning — no icon, no dwell — is work in flight that will
  /// rewrite itself with its own result.
  ///
  /// Both ends need a dwell. A card that has none is staying up until its
  /// owner takes it away, and joining one would hand the repeat a countdown
  /// that never runs — the toast would sit there counting up, with no caller
  /// left holding a handle to dismiss it.
  VoyagerToast? twinOf({
    required String message,
    required IconData? icon,
    required Duration? dwell,
    required List<VoyagerToastAction> actions,
  }) {
    if (icon == null || dwell == null || actions.isNotEmpty) return null;
    for (final toast in _toasts.reversed) {
      if (toast._dismissed || toast.actions.isNotEmpty) continue;
      if (toast._dwell == null) continue;
      if (toast._message == message && toast._icon == icon) return toast;
    }
    return null;
  }

  void add(VoyagerToast toast) {
    _toasts.add(toast);
    // The entry is only in the overlay while there is something to draw. A
    // host that stayed put would sit *under* every dialog and popover opened
    // after the app's first toast, since a later insert paints above an
    // earlier one.
    if (_entry == null) {
      _entry = OverlayEntry(builder: _build);
      _overlay.insert(_entry!);
    } else {
      rebuild();
    }
  }

  void remove(VoyagerToast toast) {
    if (!_toasts.remove(toast)) return;
    if (_toasts.isEmpty) {
      _entry!.remove();
      _entry = null;
      return;
    }
    rebuild();
  }

  void rebuild() => _entry?.markNeedsBuild();

  Widget _build(BuildContext context) => Positioned(
    top: MediaQuery.paddingOf(context).top + 8,
    left: 0,
    right: 0,
    // Below the live workout's island rather than on top of it. Listened to
    // rather than read so a workout that starts or ends under a standing toast
    // moves it, instead of leaving it parked over the island until it expires.
    child: ValueListenableBuilder<double>(
      valueListenable: topChromeInset,
      builder: (context, inset, child) => Padding(
        padding: EdgeInsets.only(top: inset),
        child: child,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final toast in _toasts)
            _VoyagerToast(
              // Keyed on the toast so a card keeps its State — and with it its
              // entry animation and its dwell clock — when one above it goes
              // away and the rest move up a place.
              key: ObjectKey(toast),
              message: toast._message,
              icon: toast._icon,
              count: toast._count,
              actions: toast.actions,
              dwell: toast._dwell,
              linger: toast.linger,
              generation: toast._generation,
              onBuilt: () => toast._built = true,
              onDismissRequested: toast.dismiss,
              dismissRequested: toast._dismissRequested,
              onDismissed: toast._finish,
            ),
        ],
      ),
    ),
  );
}

/// The stack standing in each overlay. An [Expando] rather than a map so an
/// overlay that goes away takes its stack with it.
final _stacks = Expando<_ToastStack>('toast stack');

/// The longest a hovering pointer holds the dwell open.
///
/// The hold used to be indefinite, which depends on a matching `onExit` ever
/// arriving. It does not always: minimizing the window or losing focus with
/// the cursor inside the card delivers no exit event, and the toast stays
/// pinned for the life of the app — still holding its snapshot, still offering
/// an undo whose version arithmetic went stale hours ago. A minute is far
/// longer than reading the card takes and still terminates on its own.
const _kMaxHoverHold = Duration(seconds: 60);

/// The label color for a toast's action buttons.
///
/// The buttons are tinted in the accent, so the accent cannot also be the
/// words: a pale accent on the light wafer — and any accent at all on the
/// near-solid dark plate — paints the label the same color as what is behind
/// it. Pick whichever end of the scheme stands further off the fill that is
/// actually painted, the way the accent's own on-color is picked.
Color _toastActionLabelColor(ThemeData theme) {
  final scheme = theme.colorScheme;
  final fill = Color.alphaBlend(
    scheme.primary.withValues(
      alpha: GlassButton.defaultGlassOpacity(
        theme.brightness == Brightness.dark,
      ),
    ),
    scheme.surfaceContainerHighest,
  );
  return _contrast(scheme.onSurface, fill) >= _contrast(scheme.onPrimary, fill)
      ? scheme.onSurface
      : scheme.onPrimary;
}

double _contrast(Color a, Color b) {
  final x = a.computeLuminance();
  final y = b.computeLuminance();
  return (math.max(x, y) + 0.05) / (math.min(x, y) + 0.05);
}

class _VoyagerToast extends StatefulWidget {
  const _VoyagerToast({
    super.key,
    required this.message,
    required this.icon,
    required this.count,
    required this.actions,
    required this.dwell,
    required this.linger,
    required this.generation,
    required this.onBuilt,
    required this.onDismissRequested,
    required this.dismissRequested,
    required this.onDismissed,
  });

  final String message;
  final IconData? icon;
  final int count;
  final List<VoyagerToastAction> actions;
  final Duration? dwell;
  final Duration linger;
  final int generation;
  final VoidCallback onBuilt;
  final VoidCallback onDismissRequested;
  final ValueNotifier<bool> dismissRequested;
  final VoidCallback onDismissed;

  @override
  State<_VoyagerToast> createState() => _VoyagerToastState();
}

class _VoyagerToastState extends State<_VoyagerToast>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late final AnimationController _controller;
  Timer? _dwellTimer;
  var _hovering = false;
  var _leaving = false;

  @override
  void initState() {
    super.initState();
    // Tells the handle there is now a State to hear a dismissal, so one that
    // arrives before this point can take the short way out.
    widget.onBuilt();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 180),
    )..forward();
    WidgetsBinding.instance.addObserver(this);
    widget.dismissRequested.addListener(_handleDismissRequested);
    // A listener only hears *changes*, so a flag already set before this build
    // would otherwise go unheard. Off a post-frame callback because
    // `onDismissed` removes the overlay entry, which must not run during
    // build.
    if (widget.dismissRequested.value) {
      // Guarded: `_handleDismissRequested` drives `_controller`, and an entry
      // removed between this frame and the callback has already disposed it.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _handleDismissRequested();
      });
    }
    // The full dwell, always — a toast raised by another toast's button starts
    // its own clock here rather than inheriting what was left of the one it
    // replaced, and the hover it is born under then holds that clock.
    _restartDwell(_dwellNow());
  }

  @override
  void didUpdateWidget(_VoyagerToast oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Only on a real [VoyagerToast.update]. The entry also rebuilds for
    // reasons of its own — a theme change, a resize — and those must not keep
    // pushing the dismissal out.
    if (widget.generation != oldWidget.generation) _restartDwell(_dwellNow());
    // The identity is stable today — `_insertInto`'s builder closes over the
    // one notifier — but a State subscribed to the old notifier and
    // unsubscribed from the new one would leave the toast unable to hear its
    // own dismissal, and `dispose` would unsubscribe a listener it never
    // added.
    if (widget.dismissRequested != oldWidget.dismissRequested) {
      oldWidget.dismissRequested.removeListener(_handleDismissRequested);
      widget.dismissRequested.addListener(_handleDismissRequested);
    }
  }

  /// The dwell to run from right now: the hover hold while the pointer is on
  /// the card, otherwise the full countdown.
  ///
  /// Read fresh rather than captured, so a [VoyagerToast.update] that
  /// introduces a dwell where there was none still respects a hover that
  /// started before it. `_handleHover` only fires on enter and exit, so
  /// nothing else would re-apply the hold.
  Duration? _dwellNow() {
    if (widget.dwell == null) return null;
    return _hovering ? _kMaxHoverHold : widget.dwell;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // A pointer that was over the card when the window went away will never
    // deliver its `onExit`. Treat losing the foreground as the exit.
    if (state != AppLifecycleState.resumed && _hovering) _handleHover(false);
  }

  void _restartDwell(Duration? after) {
    _dwellTimer?.cancel();
    if (after == null) return;
    _dwellTimer = Timer(after, widget.onDismissRequested);
  }

  void _handleHover(bool hovering) {
    _hovering = hovering;
    if (widget.dwell == null) return;
    _restartDwell(hovering ? _kMaxHoverHold : widget.linger);
  }

  void _handleDismissRequested() {
    if (!widget.dismissRequested.value || _leaving) return;
    _leaving = true;
    _dwellTimer?.cancel();
    _controller.reverse().whenCompleteOrCancel(widget.onDismissed);
  }

  @override
  void dispose() {
    _dwellTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    widget.dismissRequested.removeListener(_handleDismissRequested);
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final reduced = VoyagerMotion.reduced(context);
    final interactive = widget.actions.isNotEmpty;

    Widget card = Material(
      color: theme.colorScheme.surfaceContainerHighest,
      elevation: 4,
      borderRadius: BorderRadius.circular(20),
      child: Padding(
        padding: EdgeInsets.fromLTRB(16, 10, interactive ? 10 : 16, 10),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 14,
              height: 14,
              child: widget.icon == null
                  ? CircularProgressIndicator(
                      strokeWidth: 2,
                      color: theme.colorScheme.primary,
                    )
                  : Icon(
                      widget.icon,
                      size: 14,
                      color: theme.colorScheme.primary,
                    ),
            ),
            const SizedBox(width: 10),
            Flexible(
              child: Text(
                widget.message,
                style: theme.textTheme.labelLarge,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (widget.count > 1) ...[
              const SizedBox(width: 8),
              Text(
                '×${widget.count}',
                style: theme.textTheme.labelMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
            for (final action in widget.actions) ...[
              // Wide enough that the button reads as its own object rather
              // than as the end of the sentence next to it.
              const SizedBox(width: 16),
              GlassButton(
                onPressed: () {
                  // A card already on its way out does not answer to the
                  // pointer. Replacement is not atomic: `dismiss()` only
                  // starts a 180 ms reverse, and the entry stays in the
                  // overlay for all of it, underneath whichever toast took
                  // its place — while `RenderOpacity` goes on hit-testing its
                  // child at opacity zero. Two cards centred on the same point
                  // with different widths leave the wider one's button
                  // exposed, so a click on an invisible Undo restored the
                  // *previous* deletion with no visible cause.
                  //
                  // Checked here rather than by rebuilding the card as an
                  // [IgnorePointer]: `dismiss()` is reachable from a locked
                  // phase — one delete replacing another's offer mid-build —
                  // and marking the element dirty from there throws.
                  if (widget.dismissRequested.value) return;
                  action.onPressed();
                  widget.onDismissRequested();
                },
                label: action.label,
                dense: true,
                color: theme.colorScheme.primary,
                textColor: _toastActionLabelColor(theme),
              ),
            ],
          ],
        ),
      ),
    );

    if (interactive) {
      card = MouseRegion(
        onEnter: (_) => _handleHover(true),
        onExit: (_) => _handleHover(false),
        child: card,
      );
    }

    Widget body = Center(
      child: ConstrainedBox(
        // The sheet under this toast runs nearly the full window; a long
        // message plus a button has to wrap the ellipsis rather than the edge.
        constraints: BoxConstraints(
          maxWidth: MediaQuery.sizeOf(context).width - 32,
        ),
        child: FadeTransition(
          opacity: _controller,
          child: SlideTransition(
            position:
                Tween<Offset>(
                  begin: reduced ? Offset.zero : const Offset(0, -0.3),
                  end: Offset.zero,
                ).animate(
                  CurvedAnimation(
                    parent: _controller,
                    curve: reduced ? Curves.easeOut : VoyagerSpring.moveCurve,
                  ),
                ),
            child: card,
          ),
        ),
      ),
    );

    // A toast with nothing to press stays out of the way entirely.
    if (!interactive) body = IgnorePointer(child: body);

    // The card collapses as it leaves rather than vanishing and dropping the
    // stack a notch. The gap rides inside the collapse, so a card taken from
    // the middle takes its spacing with it and the ones below close up as one
    // movement.
    //
    // On the way *out* only. A [SizeTransition] driven straight off the
    // controller would also grow the card in, which means a clip to nothing
    // for the first frames it is on screen — and a card with no height has no
    // button to press. A delete's Undo was unhittable for the whole entry
    // animation. Read through an [AnimatedBuilder] rather than switched with
    // `setState`, because `_leaving` is set from a locked phase.
    return AnimatedBuilder(
      animation: _controller,
      child: Padding(padding: const EdgeInsets.only(bottom: 8), child: body),
      builder: (context, child) => ClipRect(
        child: Align(
          alignment: Alignment.topCenter,
          heightFactor: _leaving
              ? Curves.easeOut.transform(_controller.value).clamp(0.0, 1.0)
              : 1.0,
          child: child,
        ),
      ),
    );
  }
}

import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:voyager/features/gaia/companion/gaia_button.dart';

/// One choice in a [GaiaNotchItem].
class GaiaNotchOption<T> {
  const GaiaNotchOption({
    required this.value,
    required this.label,
    this.detail,
    this.icon,
  });

  final T value;
  final String label;

  /// Muted text after the label, such as the model a tier runs on.
  final String? detail;

  /// Drawn before the label in [color], and moving with it. [lit] while
  /// hovered, focused or selected.
  final Widget Function(Color color, {required bool lit})? icon;
}

/// [text], after [option]'s icon if it has one.
Widget _withIcon(
  GaiaNotchOption<Object?>? option,
  Widget text, {
  Key? key,
  required Color color,
  required bool lit,
}) {
  final icon = option?.icon;
  if (icon == null) return KeyedSubtree(key: key, child: text);
  return Row(
    key: key,
    mainAxisSize: MainAxisSize.min,
    children: [
      icon(color, lit: lit),
      const SizedBox(width: 8),
      text,
    ],
  );
}

/// A group in a [GaiaNotch]: a trigger showing the selected option, which
/// opens all of them.
class GaiaNotchItem<T> {
  const GaiaNotchItem({
    required this.options,
    required this.value,
    required this.onChanged,
  });

  final List<GaiaNotchOption<T>> options;

  /// The selected option's value. The notch keeps no selection of its own:
  /// [onChanged] asks, and a parent that turns the change down keeps [value].
  final T value;

  /// May answer later, as after a confirmation: until its future completes
  /// the trigger shows the option picked, then whatever [value] is.
  final FutureOr<void> Function(T value) onChanged;

  int get _selected => options.indexWhere((option) => option.value == value);

  // Called here, where T is the real one: read through the notch's
  // GaiaNotchItem<Object?>, [onChanged] fails its runtime type check.
  FutureOr<void> _pick(int index) => onChanged(options[index].value);
}

/// Gaia's notch (after the shadcn-style Notch): a bar of triggers in a
/// [GaiaGlowRing], as Gaia's buttons are, that morphs on a spring into the
/// options of the one clicked. Opening, the selection rises out of its
/// trigger into its row while the other options come in one by one out of
/// a blur. Closing runs it backwards: the option picked (or the selected
/// one, on Esc or a click outside) settles back into the trigger, and the
/// rest blur out bottom first, drawn in toward it as the ring shrinks. Up
/// and Down or Tab move between options, Enter or Space picks.
///
/// Open, it grows up and to the left from its bottom right corner, over
/// whatever is there, while its place in the layout keeps the bar's size.
/// Closed, it sits in that place itself, so whatever it's in (as Gaia's
/// composer) still counts the cursor over it as over itself.
class GaiaNotch extends StatefulWidget {
  const GaiaNotch({super.key, required this.items});

  final List<GaiaNotchItem<Object?>> items;

  @override
  State<GaiaNotch> createState() => _GaiaNotchState();
}

/// The shell's morph, and each option's entrance.
const _shellSpring = SpringDescription(mass: 1, stiffness: 380, damping: 34);
const _optionSpring = SpringDescription(mass: 1, stiffness: 420, damping: 30);

/// Long enough for either spring to settle.
const _springTime = Duration(milliseconds: 400);
const _fade = Duration(milliseconds: 150);

/// When the first option starts in, and how far behind it each next one is.
const _optionsDelay = Duration(milliseconds: 80);
const _optionsStagger = Duration(milliseconds: 45);

/// Going out, bottom first: quicker, so each is gone before it's drawn in
/// on top of the option landing.
const _leaveStagger = Duration(milliseconds: 30);
const _leaveSpeed = 1.5;

const _bright = Color(0xFFF5F5F5);
const _muted = Color(0xFFA3A3A3);
const _dim = Color(0xFFD4D4D4);
const _textStyle = TextStyle(fontSize: 13, fontWeight: FontWeight.w500);

/// The closed bar's, smaller than the open options'.
const _triggerStyle = TextStyle(fontSize: 12, fontWeight: FontWeight.w500);
const _radius = 12.0;

/// An option on its way between item [item]'s trigger and its row: up
/// into the row as the notch opens, or down into the trigger as it closes.
/// The colours are how the row looks.
class _Flight {
  const _Flight({
    required this.item,
    required this.option,
    required this.fill,
    required this.border,
    required this.label,
    required this.detail,
  });

  final int item;
  final int option;
  final Color fill;
  final Color border;
  final Color label;
  final Color detail;
}

class _GaiaNotchState extends State<GaiaNotch> with TickerProviderStateMixin {
  final _link = LayerLink();
  final _portal = OverlayPortalController();

  /// The open item's index; null while the bar shows.
  int? _open;

  /// The item whose options are drawn: the open one, or the one closing.
  /// While there is one, the shell is in the overlay.
  int? _shown;

  /// The options fading in, and the bar out.
  late final _panel = AnimationController(vsync: this, duration: _fade);

  /// The shell's morph either way, and everything that moves with it.
  late final _move = AnimationController(vsync: this, duration: _springTime)
    ..addStatusListener((status) {
      if (status == AnimationStatus.completed) _settle();
    });
  late final _moved = CurvedAnimation(
    parent: _move,
    curve: const _SpringCurve(_shellSpring),
  );

  _Flight? _flight;

  /// An option picked but not yet answered for, shown in its trigger.
  ({int item, int option})? _pending;

  var _hovered = false;

  /// The shell, moved between its place and the overlay with its state.
  final _shellKey = GlobalKey();

  /// What's inside the shell, which positions are measured in: they hold
  /// while it resizes, unlike positions on screen through the overlay.
  final _frame = GlobalKey();

  /// The shown options' rows and texts, and the triggers and theirs.
  final _rows = <int, GlobalKey>{};
  final _texts = <int, GlobalKey>{};
  final _triggers = <int, GlobalKey>{};
  final _triggerTexts = <int, GlobalKey>{};

  /// What had the focus when the notch opened, which gets it back on close.
  FocusNode? _returnFocus;

  @override
  void dispose() {
    _moved.dispose();
    _move.dispose();
    _panel.dispose();
    super.dispose();
  }

  /// The option the item shows: the one picked, or else the selected one.
  int _current(int item) {
    final pending = _pending;
    return pending != null && pending.item == item
        ? pending.option
        : widget.items[item]._selected;
  }

  void _openItem(int index) {
    _returnFocus = FocusManager.instance.primaryFocus;
    final selected = _current(index);
    setState(() {
      _open = index;
      _shown = index;
      _flight = selected < 0 ? null : _flightOf(index, selected, active: true);
    });
    _portal.show();
    _panel.forward(from: 0);
    _move.forward(from: 0);
  }

  /// Lands [option] (the selected one if null) in the trigger.
  void _close({int? option}) {
    final open = _open;
    if (open == null) return;
    final selected = widget.items[open]._selected;
    final landing = option ?? _current(open);
    setState(() {
      _open = null;
      _flight = landing < 0
          ? null
          : _flightOf(open, landing, active: landing == selected);
    });
    _move.forward(from: 0);
    _returnFocus?.requestFocus();
    _returnFocus = null;
  }

  /// The morph done: a flight is over, and once closed the shell goes back
  /// to its place.
  void _settle() {
    setState(() {
      _flight = null;
      if (_open == null) _shown = null;
    });
    if (_open == null) _portal.hide();
  }

  /// How the option's row looks: a picked one other than the selected was
  /// hovered or focused to be picked.
  _Flight _flightOf(int item, int option, {required bool active}) {
    final accent = Theme.of(context).colorScheme.primary;
    return _Flight(
      item: item,
      option: option,
      fill: active
          ? accent.withValues(alpha: 0.85)
          : Colors.white.withValues(alpha: 0.05),
      border: active
          ? Color.lerp(accent, Colors.white, 0.2)!
          : Colors.transparent,
      label: Colors.white,
      detail: active ? Colors.white.withValues(alpha: 0.75) : _muted,
    );
  }

  void _select(int item, int option) {
    final pending = (item: item, option: option);
    _pending = pending;
    // Closed first, so a confirmation the change opens has the focus.
    _close(option: option);
    final answer = widget.items[item]._pick(option);
    void answered() {
      if (mounted && _pending == pending) setState(() => _pending = null);
    }

    if (answer is Future<void>) {
      answer.whenComplete(answered);
    } else {
      answered();
    }
  }

  @override
  Widget build(BuildContext context) {
    final shown = _shown != null && _shown! < widget.items.length
        ? _shown
        : null;
    return OverlayPortal(
      controller: _portal,
      overlayChildBuilder: (context) => Align(
        alignment: Alignment.topLeft,
        child: CompositedTransformFollower(
          link: _link,
          showWhenUnlinked: false,
          targetAnchor: Alignment.bottomRight,
          followerAnchor: Alignment.bottomRight,
          child: TapRegion(
            onTapOutside: (_) => _close(),
            // Inside a text field's group too, so a notch in a field's
            // trailing (as in Gaia's composer) doesn't take its focus.
            child: TextFieldTapRegion(child: _shell(shown)),
          ),
        ),
      ),
      child: CompositedTransformTarget(
        link: _link,
        child: shown == null
            ? _shell(null)
            // Holds the bar's place while the shell is in the overlay; the
            // ring's width round it.
            : Visibility(
                visible: false,
                maintainSize: true,
                maintainAnimation: true,
                maintainState: true,
                child: Padding(
                  padding: const EdgeInsets.all(1),
                  child: _Bar(
                    items: widget.items,
                    pending: _pending,
                    onOpen: (_) {},
                    fade: 1,
                  ),
                ),
              ),
      ),
    );
  }

  /// The ring, sizing itself to what's inside on the spring, with a shadow
  /// as far as the options show.
  Widget _shell(int? shown) {
    final open = _open != null && shown != null;
    final flight = _flight;
    return MouseRegion(
      key: _shellKey,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: AnimatedBuilder(
        animation: Listenable.merge([_panel, _move]),
        builder: (context, ring) => DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(_radius),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(
                  alpha:
                      0.55 *
                      (open
                          ? _panel.value
                          : shown != null
                          ? 1 - _move.value
                          : 0),
                ),
                offset: const Offset(0, 12),
                blurRadius: 40,
                spreadRadius: -8,
              ),
            ],
          ),
          child: ring,
        ),
        child: GaiaGlowRing(
          radius: _radius,
          hovered: _hovered,
          child: AnimatedSize(
            duration: _springTime,
            curve: const _SpringCurve(_shellSpring),
            alignment: Alignment.bottomRight,
            child: Stack(
              key: _frame,
              alignment: Alignment.bottomRight,
              clipBehavior: Clip.none,
              children: [
                _Ghost(
                  sizes: !open,
                  child: IgnorePointer(
                    ignoring: open,
                    child: ExcludeFocus(
                      excluding: open,
                      child: AnimatedBuilder(
                        animation: Listenable.merge([_panel, _move]),
                        builder: (context, _) => _Bar(
                          items: widget.items,
                          pending: _pending,
                          onOpen: _openItem,
                          fade: open
                              ? 1 - _panel.value
                              : shown != null
                              ? _move.value
                              : 1,
                          frame: _frame,
                          triggers: _triggers,
                          triggerTexts: _triggerTexts,
                          rows: _rows,
                          texts: _texts,
                          flight: flight,
                          // At 1 in the trigger, at 0 in the row.
                          at: open ? ReverseAnimation(_moved) : _moved,
                        ),
                      ),
                    ),
                  ),
                ),
                if (shown != null)
                  _Ghost(
                    sizes: open,
                    // On its way out: no longer clickable or focusable.
                    child: IgnorePointer(
                      ignoring: !open,
                      child: ExcludeFocus(
                        excluding: !open,
                        child: FadeTransition(
                          // Closing, each option fades out on its own.
                          opacity: open ? _panel : kAlwaysCompleteAnimation,
                          child: _Options(
                            key: ValueKey(shown),
                            item: widget.items[shown],
                            frame: _frame,
                            rows: _rows,
                            texts: _texts,
                            trigger: _triggerTexts.putIfAbsent(
                              shown,
                              GlobalKey.new,
                            ),
                            hidden: flight?.item == shown
                                ? flight!.option
                                : null,
                            leaving: open ? null : _move,
                            drawnIn: open ? null : _moved,
                            onSelect: (index) => _select(shown, index),
                            onClose: _close,
                          ),
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

/// [child], counting toward its parent's size only while it [sizes]. When
/// it doesn't, it hangs from its parent's bottom right corner, still
/// painted but taking no room, and not hit.
class _Ghost extends SingleChildRenderObjectWidget {
  const _Ghost({required this.sizes, required super.child});

  final bool sizes;

  @override
  RenderObject createRenderObject(BuildContext context) => _RenderGhost(sizes);

  @override
  void updateRenderObject(BuildContext context, _RenderGhost renderObject) {
    renderObject.sizes = sizes;
  }
}

class _RenderGhost extends RenderShiftedBox {
  _RenderGhost(this._sizes) : super(null);

  bool _sizes;
  set sizes(bool value) {
    if (value == _sizes) return;
    _sizes = value;
    markNeedsLayout();
  }

  @override
  void performLayout() {
    final child = this.child!;
    child.layout(constraints.loosen(), parentUsesSize: true);
    size = constraints.constrain(_sizes ? child.size : Size.zero);
    (child.parentData! as BoxParentData).offset = _sizes
        ? Offset.zero
        : -child.size.bottomRight(Offset.zero);
  }
}

/// The triggers, with dotted dividers between them. All but a [flight]'s
/// trigger show at [fade]. The shell's bar keys its triggers and their
/// texts in [triggers] and [triggerTexts], and flies its [flight] between
/// its trigger and its row in [rows] and [texts], measured in [frame].
class _Bar extends StatelessWidget {
  const _Bar({
    required this.items,
    required this.pending,
    required this.onOpen,
    required this.fade,
    this.frame,
    this.triggers,
    this.triggerTexts,
    this.rows,
    this.texts,
    this.flight,
    this.at = kAlwaysCompleteAnimation,
  });

  final List<GaiaNotchItem<Object?>> items;
  final ({int item, int option})? pending;
  final ValueChanged<int> onOpen;
  final double fade;
  final GlobalKey? frame;
  final Map<int, GlobalKey>? triggers;
  final Map<int, GlobalKey>? triggerTexts;
  final Map<int, GlobalKey>? rows;
  final Map<int, GlobalKey>? texts;
  final _Flight? flight;

  /// Where [flight] is: 1 in the trigger, 0 in the row (and a little past
  /// either, on the spring).
  final Animation<double> at;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(1),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final (index, item) in items.indexed) ...[
            if (index > 0) Opacity(opacity: fade, child: const _Divider()),
            // Clickable while it flies, too.
            Opacity(
              opacity: flight?.item == index ? 1 : fade,
              child: _Pressable(
                onPressed: () => onOpen(index),
                builder: (highlighted) => _trigger(
                  index,
                  item,
                  flight?.item == index ? false : highlighted,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _trigger(int index, GaiaNotchItem<Object?> item, bool highlighted) {
    final picked = pending;
    final selected = picked != null && picked.item == index
        ? picked.option
        : item._selected;
    final option = selected < 0 ? null : item.options[selected];
    final flight = this.flight?.item == index ? this.flight : null;
    final t = at.value.clamp(0.0, 1.0);
    Widget text = Text.rich(
      TextSpan(
        children: [
          TextSpan(text: option?.label ?? 'None'),
          if (option?.detail case final detail?)
            TextSpan(
              text: '  $detail',
              style: TextStyle(
                color: flight == null
                    ? _muted
                    : Color.lerp(flight.detail, _muted, t),
              ),
            ),
        ],
      ),
      style: _triggerStyle.copyWith(
        color: flight == null ? _bright : Color.lerp(flight.label, _bright, t),
      ),
      maxLines: 1,
    );
    text = _withIcon(
      option,
      text,
      key: triggerTexts?.putIfAbsent(index, GlobalKey.new),
      color: flight == null
          ? (highlighted ? Colors.white : _muted)
          : Color.lerp(flight.label, _muted, t)!,
      // Still lit as it flies, as its row is.
      lit: flight != null || highlighted,
    );
    if (flight != null) {
      text = _Fly(
        frame: frame!,
        from: texts![flight.option],
        at: at,
        child: text,
      );
    }
    Widget trigger = AnimatedContainer(
      key: triggers?.putIfAbsent(index, GlobalKey.new),
      duration: _fade,
      height: 22,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      alignment: Alignment.center,
      child: text,
    );
    if (flight != null) {
      trigger = _Fly(
        frame: frame!,
        from: rows![flight.option],
        at: at,
        pill: flight,
        child: trigger,
      );
    }
    return trigger;
  }
}

/// Paints [child] moved from where [from] is toward where [anchor] is (this
/// itself if null) as [at] goes from 0 to 1, both measured in [frame]. With
/// a [pill], it instead stays put and paints [pill]'s background behind it,
/// going from [from]'s rect and look at 0 to its own, clear, at 1.
class _Fly extends SingleChildRenderObjectWidget {
  const _Fly({
    required this.frame,
    required this.from,
    required this.at,
    this.anchor,
    this.pill,
    super.child,
  });

  final GlobalKey frame;
  final GlobalKey? from;
  final GlobalKey? anchor;
  final Animation<double> at;
  final _Flight? pill;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderFly(frame, from, anchor, at, pill);

  @override
  void updateRenderObject(BuildContext context, _RenderFly renderObject) {
    renderObject
      ..frame = frame
      ..from = from
      ..anchor = anchor
      ..at = at
      ..pill = pill;
  }
}

class _RenderFly extends RenderProxyBox {
  _RenderFly(this.frame, this.from, this.anchor, this._at, this.pill);

  // Read only in paint, which every change of [at] schedules.
  GlobalKey frame;
  GlobalKey? from;
  GlobalKey? anchor;
  _Flight? pill;

  Animation<double> _at;
  set at(Animation<double> value) {
    if (value == _at) return;
    if (attached) {
      _at.removeListener(markNeedsPaint);
      value.addListener(markNeedsPaint);
    }
    _at = value;
    markNeedsPaint();
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _at.addListener(markNeedsPaint);
  }

  @override
  void detach() {
    _at.removeListener(markNeedsPaint);
    super.detach();
  }

  static RenderBox? _box(GlobalKey? key) {
    final box = key?.currentContext?.findRenderObject() as RenderBox?;
    return box != null && box.attached && box.hasSize ? box : null;
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    final t = _at.value;
    final frame = _box(this.frame);
    final from = _box(this.from);
    final anchor = this.anchor == null ? this : _box(this.anchor);
    if (t == 1 || frame == null || from == null || anchor == null) {
      return super.paint(context, offset);
    }
    final gap =
        from.localToGlobal(Offset.zero, ancestor: frame) -
        anchor.localToGlobal(Offset.zero, ancestor: frame);
    final pill = this.pill;
    if (pill == null) {
      super.paint(context, offset + gap * (1 - t));
      return;
    }
    final clear = t.clamp(0.0, 1.0);
    final rrect = RRect.fromRectAndRadius(
      Rect.lerp(gap & from.size, Offset.zero & size, t)!.shift(offset),
      Radius.circular(6 + 8 * t),
    );
    context.canvas
      ..drawRRect(
        rrect,
        Paint()..color = pill.fill.withValues(alpha: pill.fill.a * (1 - clear)),
      )
      ..drawRRect(
        rrect.deflate(0.5),
        Paint()
          ..style = PaintingStyle.stroke
          ..color = pill.border.withValues(alpha: pill.border.a * (1 - clear)),
      );
    super.paint(context, offset);
  }
}

class _Divider extends StatelessWidget {
  const _Divider();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.symmetric(horizontal: 2),
      child: CustomPaint(size: Size(1, 16), painter: _DottedLine()),
    );
  }
}

/// A 1px dot every 4px, down the middle.
class _DottedLine extends CustomPainter {
  const _DottedLine();

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = Colors.white.withValues(alpha: 0.35);
    for (var y = 0.0; y < size.height; y += 4) {
      canvas.drawRect(Rect.fromLTWH(0, y, size.width, 1), paint);
    }
  }

  @override
  bool shouldRepaint(_DottedLine old) => false;
}

/// An open item's options, the selected one focused, as wide as the widest.
/// [rows] and [texts] get keys for each option to be measured by; the
/// [hidden] one is in flight. While [leaving] runs, the others blur out
/// bottom first and are drawn in toward the [trigger]'s text as [drawnIn]
/// goes to 1.
class _Options extends StatefulWidget {
  const _Options({
    super.key,
    required this.item,
    required this.frame,
    required this.rows,
    required this.texts,
    required this.trigger,
    required this.hidden,
    required this.leaving,
    required this.drawnIn,
    required this.onSelect,
    required this.onClose,
  });

  final GaiaNotchItem<Object?> item;
  final GlobalKey frame;
  final Map<int, GlobalKey> rows;
  final Map<int, GlobalKey> texts;
  final GlobalKey trigger;
  final int? hidden;
  final Animation<double>? leaving;
  final Animation<double>? drawnIn;
  final ValueChanged<int> onSelect;
  final VoidCallback onClose;

  @override
  State<_Options> createState() => _OptionsState();
}

class _OptionsState extends State<_Options>
    with SingleTickerProviderStateMixin {
  /// Runs, linearly, until the last option has settled.
  late final _entrance = AnimationController(
    vsync: this,
    duration:
        _optionsDelay +
        _optionsStagger * (widget.item.options.length - 1) +
        _springTime,
  )..forward();

  @override
  void dispose() {
    _entrance.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final options = widget.item.options;
    final selected = widget.item._selected;
    final drawnIn = widget.drawnIn;
    // A scope of its own, so Tab and the arrows stay among the options.
    return FocusScope(
      child: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.escape): widget.onClose,
          const SingleActivator(LogicalKeyboardKey.arrowDown): () =>
              FocusManager.instance.primaryFocus?.nextFocus(),
          const SingleActivator(LogicalKeyboardKey.arrowUp): () =>
              FocusManager.instance.primaryFocus?.previousFocus(),
        },
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: IntrinsicWidth(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final (index, option) in options.indexed) ...[
                  if (index > 0) const SizedBox(height: 6),
                  Opacity(
                    opacity: index == widget.hidden ? 0 : 1,
                    child: _Fly(
                      frame: widget.frame,
                      from: widget.trigger,
                      anchor: widget.texts.putIfAbsent(index, GlobalKey.new),
                      at: drawnIn == null
                          ? kAlwaysCompleteAnimation
                          : ReverseAnimation(drawnIn),
                      child: _Entering(
                        entrance: _entrance,
                        delay: _optionsDelay + _optionsStagger * index,
                        leaving: widget.leaving,
                        // Counting only the options leaving.
                        leaveDelay:
                            _leaveStagger *
                            [
                              for (
                                var below = index + 1;
                                below < options.length;
                                below++
                              )
                                if (below != widget.hidden) below,
                            ].length,
                        child: _Pressable(
                          // The first when none is, so the keys work at once.
                          autofocus: index == (selected < 0 ? 0 : selected),
                          selected: index == selected,
                          onPressed: () => widget.onSelect(index),
                          builder: (highlighted) => _option(
                            index,
                            option,
                            index == selected,
                            highlighted,
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _option(
    int index,
    GaiaNotchOption<Object?> option,
    bool active,
    bool lit,
  ) {
    final accent = Theme.of(context).colorScheme.primary;
    return AnimatedContainer(
      key: widget.rows.putIfAbsent(index, GlobalKey.new),
      duration: _fade,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: active
            ? accent.withValues(alpha: 0.85)
            : Colors.white.withValues(alpha: lit ? 0.05 : 0),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(
          color: active
              ? Color.lerp(accent, Colors.white, lit ? 0.6 : 0.2)!
              : Colors.transparent,
        ),
      ),
      child: Row(
        children: [
          Expanded(
            // Left-aligned, so the text measured is only as wide as itself.
            child: Align(
              alignment: Alignment.centerLeft,
              heightFactor: 1,
              child: _withIcon(
                option,
                key: widget.texts.putIfAbsent(index, GlobalKey.new),
                color: active || lit ? Colors.white : _muted,
                lit: active || lit,
                Text.rich(
                  TextSpan(
                    children: [
                      TextSpan(text: option.label),
                      if (option.detail case final detail?)
                        TextSpan(
                          text: '  $detail',
                          style: TextStyle(
                            color: active
                                ? Colors.white.withValues(alpha: 0.75)
                                : _muted,
                          ),
                        ),
                    ],
                  ),
                  style: _textStyle.copyWith(
                    color: active || lit ? Colors.white : _dim,
                  ),
                  maxLines: 1,
                ),
              ),
            ),
          ),
          const SizedBox(width: 24),
          // White, where the accent's own colour would vanish on the
          // accent fill.
          SizedBox.square(
            dimension: 6,
            child: active
                ? const DecoratedBox(
                    decoration: BoxDecoration(
                      color: Colors.white,
                      shape: BoxShape.circle,
                    ),
                  )
                : null,
          ),
        ],
      ),
    );
  }
}

/// [child] dropping in from 10px up, out of a blur, on [_optionSpring],
/// [delay] into [entrance]; and, [leaveDelay] into [leaving], going back
/// the way it came.
class _Entering extends StatelessWidget {
  const _Entering({
    required this.entrance,
    required this.delay,
    required this.leaving,
    required this.leaveDelay,
    required this.child,
  });

  final AnimationController entrance;
  final Duration delay;
  final Animation<double>? leaving;
  final Duration leaveDelay;
  final Widget child;

  /// How far in, on the spring, [delay] into [controller] running for
  /// [length].
  static double _in(
    Animation<double> controller,
    Duration length,
    Duration delay,
  ) {
    final elapsed =
        controller.value * length.inMicroseconds / 1e6 -
        delay.inMicroseconds / 1e6;
    return elapsed <= 0
        ? 0
        : SpringSimulation(_optionSpring, 0, 1, 0).x(elapsed);
  }

  @override
  Widget build(BuildContext context) {
    final leaving = this.leaving;
    return AnimatedBuilder(
      animation: Listenable.merge([entrance, leaving]),
      child: child,
      builder: (context, child) {
        final t =
            _in(entrance, entrance.duration!, delay) *
            (leaving == null
                ? 1
                : 1 - _in(leaving, _springTime * _leaveSpeed, leaveDelay));
        final blur = 4 * (1 - t).clamp(0.0, 1.0);
        return Opacity(
          opacity: t.clamp(0.0, 1.0),
          child: Transform.translate(
            offset: Offset(0, -10 * (1 - t)),
            child: blur < 0.05
                ? child
                : ImageFiltered(
                    imageFilter: ImageFilter.blur(sigmaX: blur, sigmaY: blur),
                    child: child,
                  ),
          ),
        );
      },
    );
  }
}

/// Clickable and keyboard-activatable, lit while hovered or focused from
/// the keyboard.
class _Pressable extends StatefulWidget {
  const _Pressable({
    required this.onPressed,
    required this.builder,
    this.autofocus = false,
    this.selected,
  });

  final VoidCallback onPressed;
  final Widget Function(bool highlighted) builder;
  final bool autofocus;
  final bool? selected;

  @override
  State<_Pressable> createState() => _PressableState();
}

class _PressableState extends State<_Pressable> {
  var _hovered = false;
  var _focused = false;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      selected: widget.selected,
      child: FocusableActionDetector(
        autofocus: widget.autofocus,
        mouseCursor: SystemMouseCursors.click,
        actions: {
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (_) => widget.onPressed(),
          ),
        },
        onShowHoverHighlight: (hovered) => setState(() => _hovered = hovered),
        onShowFocusHighlight: (focused) => setState(() => _focused = focused),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onPressed,
          child: widget.builder(_hovered || _focused),
        ),
      ),
    );
  }
}

/// A curve tracing [spring] from 0 to 1 over [_springTime].
class _SpringCurve extends Curve {
  const _SpringCurve(this.spring);

  final SpringDescription spring;

  @override
  double transformInternal(double t) =>
      SpringSimulation(spring, 0, 1, 0).x(t * _springTime.inMicroseconds / 1e6);
}

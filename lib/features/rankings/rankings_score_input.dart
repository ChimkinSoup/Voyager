import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:voyager/core/motion/motion.dart';
import 'package:voyager/core/theme/voyager_theme.dart';
import 'package:voyager/core/widgets/contextual_popover.dart';
import 'package:voyager/core/widgets/field_scroll_padding.dart';
import 'package:voyager/core/widgets/select_all_on_click.dart';
import 'package:voyager/core/widgets/voyager_spinner_wheel.dart';
import 'package:voyager/domain/models/ranking_models.dart';
import 'package:voyager/domain/rankings/ranking_queries.dart';

/// What the number shows when nothing has been scored.
///
/// A dash rather than an empty slot: a blank reads as a row that failed to
/// draw, and it leaves nothing to click.
const rankingUnscoredLabel = '—';

/// How a score popover was closed.
///
/// [cancelled] is the only outcome that writes nothing; a non-cancelled
/// outcome carries the score to store, and a null [score] on one of those is
/// a deliberate clear.
class RankingScoreOutcome {
  const RankingScoreOutcome.commit(this.score) : cancelled = false;
  const RankingScoreOutcome.cancelled() : score = null, cancelled = true;

  final double? score;
  final bool cancelled;
}

/// Opens the score popover anchored to [anchorContext].
///
/// Returns null when the route was popped by something other than the popover
/// itself, which the caller treats the same as a cancel.
Future<RankingScoreOutcome?> showRankingScorePopover({
  required BuildContext context,
  required BuildContext anchorContext,
  required double? value,
  required int scoreMax,
  required RankingScorePrecision precision,
  required String label,
  Color? accentColor,
  ValueChanged<double>? onDraftChanged,
}) => showContextualPopover<RankingScoreOutcome>(
  context: context,
  buttonContext: anchorContext,
  width: 200,
  accentColor: accentColor,
  builder: (_) => RankingScorePopover(
    value: value,
    scoreMax: scoreMax,
    precision: precision,
    label: label,
    onDraftChanged: onDraftChanged,
  ),
);

/// The score input: a text field over two rollers, drafted until it is
/// dismissed.
///
/// Nothing here writes. The popover hands one [RankingScoreOutcome] back when
/// it closes, and every path out of it — outside click, Enter, Esc, Clear — is
/// one of those outcomes, so the caller has a single place to save from.
class RankingScorePopover extends StatefulWidget {
  const RankingScorePopover({
    super.key,
    required this.value,
    required this.scoreMax,
    required this.precision,
    required this.label,
    this.onDraftChanged,
  });

  /// Null opens on the scale's midpoint as a draft, which outside-click and
  /// Enter both commit (§7.5). Esc is the way back to null.
  final double? value;

  final int scoreMax;
  final RankingScorePrecision precision;

  /// Names the thing being scored, for the screen reader.
  final String label;

  /// Every value the draft passes through, including the ones a roller is
  /// only scrolling over. The surface behind the popover redraws its number
  /// and stars from these, so the score being dialled in is visible on the
  /// thing it belongs to rather than only in the popover's own box.
  ///
  /// Nothing here is written: the draft still has to be committed, and a
  /// cancel leaves the surface to fall back to its stored score.
  final ValueChanged<double>? onDraftChanged;

  @override
  State<RankingScorePopover> createState() => _RankingScorePopoverState();
}

class _RankingScorePopoverState extends State<RankingScorePopover> {
  /// Tall enough for three rows: the selected one and the neighbour above and
  /// below it, which is all the context a 0–10 column needs.
  static const _itemExtent = 32.0;
  static const _wheelRows = 3;

  /// The far end of the endless right roller's runway. Large enough that the
  /// user cannot scroll off it, small enough to stay exact in an int.
  static const _rightOrigin = 1000;

  late double _value;
  late final TextEditingController _textController;
  late final FocusNode _textFocus;
  late final FixedExtentScrollController _leftController;
  FixedExtentScrollController? _rightController;

  /// Any roller move or text change since the popover opened. An untouched
  /// scored value is left exactly as it was rather than rewritten with itself
  /// (§7.5, "keep same").
  var _edited = false;

  var _selectAllNextTap = false;
  var _syncingText = false;
  var _syncingRight = false;
  var _settlePending = false;
  var _canPop = false;

  int _lastRightIndex = _rightOrigin;

  bool get _hasRightWheel => widget.precision != RankingScorePrecision.integers;

  /// Steps in one point of the scale — 2 for halves, 10 for tenths. One index
  /// on the right roller is one of these.
  int get _unitsPerPoint =>
      widget.precision == RankingScorePrecision.half ? 2 : 10;

  double get _unit => 1 / _unitsPerPoint;

  /// The digit each right-roller index prints: `0`/`5` in half mode, `0`–`9`
  /// in tenths. Both are tenths on the page; halves simply skip eight of them.
  int _digitAt(int index) => widget.precision == RankingScorePrecision.half
      ? _digitIndexOf(index) * 5
      : _digitIndexOf(index);

  /// An index's slot in one cycle of the roller, for an index that may be
  /// negative — Dart's `%` already returns a non-negative remainder here, but
  /// the intent is worth naming once rather than at all four call sites.
  int _digitIndexOf(int index) {
    final slot = index % _unitsPerPoint;
    return slot < 0 ? slot + _unitsPerPoint : slot;
  }

  int get _digitIndex =>
      ((_value - _value.floorToDouble()) * _unitsPerPoint).round();

  /// The right-roller rows the draft can reach: the one that reads `0.0` and
  /// the one that reads `scoreMax.0`.
  ///
  /// The roller is endless so it can carry, so these move with it — measured
  /// back from wherever it sits now, and shifted whenever the left roller
  /// changes the whole part underneath it. Rows past them print nothing: they
  /// are scores off the scale, and the roller refuses to rest on them.
  VoyagerWheelLimits _rightLimits() {
    final zero = _lastRightIndex - (_value * _unitsPerPoint).round();
    return (first: zero, last: zero + widget.scoreMax * _unitsPerPoint);
  }

  VoyagerWheelLimits _leftLimits() => (first: 0, last: widget.scoreMax);

  @override
  void initState() {
    super.initState();
    _value = widget.value == null
        ? rankingFieldMidpoint(widget.scoreMax, precision: widget.precision)
        : roundRankingScore(
            widget.value!,
            scoreMax: widget.scoreMax,
            precision: widget.precision,
          );

    _textController = TextEditingController(text: formatRankingScore(_value));
    _textFocus = FocusNode();
    _leftController = FixedExtentScrollController(initialItem: _value.floor());
    if (_hasRightWheel) {
      _lastRightIndex = _rightOrigin + _digitIndex;
      _rightController = FixedExtentScrollController(
        initialItem: _lastRightIndex,
      );
    }

    _textFocus.addListener(() {
      if (_textFocus.hasFocus) {
        _selectAllNextTap = true;
      } else {
        // Blur clamps and snaps the draft into the rollers without closing
        // anything (§7.4).
        _writeText();
        _syncWheels(animate: false);
      }
    });
    _textController.addListener(_onTextChanged);

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _textFocus.requestFocus();
      _textController.selection = TextSelection(
        baseOffset: 0,
        extentOffset: _textController.text.length,
      );
      _selectAllNextTap = false;
    });
  }

  @override
  void dispose() {
    _textController.dispose();
    _textFocus.dispose();
    _leftController.dispose();
    _rightController?.dispose();
    super.dispose();
  }

  // -------------------------------------------------------------------- draft

  void _setValue(double next, {bool updateText = true}) {
    final rounded = roundRankingScore(
      next,
      scoreMax: widget.scoreMax,
      precision: widget.precision,
    );
    if (rounded == _value) return;
    setState(() {
      _value = rounded;
      _edited = true;
    });
    if (updateText) _writeText();
    widget.onDraftChanged?.call(rounded);
  }

  void _writeText() {
    final text = formatRankingScore(_value);
    if (_textController.text == text) return;
    _syncingText = true;
    _textController.text = text;
    _syncingText = false;
  }

  void _onTextChanged() {
    if (_syncingText || !_textFocus.hasFocus) return;
    final parsed = double.tryParse(_textController.text.trim());
    // A pasted run of 400 digits parses to infinity.
    if (parsed == null || !parsed.isFinite) return;
    _setValue(parsed, updateText: false);
    _syncWheels(animate: false);
  }

  /// Puts both rollers back where [_value] says they belong.
  ///
  /// Jumps rather than animates for anything but a single-step correction: an
  /// animation across several items reports every index it passes, and the
  /// left roller reads its index as the score's whole part.
  void _syncWheels({required bool animate}) {
    final leftTarget = _value.floor();
    if (_leftController.hasClients &&
        _leftController.selectedItem != leftTarget) {
      if (animate && (_leftController.selectedItem - leftTarget).abs() == 1) {
        _leftController.animateToItem(
          leftTarget,
          duration: const Duration(milliseconds: 220),
          curve: VoyagerSpring.moveCurve,
        );
      } else {
        _leftController.jumpToItem(leftTarget);
      }
    }

    final right = _rightController;
    if (right == null || !right.hasClients) return;
    final current = right.selectedItem;
    // The nearest index printing the digit the draft wants, so a correction
    // never spins the roller the long way round.
    var delta = _digitIndex - _digitIndexOf(current);
    if (delta.abs() * 2 > _unitsPerPoint) {
      delta += delta > 0 ? -_unitsPerPoint : _unitsPerPoint;
    }
    final target = current + delta;
    if (target == current) return;
    // A rebuild, because the limits are measured from this: the blank rows
    // past them have to follow the roller to where it is going.
    setState(() => _lastRightIndex = target);
    _syncingRight = true;
    if (animate && delta.abs() == 1) {
      right
          .animateToItem(
            target,
            duration: const Duration(milliseconds: 220),
            curve: VoyagerSpring.moveCurve,
          )
          .whenComplete(() => _syncingRight = false);
    } else {
      right.jumpToItem(target);
      _syncingRight = false;
    }
  }

  // ------------------------------------------------------------------ rollers

  /// The left roller reads absolutely: its index *is* the score's whole part,
  /// so a carry that animates it into place lands on the value already set
  /// rather than adding to it a second time.
  void _onLeftChanged(int index) {
    _setValue(index + (_value - _value.floorToDouble()));
  }

  /// The right roller reads as a delta, which is what lets it carry: rolling
  /// past the last digit is one more step, and the step is what crosses the
  /// integer boundary.
  ///
  /// A row past a limit is read as the limit. The physics keeps the roller
  /// from resting there, but a step onto it counted here would come back off
  /// it as a step the other way — and 10.0 would spring back as 9.9.
  void _onRightChanged(int index) {
    if (_syncingRight) {
      _lastRightIndex = index;
      return;
    }
    final limits = _rightLimits();
    final reached = index.clamp(limits.first, limits.last);
    final delta = reached - _lastRightIndex;
    _lastRightIndex = reached;
    if (delta == 0) return;
    final before = _value;
    _setValue(_value + delta * _unit);
    if (_value.floor() != before.floor()) _syncWheels(animate: true);
  }

  bool _onWheelNotification(ScrollNotification notification) {
    if (notification is ScrollEndNotification) _settle();
    return false;
  }

  /// Runs once the scroll stops, never on the ticks along the way (§7.3).
  ///
  /// Pushing a roller past an end changes nothing, so this only puts the
  /// rollers back on the draft: the one place that needs it is the clamp at
  /// `scoreMax`, where rolling the whole part up from `scoreMax - 1.5` lands
  /// on `scoreMax.0` and leaves the digit roller showing the fraction that
  /// was dropped.
  ///
  /// Deferred, because the end notification is sent from inside
  /// [ScrollPosition.beginActivity] before the roller has left the scroll
  /// that ended. A jump from there ends that same scroll again, and so on
  /// until the stack overflows; an animation started from there is disposed
  /// as soon as the notification returns.
  void _settle() {
    if (_settlePending) return;
    _settlePending = true;
    scheduleMicrotask(() {
      _settlePending = false;
      if (mounted) _syncWheels(animate: true);
    });
  }

  // ------------------------------------------------------------------ closing

  /// Outside click and Enter (§7.5): an untouched scored value is left alone,
  /// everything else commits the draft — including the midpoint an unscored
  /// surface opened on.
  void _dismiss() {
    if (!_edited && widget.value != null) {
      _close(const RankingScoreOutcome.cancelled());
    } else {
      _close(RankingScoreOutcome.commit(_value));
    }
  }

  void _clear() {
    // Nothing to clear on a surface that was never scored, and writing null
    // over null would still bump the row's version.
    _close(
      widget.value == null
          ? const RankingScoreOutcome.cancelled()
          : const RankingScoreOutcome.commit(null),
    );
  }

  void _close(RankingScoreOutcome outcome) {
    if (!mounted || _canPop) return;
    setState(() => _canPop = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) Navigator.of(context).pop(outcome);
    });
  }

  /// Escape has to be caught here rather than left to the app's Dismiss
  /// shortcut: that shortcut and the barrier both pop the same route, and only
  /// one of the two abandons the draft. A [Focus] above the text field sees
  /// the key first, on the way up from whatever inside has it.
  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    if (event.logicalKey != LogicalKeyboardKey.escape) {
      return KeyEventResult.ignored;
    }
    _close(const RankingScoreOutcome.cancelled());
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent = theme.colorScheme.primary;

    return PopScope(
      canPop: _canPop,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        // Only the barrier reaches this: Escape closes through [_onKey], which
        // has already set [_canPop] and popped with its own outcome.
        _dismiss();
      },
      child: Focus(
        onKeyEvent: _onKey,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 8, 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(child: _scoreField(theme, accent)),
                  const SizedBox(width: 4),
                  IconButton(
                    onPressed: _clear,
                    tooltip: 'Clear score',
                    iconSize: 15,
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(PhosphorIconsRegular.eraser),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              SizedBox(
                height: _itemExtent * _wheelRows,
                child: VoyagerSpinnerFade(
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      VoyagerSpinnerWheel(
                        width: 48,
                        controller: _leftController,
                        itemExtent: _itemExtent,
                        itemCount: widget.scoreMax + 1,
                        limits: _leftLimits,
                        onSelectedItemChanged: _onLeftChanged,
                        onNotification: _onWheelNotification,
                        itemBuilder: (ctx, index) => _wheelItem(
                          theme,
                          accent,
                          '$index',
                          selected: index == _value.floor(),
                        ),
                      ),
                      if (_hasRightWheel) ...[
                        Text(
                          '.',
                          style: theme.textTheme.titleMedium?.copyWith(
                            color: accent,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        VoyagerSpinnerWheel(
                          width: 40,
                          controller: _rightController!,
                          itemExtent: _itemExtent,
                          limits: _rightLimits,
                          onSelectedItemChanged: _onRightChanged,
                          onNotification: _onWheelNotification,
                          itemBuilder: (ctx, index) {
                            final limits = _rightLimits();
                            if (index < limits.first || index > limits.last) {
                              return const SizedBox.shrink();
                            }
                            return _wheelItem(
                              theme,
                              accent,
                              '${_digitAt(index)}',
                              selected: _digitIndexOf(index) == _digitIndex,
                            );
                          },
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _wheelItem(
    ThemeData theme,
    Color accent,
    String text, {
    required bool selected,
  }) => Center(
    child: Text(
      text,
      style: theme.textTheme.titleMedium?.copyWith(
        color: selected
            ? accent
            : theme.colorScheme.onSurface.withValues(alpha: 0.32),
        fontWeight: selected ? FontWeight.bold : null,
      ),
    ),
  );

  Widget _scoreField(ThemeData theme, Color accent) {
    return Semantics(
      label: '${widget.label} score out of ${widget.scoreMax}',
      textField: true,
      child: Container(
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(VoyagerTheme.fieldRadius),
          border: Border.all(color: accent, width: 2),
        ),
        child: Material(
          type: MaterialType.transparency,
          child: SelectAllOnClick(
            controller: _textController,
            focusNode: _textFocus,
            selectAllPending: () => _selectAllNextTap,
            child: TextField(
              controller: _textController,
              focusNode: _textFocus,
              textAlign: TextAlign.center,
              scrollPadding: kVoyagerFieldScrollPadding,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              inputFormatters: [
                FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
              ],
              contextMenuBuilder: (context, state) => const SizedBox.shrink(),
              style: theme.textTheme.titleMedium?.copyWith(color: accent),
              onTap: () {
                if (!_selectAllNextTap) return;
                _textController.selection = TextSelection(
                  baseOffset: 0,
                  extentOffset: _textController.text.length,
                );
                _selectAllNextTap = false;
              },
              onSubmitted: (_) => _dismiss(),
              decoration: const InputDecoration(
                isCollapsed: true,
                // The app fills its fields, and a filled InputDecorator paints
                // that fill in the *border's* shape — which, with no border, is
                // a square. Under the rounded box drawn around this field the
                // square fill reaches into all four corners and eats the curve.
                filled: false,
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
                contentPadding: EdgeInsets.symmetric(
                  horizontal: 8,
                  vertical: 8,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The number every score surface is set from: click to open the popover, wheel
/// to nudge, long-press to clear.
///
/// The stars beside it are decoration — this is the whole control, and it is
/// the same one on a list row, an overall row and a template field.
class RankingScoreNumber extends StatelessWidget {
  const RankingScoreNumber({
    super.key,
    required this.value,
    required this.scoreMax,
    required this.precision,
    required this.label,
    required this.onChanged,
    this.onDraftChanged,
    this.style,
    this.width,
    this.textAlign = TextAlign.left,
    this.accentColor,
    this.unscoredColor,
  });

  final double? value;
  final int scoreMax;
  final RankingScorePrecision precision;

  /// Names the thing being scored — the entry, the unit, the field — for the
  /// popover and the screen reader.
  final String label;

  /// Null makes the number read-only: an archived category still shows its
  /// scores, it just cannot be opened (§6.1).
  final ValueChanged<double?>? onChanged;

  /// The score the open popover is currently sitting on, reported on every
  /// tick of a roller, and null once the popover has closed without writing.
  ///
  /// A popover that writes reports the score through [onChanged] instead, and
  /// sends no null after it: the surface keeps showing what was written until
  /// the save lands. [RankingScoreHold] is the surfaces' side of this.
  final ValueChanged<double?>? onDraftChanged;

  final TextStyle? style;
  final double? width;
  final TextAlign textAlign;
  final Color? accentColor;
  final Color? unscoredColor;

  bool get _isInteractive => onChanged != null;

  Future<void> _open(BuildContext context) async {
    final outcome = await showRankingScorePopover(
      context: context,
      anchorContext: context,
      value: value,
      scoreMax: scoreMax,
      precision: precision,
      label: label,
      accentColor: accentColor,
      onDraftChanged: onDraftChanged?.call,
    );
    // A write keeps the draft on screen: the save lands a few frames after the
    // popover closes, and dropping the draft here showed the old score for
    // those frames.
    if (outcome == null || outcome.cancelled) {
      onDraftChanged?.call(null);
    } else {
      onChanged!(outcome.score);
    }
  }

  /// One step in the direction of the wheel, committed on the spot (§6.2). An
  /// unscored surface starts from the midpoint, so the first notch lands one
  /// step either side of it.
  void _nudge(int direction) {
    final base = value ?? rankingFieldMidpoint(scoreMax, precision: precision);
    onChanged!(
      roundRankingScore(
        base + direction * rankingScoreStep(precision),
        scoreMax: scoreMax,
        precision: precision,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scored = value != null;
    final text = Text(
      scored ? formatRankingScore(value!) : rankingUnscoredLabel,
      textAlign: textAlign,
      maxLines: 1,
      style: (style ?? theme.textTheme.labelLarge)?.copyWith(
        color: scored
            ? (accentColor ?? theme.colorScheme.primary)
            : (unscoredColor ??
                  theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.6)),
      ),
    );

    final sized = width == null ? text : SizedBox(width: width, child: text);
    final semanticLabel = scored
        ? '$label ${formatRankingScore(value!)} of $scoreMax'
        : '$label unscored';

    if (!_isInteractive) {
      return Semantics(label: semanticLabel, child: sized);
    }

    return Semantics(
      button: true,
      label: semanticLabel,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: Listener(
          onPointerSignal: (event) {
            if (event is! PointerScrollEvent) return;
            // Registering resolves the notch in this control's favour, so the
            // list the row sits in does not scroll under the pointer as well.
            GestureBinding.instance.pointerSignalResolver.register(event, (
              resolved,
            ) {
              final scroll = resolved as PointerScrollEvent;
              if (scroll.scrollDelta.dy == 0) return;
              _nudge(scroll.scrollDelta.dy < 0 ? 1 : -1);
            });
          },
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => _open(context),
            onLongPress: scored ? () => onChanged!(null) : null,
            child: Tooltip(
              message: scored ? 'Edit score' : 'Set score',
              waitDuration: const Duration(milliseconds: 600),
              // Hover still raises it; long-press must not. Tooltip's default
              // long-press trigger is a gesture recognizer *inside* this
              // control's, so it would win the arena and swallow the clear.
              triggerMode: TooltipTriggerMode.manual,
              child: sized,
            ),
          ),
        ),
      ),
    );
  }
}

/// The score a surface draws in place of its stored one: the popover's draft
/// while it is open, then whatever the number wrote until the save carries it
/// back.
///
/// Every save here is async, and the stored score only moves once it lands —
/// a few frames after the popover closes. Showing the stored score in between
/// flashed the old one: a blank between the draft and the saved number.
///
/// Wire [holdDraft] to [RankingScoreNumber.onDraftChanged] and pass the save
/// through [holdingWrites], then draw [shownScore].
mixin RankingScoreHold<T extends StatefulWidget> on State<T> {
  /// The score as stored, which the held one gives way to once they match.
  double? get storedScore;

  /// A record so a written clear — a null score — can be held too.
  ({double? score})? _held;

  double? get shownScore {
    final held = _held;
    return held == null ? storedScore : held.score;
  }

  /// A null draft is a popover closed without writing, which drops straight
  /// back to the stored score.
  void holdDraft(double? draft) {
    if (draft == null) {
      if (_held != null) setState(() => _held = null);
    } else {
      _hold(draft);
    }
  }

  /// [write], holding each score it is handed until the store catches up.
  ValueChanged<double?>? holdingWrites(ValueChanged<double?>? write) {
    if (write == null) return null;
    return (score) {
      _hold(score);
      write(score);
    };
  }

  void _hold(double? score) =>
      setState(() => _held = score == storedScore ? null : (score: score));

  /// Released on a match rather than on any change: two quick wheel notches
  /// land one after the other, and the first landing must not pull the number
  /// back under the second.
  @override
  void didUpdateWidget(covariant T oldWidget) {
    super.didUpdateWidget(oldWidget);
    final held = _held;
    if (held != null && held.score == storedScore) _held = null;
  }
}

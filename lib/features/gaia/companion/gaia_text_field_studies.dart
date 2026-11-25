import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:voyager/features/gaia/companion/gaia_button.dart';
import 'package:voyager/features/gaia/companion/gaia_style.dart';
import 'package:voyager/features/gaia/companion/gaia_text_field.dart';

/// Other looks for [GaiaTextField], as the composer would wear them: an
/// attach button, the text and a send button. Plain fields underneath, so
/// none of them has Vim, spellcheck or lists; only the look differs.
enum _Study {
  ring(
    'Quiet ring',
    'A hairline edge at rest that brightens on hover and turns the accent '
        'on focus. No light.',
  ),
  floating(
    'Floating',
    "A menu's surface over a drop shadow, lifting further while it has "
        'focus. Lighter than before.',
  ),
  floatingRing(
    'Floating ring',
    'Floating, with the quiet ring\'s edge: brighter on hover, the accent '
        'on focus.',
  ),
  liftedRing(
    'Lifted ring',
    'Flat as the quiet ring at rest; focus lifts it onto a shadow as its '
        'edge turns the accent.',
  ),
  tintedLift(
    'Tinted lift',
    'Floating ring, its shadow turning the accent on focus, as if lit from '
        'beneath.',
  ),
  topLight(
    'Top light',
    'Floating ring, with a highlight along its top edge as if lit from '
        'above.',
  ),
  corners(
    'Corner marks',
    'No edge, only its four corners marked. Focus runs the marks out along '
        'the sides in the accent, like a viewfinder closing in.',
  ),
  rails(
    'Rails',
    'Lines above and below only, no sides. Focus draws the accent out '
        'along both from the middle.',
  ),
  dashed(
    'Dashed',
    'A dashed edge at rest that closes into a solid accent line on focus.',
  ),
  stacked(
    'Stacked',
    'A second sheet peeking out beneath, as a stack of paper; focus fans it '
        'out a little further.',
  ),
  tide(
    'Tide',
    'The quiet ring, with a faint accent tint rising from the bottom while '
        'it has focus.',
  ),
  inset(
    'Inset well',
    'Pressed into the panel rather than lifted off it: darker, shaded under '
        'its top edge, a faint highlight along its bottom. Focus turns the '
        'edge the accent.',
  ),
  halo(
    'Halo',
    'The quiet ring, with an even glow in the accent all round it: a hint '
        'on hover, full on focus.',
  ),
  orbit(
    'Orbit',
    'A hairline at rest; on focus a short arc of the accent circles the '
        'edge, slowly, for as long as it has focus.',
  ),
  pill(
    'Pill',
    'The quiet ring as a capsule, its ends as round as one line is tall.',
  ),
  underline(
    'Underline',
    'Rounded only along the top, with a single line along the bottom that '
        'thickens into the accent on focus. No sides.',
  ),
  spine(
    'Spine',
    'A faint hairline edge and a short bar on the leading side that grows '
        'the full height in the accent on focus.',
  ),
  aurora(
    'Aurora edge v1',
    'A dim edge at rest; on focus, soft lights in hues around the accent '
        'drift, swell and fade along it, slowly, like an aurora.',
  ),
  aurora2(
    'Aurora edge v2',
    'Aurora edge v1 with the whole edge coloured: a faint wash of the same '
        'hues turning slowly all the way round, under more and wider lights.',
  ),
  aurora3(
    'Aurora edge v3',
    'Aurora edge v2, calmer: the lights fainter, their haze barely there, '
        'swelling less and moving at half the speed.',
  ),
  aurora31(
    'Aurora edge v3.1 (glow)',
    'v3 with a soft glow of its colours spreading outward from the edge, '
        'so it seems to give off light.',
  ),
  aurora32(
    'Aurora edge v3.2 (spill)',
    'v3 with its colours spilling a little way into the field, as light on '
        'the inside of the edge.',
  ),
  aurora33(
    'Aurora edge v3.3 (shimmer)',
    "v3 with faint brighter streaks drifting along the edge, like an "
        "aurora's curtains.",
  ),
  aurora34(
    'Aurora edge v3.4 (all three)',
    'v3 with the glow, the spill and the shimmer together.',
  ),
  aurora4(
    'Aurora edge v4',
    'v3 with the glow and the shimmer together, no spill. The glow a little '
        "softer than v3.1's.",
  ),
  aurora41(
    'Aurora edge v4.1 (colour drift)',
    'v4 with the colours themselves slowly drifting: the whole palette '
        'wanders a little either side of the accent and back.',
  ),
  aurora42(
    'Aurora edge v4.2 (bloom)',
    "v4 with each light blooming outward where it is, so the glow is "
        "brighter around the lights rather than even all round.",
  ),
  aurora43(
    'Aurora edge v4.3 (breathing glow)',
    'v4 with the glow slowly rising and falling, about every half minute.',
  ),
  aurora44(
    'Aurora edge v4.4 (typing pulse)',
    'v4 that answers your typing: each keystroke brightens the edge and '
        'its glow for a moment, fading back.',
  ),
  aurora5(
    'Aurora edge v5',
    "v4 with v4.1's colour drift and v4.2's bloom, a little softer. Each "
        'light keeps to its own stretch of the edge and drifts its colour on '
        'its own, so they never pile up or turn one shade together.',
  ),
  aurora51(
    'Aurora edge v5.1 (60%)',
    "v5 with its colours kept to 60% as far from the accent: 75° away at "
        'most.',
  ),
  aurora52(
    'Aurora edge v5.2 (40%)',
    "v5 with its colours kept to 40% as far from the accent: 50° away at "
        'most.',
  ),
  aurora53(
    'Aurora edge v5.3 (25%)',
    "v5 with its colours kept to 25% as far from the accent: 30° away at "
        'most, close neighbours only.',
  ),
  aurora54(
    'Aurora edge v5.4 (12%)',
    'v5 in shades of the accent alone, its colours 15° away at most.',
  ),
  aurora6('Aurora edge v6', 'v5.1, its bloom turned down a tenth.');

  const _Study(this.label, this.description);
  final String label, description;

  bool get isAurora => name.startsWith('aurora');
}

class GaiaTextFieldStudies extends StatelessWidget {
  const GaiaTextFieldStudies({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    Widget panel(String title, String description, Widget field) => Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: gaiaSurface(theme.colorScheme.primary),
          borderRadius: BorderRadius.circular(GaiaRadius.panel),
          border: Border.all(color: GaiaInk.hairline),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: GaiaInk.bright,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 2),
            Text(description, style: muted),
            const SizedBox(height: 12),
            field,
          ],
        ),
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Hover, click into and type in each; they grow to five lines.',
          style: muted,
        ),
        const SizedBox(height: 8),
        panel(
          'Current',
          'Gaia\'s text field as it is now (Aurora edge v6), for comparison.',
          const _Current(),
        ),
        for (final study in _Study.values)
          panel(study.label, study.description, _StudyField(study: study)),
      ],
    );
  }
}

/// The attach and send buttons, as the composer has them.
Widget _attach() => GaiaButton(icon: Icons.add, size: 30, onPressed: () {});
Widget _send() =>
    GaiaButton(icon: Icons.arrow_upward, size: 30, onPressed: () {});

class _Current extends StatefulWidget {
  const _Current();

  @override
  State<_Current> createState() => _CurrentState();
}

class _CurrentState extends State<_Current> {
  final _text = TextEditingController();
  final _focus = FocusNode();

  @override
  void dispose() {
    _text.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => GaiaTextField(
    controller: _text,
    focusNode: _focus,
    minLines: 1,
    maxLines: 5,
    hintText: 'Message Gaia',
    leading: Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: _attach(),
    ),
    trailing: _send(),
  );
}

/// A composer drawn as [study].
class _StudyField extends StatefulWidget {
  const _StudyField({required this.study});

  final _Study study;

  @override
  State<_StudyField> createState() => _StudyFieldState();
}

class _StudyFieldState extends State<_StudyField>
    with TickerProviderStateMixin {
  final _text = TextEditingController();
  final _focus = FocusNode();
  var _hovered = false;

  /// The orbit's arc, a turn every four seconds while it has focus; for
  /// the aurora, a minute that its lights loop over (two for v3, at half
  /// the speed).
  late final _spin = AnimationController(
    vsync: this,
    duration: Duration(
      seconds: switch (widget.study) {
        _Study.aurora || _Study.aurora2 => 60,
        final study when study.isAurora => 120,
        _ => 4,
      },
    ),
  );

  /// Aurora v4.4's flare, run from 0 on each keystroke; at rest at 1.
  late final _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 700),
    value: 1,
  );
  var _lastText = '';

  @override
  void initState() {
    super.initState();
    _focus.addListener(() {
      if (widget.study == _Study.orbit || widget.study.isAurora) {
        _focus.hasFocus ? _spin.repeat() : _spin.stop();
      }
      setState(() {});
    });
    if (widget.study == _Study.aurora44) {
      // Only text changes, not the caret moving.
      _text.addListener(() {
        if (_text.text == _lastText) return;
        _lastText = _text.text;
        _pulse.forward(from: 0);
      });
    }
  }

  @override
  void dispose() {
    _spin.dispose();
    _pulse.dispose();
    _text.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent = theme.colorScheme.primary;
    final focused = _focus.hasFocus;
    final study = widget.study;

    // The quiet ring's edge: accent on focus, brighter on hover, a hairline
    // at rest.
    final edge = focused
        ? accent.withValues(alpha: 0.7)
        : Colors.white.withValues(alpha: _hovered ? 0.18 : 0.1);
    final radius = BorderRadius.circular(GaiaRadius.row);
    // The floating surface: a little above the field's fill, lighter than
    // a menu's.
    final raised = Color.lerp(gaiaFieldFill, Colors.white, 0.02)!;
    BoxShadow drop({required bool lifted, Color color = Colors.black}) =>
        BoxShadow(
          color: color.withValues(alpha: lifted ? 0.6 : 0.35),
          offset: Offset(0, lifted ? 10 : 3),
          blurRadius: lifted ? 28 : 10,
          spreadRadius: -6,
        );

    final row = Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Padding(padding: const EdgeInsets.all(5), child: _attach()),
        Expanded(
          child: TextField(
            controller: _text,
            focusNode: _focus,
            minLines: 1,
            maxLines: 5,
            style: theme.textTheme.bodyLarge!.copyWith(
              color: theme.colorScheme.onSurface,
            ),
            cursorColor: accent,
            decoration: const InputDecoration(
              hintText: 'Message Gaia',
              hintStyle: TextStyle(color: GaiaInk.faint),
              filled: false,
              border: InputBorder.none,
              enabledBorder: InputBorder.none,
              focusedBorder: InputBorder.none,
              isDense: true,
              contentPadding: EdgeInsets.symmetric(vertical: 13),
            ),
          ),
        ),
        Padding(padding: const EdgeInsets.all(5), child: _send()),
      ],
    );

    Widget box({
      required Color fill,
      Color? border,
      List<BoxShadow> shadows = const [],
      bool square = false,
      BorderRadius? shape,
      Widget? child,
    }) => AnimatedContainer(
      duration: GaiaMotion.move,
      curve: GaiaMotion.curve,
      decoration: BoxDecoration(
        color: fill,
        // Rails have no sides to round.
        borderRadius: square ? null : shape ?? radius,
        border: border == null ? null : Border.all(color: border),
        boxShadow: shadows,
      ),
      child: child ?? row,
    );

    // An outline painted over the field, eased between rest (0) and
    // focus (1).
    Widget outlined(CustomPainter Function(double t) painter) =>
        TweenAnimationBuilder<double>(
          tween: Tween(end: focused ? 1 : 0),
          duration: GaiaMotion.move,
          curve: GaiaMotion.curve,
          builder: (context, t, child) =>
              CustomPaint(foregroundPainter: painter(t), child: child),
          child: row,
        );

    final Widget field = switch (study) {
      _Study.ring => box(fill: gaiaFieldFill, border: edge),
      _Study.floating => box(
        fill: raised,
        border: Colors.white.withValues(
          alpha: focused || _hovered ? 0.14 : 0.08,
        ),
        shadows: [drop(lifted: focused)],
      ),
      _Study.floatingRing => box(
        fill: raised,
        border: edge,
        shadows: [drop(lifted: focused)],
      ),
      _Study.liftedRing => box(
        fill: focused ? raised : gaiaFieldFill,
        border: edge,
        shadows: [
          focused
              ? drop(lifted: true)
              : const BoxShadow(color: Colors.transparent, spreadRadius: -6),
        ],
      ),
      _Study.tintedLift => box(
        fill: raised,
        border: edge,
        shadows: [
          drop(lifted: focused, color: focused ? accent : Colors.black),
        ],
      ),
      _Study.topLight => box(
        fill: raised,
        border: edge,
        shadows: [drop(lifted: focused)],
        child: Stack(
          children: [
            row,
            Positioned(
              left: 10,
              right: 10,
              top: 0,
              height: 1,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [
                      Colors.white.withValues(alpha: 0),
                      Colors.white.withValues(alpha: focused ? 0.5 : 0.3),
                      Colors.white.withValues(alpha: 0),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
      _Study.corners => box(
        fill: gaiaFieldFill,
        child: outlined(
          (t) => _CornerMarks(
            t: t,
            rest: Colors.white.withValues(alpha: _hovered ? 0.4 : 0.25),
            lit: accent,
          ),
        ),
      ),
      _Study.rails => box(
        fill: gaiaFieldFill,
        square: true,
        child: outlined(
          (t) => _Rails(
            t: t,
            rest: Colors.white.withValues(alpha: _hovered ? 0.18 : 0.1),
            lit: accent,
          ),
        ),
      ),
      _Study.dashed => box(
        fill: gaiaFieldFill,
        child: outlined(
          (t) => _Dashed(
            t: t,
            rest: Colors.white.withValues(alpha: _hovered ? 0.3 : 0.18),
            lit: accent.withValues(alpha: 0.7),
            radius: GaiaRadius.row,
          ),
        ),
      ),
      _Study.stacked => Stack(
        clipBehavior: Clip.none,
        children: [
          AnimatedPositioned(
            duration: GaiaMotion.move,
            curve: GaiaMotion.curve,
            left: 10,
            right: 10,
            top: 0,
            bottom: focused ? -8 : -5,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: Color.lerp(gaiaFieldFill, Colors.black, 0.25),
                borderRadius: radius,
                border: Border.all(
                  color: focused
                      ? accent.withValues(alpha: 0.35)
                      : Colors.white.withValues(alpha: 0.07),
                ),
              ),
            ),
          ),
          box(fill: gaiaFieldFill, border: edge),
        ],
      ),
      _Study.tide => box(
        fill: gaiaFieldFill,
        border: edge,
        child: ClipRRect(
          borderRadius: radius,
          child: Stack(
            children: [
              Positioned.fill(
                child: Align(
                  alignment: Alignment.bottomCenter,
                  child: AnimatedFractionallySizedBox(
                    duration: const Duration(milliseconds: 400),
                    curve: GaiaMotion.curve,
                    widthFactor: 1,
                    heightFactor: focused ? 1 : 0,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.bottomCenter,
                          end: Alignment.topCenter,
                          colors: [
                            accent.withValues(alpha: 0.14),
                            accent.withValues(alpha: 0),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              row,
            ],
          ),
        ),
      ),
      _Study.inset => box(
        fill: Color.lerp(gaiaFieldFill, Colors.black, 0.3)!,
        border: focused
            ? accent.withValues(alpha: 0.6)
            : Colors.black.withValues(alpha: _hovered ? 0.6 : 0.45),
        child: ClipRRect(
          borderRadius: radius,
          child: Stack(
            children: [
              row,
              // The shade the top edge casts into the well.
              Positioned(
                left: 0,
                right: 0,
                top: 0,
                height: 10,
                child: IgnorePointer(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          Colors.black.withValues(alpha: 0.45),
                          Colors.black.withValues(alpha: 0),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              // Light catching the well's lower lip.
              Positioned(
                left: 10,
                right: 10,
                bottom: 0,
                height: 1,
                child: ColoredBox(color: Colors.white.withValues(alpha: 0.08)),
              ),
            ],
          ),
        ),
      ),
      _Study.halo => box(
        fill: gaiaFieldFill,
        border: edge,
        shadows: [
          BoxShadow(
            color: accent.withValues(
              alpha: focused
                  ? 0.35
                  : _hovered
                  ? 0.12
                  : 0,
            ),
            blurRadius: 18,
          ),
        ],
      ),
      _Study.orbit => box(
        fill: gaiaFieldFill,
        child: TweenAnimationBuilder<double>(
          tween: Tween(end: focused ? 1 : 0),
          duration: GaiaMotion.move,
          curve: GaiaMotion.curve,
          builder: (context, t, child) => AnimatedBuilder(
            animation: _spin,
            builder: (context, child) => CustomPaint(
              foregroundPainter: _Orbit(
                t: t,
                turn: _spin.value,
                rest: Colors.white.withValues(alpha: _hovered ? 0.18 : 0.1),
                lit: accent,
                radius: GaiaRadius.row,
              ),
              child: child,
            ),
            child: child,
          ),
          child: row,
        ),
      ),
      // As round as the field is tall on one line: the buttons' 30 and the
      // 5 round them.
      _Study.pill => box(
        fill: gaiaFieldFill,
        border: edge,
        shape: BorderRadius.circular(20),
      ),
      _Study.underline => box(
        fill: gaiaFieldFill,
        shape: const BorderRadius.vertical(
          top: Radius.circular(GaiaRadius.row),
        ),
        child: Stack(
          children: [
            row,
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: IgnorePointer(
                child: AnimatedContainer(
                  duration: GaiaMotion.move,
                  curve: GaiaMotion.curve,
                  height: focused ? 2 : 1,
                  color: focused
                      ? accent
                      : Colors.white.withValues(alpha: _hovered ? 0.3 : 0.18),
                ),
              ),
            ),
          ],
        ),
      ),
      _Study.spine => box(
        fill: gaiaFieldFill,
        border: Colors.white.withValues(alpha: _hovered ? 0.14 : 0.08),
        child: ClipRRect(
          borderRadius: radius,
          child: Stack(
            children: [
              row,
              Positioned(
                left: 0,
                top: 0,
                bottom: 0,
                width: 3,
                child: IgnorePointer(
                  child: Center(
                    child: AnimatedFractionallySizedBox(
                      duration: GaiaMotion.move,
                      curve: GaiaMotion.curve,
                      widthFactor: 1,
                      heightFactor: focused ? 1 : 0.4,
                      child: AnimatedContainer(
                        duration: GaiaMotion.move,
                        curve: GaiaMotion.curve,
                        color: focused
                            ? accent
                            : Colors.white.withValues(
                                alpha: _hovered ? 0.3 : 0.18,
                              ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
      // Every aurora: the studies above are all the rest.
      _ => box(
        fill: gaiaFieldFill,
        child: TweenAnimationBuilder<double>(
          tween: Tween(end: focused ? 1 : 0),
          duration: GaiaMotion.move,
          curve: GaiaMotion.curve,
          builder: (context, t, child) => AnimatedBuilder(
            animation: Listenable.merge([_spin, _pulse]),
            builder: (context, child) => CustomPaint(
              foregroundPainter: _Aurora(
                t: t,
                time: _spin.value,
                rest: Colors.white.withValues(alpha: _hovered ? 0.18 : 0.1),
                accent: accent,
                radius: GaiaRadius.row,
                full: study != _Study.aurora,
                calm: study != _Study.aurora && study != _Study.aurora2,
                glow: switch (study) {
                  _Study.aurora31 || _Study.aurora34 => 1,
                  _ when study.index >= _Study.aurora4.index => 0.65,
                  _ => 0,
                },
                spill: study == _Study.aurora32 || study == _Study.aurora34,
                shimmer:
                    study == _Study.aurora33 ||
                    study == _Study.aurora34 ||
                    study.index >= _Study.aurora4.index,
                drift:
                    study == _Study.aurora41 ||
                    study.index >= _Study.aurora5.index,
                bloom: switch (study) {
                  _Study.aurora42 => 1,
                  _Study.aurora6 => 0.765,
                  _ when study.index >= _Study.aurora5.index => 0.85,
                  _ => 0,
                },
                spread: study.index >= _Study.aurora5.index,
                range: switch (study) {
                  _Study.aurora51 || _Study.aurora6 => 0.6,
                  _Study.aurora52 => 0.4,
                  _Study.aurora53 => 0.25,
                  _Study.aurora54 => 0.12,
                  _ => 1,
                },
                breathe: study == _Study.aurora43,
                pulse: 1 - _pulse.value,
              ),
              child: child,
            ),
            child: child,
          ),
          child: row,
        ),
      ),
    };

    return MouseRegion(
      cursor: SystemMouseCursors.text,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        // A click anywhere on it, buttons aside, puts the caret in it.
        onTap: _focus.requestFocus,
        child: field,
      ),
    );
  }
}

/// Four corner brackets, running [t] of the way along each side towards
/// the middle in [lit].
class _CornerMarks extends CustomPainter {
  _CornerMarks({required this.t, required this.rest, required this.lit});

  final double t;
  final Color rest, lit;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5
      ..strokeCap = StrokeCap.round
      ..color = Color.lerp(rest, lit, t)!;
    final across = ui.lerpDouble(10, size.width * 0.12, t)!;
    final down = ui.lerpDouble(8, size.height * 0.3, t)!;
    const r = GaiaRadius.row;
    final w = size.width - 0.75, h = size.height - 0.75;
    const o = 0.75;
    for (final (x, y, sx, sy) in [
      (o, o, 1.0, 1.0),
      (w, o, -1.0, 1.0),
      (o, h, 1.0, -1.0),
      (w, h, -1.0, -1.0),
    ]) {
      canvas.drawPath(
        Path()
          ..moveTo(x, y + sy * down)
          ..lineTo(x, y + sy * r)
          ..quadraticBezierTo(x, y, x + sx * r, y)
          ..lineTo(x + sx * across, y),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_CornerMarks old) =>
      old.t != t || old.rest != rest || old.lit != lit;
}

/// Hairlines along the top and bottom, with [lit] drawn out from their
/// middles [t] of the way.
class _Rails extends CustomPainter {
  _Rails({required this.t, required this.rest, required this.lit});

  final double t;
  final Color rest, lit;

  @override
  void paint(Canvas canvas, Size size) {
    final restPaint = Paint()..color = rest;
    final litPaint = Paint()..color = lit;
    final half = size.width / 2 * t;
    for (final y in [0.0, size.height - 1]) {
      canvas.drawRect(Rect.fromLTWH(0, y, size.width, 1), restPaint);
      if (t > 0) {
        canvas.drawRect(
          Rect.fromLTWH(size.width / 2 - half, y, half * 2, 1),
          litPaint,
        );
      }
    }
  }

  @override
  bool shouldRepaint(_Rails old) =>
      old.t != t || old.rest != rest || old.lit != lit;
}

/// A rounded edge in dashes whose gaps close as [t] runs to 1.
class _Dashed extends CustomPainter {
  _Dashed({
    required this.t,
    required this.rest,
    required this.lit,
    required this.radius,
  });

  final double t;
  final Color rest, lit;
  final double radius;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = Color.lerp(rest, lit, t)!;
    final outline = Path()
      ..addRRect(
        RRect.fromRectAndRadius(
          (Offset.zero & size).deflate(0.5),
          Radius.circular(radius),
        ),
      );
    if (t >= 1) {
      canvas.drawPath(outline, paint);
      return;
    }
    const dash = 5.0;
    final gap = 4.0 * (1 - t);
    for (final metric in outline.computeMetrics()) {
      for (var d = 0.0; d < metric.length; d += dash + gap) {
        canvas.drawPath(metric.extractPath(d, d + dash), paint);
      }
    }
  }

  @override
  bool shouldRepaint(_Dashed old) =>
      old.t != t || old.rest != rest || old.lit != lit;
}

/// A hairline edge in [rest], with an arc of [lit] fading in as [t] runs
/// to 1, [turn] of the way round from the top.
class _Orbit extends CustomPainter {
  _Orbit({
    required this.t,
    required this.turn,
    required this.rest,
    required this.lit,
    required this.radius,
  });

  final double t, turn;
  final Color rest, lit;
  final double radius;

  @override
  void paint(Canvas canvas, Size size) {
    final rrect = RRect.fromRectAndRadius(
      (Offset.zero & size).deflate(0.75),
      Radius.circular(radius),
    );
    canvas.drawRRect(
      rrect,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = rest,
    );
    if (t == 0) return;
    final arc = lit.withValues(alpha: lit.a * t);
    canvas.drawRRect(
      rrect,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..shader = SweepGradient(
          colors: [arc.withValues(alpha: 0), arc, arc.withValues(alpha: 0)],
          stops: const [0.6, 0.85, 1],
          transform: GradientRotation(turn * 2 * 3.141592653589793),
        ).createShader(Offset.zero & size),
    );
  }

  @override
  bool shouldRepaint(_Orbit old) =>
      old.t != t || old.turn != turn || old.rest != rest || old.lit != lit;
}

/// A rounded edge in [rest] that, as [t] runs to 1, takes on soft lights
/// in hues around [accent] which drift, swell and fade along it. [time]
/// runs 0 to 1 over a minute, and every light comes back to where it began.
/// [full] (v2) lays a wash of the same hues all the way round underneath,
/// turning once a minute, and adds more and wider lights. [calm] (v3)
/// keeps the lights fainter and steadier. The v3.x touches, each over the
/// wash: [glow] spreads it outward, [spill] lets it in onto the field, and
/// [shimmer] runs brighter streaks along it; [glow] is how strong the glow
/// is, 0 for none. The v4.x touches: [drift] wanders the palette's hue,
/// [bloom] lets each light glow outward (its strength, 0 for none),
/// [breathe] swells the glow, and
/// [pulse] (1 just after a keystroke, falling to 0) brightens it all.
/// [spread] (v5) gives each light its own stretch of the edge and its own
/// drift, and layers them instead of adding them, so that they can't
/// gather into one place or one shade, and runs its colours more
/// saturated and a little stronger, at the accent's own lightness. [range] scales how far every hue, and
/// its drift, strays from the accent (v5.x).
class _Aurora extends CustomPainter {
  _Aurora({
    required this.t,
    required this.time,
    required this.rest,
    required this.accent,
    required this.radius,
    required this.full,
    required this.calm,
    this.glow = 0,
    this.spill = false,
    this.shimmer = false,
    this.drift = false,
    this.bloom = 0,
    this.breathe = false,
    this.pulse = 0,
    this.spread = false,
    this.range = 1,
  });

  final double t, time, glow, pulse, bloom, range;
  final Color rest, accent;
  final double radius;
  final bool full, calm, spill, shimmer, drift, breathe, spread;

  /// Each light: its hue away from the accent, and how many times a minute
  /// it crosses, rises and swells, with a phase so they don't move as one.
  static const _lights = [
    (hue: 0.0, across: 2, rise: 3, phase: 0.0),
    (hue: 45.0, across: 3, rise: 2, phase: 2.1),
    (hue: -40.0, across: 1, rise: 4, phase: 4.2),
    (hue: 100.0, across: 4, rise: 1, phase: 1.3),
  ];

  /// v2's extra lights.
  static const _more = [
    (hue: 20.0, across: 3, rise: 5, phase: 3.4),
    (hue: -70.0, across: 2, rise: 3, phase: 5.5),
  ];

  @override
  void paint(Canvas canvas, Size size) {
    final rrect = RRect.fromRectAndRadius(
      (Offset.zero & size).deflate(0.75),
      Radius.circular(radius),
    );
    canvas.drawRRect(
      rrect,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = rest,
    );
    if (t == 0) return;
    final base = HSLColor.fromColor(accent);
    final turn = time * 2 * math.pi;
    // Up to 25° either side of the accent and back, once a loop; with a
    // [phase], out of step with the rest.
    Color hue(double shift, {double phase = 0}) => base
        .withHue(
          (base.hue +
                  range * (shift + (drift ? 25 * math.sin(turn + phase) : 0))) %
              360,
        )
        // v5 keeps the accent's own lightness, so a pale accent stays
        // pale; only kept off the ends, where no colour would show.
        .withLightness(spread ? base.lightness.clamp(0.5, 0.82) : 0.65)
        // v5 runs its hues at full colour, whatever the accent's.
        .withSaturation(
          spread ? math.max(base.saturation, 0.9) : base.saturation,
        )
        .toColor();
    // A keystroke's flare, easing off.
    final flare = 1 + 0.8 * Curves.easeOut.transform(pulse);
    if (full) {
      Shader wash(double alpha) => SweepGradient(
        colors: [
          // The last stop meets the first, so shares its phase.
          for (final (shift, phase) in [
            (0.0, 0.0),
            (45.0, 1.7),
            (-40.0, 3.4),
            (100.0, 5.1),
            (0.0, 0.0),
          ])
            hue(
              shift,
              phase: spread ? phase : 0,
            ).withValues(alpha: math.min(1, alpha * t * flare)),
        ],
        transform: GradientRotation(turn),
      ).createShader(Offset.zero & size);
      canvas.drawRRect(
        rrect,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5
          ..shader = wash(spread ? 0.45 : 0.3),
      );
      if (glow > 0) {
        // Rising and falling every half minute.
        final breath = breathe ? 0.6 + 0.4 * math.sin(4 * turn) : 1;
        canvas.drawRRect(
          rrect,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 6
            ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6)
            ..shader = wash(0.14 * glow * breath),
        );
      }
      if (spill) {
        canvas
          ..save()
          ..clipRRect(rrect)
          ..drawRRect(
            rrect,
            Paint()
              ..style = PaintingStyle.stroke
              ..strokeWidth = 18
              ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 10)
              ..shader = wash(0.1),
          )
          ..restore();
      }
      if (shimmer) {
        // Two sets of streaks of different widths drifting opposite ways,
        // so they never settle into a pattern. Each moves a whole number
        // of streaks a loop, to come back where it began.
        for (final (band, laps) in [
          (size.width / 7, 6),
          (size.width / 4, -4),
        ]) {
          final shift = time * 2 * band * laps;
          canvas.drawRRect(
            rrect,
            Paint()
              ..style = PaintingStyle.stroke
              ..strokeWidth = 1.5
              ..blendMode = BlendMode.plus
              ..shader = ui.Gradient.linear(
                Offset(shift, 0),
                Offset(shift + band, 0),
                [
                  Colors.white.withValues(alpha: 0),
                  Colors.white.withValues(alpha: 0.1 * t * flare),
                ],
                null,
                TileMode.mirror,
              ),
          );
        }
      }
    }
    final lights = full ? [..._lights, ..._more] : _lights;
    // Spread, each light's stretch of the edge.
    final slot = size.width / lights.length;
    for (final (i, light) in lights.indexed) {
      final p = light.phase;
      // Spread, a light wanders about the middle of its own stretch, on the
      // top edge or the bottom by turns, and reaches about as far as the
      // next one's, so neighbours meet but never all gather.
      final centre = spread
          ? Offset(
              slot * (i + 0.5) + 0.6 * slot * math.sin(light.across * turn + p),
              size.height * (i.isEven ? 0.15 : 0.85) +
                  size.height * 0.3 * math.sin(light.rise * turn + 2 * p),
            )
          : Offset(
              size.width * (0.5 + 0.55 * math.sin(light.across * turn + p)),
              size.height * (0.5 + 0.9 * math.sin(light.rise * turn + 2 * p)),
            );
      final reach = spread
          ? slot *
                (1.1 + 0.3 * math.sin((light.across + light.rise) * turn + p))
          : size.width *
                ((full ? 0.32 : 0.22) +
                    (full ? 0.12 : 0.1) *
                        math.sin((light.across + light.rise) * turn + p));
      // Brightness breathes too, so a light can all but go out.
      // Calm lights only dim a little, never going out or flaring.
      final swell = math.sin((light.rise + 1) * turn + 3 * p);
      final glow = calm ? 0.75 + 0.25 * swell : 0.5 + 0.5 * swell;
      final colour = hue(light.hue, phase: spread ? p : 0);
      // Added light runs together into one pale shade where lights
      // overlap; layered, each keeps its own colour.
      final blend = spread ? BlendMode.srcOver : BlendMode.plus;
      Shader shader(double alpha) => RadialGradient(
        colors: [
          colour.withValues(alpha: alpha * glow * t),
          colour.withValues(alpha: 0),
        ],
      ).createShader(Rect.fromCircle(center: centre, radius: reach));
      canvas
        ..drawRRect(
          rrect,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.5
            ..blendMode = blend
            ..shader = shader(
              spread
                  ? 0.4
                  : calm
                  ? 0.25
                  : 0.5,
            ),
        )
        // A faint haze around the line, as an aurora has; blooming, a
        // wider, brighter one.
        ..drawRRect(
          rrect,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = bloom > 0 ? 8 : 4
            ..blendMode = blend
            ..maskFilter = MaskFilter.blur(BlurStyle.normal, bloom > 0 ? 8 : 4)
            ..shader = shader(
              bloom > 0
                  ? 0.14 * bloom
                  : calm
                  ? 0.05
                  : 0.15,
            ),
        );
    }
  }

  @override
  bool shouldRepaint(_Aurora old) =>
      old.t != t ||
      old.time != time ||
      old.rest != rest ||
      old.accent != accent ||
      old.full != full ||
      old.calm != calm ||
      old.glow != glow ||
      old.spill != spill ||
      old.shimmer != shimmer ||
      old.drift != drift ||
      old.bloom != bloom ||
      old.breathe != breathe ||
      old.pulse != pulse ||
      old.spread != spread ||
      old.range != range;
}

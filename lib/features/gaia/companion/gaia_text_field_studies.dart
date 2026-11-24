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
  );

  const _Study(this.label, this.description);
  final String label, description;
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
          'The light that follows the cursor and the caret, for comparison.',
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

class _StudyFieldState extends State<_StudyField> {
  final _text = TextEditingController();
  final _focus = FocusNode();
  var _hovered = false;

  @override
  void initState() {
    super.initState();
    _focus.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
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
      Widget? child,
    }) => AnimatedContainer(
      duration: GaiaMotion.move,
      curve: GaiaMotion.curve,
      decoration: BoxDecoration(
        color: fill,
        // Rails have no sides to round.
        borderRadius: square ? null : radius,
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
          builder: (context, t, child) => CustomPaint(
            foregroundPainter: painter(t),
            child: child,
          ),
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
          drop(
            lifted: focused,
            color: focused ? accent : Colors.black,
          ),
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

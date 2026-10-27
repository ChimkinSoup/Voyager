import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:voyager/features/gaia/companion/gaia_button.dart';
import 'package:voyager/features/gaia/companion/gaia_orb_materials.dart';
import 'package:voyager/features/gaia/companion/gaia_spinner.dart';

/// An isolated Astral core study with state, arrival, light and size previews.
/// The preview's own stars gather into it without changing the live chat.
class GaiaOrbStudio extends StatefulWidget {
  const GaiaOrbStudio({super.key});

  @override
  State<GaiaOrbStudio> createState() => _GaiaOrbStudioState();
}

class _GaiaOrbStudioState extends State<GaiaOrbStudio> {
  var _mood = GaiaOrbMood.idle;
  var _size = 112.0;
  var _paused = false;
  var _arrival = 0;
  var _gather = 0;
  var _burst = 0;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    Widget action({
      required String label,
      required IconData icon,
      required VoidCallback onPressed,
    }) => IntrinsicWidth(
      child: GaiaButton(label: label, icon: icon, onPressed: onPressed),
    );
    Widget study(GaiaOrbDesign design) => Column(
      key: ValueKey(design),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: ColoredBox(
            color: theme.scaffoldBackgroundColor,
            child: SizedBox(
              height: 220,
              width: double.infinity,
              child: GaiaOrbStudy(
                design: design,
                mood: _mood,
                diameter: _size,
                paused: _paused,
                arrival: _arrival,
                gather: _gather,
                burst: _burst,
              ),
            ),
          ),
        ),
        const SizedBox(height: 8),
        Text(design.name, style: theme.textTheme.titleSmall),
        const SizedBox(height: 2),
        Text(design.description, style: muted),
      ],
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Astral core appearance. Message transitions are below.',
          style: muted,
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final mood in GaiaOrbMood.values)
              ChoiceChip(
                label: Text(mood.label),
                selected: _mood == mood,
                onSelected: (_) => setState(() => _mood = mood),
              ),
          ],
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            action(
              label: 'Gather stars',
              icon: Icons.auto_awesome,
              onPressed: () => setState(() {
                _mood = GaiaOrbMood.thinking;
                _paused = false;
                _gather++;
              }),
            ),
            action(
              label: 'Replay arrival',
              icon: Icons.replay,
              onPressed: () => setState(() {
                if (_mood == GaiaOrbMood.done) _mood = GaiaOrbMood.idle;
                _paused = false;
                _arrival++;
              }),
            ),
            action(
              label: _paused ? 'Play' : 'Pause',
              icon: _paused ? Icons.play_arrow : Icons.pause,
              onPressed: () => setState(() => _paused = !_paused),
            ),
            action(
              label: 'Pulse',
              icon: Icons.flare,
              onPressed: () => setState(() {
                if (_mood == GaiaOrbMood.done) _mood = GaiaOrbMood.idle;
                _paused = false;
                _burst++;
              }),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final preset in const {
              'Showcase · 112 px': 112.0,
              'Chat · 48 px': 48.0,
            }.entries)
              ChoiceChip(
                label: Text(preset.key),
                selected: _size == preset.value,
                onSelected: (_) => setState(() => _size = preset.value),
              ),
          ],
        ),
        const SizedBox(height: 12),
        Text(
          'Arrival starts with light, then traces the orbits. Done folds those '
          'orbits into the model mark; switching back opens them again.',
          style: muted,
        ),
        const SizedBox(height: 8),
        study(GaiaOrbDesign.astral),
        const SizedBox(height: 20),
        Text('Loading spinner', style: theme.textTheme.titleSmall),
        const SizedBox(height: 8),
        Text('Astral core, reduced to two orbits and a light.', style: muted),
        const SizedBox(height: 12),
        const Wrap(
          spacing: 20,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            _SpinnerSample(size: 12),
            _SpinnerSample(size: 16),
            _SpinnerSample(size: 24),
            _SpinnerSample(size: 36),
          ],
        ),
      ],
    );
  }
}

class _SpinnerSample extends StatelessWidget {
  const _SpinnerSample({required this.size});

  final double size;

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      SizedBox.square(
        dimension: 44,
        child: Center(child: GaiaSpinner(size: size)),
      ),
      Text('${size.round()} px', style: Theme.of(context).textTheme.bodySmall),
    ],
  );
}

/// Every thinking and replying style side by side, each looping its own
/// state, and a whole message played through with the pair picked.
class GaiaOrbMotionStudies extends StatefulWidget {
  const GaiaOrbMotionStudies({super.key});

  @override
  State<GaiaOrbMotionStudies> createState() => _GaiaOrbMotionStudiesState();
}

class _GaiaOrbMotionStudiesState extends State<GaiaOrbMotionStudies> {
  var _thinking = GaiaOrbThinking.classic;
  var _replying = GaiaOrbReplying.classic;
  var _mood = GaiaOrbMood.thinking;
  final _timers = <Timer>[];

  @override
  void dispose() {
    for (final timer in _timers) {
      timer.cancel();
    }
    super.dispose();
  }

  void _setMood(GaiaOrbMood mood) {
    for (final timer in _timers) {
      timer.cancel();
    }
    _timers.clear();
    setState(() => _mood = mood);
  }

  /// A message from start to finish: thinking, the reply, then the mark.
  void _play() {
    _setMood(GaiaOrbMood.idle);
    // Scaled by [timeDilation] so slow animations get the whole message.
    void at(int ms, GaiaOrbMood mood) => _timers.add(
      Timer(Duration(milliseconds: ms) * timeDilation, () {
        if (mounted) setState(() => _mood = mood);
      }),
    );
    at(500, GaiaOrbMood.thinking);
    at(4500, GaiaOrbMood.speaking);
    at(9000, GaiaOrbMood.done);
  }

  Widget _tile({
    required String label,
    required String description,
    required bool selected,
    required Widget orb,
    required VoidCallback onTap,
  }) {
    final theme = Theme.of(context);
    return Material(
      color: theme.scaffoldBackgroundColor,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(
          color: selected ? theme.colorScheme.primary : Colors.transparent,
          width: 1.5,
        ),
      ),
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(height: 120, child: orb),
              Text(label, style: theme.textTheme.titleSmall),
              const SizedBox(height: 2),
              Text(
                description,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// [tiles] two to a row, each row as tall as its taller tile.
  Widget _pairs(List<Widget> tiles) => Column(
    children: [
      for (var i = 0; i < tiles.length; i += 2)
        Padding(
          padding: EdgeInsets.only(top: i == 0 ? 0 : 8),
          child: IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(child: tiles[i]),
                const SizedBox(width: 8),
                Expanded(
                  child: i + 1 < tiles.length ? tiles[i + 1] : const SizedBox(),
                ),
              ],
            ),
          ),
        ),
    ],
  );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Each study loops its own state. Tap one to play it in the '
          'message below.',
          style: muted,
        ),
        const SizedBox(height: 12),
        Text('Thinking', style: theme.textTheme.labelLarge),
        const SizedBox(height: 6),
        _pairs([
          for (final style in GaiaOrbThinking.values)
            _tile(
              label: style.label,
              description: style.description,
              selected: _thinking == style,
              onTap: () => setState(() => _thinking = style),
              orb: GaiaOrbStudy(
                design: GaiaOrbDesign.astral,
                mood: GaiaOrbMood.thinking,
                diameter: 72,
                thinkingStyle: style,
              ),
            ),
        ]),
        const SizedBox(height: 12),
        Text('Replying', style: theme.textTheme.labelLarge),
        const SizedBox(height: 6),
        _pairs([
          for (final style in GaiaOrbReplying.values)
            _tile(
              label: style.label,
              description: style.description,
              selected: _replying == style,
              onTap: () => setState(() => _replying = style),
              orb: GaiaOrbStudy(
                design: GaiaOrbDesign.astral,
                mood: GaiaOrbMood.speaking,
                diameter: 72,
                replyingStyle: style,
              ),
            ),
        ]),
        const SizedBox(height: 12),
        ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: ColoredBox(
            color: theme.scaffoldBackgroundColor,
            child: SizedBox(
              height: 220,
              width: double.infinity,
              child: GaiaOrbStudy(
                design: GaiaOrbDesign.astral,
                mood: _mood,
                thinkingStyle: _thinking,
                replyingStyle: _replying,
              ),
            ),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          '${_thinking.label} thinking, then ${_replying.label} replying.',
          style: theme.textTheme.titleSmall,
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            for (final mood in GaiaOrbMood.values)
              ChoiceChip(
                label: Text(mood.label),
                selected: _mood == mood,
                onSelected: (_) => _setMood(mood),
              ),
            IntrinsicWidth(
              child: GaiaButton(
                label: 'Play a message',
                icon: Icons.play_arrow,
                onPressed: _play,
              ),
            ),
          ],
        ),
      ],
    );
  }
}

enum GaiaOrbDesign {
  astral(
    'Astral core',
    'Long rays, a soft centre, and freely drifting particles inside luminous orbits.',
  );

  const GaiaOrbDesign(this.name, this.description);
  final String name;
  final String description;
  GaiaOrbMaterial get material => GaiaOrbMaterial.astral;
}

enum GaiaOrbMood {
  idle('Idle'),
  thinking('Thinking'),
  speaking('Replying'),
  done('Done');

  const GaiaOrbMood(this.label);
  final String label;
}

/// An isolated study with the same thinking/replying/glyph vocabulary as the
/// real orb. Stable particle identities allow continuous deformation between
/// states and into the existing tier mark, rather than replacing the picture.
class GaiaOrbStudy extends StatefulWidget {
  const GaiaOrbStudy({
    super.key,
    required this.design,
    required this.mood,
    this.diameter = 112,
    this.tier = 1,
    this.paused = false,
    this.arrival = 0,
    this.gather = 0,
    this.burst = 0,
    this.thinkingStyle = GaiaOrbThinking.classic,
    this.replyingStyle = GaiaOrbReplying.classic,
  }) : assert(tier >= 0 && tier <= 2),
       assert(diameter > 0);

  final GaiaOrbDesign design;
  final GaiaOrbMood mood;
  final double diameter;
  final int tier;
  final bool paused;
  final int arrival;
  final int gather;
  final int burst;
  final GaiaOrbThinking thinkingStyle;
  final GaiaOrbReplying replyingStyle;

  @override
  State<GaiaOrbStudy> createState() => _GaiaOrbStudyState();
}

class _GaiaOrbStudyState extends State<GaiaOrbStudy>
    with SingleTickerProviderStateMixin {
  final _motion = _StudyMotion();
  late final Ticker _ticker = createTicker(_tick);
  var _last = Duration.zero;
  var _reduced = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reduced = MediaQuery.disableAnimationsOf(context);
    _sync();
  }

  @override
  void didUpdateWidget(GaiaOrbStudy oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.arrival != widget.arrival) {
      _motion.bloom = 0;
      _motion.burstAge = 4;
    }
    if (oldWidget.burst != widget.burst) {
      _motion.burstAge = 0;
      _motion.bloom = 1;
    }
    if (oldWidget.gather != widget.gather) _motion.gatherAge = 0;
    _sync();
  }

  void _sync() {
    if (_reduced) {
      _motion.snap(widget.mood);
      _motion.gatherAge = 4;
      _motion.burstAge = 4;
    }
    final run =
        !_reduced &&
        !widget.paused &&
        TickerMode.valuesOf(context).enabled &&
        GaiaAmbient.of(context) &&
        (widget.mood != GaiaOrbMood.done || _motion.gather < 0.999);
    if (run && !_ticker.isActive) {
      _last = Duration.zero;
      _ticker.start();
    } else if (!run) {
      _ticker.stop();
    }
  }

  void _tick(Duration elapsed) {
    final dt = math.min((elapsed - _last).inMicroseconds / 1e6, 0.05);
    _last = elapsed;
    _motion.step(dt, widget.mood, widget.thinkingStyle, widget.replyingStyle);
    if (widget.mood == GaiaOrbMood.done && _motion.gather >= 0.999) {
      _ticker.stop();
    }
  }

  @override
  void dispose() {
    _ticker.dispose();
    _motion.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Semantics(
    label: '${widget.design.name}, ${widget.mood.label} orb preview',
    child: MouseRegion(
      onHover: (event) {
        if (!_reduced && !widget.paused) {
          final centre = (context.size ?? Size.zero).center(Offset.zero);
          _motion.lookAt((event.localPosition - centre) * 0.035);
        }
      },
      onExit: (_) => _motion.lookAt(null),
      child: RepaintBoundary(
        child: CustomPaint(
          painter: _StudyPainter(
            motion: _motion,
            design: widget.design,
            diameter: widget.diameter,
            tier: widget.tier,
            thinkingStyle: widget.thinkingStyle,
            replyingStyle: widget.replyingStyle,
            accent: Theme.of(context).colorScheme.primary,
            ink: Theme.of(context).colorScheme.onSurface,
            surface: Theme.of(context).scaffoldBackgroundColor,
            devicePixelRatio: MediaQuery.devicePixelRatioOf(context),
          ),
          child: const SizedBox.expand(),
        ),
      ),
    ),
  );
}

class _StudyMotion extends GaiaOrbMotion {
  _StudyMotion() {
    bloom = 1;
  }

  double gatherAge = 4;
  double burstAge = 4;
  Offset? cursor;
  Offset lean = Offset.zero;

  void lookAt(Offset? value) => cursor = value;

  void snap(GaiaOrbMood mood) {
    snapTo(
      thinks: mood == GaiaOrbMood.thinking,
      speaks: mood == GaiaOrbMood.speaking,
      gathers: mood == GaiaOrbMood.done,
    );
    lean = Offset.zero;
    notifyListeners();
  }

  void step(
    double dt,
    GaiaOrbMood mood,
    GaiaOrbThinking thinkingStyle,
    GaiaOrbReplying replyingStyle,
  ) {
    advance(
      dt,
      thinks: mood == GaiaOrbMood.thinking,
      speaks: mood == GaiaOrbMood.speaking,
      gathers: mood == GaiaOrbMood.done,
      thinkingStyle: thinkingStyle,
      replyingStyle: replyingStyle,
    );
    gatherAge = math.min(gatherAge + dt, 4);
    burstAge = math.min(burstAge + dt, 4);
    lean = Offset.lerp(lean, cursor ?? Offset.zero, 1 - math.exp(-dt * 5))!;
    notifyListeners();
  }
}

const _tau = 2 * math.pi;
final _stars = List.generate(44, (i) {
  final random = math.Random(1907 + i * 31);
  return (
    x: random.nextDouble(),
    y: random.nextDouble(),
    radius: 0.45 + random.nextDouble() * 0.8,
    phase: random.nextDouble() * _tau,
  );
});

class _StudyPainter extends CustomPainter {
  _StudyPainter({
    required this.motion,
    required this.design,
    required this.diameter,
    required this.tier,
    required this.thinkingStyle,
    required this.replyingStyle,
    required this.accent,
    required this.ink,
    required this.surface,
    required this.devicePixelRatio,
  }) : super(repaint: motion);

  final _StudyMotion motion;
  final GaiaOrbDesign design;
  final double diameter, devicePixelRatio;
  final int tier;
  final GaiaOrbThinking thinkingStyle;
  final GaiaOrbReplying replyingStyle;
  final Color accent, ink, surface;

  @override
  void paint(Canvas canvas, Size size) {
    final m = motion;
    final t = m.clock.time;
    final centre = size.center(Offset.zero);
    final c = centre + m.lean * (1 - m.gather);
    final r = math.min(diameter / 2, size.shortestSide * 0.36);
    final paint = Paint();
    final lit = Color.lerp(accent, ink, 0.55)!;
    final gather = m.gatherAge < 3.4;

    // These are the preview's own stars, not the live chat's starfield.
    for (var i = 0; i < _stars.length; i++) {
      final star = _stars[i];
      final home = Offset(star.x * size.width, star.y * size.height);
      var point = home;
      var alpha = 0.16 + 0.12 * (0.5 + 0.5 * math.sin(t + star.phase));
      if (gather) {
        final age = (m.gatherAge - (i % 8) * 0.055).clamp(0.0, 3.0);
        final flight = Curves.easeInOutCubic.transform(
          (age / 1.65).clamp(0.0, 1.0),
        );
        final release = Curves.easeOutCubic.transform(
          ((age - 2) / 0.9).clamp(0.0, 1.0),
        );
        final pull = flight * (1 - release);
        final bend =
            Offset(-(home - c).dy, (home - c).dx) *
            (math.sin(pull * math.pi) * 0.32);
        point = Offset.lerp(home, c, pull)! + bend;
        alpha += pull * 0.55;
      }
      canvas.drawCircle(
        point,
        star.radius,
        paint..color = lit.withValues(alpha: alpha),
      );
    }

    paintGaiaMaterialOrb(
      canvas,
      size,
      material: design.material,
      centre: c,
      radius: r,
      clock: m.clock,
      thinking: m.thinking,
      replying: m.speaking,
      done: m.gather,
      revealAge: m.bloom * kGaiaAstralArrivalTime,
      burstAge: m.burstAge,
      accent: accent,
      ink: ink,
      surface: surface,
      tier: tier,
      devicePixelRatio: devicePixelRatio,
      thinkingStyle: thinkingStyle,
      replyingStyle: replyingStyle,
    );
  }

  @override
  bool shouldRepaint(_StudyPainter old) =>
      old.design != design ||
      old.diameter != diameter ||
      old.devicePixelRatio != devicePixelRatio ||
      old.accent != accent ||
      old.ink != ink ||
      old.surface != surface ||
      old.tier != tier ||
      old.thinkingStyle != thinkingStyle ||
      old.replyingStyle != replyingStyle ||
      old.motion != motion;
}

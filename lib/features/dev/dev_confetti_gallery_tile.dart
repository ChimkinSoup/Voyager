import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/effects/confetti.dart';

/// Side-by-side candidates for the to-do completion confetti, for picking
/// which one the checkbox should fire.
///
/// Browse-only: completing a task always fires [ConfettiEffect.taskComplete]
/// (#34 here) regardless of what's played. Switching it is a manual code
/// change — there is intentionally no live picker.
class DevConfettiGallerySection extends ConsumerWidget {
  const DevConfettiGallerySection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final panelOpen = ref.watch(devConfettiGalleryPanelOpenProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SwitchListTile(
          title: const Text('Confetti gallery'),
          subtitle: const Text(
            'Candidate to-do completion bursts. Tap a box to play one, or play '
            'them all side by side. Browse-only — does not change the live '
            'checkbox.',
          ),
          value: panelOpen,
          onChanged: (value) {
            ref.read(devConfettiGalleryPanelOpenProvider.notifier).state =
                value;
          },
        ),
        if (panelOpen) const _ConfettiGallery(),
      ],
    );
  }
}

/// One gallery entry: a numbered name plus the burst(s) it fires. Builders
/// take the theme accent so list-colored variants can be previewed.
class _ConfettiVariant {
  const _ConfettiVariant(this.label, this.build, {this.followUp});

  final String label;
  final List<ConfettiEffect> Function(Color accent) build;

  /// Optional second stage, fired [delay] after the first at [offset] from
  /// the checkbox (e.g. a firework exploding at the top of its rise).
  final ({
    Duration delay,
    Offset offset,
    List<ConfettiEffect> Function(Color accent) build,
  })?
  followUp;
}

const _gold = <Color>[
  Color(0xFFFFD166),
  Color(0xFFFFE8A3),
  Color(0xFFF4B942),
  Color(0xFFFFFFFF),
];

/// [_gold] mixed with shades of the list [accent].
List<Color> _goldAndAccent(Color accent) => [
  ..._gold,
  accent,
  Color.lerp(accent, Colors.white, 0.45)!,
  Color.lerp(accent, Colors.black, 0.25)!,
];

/// The ring of dots a [_variants] firework explodes into. [radius] scales the
/// launch speeds, and so how far out the ring spreads (1 = Fireworks' size).
ConfettiEffect _fireworkBurst(Color accent, {double radius = 1}) {
  return ConfettiEffect(
    particleCount: 24,
    colors: _goldAndAccent(accent),
    shape: ConfettiShape.dot,
    minParticleSize: 3,
    maxParticleSize: 5,
    spread: math.pi * 2,
    minSpeed: 140 * radius,
    maxSpeed: 200 * radius,
    gravity: 220,
    drift: 0,
    duration: const Duration(milliseconds: 1200),
  );
}

/// [_fireworkBurst] without gravity and with a much shorter life, so the dots
/// keep their launch direction and fade out mid-flight.
ConfettiEffect _flashBurst(Color accent, {double radius = 1}) {
  return _fireworkBurst(
    accent,
    radius: radius,
  ).copyWith(gravity: 0, duration: const Duration(milliseconds: 550));
}

/// Midway between [_fireworkBurst] and [_flashBurst]: lighter gravity and a
/// mid-length life.
ConfettiEffect _sagBurst(Color accent, {double radius = 1}) {
  return _fireworkBurst(
    accent,
    radius: radius,
  ).copyWith(gravity: 110, duration: const Duration(milliseconds: 850));
}

final _variants = <_ConfettiVariant>[
  _ConfettiVariant('Original', (_) => const [ConfettiEffect()]),
  _ConfettiVariant(
    'Pop',
    (_) => const [
      ConfettiEffect(
        particleCount: 18,
        spread: math.pi * 2,
        minSpeed: 120,
        maxSpeed: 220,
        gravity: 300,
        drift: 10,
        duration: Duration(milliseconds: 700),
        scale: 0.8,
      ),
    ],
  ),
  _ConfettiVariant(
    'Fountain',
    (_) => const [
      ConfettiEffect(
        particleCount: 30,
        spread: 0.5,
        minSpeed: 380,
        maxSpeed: 560,
        gravity: 1100,
        duration: Duration(milliseconds: 1300),
      ),
    ],
  ),
  _ConfettiVariant(
    'Shower',
    (_) => const [
      ConfettiEffect(
        particleCount: 70,
        spread: 2.2,
        minParticleSize: 6,
        maxParticleSize: 13,
        minSpeed: 220,
        maxSpeed: 480,
        duration: Duration(milliseconds: 1600),
      ),
    ],
  ),
  _ConfettiVariant(
    'Sparkle',
    (_) => const [
      ConfettiEffect(
        particleCount: 24,
        colors: _gold,
        shape: ConfettiShape.dot,
        minParticleSize: 3,
        maxParticleSize: 6,
        spread: math.pi * 2,
        minSpeed: 60,
        maxSpeed: 200,
        gravity: 0,
        drift: 6,
        duration: Duration(milliseconds: 900),
      ),
    ],
  ),
  _ConfettiVariant(
    'Sequins',
    (_) => const [
      ConfettiEffect(
        particleCount: 28,
        shape: ConfettiShape.dot,
        minParticleSize: 4,
        maxParticleSize: 7,
        spread: 1.1,
        minSpeed: 260,
        maxSpeed: 420,
        gravity: 900,
        drift: 18,
      ),
    ],
  ),
  _ConfettiVariant(
    'Side cannons',
    (_) => const [
      ConfettiEffect(
        particleCount: 16,
        spread: 0.45,
        direction: -math.pi / 2 - 0.85,
        minSpeed: 260,
        maxSpeed: 420,
      ),
      ConfettiEffect(
        particleCount: 16,
        spread: 0.45,
        direction: -math.pi / 2 + 0.85,
        minSpeed: 260,
        maxSpeed: 420,
      ),
    ],
  ),
  _ConfettiVariant(
    'List color',
    (accent) => [
      ConfettiEffect(
        colors: [
          accent,
          Color.lerp(accent, Colors.white, 0.45)!,
          Color.lerp(accent, Colors.black, 0.25)!,
        ],
      ),
    ],
  ),
  // Subtler set: fewer particles, tighter cones.
  _ConfettiVariant(
    'Mini',
    (_) => const [
      ConfettiEffect(
        particleCount: 12,
        spread: 0.9,
        minSpeed: 140,
        maxSpeed: 280,
        scale: 0.85,
      ),
    ],
  ),
  _ConfettiVariant(
    'Flick',
    (_) => const [
      ConfettiEffect(
        particleCount: 8,
        spread: 0.5,
        minSpeed: 220,
        maxSpeed: 340,
        gravity: 900,
        duration: Duration(milliseconds: 900),
      ),
    ],
  ),
  _ConfettiVariant(
    'Puff',
    (_) => const [
      ConfettiEffect(
        particleCount: 10,
        shape: ConfettiShape.dot,
        minParticleSize: 3,
        maxParticleSize: 6,
        spread: 1.0,
        minSpeed: 80,
        maxSpeed: 160,
        gravity: 200,
        drift: 8,
        duration: Duration(milliseconds: 800),
      ),
    ],
  ),
  _ConfettiVariant(
    'Gold flick',
    (_) => const [
      ConfettiEffect(
        particleCount: 10,
        colors: _gold,
        shape: ConfettiShape.dot,
        minParticleSize: 3,
        maxParticleSize: 6,
        spread: 0.6,
        minSpeed: 200,
        maxSpeed: 320,
        gravity: 700,
        drift: 10,
      ),
    ],
  ),
  _ConfettiVariant(
    'Tilt right',
    (_) => const [
      ConfettiEffect(
        particleCount: 12,
        spread: 0.6,
        direction: -math.pi / 2 + 0.5,
        minSpeed: 180,
        maxSpeed: 320,
      ),
    ],
  ),
  _ConfettiVariant(
    'Twin flick',
    (_) => const [
      ConfettiEffect(
        particleCount: 6,
        spread: 0.3,
        direction: -math.pi / 2 - 0.5,
        minSpeed: 200,
        maxSpeed: 320,
      ),
      ConfettiEffect(
        particleCount: 6,
        spread: 0.3,
        direction: -math.pi / 2 + 0.5,
        minSpeed: 200,
        maxSpeed: 320,
      ),
    ],
  ),
  _ConfettiVariant(
    'Float',
    (_) => const [
      ConfettiEffect(
        particleCount: 10,
        spread: 0.8,
        minSpeed: 100,
        maxSpeed: 200,
        gravity: 260,
        drift: 22,
        duration: Duration(milliseconds: 1400),
      ),
    ],
  ),
  _ConfettiVariant(
    'List color mini',
    (accent) => [
      ConfettiEffect(
        particleCount: 12,
        spread: 0.8,
        minSpeed: 150,
        maxSpeed: 300,
        colors: [
          accent,
          Color.lerp(accent, Colors.white, 0.45)!,
          Color.lerp(accent, Colors.black, 0.25)!,
        ],
      ),
    ],
  ),
  // Gold flick's dots in gold + list colors, thrown on Mini's arc with no
  // sideways sway, so they just go up and fall.
  _ConfettiVariant(
    'Gold + list toss',
    (accent) => [
      ConfettiEffect(
        particleCount: 12,
        colors: _goldAndAccent(accent),
        shape: ConfettiShape.dot,
        minParticleSize: 3,
        maxParticleSize: 6,
        spread: 0.9,
        minSpeed: 140,
        maxSpeed: 280,
        drift: 0,
        scale: 0.85,
      ),
    ],
  ),
  // #17's dots. Near-equal speeds so they spread as an expanding ring, with
  // light gravity so the ring holds its shape before settling down.
  _ConfettiVariant(
    'Ring',
    (accent) => [
      ConfettiEffect(
        particleCount: 16,
        colors: _goldAndAccent(accent),
        shape: ConfettiShape.dot,
        minParticleSize: 3,
        maxParticleSize: 6,
        spread: math.pi * 2,
        minSpeed: 150,
        maxSpeed: 170,
        gravity: 150,
        drift: 0,
        duration: Duration(milliseconds: 1000),
        scale: 0.85,
      ),
    ],
  ),
  // A single spark rises ~150px (520²/(2·900)) and peaks at ~580ms, where the
  // follow-up bursts into a slow ring of #17's dots.
  _ConfettiVariant(
    'Fireworks',
    (_) => const [
      ConfettiEffect(
        particleCount: 1,
        colors: [Color(0xFFFFE8A3)],
        shape: ConfettiShape.dot,
        minParticleSize: 4,
        maxParticleSize: 4,
        spread: 0,
        minSpeed: 520,
        maxSpeed: 520,
        gravity: 900,
        drift: 0,
        duration: Duration(milliseconds: 620),
      ),
    ],
    followUp: (
      delay: const Duration(milliseconds: 580),
      offset: const Offset(0, -150),
      build: (accent) => [_fireworkBurst(accent)],
    ),
  ),
  // #17 thrown harder: apex roughly 2x as high, with a longer life so the
  // dots have time to fall back down.
  _ConfettiVariant(
    'High toss',
    (accent) => [
      ConfettiEffect(
        particleCount: 12,
        colors: _goldAndAccent(accent),
        shape: ConfettiShape.dot,
        minParticleSize: 3,
        maxParticleSize: 6,
        spread: 0.9,
        minSpeed: 220,
        maxSpeed: 400,
        drift: 0,
        duration: const Duration(milliseconds: 1500),
        scale: 0.85,
      ),
    ],
  ),
  // Fireworks' explosion with no rise, centered on the checkbox, at a range
  // of radii.
  _ConfettiVariant(
    'Burst S',
    (accent) => [_fireworkBurst(accent, radius: 0.5)],
  ),
  _ConfettiVariant(
    'Burst M',
    (accent) => [_fireworkBurst(accent, radius: 0.75)],
  ),
  _ConfettiVariant('Burst L', (accent) => [_fireworkBurst(accent)]),
  _ConfettiVariant(
    'Burst XL',
    (accent) => [_fireworkBurst(accent, radius: 1.4)],
  ),
  // The same bursts with no gravity and a short life, so the dots fly
  // straight out as an expanding ring and fade before they'd fall.
  _ConfettiVariant('Ring XS', (accent) => [_flashBurst(accent, radius: 0.35)]),
  _ConfettiVariant('Ring S', (accent) => [_flashBurst(accent, radius: 0.5)]),
  _ConfettiVariant('Ring M', (accent) => [_flashBurst(accent, radius: 0.75)]),
  _ConfettiVariant('Ring L', (accent) => [_flashBurst(accent)]),
  // Between Burst and Ring: half Burst's gravity and a mid-length life, so the
  // ring expands, then sags a little as it fades.
  _ConfettiVariant('Sag XS', (accent) => [_sagBurst(accent, radius: 0.35)]),
  _ConfettiVariant('Sag S', (accent) => [_sagBurst(accent, radius: 0.5)]),
  _ConfettiVariant('Sag M', (accent) => [_sagBurst(accent, radius: 0.75)]),
  _ConfettiVariant('Sag L', (accent) => [_sagBurst(accent)]),
  // Sag S with a wider speed range (Sag S launches at 70–100), so dots land
  // at varied distances and fill the circle instead of forming one ring.
  _ConfettiVariant(
    'Sag S filled',
    (accent) => [_sagBurst(accent, radius: 0.5).copyWith(minSpeed: 15)],
  ),
  _ConfettiVariant(
    'Sag S half-filled',
    (accent) => [_sagBurst(accent, radius: 0.5).copyWith(minSpeed: 45)],
  ),
];

class _ConfettiGallery extends StatefulWidget {
  const _ConfettiGallery();

  @override
  State<_ConfettiGallery> createState() => _ConfettiGalleryState();
}

class _ConfettiGalleryState extends State<_ConfettiGallery> {
  late final _cellKeys = List.generate(_variants.length, (_) => GlobalKey());

  void _play(int index) {
    final cellContext = _cellKeys[index].currentContext;
    if (cellContext == null) return;
    final accent = Theme.of(context).colorScheme.primary;
    final variant = _variants[index];
    for (final effect in variant.build(accent)) {
      ConfettiOverlay.burstFromContext(cellContext, effect: effect);
    }
    final followUp = variant.followUp;
    if (followUp == null) return;
    final box = cellContext.findRenderObject()! as RenderBox;
    final center = box.localToGlobal(box.size.center(Offset.zero));
    Future.delayed(followUp.delay, () {
      if (!mounted) return;
      for (final effect in followUp.build(accent)) {
        ConfettiOverlay.burst(
          context,
          globalPosition: center + followUp.offset,
          effect: effect,
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          FilledButton.tonal(
            onPressed: () {
              for (var i = 0; i < _variants.length; i++) {
                _play(i);
              }
            },
            child: const Text('Play all'),
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 24,
            runSpacing: 16,
            children: [
              for (var i = 0; i < _variants.length; i++)
                _ConfettiCell(
                  number: i + 1,
                  label: _variants[i].label,
                  originKey: _cellKeys[i],
                  onTap: () => _play(i),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _ConfettiCell extends StatelessWidget {
  const _ConfettiCell({
    required this.number,
    required this.label,
    required this.originKey,
    required this.onTap,
  });

  final int number;
  final String label;
  final GlobalKey originKey;
  final VoidCallback onTap;

  static const _size = 96.0;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SizedBox(
      width: _size,
      child: Column(
        children: [
          InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(8),
            child: Container(
              width: _size,
              height: _size,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: theme.dividerColor),
              ),
              // Checkbox-sized marker the burst is anchored to, so the
              // preview matches the scale it'll have in the to-do list.
              child: Container(
                key: originKey,
                width: 18,
                height: 18,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(5),
                  border: Border.all(
                    color: theme.colorScheme.primary,
                    width: 2,
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            '$number. $label',
            style: theme.textTheme.labelMedium,
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}

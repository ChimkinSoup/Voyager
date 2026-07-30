import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/widgets/geometric_texture.dart';
import 'package:voyager/core/widgets/glass_button.dart';

class DevGeometricWaveSection extends ConsumerWidget {
  const DevGeometricWaveSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final panelOpen = ref.watch(devGeometricWavePanelOpenProvider);
    final params = ref.watch(geometricWaveParamsProvider);
    final notifier = ref.read(geometricWaveParamsProvider.notifier);

    void update(GeometricWaveParams next) => notifier.update(next);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SwitchListTile(
          title: const Text('Geometric wave tuning'),
          subtitle: const Text(
            'Background wave train that makes clustered triangles twinkle as it sweeps (saved locally)',
          ),
          value: panelOpen,
          onChanged: (value) {
            ref.read(devGeometricWavePanelOpenProvider.notifier).state = value;
          },
        ),
        if (panelOpen) ...[
          const SizedBox(height: 8),
          SwitchListTile(
            title: const Text('Wave enabled'),
            subtitle: const Text('Off by default — turn on to animate the background'),
            value: params.enabled,
            onChanged: (v) => update(params.copyWith(enabled: v)),
          ),
          SwitchListTile(
            title: const Text('Scatter mode'),
            subtitle: const Text(
              'Replaces the wave: triangles fire independently all over the screen, and the accent gradient switches off. Animates on its own — no need for "Wave enabled". Makes the texture panel\'s intensity/focal sliders inert.',
            ),
            value: params.scatterMode,
            onChanged: (v) => update(params.copyWith(scatterMode: v)),
          ),
          if (params.scatterMode)
            _WaveSlider(
              label: 'Lit amount',
              subtitle: 'What fraction of triangles are lit at any instant. Independent of Pop hold — stretching the hold slows each flash without lighting more of them.',
              value: params.scatterLitAmount,
              min: 0.01,
              max: 0.25,
              divisions: 48,
              display: '${(params.scatterLitAmount * 100).toStringAsFixed(0)}%',
              onChanged: (v) => update(params.copyWith(scatterLitAmount: v)),
            ),
          // Wave-only controls: scatter has no wavefront to shape, no direction
          // to travel, and derives its own cycle length from Lit amount.
          if (!params.scatterMode) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Text('Shape', style: Theme.of(context).textTheme.titleSmall),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: SegmentedButton<GeometricWaveShape>(
                segments: const [
                  ButtonSegment(
                    value: GeometricWaveShape.linear,
                    label: Text('Linear sweep'),
                  ),
                  ButtonSegment(
                    value: GeometricWaveShape.radial,
                    label: Text('Radial expand'),
                  ),
                ],
                selected: {params.shape},
                onSelectionChanged: (selection) =>
                    update(params.copyWith(shape: selection.first)),
              ),
            ),
            _WaveSlider(
              label: 'Direction',
              subtitle: 'Linear sweep travel direction, degrees (unused in radial mode)',
              value: params.directionDegrees,
              min: 0,
              max: 360,
              divisions: 72,
              display: '${params.directionDegrees.toStringAsFixed(0)}°',
              onChanged: (v) => update(params.copyWith(directionDegrees: v)),
            ),
            _WaveSlider(
              label: 'Speed',
              subtitle: 'Wavefront travel speed — higher = faster sweep/expand',
              value: params.speed,
              min: 0.05,
              max: 1.5,
              divisions: 145,
              display: params.speed.toStringAsFixed(2),
              onChanged: (v) => update(params.copyWith(speed: v)),
            ),
            _WaveSlider(
              label: 'Band width',
              subtitle: 'How thick the band of sparkles is — higher = more spread out',
              value: params.width,
              min: 0.02,
              max: 0.6,
              divisions: 58,
              display: params.width.toStringAsFixed(2),
              onChanged: (v) => update(params.copyWith(width: v)),
            ),
            _WaveSlider(
              label: 'Wave spacing',
              subtitle: 'Distance between simultaneous wavefronts — lower = more waves on screen at once',
              value: params.period,
              min: 0.3,
              max: 15.0,
              divisions: 147,
              display: '${params.period.toStringAsFixed(1)}s',
              onChanged: (v) => update(params.copyWith(period: v)),
            ),
          ],
          _WaveSlider(
            label: 'Pop hold',
            subtitle: 'How long each individual triangle stays lit as it flashes',
            value: params.popHoldSeconds,
            min: 0.1,
            max: 3.0,
            divisions: 290,
            display: '${params.popHoldSeconds.toStringAsFixed(2)}s',
            onChanged: (v) => update(params.copyWith(popHoldSeconds: v)),
          ),
          _WaveSlider(
            label: 'Pop scale',
            subtitle: 'How much popped triangles appear to grow',
            value: params.popScale,
            min: 1.0,
            max: 2.0,
            divisions: 100,
            display: '${params.popScale.toStringAsFixed(2)}x',
            onChanged: (v) => update(params.copyWith(popScale: v)),
          ),
          _WaveSlider(
            label: 'Pop brightness',
            subtitle: 'Extra brightness burst on popped triangles',
            value: params.popBrightness,
            min: 0.0,
            max: 1.2,
            divisions: 120,
            display: params.popBrightness.toStringAsFixed(2),
            onChanged: (v) => update(params.copyWith(popBrightness: v)),
          ),
          // Also wave-only: scatter bypasses the clustered mask to stay even,
          // and uses its own fixed fire probability so Lit amount can be exact.
          if (!params.scatterMode) ...[
            _WaveSlider(
              label: 'Mask density',
              subtitle: 'How many triangles are ever eligible to twinkle as the wave passes',
              value: params.maskDensity,
              min: 0.0,
              max: 1.0,
              divisions: 100,
              display: params.maskDensity.toStringAsFixed(2),
              onChanged: (v) => update(params.copyWith(maskDensity: v)),
            ),
            _WaveSlider(
              label: 'Twinkle sparsity',
              subtitle: 'What fraction of eligible triangles actually fire on each pass — lower = sparser, more individual sparkles',
              value: params.twinkleSparsity,
              min: 0.0,
              max: 1.0,
              divisions: 100,
              display: params.twinkleSparsity.toStringAsFixed(2),
              onChanged: (v) => update(params.copyWith(twinkleSparsity: v)),
            ),
          ],
          _WaveSlider(
            label: 'Brightness variance',
            subtitle: 'How much each flash\'s peak brightness varies, re-rolled every cycle — 0 = every flash identical',
            value: params.popBrightnessVariance,
            min: 0.0,
            max: 1.0,
            divisions: 100,
            display: params.popBrightnessVariance.toStringAsFixed(2),
            onChanged: (v) => update(params.copyWith(popBrightnessVariance: v)),
          ),
          _WaveSlider(
            label: 'Hinge tilt',
            subtitle: 'How far a triangle pitches as it lifts — 0 rises flat like an elevator, 1 keeps the hinged edge on the grid',
            value: params.tiltAmount,
            min: 0.0,
            max: 1.0,
            divisions: 100,
            display: params.tiltAmount.toStringAsFixed(2),
            onChanged: (v) => update(params.copyWith(tiltAmount: v)),
          ),
          _WaveSlider(
            label: 'Tilt shading',
            subtitle: 'How much the pitch shows as brightness across the face — 0 leaves the tilt visible only via its shadow',
            value: params.tiltShading,
            min: 0.0,
            max: 1.0,
            divisions: 100,
            display: params.tiltShading.toStringAsFixed(2),
            onChanged: (v) => update(params.copyWith(tiltShading: v)),
          ),
          _WaveSlider(
            label: 'Mass lag',
            subtitle: 'How long the physical lift trails the light flash — 0 re-couples them into one flat effect',
            value: params.massLagSeconds,
            min: 0.0,
            max: 0.5,
            divisions: 100,
            display: '${params.massLagSeconds.toStringAsFixed(2)}s',
            onChanged: (v) => update(params.copyWith(massLagSeconds: v)),
          ),
          _WaveSlider(
            label: 'Mass spring',
            subtitle: 'How much the lift overshoots and settles back — 0 glides to a stop with no bounce',
            value: params.massSpring,
            min: 0.0,
            max: 1.0,
            divisions: 100,
            display: params.massSpring.toStringAsFixed(2),
            onChanged: (v) => update(params.copyWith(massSpring: v)),
          ),
          _WaveSlider(
            label: 'Light direction',
            subtitle: 'Where the light shines from, degrees (225° = upper-left) — shadows fall the opposite way',
            value: params.shadowLightDegrees,
            min: 0,
            max: 360,
            divisions: 72,
            display: '${params.shadowLightDegrees.toStringAsFixed(0)}°',
            onChanged: (v) => update(params.copyWith(shadowLightDegrees: v)),
          ),
          _WaveSlider(
            label: 'Shadow offset',
            subtitle: 'How far a popped triangle throws its shadow — also how wide the visible crescent gets',
            value: params.shadowOffset,
            min: 0.0,
            max: 0.35,
            divisions: 70,
            display: params.shadowOffset.toStringAsFixed(2),
            onChanged: (v) => update(params.copyWith(shadowOffset: v)),
          ),
          _WaveSlider(
            label: 'Shadow softness',
            subtitle: 'Falloff at the shadow\'s outer edge — keep below the offset or it never reaches full strength',
            value: params.shadowSoftness,
            min: 0.01,
            max: 0.3,
            divisions: 58,
            display: params.shadowSoftness.toStringAsFixed(2),
            onChanged: (v) => update(params.copyWith(shadowSoftness: v)),
          ),
          _WaveSlider(
            label: 'Shadow strength',
            subtitle: 'How dark the shadow gets — 0 turns shadows off entirely',
            value: params.shadowStrength,
            min: 0.0,
            max: 1.0,
            divisions: 100,
            display: params.shadowStrength.toStringAsFixed(2),
            onChanged: (v) => update(params.copyWith(shadowStrength: v)),
          ),
          if (!params.scatterMode)
            _WaveSlider(
              label: 'Cluster scale',
              subtitle: 'How dense/tight the popped-triangle clusters are — lower = bigger clusters',
              value: params.maskClusterScale,
              min: 1.0,
              max: 20.0,
              divisions: 190,
              display: params.maskClusterScale.toStringAsFixed(1),
              onChanged: (v) => update(params.copyWith(maskClusterScale: v)),
            ),
          Align(
            alignment: Alignment.centerLeft,
            child: GlassButton(
              onPressed: () => unawaited(notifier.resetToDefaults()),
              label: 'Reset to defaults',
              dense: true,
            ),
          ),
        ],
      ],
    );
  }
}

class _WaveSlider extends StatelessWidget {
  const _WaveSlider({
    required this.label,
    required this.subtitle,
    required this.value,
    required this.min,
    required this.max,
    required this.divisions,
    required this.display,
    required this.onChanged,
  });

  final String label;
  final String subtitle;
  final double value;
  final double min;
  final double max;
  final int divisions;
  final String display;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  label,
                  style: Theme.of(context).textTheme.titleSmall,
                ),
              ),
              Text(
                display,
                style: Theme.of(context).textTheme.labelMedium?.copyWith(
                  color: Theme.of(context).colorScheme.primary,
                ),
              ),
            ],
          ),
          Text(subtitle, style: Theme.of(context).textTheme.bodySmall),
          Slider(
            value: value.clamp(min, max),
            min: min,
            max: max,
            divisions: divisions,
            onChanged: onChanged,
          ),
        ],
      ),
    );
  }
}

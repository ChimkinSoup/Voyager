import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/widgets/geometric_texture.dart';

class DevGeometricTextureSection extends ConsumerWidget {
  const DevGeometricTextureSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final panelOpen = ref.watch(devGeometricTexturePanelOpenProvider);
    final params = ref.watch(geometricTextureParamsProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SwitchListTile(
          title: const Text('Geometric texture tuning'),
          subtitle: const Text(
            'Live sliders for low-poly facet shader (session only)',
          ),
          value: panelOpen,
          onChanged: (value) {
            ref.read(devGeometricTexturePanelOpenProvider.notifier).state =
                value;
          },
        ),
        if (panelOpen) ...[
          const SizedBox(height: 8),
          _GeometricTextureSlider(
            label: 'Scale',
            subtitle: 'Triangle density — higher = smaller, more numerous facets',
            value: params.scale,
            min: 2,
            max: 30,
            divisions: 28,
            display: params.scale.toStringAsFixed(1),
            onChanged: (value) {
              ref.read(geometricTextureParamsProvider.notifier).state =
                  params.copyWith(scale: value);
            },
          ),
          _GeometricTextureSlider(
            label: 'Intensity',
            subtitle:
                'Facet contrast — 0.2 = subtle, 0.6 = deep dramatic shadows',
            value: params.intensity,
            min: 0.05,
            max: 0.6,
            divisions: 55,
            display: params.intensity.toStringAsFixed(2),
            onChanged: (value) {
              ref.read(geometricTextureParamsProvider.notifier).state =
                  params.copyWith(intensity: value);
            },
          ),
          _GeometricTextureSlider(
            label: 'Randomness',
            subtitle:
                'Vertex jitter — 0.0 = perfect grid, 0.9 = organic, 1.5 = chaotic',
            value: params.randomness,
            min: 0.0,
            max: 1.5,
            divisions: 150,
            display: params.randomness.toStringAsFixed(2),
            onChanged: (value) {
              ref.read(geometricTextureParamsProvider.notifier).state =
                  params.copyWith(randomness: value);
            },
          ),
          _GeometricTextureSlider(
            label: 'Shape complexity',
            subtitle:
                'Polygon mix — 0.0 = triangles only, 1.0 = quads + both triangle orientations',
            value: params.shapeComplexity,
            min: 0.0,
            max: 1.0,
            divisions: 100,
            display: params.shapeComplexity.toStringAsFixed(2),
            onChanged: (value) {
              ref.read(geometricTextureParamsProvider.notifier).state =
                  params.copyWith(shapeComplexity: value);
            },
          ),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              onPressed: () {
                ref.read(geometricTextureParamsProvider.notifier).state =
                    GeometricTextureParams.defaults;
              },
              child: const Text('Reset to defaults'),
            ),
          ),
        ],
      ],
    );
  }
}

class _GeometricTextureSlider extends StatelessWidget {
  const _GeometricTextureSlider({
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

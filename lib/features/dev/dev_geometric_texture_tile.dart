import 'dart:async';

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
    final notifier = ref.read(geometricTextureParamsProvider.notifier);

    void update(GeometricTextureParams next) => notifier.update(next);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SwitchListTile(
          title: const Text('Geometric texture tuning'),
          subtitle: const Text(
            'Live sliders for equilateral-triangle gradient shader (saved locally)',
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
            subtitle: 'Triangle density — higher = smaller, more numerous triangles',
            value: params.scale,
            min: 4,
            max: 24,
            divisions: 20,
            display: params.scale.toStringAsFixed(1),
            onChanged: (v) => update(params.copyWith(scale: v)),
          ),
          _GeometricTextureSlider(
            label: 'Intensity',
            subtitle:
                'Peak accent strength at focal point — 0.0 = invisible, 1.0 = saturated',
            value: params.intensity,
            min: 0.0,
            max: 1.0,
            divisions: 100,
            display: params.intensity.toStringAsFixed(2),
            onChanged: (v) => update(params.copyWith(intensity: v)),
          ),
          _GeometricTextureSlider(
            label: 'Variation floor',
            subtitle:
                'Minimum triangle brightness — higher = fewer very dark triangles',
            value: params.variationFloor,
            min: 0.5,
            max: 0.95,
            divisions: 45,
            display: params.variationFloor.toStringAsFixed(2),
            onChanged: (v) => update(params.copyWith(variationFloor: v)),
          ),
          _GeometricTextureSlider(
            label: 'Focal spread',
            subtitle:
                'Gradient radius — larger = color reaches further from the focal point',
            value: params.focalSpread,
            min: 0.1,
            max: 2.0,
            divisions: 190,
            display: params.focalSpread.toStringAsFixed(2),
            onChanged: (v) => update(params.copyWith(focalSpread: v)),
          ),
          _GeometricTextureSlider(
            label: 'Flash Brightness',
            subtitle: 'How much lighter triangles get when they flash',
            value: params.flashBrightness,
            min: 0.0,
            max: 1.0,
            divisions: 100,
            display: params.flashBrightness.toStringAsFixed(2),
            onChanged: (v) => update(params.copyWith(flashBrightness: v)),
          ),
          _GeometricTextureSlider(
            label: 'Flash Density',
            subtitle: 'Probability of a triangle flashing at any given time',
            value: params.flashDensity,
            min: 0.0,
            max: 1.0,
            divisions: 100,
            display: params.flashDensity.toStringAsFixed(2),
            onChanged: (v) => update(params.copyWith(flashDensity: v)),
          ),
          _GeometricTextureSlider(
            label: 'Flash Speed',
            subtitle: 'Speed of the flashing animation cycle',
            value: params.flashSpeed,
            min: 0.1,
            max: 5.0,
            divisions: 49,
            display: params.flashSpeed.toStringAsFixed(2),
            onChanged: (v) => update(params.copyWith(flashSpeed: v)),
          ),
          // Focal point presets
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Text(
              'Focal point presets',
              style: Theme.of(context).textTheme.titleSmall,
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Wrap(
              spacing: 4,
              children: [
                _PresetButton(
                  label: 'Center',
                  onTap: () =>
                      update(params.copyWith(focalPointX: 0.5, focalPointY: 0.5)),
                ),
                _PresetButton(
                  label: 'Left',
                  onTap: () =>
                      update(params.copyWith(focalPointX: 0.0, focalPointY: 0.5)),
                ),
                _PresetButton(
                  label: 'Right',
                  onTap: () =>
                      update(params.copyWith(focalPointX: 1.0, focalPointY: 0.5)),
                ),
                _PresetButton(
                  label: 'Top',
                  onTap: () =>
                      update(params.copyWith(focalPointX: 0.5, focalPointY: 0.0)),
                ),
                _PresetButton(
                  label: 'Bottom',
                  onTap: () =>
                      update(params.copyWith(focalPointX: 0.5, focalPointY: 1.0)),
                ),
                _PresetButton(
                  label: 'Top-left',
                  onTap: () =>
                      update(params.copyWith(focalPointX: 0.0, focalPointY: 0.0)),
                ),
                _PresetButton(
                  label: 'Top-right',
                  onTap: () =>
                      update(params.copyWith(focalPointX: 1.0, focalPointY: 0.0)),
                ),
                _PresetButton(
                  label: 'Bottom-left',
                  onTap: () =>
                      update(params.copyWith(focalPointX: 0.0, focalPointY: 1.0)),
                ),
                _PresetButton(
                  label: 'Bottom-right',
                  onTap: () =>
                      update(params.copyWith(focalPointX: 1.0, focalPointY: 1.0)),
                ),
              ],
            ),
          ),
          const SizedBox(height: 4),
          _GeometricTextureSlider(
            label: 'Focal X',
            subtitle: 'Horizontal position — 0.0 = left edge, 1.0 = right edge',
            value: params.focalPointX,
            min: 0.0,
            max: 1.0,
            divisions: 100,
            display: params.focalPointX.toStringAsFixed(2),
            onChanged: (v) => update(params.copyWith(focalPointX: v)),
          ),
          _GeometricTextureSlider(
            label: 'Focal Y',
            subtitle: 'Vertical position — 0.0 = top edge, 1.0 = bottom edge',
            value: params.focalPointY,
            min: 0.0,
            max: 1.0,
            divisions: 100,
            display: params.focalPointY.toStringAsFixed(2),
            onChanged: (v) => update(params.copyWith(focalPointY: v)),
          ),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              onPressed: () => unawaited(notifier.resetToDefaults()),
              child: const Text('Reset to defaults'),
            ),
          ),
        ],
      ],
    );
  }
}

class _PresetButton extends StatelessWidget {
  const _PresetButton({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return TextButton(
      style: TextButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        minimumSize: Size.zero,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        textStyle: Theme.of(context).textTheme.labelSmall,
      ),
      onPressed: onTap,
      child: Text(label),
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

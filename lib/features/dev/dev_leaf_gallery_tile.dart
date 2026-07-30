import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/widgets/leaf_shapes.dart';

/// Still previews of every catalogued [LeafDesign], each at a few rotation
/// angles, for browsing which watercolor leaf/petal silhouette to use in the
/// background field.
///
/// Browse-only: [PetalField] always draws [LeafDesign.petal] regardless of
/// what's open here. Switching the live background to a different design is
/// a manual code change, made one design at a time on request — there is
/// intentionally no live picker.
class DevLeafGallerySection extends ConsumerWidget {
  const DevLeafGallerySection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final panelOpen = ref.watch(devLeafGalleryPanelOpenProvider);
    final color = ref.watch(petalFieldParamsProvider).color;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SwitchListTile(
          title: const Text('Leaf design gallery'),
          subtitle: const Text(
            'Still previews of each background petal/leaf design, at a few '
            'angles. Browse-only — opening this does not change the live '
            'background.',
          ),
          value: panelOpen,
          onChanged: (value) {
            ref.read(devLeafGalleryPanelOpenProvider.notifier).state = value;
          },
        ),
        if (panelOpen) ...[
          const SizedBox(height: 8),
          for (final design in LeafDesign.values)
            _LeafDesignRow(design: design, color: color),
          _PlaceholderDesignsRow(startNumber: LeafDesign.values.length),
        ],
      ],
    );
  }
}

class _LeafDesignRow extends StatelessWidget {
  const _LeafDesignRow({required this.design, required this.color});

  final LeafDesign design;
  final Color color;

  // ~-20°, 0°, +20° in radians.
  static const _angles = [-0.35, 0.0, 0.35];

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${design.number}. ${design.label}',
            style: Theme.of(context).textTheme.titleSmall,
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              for (final angle in _angles) ...[
                _LeafPreview(design: design, color: color, rotation: angle),
                const SizedBox(width: 12),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

class _LeafPreview extends StatelessWidget {
  const _LeafPreview({
    required this.design,
    required this.color,
    required this.rotation,
  });

  final LeafDesign design;
  final Color color;
  final double rotation;

  static const _size = 72.0;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: _size,
      height: _size,
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Theme.of(context).dividerColor),
      ),
      child: CustomPaint(
        size: const Size(_size, _size),
        painter: _LeafPreviewPainter(
          design: design,
          color: color,
          rotation: rotation,
        ),
      ),
    );
  }
}

class _LeafPreviewPainter extends CustomPainter {
  _LeafPreviewPainter({
    required this.design,
    required this.color,
    required this.rotation,
  });

  final LeafDesign design;
  final Color color;
  final double rotation;

  @override
  void paint(Canvas canvas, Size size) {
    final extent = size.shortestSide * 0.62;

    canvas.save();
    canvas.translate(size.width / 2, size.height / 2);
    canvas.rotate(rotation);
    paintLeaf(
      canvas,
      design,
      Rect.fromCenter(center: Offset.zero, width: extent, height: extent),
      color,
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _LeafPreviewPainter oldDelegate) {
    return oldDelegate.design != design ||
        oldDelegate.color != color ||
        oldDelegate.rotation != rotation;
  }
}

/// Empty slots signalling where the next catalogued designs will go.
class _PlaceholderDesignsRow extends StatelessWidget {
  const _PlaceholderDesignsRow({required this.startNumber});

  final int startNumber;

  static const _count = 2;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Reserved for future designs',
            style: Theme.of(context).textTheme.titleSmall,
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              for (var i = 0; i < _count; i++) ...[
                _PlaceholderSlot(number: startNumber + i),
                const SizedBox(width: 12),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

class _PlaceholderSlot extends StatelessWidget {
  const _PlaceholderSlot({required this.number});

  final int number;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: 72,
      height: 72,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: theme.dividerColor),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(PhosphorIconsRegular.plus, size: 16, color: theme.disabledColor),
          const SizedBox(height: 2),
          Text(
            '$number',
            style: theme.textTheme.labelSmall?.copyWith(color: theme.disabledColor),
          ),
        ],
      ),
    );
  }
}

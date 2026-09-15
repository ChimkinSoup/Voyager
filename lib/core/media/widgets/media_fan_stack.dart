import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/media/widgets/media_image.dart';
import 'package:voyager/core/media/widgets/media_lightbox.dart';
import 'package:voyager/core/theme/voyager_theme.dart';
import 'package:voyager/domain/models/media_models.dart';

/// A corner-sized fan of an owner's images.
///
/// The compact counterpart to the gallery strip, for surfaces that are
/// mostly text and have no room for a row of thumbnails — the journal body,
/// where the fan floats in the bottom-right of the writing area. It shows
/// nothing at all until the entry has an image, so an entry without pictures
/// looks exactly as it did before there were any.
///
/// The fan is a single control, not a set: the whole stack opens the
/// lightbox, which is where the images are looked through and removed. Only
/// [maxVisible] cards are drawn no matter how many the owner has — past that
/// the peeks are too thin to read — and the count badge carries the rest.
class MediaFanStack extends ConsumerStatefulWidget {
  const MediaFanStack({
    super.key,
    required this.collection,
    required this.documentId,
    this.facet = MediaFacet.gallery,
    this.accentColor,
    this.thumbnailSize = 56,
    this.maxVisible = 3,
    this.onTap,
  });

  final String collection;
  final String documentId;
  final MediaFacet facet;
  final Color? accentColor;

  /// Edge of the front card. The cards behind it are the same size, offset.
  final double thumbnailSize;

  /// How many cards the fan draws before it stops fanning and counts.
  final int maxVisible;

  /// What tapping the fan does. Null opens the lightbox on the first image,
  /// which is what a surface with a handful of pictures wants; rankings passes
  /// its own so a large gallery gets a grid to choose from first (§7.5).
  final VoidCallback? onTap;

  @override
  ConsumerState<MediaFanStack> createState() => _MediaFanStackState();
}

/// One image, paired with the row that places it on this owner.
///
/// Paired rather than held as two lists because `assetsFor` drops references
/// whose asset row has gone, which slides every index after it — and the
/// index is what a removal is aimed with.
typedef _FanImage = ({MediaReference reference, MediaAsset asset});

class _MediaFanStackState extends ConsumerState<MediaFanStack> {
  var _images = const <_FanImage>[];

  /// Step between cards. Applied to `right`/`bottom`, so the deeper cards
  /// walk up and to the left — into the writing area, away from the corner
  /// the front card is pinned to.
  static const _stepX = 11.0;
  static const _stepY = 4.0;
  static const _stepAngle = 0.085;

  /// Room for the corners a rotated card throws outside its own box.
  static const _slop = 5.0;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  @override
  void didUpdateWidget(MediaFanStack oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.documentId != widget.documentId ||
        oldWidget.collection != widget.collection ||
        oldWidget.facet != widget.facet) {
      _reload();
    }
  }

  Future<void> _reload() async {
    final service = ref.read(mediaServiceProvider);
    final references = await service.referencesFor(
      widget.collection,
      widget.documentId,
      facet: widget.facet,
    );
    final images = <_FanImage>[];
    for (final reference in references) {
      final asset = await service.asset(reference.mediaId);
      if (asset != null) images.add((reference: reference, asset: asset));
    }
    if (!mounted) return;
    setState(() => _images = images);
  }

  void _open() {
    showMediaLightbox(
      context,
      assets: [for (final image in _images) image.asset],
      onRemove: (asset) async {
        final index = _images.indexWhere((it) => it.asset.id == asset.id);
        if (index < 0) return;
        await ref
            .read(mediaServiceProvider)
            .removeReference(_images[index].reference.id);
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    // Same reason the strip listens: a finished download turns a placeholder
    // into a picture, and an image removed in the lightbox has to leave the
    // fan, neither of which changes anything this state holds on its own.
    ref.listen(mediaServiceProvider, (_, _) => _reload());

    if (_images.isEmpty) return const SizedBox.shrink();

    final theme = Theme.of(context);
    final visible = math.min(_images.length, widget.maxVisible);
    final hidden = _images.length - visible;
    final size = widget.thumbnailSize;
    final width = size + _stepX * (visible - 1) + _slop * 2;
    final height = size + _stepY * (visible - 1) + _slop * 2;

    return Tooltip(
      message: _images.length == 1 ? '1 image' : '${_images.length} images',
      child: GestureDetector(
        onTap: widget.onTap ?? _open,
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          child: SizedBox(
            width: width,
            height: height,
            child: Stack(
              // The rotated cards throw their corners past the box the fan
              // reserves; clipping them would square off the very edges that
              // make it read as a stack.
              clipBehavior: Clip.none,
              children: [
                // Back to front, so the first image — the one the lightbox
                // opens on — is the card on top.
                for (var depth = visible - 1; depth >= 0; depth--)
                  Positioned(
                    right: _slop + _stepX * depth,
                    bottom: _slop + _stepY * depth,
                    child: Transform.rotate(
                      angle: -_stepAngle * depth,
                      child: _FanCard(
                        asset: _images[depth].asset,
                        size: size,
                        theme: theme,
                      ),
                    ),
                  ),
                if (hidden > 0)
                  Positioned(
                    right: _slop - 4,
                    top: _slop - 6,
                    child: _FanCount(
                      count: hidden,
                      accent: widget.accentColor ?? theme.colorScheme.primary,
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

class _FanCard extends StatelessWidget {
  const _FanCard({
    required this.asset,
    required this.size,
    required this.theme,
  });

  final MediaAsset asset;
  final double size;
  final ThemeData theme;

  @override
  Widget build(BuildContext context) {
    final vc = VoyagerColors.of(context);
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        // The surface-coloured rim is what separates one card from the next,
        // and the fan from whatever text it is floating over.
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: theme.colorScheme.surface, width: 2),
        boxShadow: [
          BoxShadow(
            color: vc.shadow.withValues(
              alpha: theme.brightness == Brightness.dark
                  ? 0.22
                  : vc.strongShadowAlpha,
            ),
            blurRadius: 6 * vc.shadowBlurScale,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: MediaImage(
        asset: asset,
        width: size,
        height: size,
        borderRadius: BorderRadius.circular(8),
      ),
    );
  }
}

class _FanCount extends StatelessWidget {
  const _FanCount({required this.count, required this.accent});

  final int count;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: accent,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        '+$count',
        style: TextStyle(
          // Picked from the accent's luminance — see VoyagerColors.onAccent.
          color: accent.computeLuminance() > 0.55
              ? const Color(0xFF1B1B22)
              : Colors.white,
          fontSize: 10,
          fontWeight: FontWeight.w600,
          height: 1.2,
        ),
      ),
    );
  }
}

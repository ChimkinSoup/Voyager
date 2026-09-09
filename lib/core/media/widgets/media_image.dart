import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/domain/models/media_models.dart';

/// Renders one [MediaAsset], resolving its bytes and showing an honest state
/// when it cannot.
///
/// The four states are the design's: bytes present, a transfer in progress,
/// downloads switched off, and a failure the user can retry. Deliberately no
/// fifth "indefinite spinner" state — a missing image with downloads disabled
/// says so rather than spinning forever.
class MediaImage extends ConsumerStatefulWidget {
  const MediaImage({
    super.key,
    required this.asset,
    this.width,
    this.height,
    this.fit = BoxFit.cover,
    this.borderRadius,
    this.decodeFullResolution = false,
  });

  final MediaAsset asset;
  final double? width;
  final double? height;
  final BoxFit fit;
  final BorderRadius? borderRadius;

  /// Whether to keep every ingest pixel in the image cache.
  ///
  /// Only the lightbox wants this: it zooms to 8x, so a copy decoded at the
  /// size it first paints at would go soft the moment the user zooms in.
  /// Everywhere else a thumbnail decoded at ingest size costs megabytes of
  /// cache per image for pixels that are thrown away before they are painted.
  final bool decodeFullResolution;

  @override
  ConsumerState<MediaImage> createState() => _MediaImageState();
}

class _MediaImageState extends ConsumerState<MediaImage> {
  Uint8List? _bytes;
  bool _loading = true;

  /// Which asset [_bytes] belongs to, so a strip that reorders or replaces an
  /// image does not keep painting the previous one against the new row.
  String? _loadedForContentHash;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(MediaImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.asset.contentHash != widget.asset.contentHash ||
        oldWidget.asset.downloadState != widget.asset.downloadState) {
      _load();
    }
  }

  Future<void> _load() async {
    final asset = widget.asset;
    if (_loadedForContentHash == asset.contentHash && _bytes != null) return;
    setState(() => _loading = true);

    final service = ref.read(mediaServiceProvider);
    // Reads local bytes first and only then considers a download, so an image
    // already on disk costs one file read and never touches the settings or
    // the network.
    final bytes = await service.bytesFor(asset);
    if (!mounted) return;
    setState(() {
      _bytes = bytes;
      _loadedForContentHash = bytes == null ? null : asset.contentHash;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    // Watched so a transfer finishing repaints this image without the parent
    // surface having to know a download was in flight.
    ref.watch(mediaServiceProvider);

    final radius = widget.borderRadius ?? BorderRadius.circular(10);
    final bytes = _bytes;

    final Widget content;
    if (bytes != null) {
      content = LayoutBuilder(
        builder: (context, constraints) {
          // The box this image will actually be painted into: an explicit size
          // when the caller gave one, otherwise whatever the parent allows.
          final decode = widget.decodeFullResolution
              ? null
              : mediaDecodeSize(
                  sourceWidth: widget.asset.width,
                  sourceHeight: widget.asset.height,
                  boxWidth:
                      widget.width ??
                      (constraints.hasBoundedWidth
                          ? constraints.maxWidth
                          : null),
                  boxHeight:
                      widget.height ??
                      (constraints.hasBoundedHeight
                          ? constraints.maxHeight
                          : null),
                  devicePixelRatio: MediaQuery.devicePixelRatioOf(context),
                  fit: widget.fit,
                );
          return Image.memory(
            bytes,
            width: widget.width,
            height: widget.height,
            fit: widget.fit,
            cacheWidth: decode?.width,
            cacheHeight: decode?.height,
            // The bytes are re-decoded whenever the decode size changes, so a
            // strip of ten images only pays for it once per layout size — not
            // once per scroll frame.
            gaplessPlayback: true,
          );
        },
      );
    } else {
      content = _MediaImagePlaceholder(
        asset: widget.asset,
        loading: _loading,
        width: widget.width,
        height: widget.height,
        onRetry: () async {
          await ref.read(mediaTransferWorkerProvider).retry(widget.asset);
          await _load();
        },
      );
    }

    return ClipRRect(borderRadius: radius, child: content);
  }
}

/// The size a `sourceWidth` x `sourceHeight` image should be decoded at to be
/// painted into a box of `boxWidth` x `boxHeight` logical pixels under [fit],
/// or null to decode at full size.
///
/// Both returned dimensions come from a single scale factor, so the aspect
/// ratio survives even though [Image.memory] resizes with
/// `ResizeImagePolicy.exact`, which would otherwise stretch the picture to
/// whatever pair of numbers it is handed.
@visibleForTesting
({int width, int height})? mediaDecodeSize({
  required int sourceWidth,
  required int sourceHeight,
  required double? boxWidth,
  required double? boxHeight,
  required double devicePixelRatio,
  required BoxFit fit,
}) {
  if (sourceWidth <= 0 || sourceHeight <= 0) return null;
  // [BoxFit.none] paints at intrinsic size, so there is nothing to shrink to.
  if (fit == BoxFit.none) return null;

  double? ratio(double? box, int source) {
    if (box == null || !box.isFinite || box <= 0) return null;
    return box * devicePixelRatio / source;
  }

  final byWidth = ratio(boxWidth, sourceWidth);
  final byHeight = ratio(boxHeight, sourceHeight);

  final double? scale;
  switch (fit) {
    // Cover crops, so it needs whichever axis has to stretch furthest. With
    // only one axis known that number is unknowable, and guessing low is a
    // blurry image — decode everything instead.
    case BoxFit.cover:
    case BoxFit.fill:
      scale = byWidth == null || byHeight == null
          ? null
          : math.max(byWidth, byHeight);
    case BoxFit.fitWidth:
      scale = byWidth;
    case BoxFit.fitHeight:
      scale = byHeight;
    // Contain and scaleDown fit inside the box, so a single known axis is an
    // upper bound on what they will use — safe to decode at.
    case BoxFit.contain:
    case BoxFit.scaleDown:
      scale = byWidth == null
          ? byHeight
          : (byHeight == null ? byWidth : math.min(byWidth, byHeight));
    case BoxFit.none:
      scale = null;
  }
  // Never decode larger than the source: there are no extra pixels to invent.
  if (scale == null || scale >= 1) return null;

  final width = (sourceWidth * scale).round();
  final height = (sourceHeight * scale).round();
  if (width < 1 || height < 1) return null;
  return (width: width, height: height);
}

/// What is shown in place of an image whose bytes are not here.
class _MediaImagePlaceholder extends StatelessWidget {
  const _MediaImagePlaceholder({
    required this.asset,
    required this.loading,
    required this.onRetry,
    this.width,
    this.height,
  });

  final MediaAsset asset;
  final bool loading;
  final Future<void> Function() onRetry;
  final double? width;
  final double? height;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurface.withValues(alpha: 0.55);

    final transferring =
        loading ||
        asset.downloadState == MediaDownloadState.pending ||
        asset.downloadState == MediaDownloadState.downloading;
    final failed = asset.downloadState == MediaDownloadState.failed;

    final Widget body;
    if (transferring) {
      body = SizedBox(
        width: 18,
        height: 18,
        child: CircularProgressIndicator(strokeWidth: 2, color: muted),
      );
    } else if (failed) {
      body = _PlaceholderMessage(
        icon: PhosphorIconsRegular.arrowClockwise,
        label: 'Retry',
        color: theme.colorScheme.error,
        onTap: onRetry,
      );
    } else {
      // Reached when the bytes are absent and downloads are off — the design's
      // named empty state, rather than a spinner that could never resolve.
      body = _PlaceholderMessage(
        icon: PhosphorIconsRegular.cloudSlash,
        label: 'Download disabled',
        color: muted,
      );
    }

    return Container(
      width: width,
      height: height,
      alignment: Alignment.center,
      padding: const EdgeInsets.all(6),
      color: theme.colorScheme.onSurface.withValues(alpha: 0.06),
      child: body,
    );
  }
}

class _PlaceholderMessage extends StatelessWidget {
  const _PlaceholderMessage({
    required this.icon,
    required this.label,
    required this.color,
    this.onTap,
  });

  final IconData icon;
  final String label;
  final Color color;
  final Future<void> Function()? onTap;

  @override
  Widget build(BuildContext context) {
    final column = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 18, color: color),
        const SizedBox(height: 4),
        Text(
          label,
          textAlign: TextAlign.center,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(
            context,
          ).textTheme.labelSmall?.copyWith(color: color),
        ),
      ],
    );
    final tap = onTap;
    if (tap == null) return column;
    return InkWell(onTap: tap, child: column);
  }
}

/// A small corner badge showing that an asset still owes a transfer.
///
/// Rendered by the surfaces that stack chrome over an image, rather than by
/// [MediaImage] itself, so that the lightbox and the strip can place it where
/// their own chrome allows.
class MediaTransferBadge extends ConsumerWidget {
  const MediaTransferBadge({super.key, required this.asset});

  final MediaAsset asset;

  /// Whether this asset has anything worth telling the user about.
  static bool isPending(MediaAsset asset) {
    return asset.uploadState == MediaUploadState.pending ||
        asset.uploadState == MediaUploadState.uploading ||
        asset.uploadState == MediaUploadState.failed ||
        asset.downloadState == MediaDownloadState.failed;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!isPending(asset)) return const SizedBox.shrink();
    final theme = Theme.of(context);

    final failed =
        asset.uploadState == MediaUploadState.failed ||
        asset.downloadState == MediaDownloadState.failed;
    final icon = failed
        ? PhosphorIconsRegular.warningCircle
        : PhosphorIconsRegular.cloudArrowUp;
    final color = failed
        ? theme.colorScheme.error
        : theme.colorScheme.onSurface.withValues(alpha: 0.75);

    final badge = Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface.withValues(alpha: 0.85),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Icon(icon, size: 12, color: color),
    );

    if (!failed) {
      return Tooltip(message: 'Waiting to sync', child: badge);
    }

    // A parked transfer is the one state the user can do something about, so
    // the badge that reports it is also the control that clears it — the
    // upload twin of the Retry affordance [_MediaImagePlaceholder] already
    // offers for a failed download.
    //
    // A bare [MouseRegion] and [GestureDetector] rather than an [InkWell]:
    // this badge is stacked over images on surfaces that do not all have a
    // [Material] ancestor, and an ink splash needs one.
    return Tooltip(
      message:
          '${asset.failureReason ?? 'This image could not be synced.'}'
          '\nClick to retry.',
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: () => ref.read(mediaTransferWorkerProvider).retry(asset),
          child: badge,
        ),
      ),
    );
  }
}

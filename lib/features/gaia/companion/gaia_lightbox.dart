import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:voyager/core/media/widgets/media_image.dart';
import 'package:voyager/core/media/widgets/media_lightbox.dart';
import 'package:voyager/domain/models/gaia_models.dart';
import 'package:voyager/domain/models/media_models.dart';

/// Opens Voyager's image viewer on [images], starting at [initial], each
/// captioned with its `[image N]`. [imageFile] resolves each to its file,
/// as in the chat.
Future<void> showGaiaLightbox(
  BuildContext context, {
  required List<GaiaImagePart> images,
  required int initial,
  required Future<String?> Function(String mediaId) imageFile,
}) => showLightbox(
  context,
  images: [
    for (final (i, image) in images.indexed) _GaiaImage(i, image, imageFile),
  ],
  initialIndex: initial,
  captions: [for (final image in images) gaiaImageToken(image.label)],
);

class _GaiaImage implements LightboxImage {
  _GaiaImage(this.position, this.image, this.imageFile);

  /// Where in the chat it is: the same picture sent twice is one media id,
  /// but two pages, each with its own zoom.
  final int position;
  final GaiaImagePart image;
  final Future<String?> Function(String mediaId) imageFile;

  @override
  String get id => '$position';

  @override
  ImageProvider get precache => MediaAssetImage(image.mediaId, _bytes);

  Future<Uint8List?> _bytes() async {
    final path = await imageFile(image.mediaId);
    return path == null ? null : File(path).readAsBytes();
  }

  @override
  Widget build(BuildContext context) => Image(
    image: precache,
    fit: BoxFit.contain,
    gaplessPlayback: true,
    // Not on this device yet.
    errorBuilder: (context, _, _) =>
        const Icon(Icons.image_outlined, color: Colors.white54, size: 48),
  );

  @override
  Future<({Uint8List bytes, MediaImageFormat? format})?> read() async {
    final path = await imageFile(image.mediaId);
    if (path == null) return null;
    return (
      bytes: await File(path).readAsBytes(),
      format: MediaImageFormat.fromPath(path),
    );
  }

  @override
  String get saveName => 'gaia_image_${image.label}';
}

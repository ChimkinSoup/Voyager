import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:image/image.dart' as img;
import 'package:voyager/domain/models/media_models.dart';

/// Largest original an attach will accept, measured **before** compression.
///
/// The check is on the input rather than the output so that a rejection can
/// be reported immediately, without spending seconds decoding a 200 MB file
/// only to refuse it.
const int maxIngestInputBytes = 10 * 1024 * 1024;

/// Longest edge kept after downscaling.
///
/// Chosen to stay sharp when an image is opened full-screen on a desktop
/// monitor while keeping a typical photo well under a megabyte — which is
/// what makes the post-ingest size limit a formality rather than a second
/// thing to enforce.
const int maxIngestEdgePx = 2048;

/// JPEG quality for the re-encode. High enough that the recompression is not
/// visible next to the original at 100%, low enough to keep photos small.
const int ingestJpegQuality = 85;

/// Why an attach was refused. Carries a message the UI shows verbatim.
class MediaIngestException implements Exception {
  const MediaIngestException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// What ingest was handed.
///
/// Either encoded bytes this isolate can decode itself, or already-decoded
/// RGBA — the shape HEIC arrives in, because only the platform decoder on the
/// main isolate can produce it. See [MediaIngestPipeline].
class MediaIngestRequest {
  const MediaIngestRequest.encoded(this.bytes)
    : rgba = null,
      rgbaWidth = 0,
      rgbaHeight = 0;

  const MediaIngestRequest.rgba({
    required Uint8List this.rgba,
    required this.rgbaWidth,
    required this.rgbaHeight,
  }) : bytes = null;

  final Uint8List? bytes;
  final Uint8List? rgba;
  final int rgbaWidth;
  final int rgbaHeight;
}

/// Normalised bytes plus everything the asset row needs to describe them.
class MediaIngestResult {
  const MediaIngestResult({
    required this.bytes,
    required this.contentHash,
    required this.format,
    required this.width,
    required this.height,
  });

  final Uint8List bytes;

  /// SHA-256 of [bytes] — the post-ingest bytes, so two devices only dedupe
  /// onto each other when their pipelines agreed exactly.
  final String contentHash;

  final MediaImageFormat format;
  final int width;
  final int height;

  int get byteSize => bytes.length;
}

/// The image container a blob's leading bytes say it is.
///
/// Sniffed from magic numbers rather than trusted from a file extension or a
/// clipboard-declared mime type: a paste often carries neither, and a drop
/// carries whatever the source app felt like claiming.
enum SniffedImageFormat { png, jpeg, webp, heic, gif, unknown }

SniffedImageFormat sniffImageFormat(Uint8List bytes) {
  if (bytes.length < 12) return SniffedImageFormat.unknown;

  // PNG: \x89PNG\r\n\x1a\n
  if (bytes[0] == 0x89 &&
      bytes[1] == 0x50 &&
      bytes[2] == 0x4E &&
      bytes[3] == 0x47) {
    return SniffedImageFormat.png;
  }
  // JPEG: FF D8 FF
  if (bytes[0] == 0xFF && bytes[1] == 0xD8 && bytes[2] == 0xFF) {
    return SniffedImageFormat.jpeg;
  }
  // GIF: "GIF8" — sniffed only so it can be refused by name.
  if (bytes[0] == 0x47 &&
      bytes[1] == 0x49 &&
      bytes[2] == 0x46 &&
      bytes[3] == 0x38) {
    return SniffedImageFormat.gif;
  }
  // RIFF....WEBP
  if (_matchesAscii(bytes, 0, 'RIFF') && _matchesAscii(bytes, 8, 'WEBP')) {
    return SniffedImageFormat.webp;
  }
  // ISO base media: a 4-byte box length, then "ftyp", then the brand. HEIC
  // is one of several brands sharing the container, so the brand is what
  // separates it from an MP4 someone dropped by mistake.
  if (_matchesAscii(bytes, 4, 'ftyp')) {
    const heicBrands = {
      'heic',
      'heix',
      'heim',
      'heis',
      'hevc',
      'hevx',
      'hevm',
      'hevs',
      'mif1',
      'msf1',
    };
    final brand = String.fromCharCodes(bytes.sublist(8, 12));
    if (heicBrands.contains(brand)) return SniffedImageFormat.heic;
  }
  return SniffedImageFormat.unknown;
}

bool _matchesAscii(Uint8List bytes, int offset, String ascii) {
  if (bytes.length < offset + ascii.length) return false;
  for (var i = 0; i < ascii.length; i++) {
    if (bytes[offset + i] != ascii.codeUnitAt(i)) return false;
  }
  return true;
}

/// Validates [bytes] without decoding them.
///
/// Split out from [ingestImageIsolate] so the UI can refuse an oversized or
/// unsupported drop the instant it lands, rather than after a round trip
/// through a background isolate.
///
/// Returns the sniffed format so the caller knows whether the platform
/// decoder is needed. Throws [MediaIngestException] with the message to show.
SniffedImageFormat validateIngestInput(Uint8List bytes) {
  if (bytes.length > maxIngestInputBytes) {
    final mb = (bytes.length / (1024 * 1024)).toStringAsFixed(1);
    throw MediaIngestException(
      'Image is too large ($mb MB). The limit is 10 MB.',
    );
  }
  final format = sniffImageFormat(bytes);
  switch (format) {
    case SniffedImageFormat.png:
    case SniffedImageFormat.jpeg:
    case SniffedImageFormat.webp:
    case SniffedImageFormat.heic:
      return format;
    case SniffedImageFormat.gif:
      throw const MediaIngestException(
        'GIFs are not supported. Use a PNG, JPEG or WebP image.',
      );
    case SniffedImageFormat.unknown:
      throw const MediaIngestException(
        'That does not look like a PNG, JPEG, WebP or HEIC image.',
      );
  }
}

/// Decode, downscale and re-encode, off the UI isolate.
///
/// Top-level so it can be a `compute` entry point.
///
/// The output is JPEG unless the image actually uses transparency, in which
/// case it is PNG — flattening an image with an alpha channel onto an assumed
/// background is a change the user did not ask for, and JPEG has no way to
/// keep it. WebP is never *produced* (the `image` package decodes it but
/// cannot encode it), which is why a WebP input comes back out as one of the
/// other two.
MediaIngestResult ingestImageIsolate(MediaIngestRequest request) {
  final decoded = _decode(request);

  final longestEdge = decoded.width > decoded.height
      ? decoded.width
      : decoded.height;
  final resized = longestEdge > maxIngestEdgePx
      ? img.copyResize(
          decoded,
          width: decoded.width >= decoded.height ? maxIngestEdgePx : null,
          height: decoded.height > decoded.width ? maxIngestEdgePx : null,
          // Averaging every source pixel that lands in a destination pixel.
          // The default (nearest) drops most of them, which is what makes a
          // heavily downscaled screenshot look like it has been through a
          // fax machine.
          interpolation: img.Interpolation.average,
        )
      : decoded;

  final MediaImageFormat format;
  final Uint8List bytes;
  if (_hasTransparency(resized)) {
    format = MediaImageFormat.png;
    bytes = img.encodePng(resized);
  } else {
    format = MediaImageFormat.jpeg;
    bytes = img.encodeJpg(resized, quality: ingestJpegQuality);
  }

  return MediaIngestResult(
    bytes: bytes,
    contentHash: sha256.convert(bytes).toString(),
    format: format,
    width: resized.width,
    height: resized.height,
  );
}

img.Image _decode(MediaIngestRequest request) {
  final rgba = request.rgba;
  if (rgba != null) {
    return img.Image.fromBytes(
      width: request.rgbaWidth,
      height: request.rgbaHeight,
      bytes: rgba.buffer,
      numChannels: 4,
    );
  }
  final decoded = img.decodeImage(request.bytes!);
  if (decoded == null) {
    throw const MediaIngestException('That image could not be read.');
  }
  return decoded;
}

/// Whether any pixel is actually see-through.
///
/// An alpha *channel* is not the same as transparency — screenshots are
/// routinely RGBA with every pixel opaque, and treating those as PNG would
/// store a photo-sized image losslessly for no reason.
bool _hasTransparency(img.Image image) {
  if (image.numChannels < 4) return false;
  for (final pixel in image) {
    if (pixel.a < pixel.maxChannelValue) return true;
  }
  return false;
}

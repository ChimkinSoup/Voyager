import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:super_clipboard/super_clipboard.dart';

/// What the clipboard is holding, as far as the image rules care.
///
/// The design's clipboard table turns on exactly two questions — is there
/// text, and is there an image — so that is what this reduces a clipboard to.
/// Both can be true at once, which is the "paste both" row.
class MediaClipboardContents {
  const MediaClipboardContents({this.text, this.imageBytes});

  static const empty = MediaClipboardContents();

  final String? text;
  final Uint8List? imageBytes;

  bool get hasText => text != null && text!.isNotEmpty;
  bool get hasImage => imageBytes != null;
  bool get isEmpty => !hasText && !hasImage;

  /// True for the one case a non-image field must swallow rather than pass on:
  /// an image with no text to fall back to.
  bool get isImageOnly => hasImage && !hasText;
}

/// Reads images out of the system clipboard.
///
/// Flutter's own `Clipboard` is text-only, so this is the only route to a
/// pasted screenshot on any platform. Kept behind a class so the surfaces
/// that use it depend on this shape rather than on `super_clipboard`, and so
/// tests can substitute one.
class MediaClipboard {
  const MediaClipboard();

  /// The formats to try, best first.
  ///
  /// PNG leads because that is what a screenshot arrives as on every platform
  /// this ships to (Windows synthesises PNG from clipboard DIBs, which is why
  /// a plain Ctrl+PrintScreen works at all). HEIC is last because it is the
  /// one that may not decode; it is still offered so that a device which
  /// *can* decode it is not refused a paste it could have handled.
  static const _imageFormats = <SimpleFileFormat>[
    Formats.png,
    Formats.jpeg,
    Formats.webp,
    Formats.heic,
  ];

  /// What the clipboard is offering, without pulling an image's bytes.
  ///
  /// The paste rules need both answers — is there an image, is there text —
  /// before they know whether the image is wanted at all, and materialising
  /// megabytes on every Ctrl+V into a text field just to answer them would be
  /// work immediately thrown away.
  Future<({bool hasText, bool hasImage})> peek() async {
    final clipboard = SystemClipboard.instance;
    if (clipboard == null) return (hasText: false, hasImage: false);

    final reader = await clipboard.read();
    final text = await reader.readValue(Formats.plainText);
    return (
      hasText: text != null && text.isNotEmpty,
      hasImage: _imageFormats.any(reader.canProvide),
    );
  }

  Future<MediaClipboardContents> read() async {
    final clipboard = SystemClipboard.instance;
    // Null on a platform with no clipboard support at all. Nothing to paste
    // is not an error — the caller falls back to Flutter's text clipboard.
    if (clipboard == null) return MediaClipboardContents.empty;

    final reader = await clipboard.read();
    return MediaClipboardContents(
      text: await reader.readValue(Formats.plainText),
      imageBytes: await readImageFrom(reader),
    );
  }

  /// Pulls the first readable image out of any reader — a clipboard's or a
  /// drop session's, which is why this is shared rather than inlined above.
  static Future<Uint8List?> readImageFrom(DataReader reader) async {
    for (final format in _imageFormats) {
      if (!reader.canProvide(format)) continue;
      final bytes = await _readFile(reader, format);
      if (bytes != null) return bytes;
    }
    return null;
  }

  /// Bridges `getFile`'s callback style to a Future.
  ///
  /// Returns null rather than throwing when a format that advertised itself
  /// cannot actually be read: on Windows a clipboard can claim a format whose
  /// owning application has since gone away, and the right response is to try
  /// the next format rather than to fail the paste.
  static Future<Uint8List?> _readFile(
    DataReader reader,
    SimpleFileFormat format,
  ) {
    final completer = Completer<Uint8List?>();
    final progress = reader.getFile(
      format,
      (file) async {
        if (completer.isCompleted) return;
        try {
          completer.complete(await file.readAll());
        } catch (error) {
          debugPrint('[media] clipboard read failed for $format: $error');
          completer.complete(null);
        }
      },
      onError: (error) {
        debugPrint('[media] clipboard reported an error for $format: $error');
        if (!completer.isCompleted) completer.complete(null);
      },
    );
    if (progress == null && !completer.isCompleted) completer.complete(null);
    return completer.future;
  }
}

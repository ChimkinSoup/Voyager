import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/widgets/voyager_toast.dart';
import 'package:voyager/domain/models/media_models.dart';
import 'package:voyager/domain/services/media_ingest.dart';

/// How long the confirmation stays up once an attach lands.
///
/// Short: by the time it is shown the image is already in the gallery, so the
/// toast is only there to close the sentence the spinner started.
const _attachedToastDwell = Duration(milliseconds: 1600);

/// Attaches [images] to one parent, surfacing a refusal as a message rather
/// than a crash.
///
/// [MediaIngestException] carries copy meant for the user — too large, a GIF,
/// an undecodable HEIC — so it is shown verbatim; anything else is a bug and
/// says so generically.
///
/// Shared by the gallery strip and the paste scope so that an image dropped
/// on the strip, one picked through the file dialog and one pasted into the
/// surrounding editor are all refused in the same words.
///
/// A spinner toast goes up for as long as the ingest runs, then becomes the
/// confirmation. Decoding, downscaling and re-encoding a full-resolution
/// screenshot is a second or two of real work on a background isolate, and
/// without this the only thing that ever acknowledges the paste is the image
/// itself, once it is already finished — which is long enough to read as a
/// frozen app.
Future<void> attachImagesForOwner(
  WidgetRef ref, {
  required ScaffoldMessengerState messenger,
  required OverlayState overlay,
  required List<Uint8List> images,
  required String collection,
  required String documentId,
  MediaFacet facet = MediaFacet.gallery,
}) async {
  if (images.isEmpty) return;
  // Both providers are read before the first await: an attach can outlive the
  // surface that started it — closing the panel mid-ingest is enough — and a
  // [WidgetRef] read after that throws.
  final service = ref.read(mediaServiceProvider);
  final fileStore = ref.read(mediaFileStoreProvider);
  final count = images.length;
  final toast = showVoyagerToastIn(
    overlay,
    message: count == 1 ? 'Adding image…' : 'Adding $count images…',
  );
  try {
    for (final bytes in images) {
      await service.attachBytes(
        bytes: bytes,
        collection: collection,
        documentId: documentId,
        facet: facet,
      );
    }
    toast.update(
      message: count == 1 ? 'Image added' : '$count images added',
      icon: PhosphorIconsRegular.check,
      dwell: _attachedToastDwell,
    );
    // The design's required low-disk warning, raised where a new file has
    // just landed rather than on a timer.
    if (await fileStore.isDiskLow()) {
      messenger.showSnackBar(
        const SnackBar(
          content: Text(
            'Less than 5% of this disk is free. Images may stop downloading.',
          ),
          duration: Duration(seconds: 6),
        ),
      );
    }
  } on MediaIngestException catch (error) {
    // The refusal is the message now, so the spinner goes rather than turning
    // into a second thing to read on top of the snack bar.
    toast.dismiss();
    messenger.showSnackBar(SnackBar(content: Text(error.message)));
  } catch (error) {
    toast.dismiss();
    messenger.showSnackBar(
      SnackBar(content: Text('That image could not be attached: $error')),
    );
  }
}

/// Opens the platform file dialog on the formats ingest accepts.
///
/// Empty when the user cancelled, or picked something with no readable path.
/// HEIC is offered even though it is converted on the way in — the file on
/// disk is what the user recognises.
Future<List<Uint8List>> pickImageFiles({bool allowMultiple = true}) async {
  final result = await FilePicker.platform.pickFiles(
    allowMultiple: allowMultiple,
    type: FileType.custom,
    allowedExtensions: ['png', 'jpg', 'jpeg', 'webp', 'heic'],
  );
  if (result == null) return const [];
  final images = <Uint8List>[];
  for (final picked in result.files) {
    final path = picked.path;
    if (path == null) continue;
    images.add(await File(path).readAsBytes());
  }
  return images;
}

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

/// How long a refusal stays up: longer than the confirmation, since it is
/// news the user has to read rather than a close to what they already saw.
const _failedToastDwell = Duration(seconds: 4);

/// The low-disk warning standing in each overlay. Per overlay, so a warning
/// that went with a torn-down overlay, never dismissed, doesn't hold back the
/// next one.
final _lowDiskToasts = Expando<VoyagerToast>();

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
  var added = 0;
  try {
    // One attach under way from the first image to the last, so an editor
    // cancelled mid-batch waits for the images not yet started too.
    await service.trackAttach(() async {
      // Ingest already folds identical images into one asset, so an image
      // this gallery holds comes back as an asset it already references — and
      // the same image twice in one batch as the same asset twice. A second
      // copy is never what was meant (BUG-067).
      final present = {
        for (final reference in await service.referencesFor(
          collection,
          documentId,
          facet: facet,
        ))
          reference.mediaId,
      };
      for (final bytes in images) {
        final asset = await service.ingestBytes(bytes);
        if (!present.add(asset.id)) continue;
        await service.addReference(
          mediaId: asset.id,
          collection: collection,
          documentId: documentId,
          facet: facet,
        );
        added++;
      }
    });
    final skipped = count - added;
    toast.update(
      message: switch ((added, skipped)) {
        (_, 0) => count == 1 ? 'Image added' : '$count images added',
        (0, 1) => 'This image is already attached',
        (0, _) => 'These images are already attached',
        _ =>
          '${added == 1 ? 'Image' : '$added images'} added, '
              '$skipped already attached',
      },
      icon: skipped == 0
          ? PhosphorIconsRegular.check
          : PhosphorIconsRegular.warning,
      dwell: skipped == 0 ? _attachedToastDwell : _failedToastDwell,
    );
  } on MediaIngestException catch (error) {
    // The spinner becomes the refusal, in the card the user is already
    // watching.
    toast.update(
      message: error.message,
      icon: PhosphorIconsRegular.warning,
      dwell: _failedToastDwell,
    );
    return;
  } catch (error) {
    toast.update(
      message: 'That image could not be attached: $error',
      icon: PhosphorIconsRegular.warning,
      dwell: _failedToastDwell,
    );
    return;
  }
  // The design's required low-disk warning, raised where a new file has just
  // landed rather than on a timer. No dwell: it stays up until the user
  // dismisses it. Only one at a time, since a toast without a dwell never
  // joins a repeat of itself. Outside the attach's try: the images are in by
  // now, and a failed free-space query must not report that they aren't; it
  // just means there is no warning to give.
  if (!await fileStore.isDiskLow().catchError((Object _) => false)) return;
  if (!(_lowDiskToasts[overlay]?.isDismissed ?? true)) return;
  _lowDiskToasts[overlay] = showVoyagerToastIn(
    overlay,
    message: 'Less than 5% of this disk is free. Images may stop downloading.',
    icon: PhosphorIconsRegular.warning,
    actions: [VoyagerToastAction(label: 'Dismiss', onPressed: () {})],
  );
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

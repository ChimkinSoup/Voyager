import 'dart:io';

import 'package:voyager/core/media/media_service.dart';
import 'package:voyager/core/sync/firestore_collections.dart';

/// An image attached to a chat, as stored: its asset and the local file
/// holding the bytes an agent gets.
typedef GaiaStoredImage = ({
  String mediaId,
  String referenceId,
  String path,
  String mimeType,
  int width,
  int height,
});

/// Gaia's images in the media module (GAIA_HLD.md §8): one reference per
/// image, owned by its chat, so a chat's delete takes its images onto the
/// same 30-day clock and a restore brings them back.
class GaiaMedia {
  GaiaMedia(this._media);

  final MediaService _media;

  /// Ingests the image at [path] onto [chatId]. Throws
  /// `MediaIngestException` for one the module refuses.
  Future<GaiaStoredImage> attach(String chatId, String path) async {
    final reference = await _media.attachBytes(
      bytes: await File(path).readAsBytes(),
      collection: FirestoreCollections.gaiaChats,
      documentId: chatId,
    );
    final asset = (await _media.asset(reference.mediaId))!;
    return (
      mediaId: asset.id,
      referenceId: reference.id,
      path: (await _media.fileStore.fileForAsset(asset))!.path,
      mimeType: asset.mimeType,
      width: asset.width,
      height: asset.height,
    );
  }

  /// Takes an image [attach] put on a chat off it again: its send didn't
  /// happen.
  Future<void> detach(String referenceId) =>
      _media.removeReference(referenceId);

  /// The local file holding [mediaId]'s bytes; null while they're only
  /// remote, when a download is asked for.
  Future<String?> file(String mediaId) async {
    final asset = await _media.asset(mediaId);
    if (asset == null) return null;
    final file = await _media.fileStore.fileForAsset(asset);
    if (file == null) await _media.requestDownload(asset);
    return file?.path;
  }
}

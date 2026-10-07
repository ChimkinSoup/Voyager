import 'package:voyager/core/media/media_service.dart';
import 'package:voyager/core/sync/remote_sync_service.dart';
import 'package:voyager/domain/models/media_models.dart';

/// Sends media metadata up the ordinary document sync path.
///
/// The seam that keeps `MediaService` out of the sync layer: media rows are
/// plain snapshot-only records, so they need nothing beyond the two push
/// methods `RemoteSyncService` already offers for every other collection.
///
/// The service is looked up on every push rather than held: it is rebuilt
/// whenever the signed-in account changes, while `MediaService` outlives that.
/// A held one kept pushing to the previous account's `users/{uid}` path, which
/// the rules refuse with permission-denied, so every image record was parked.
class RemoteMediaSyncPublisher implements MediaSyncPublisher {
  const RemoteMediaSyncPublisher(this._remoteSync);

  final RemoteSyncService Function() _remoteSync;

  @override
  void publishAsset(MediaAsset asset) => _remoteSync().pushMediaAsset(asset);

  @override
  void publishReference(MediaReference reference) =>
      _remoteSync().pushMediaReference(reference);
}

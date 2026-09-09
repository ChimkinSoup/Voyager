import 'package:voyager/core/media/media_service.dart';
import 'package:voyager/core/sync/remote_sync_service.dart';
import 'package:voyager/domain/models/media_models.dart';

/// Sends media metadata up the ordinary document sync path.
///
/// The seam that keeps `MediaService` out of the sync layer: media rows are
/// plain snapshot-only records, so they need nothing beyond the two push
/// methods `RemoteSyncService` already offers for every other collection.
class RemoteMediaSyncPublisher implements MediaSyncPublisher {
  const RemoteMediaSyncPublisher(this._remoteSync);

  final RemoteSyncService _remoteSync;

  @override
  void publishAsset(MediaAsset asset) => _remoteSync.pushMediaAsset(asset);

  @override
  void publishReference(MediaReference reference) =>
      _remoteSync.pushMediaReference(reference);
}

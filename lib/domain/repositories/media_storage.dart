import 'dart:typed_data';

/// Thrown when a transfer failed for a reason retrying cannot fix — the
/// object is not there, or the rules refused it.
///
/// Separated from ordinary failures so the queue can park the asset instead
/// of burning its retries: a download of an object another device never
/// uploaded fails identically every time.
class MediaStoragePermanentFailure implements Exception {
  const MediaStoragePermanentFailure(this.message);

  final String message;

  @override
  String toString() => message;
}

/// The blob half of remote sync: bytes in and out of the user's Storage
/// prefix.
///
/// Deliberately separate from `SyncRepository`. Documents and blobs have
/// different failure modes, different size limits and different settings
/// gating them, and the only thing they share is the uid the paths hang off.
abstract class MediaStorage {
  /// The signed-in user's uid, or null when nobody is signed in — in which
  /// case there is nowhere to put anything and both queues stay parked.
  String? get currentUid;

  /// Uploads [bytes] to [path]. Overwriting is fine and expected: the path is
  /// the content hash, so anything already there is byte-identical.
  Future<void> upload(String path, Uint8List bytes, String mimeType);

  Future<Uint8List> download(String path);

  /// Removes the object. A missing object is success — the purge runs on
  /// every device and only the first one to reach it finds anything.
  Future<void> delete(String path);
}

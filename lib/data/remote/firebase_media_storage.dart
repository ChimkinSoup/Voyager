import 'dart:typed_data';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:voyager/core/dev/dev_flags.dart';
import 'package:voyager/domain/repositories/media_storage.dart';
import 'package:voyager/domain/services/media_ingest.dart';

/// Firebase Cloud Storage, scoped to the signed-in user's prefix.
///
/// The bucket comes from `firebase_options.dart` rather than being named
/// here, so the app and its Storage live in the same project by
/// construction.
class FirebaseMediaStorage implements MediaStorage {
  /// [currentUid] names the account whose prefix this reads and writes; the
  /// app passes the admitted one (`AuthNotifier.userId`). Without it, Firebase
  /// Auth's current user.
  FirebaseMediaStorage({
    FirebaseStorage? storage,
    FirebaseAuth? auth,
    String? Function()? currentUid,
  }) : _storage = storage ?? FirebaseStorage.instance,
       _auth = auth ?? FirebaseAuth.instance,
       _currentUid = currentUid;

  final FirebaseStorage _storage;
  final FirebaseAuth _auth;
  final String? Function()? _currentUid;

  @override
  String? get currentUid {
    final currentUid = _currentUid;
    return currentUid == null ? _auth.currentUser?.uid : currentUid();
  }

  @override
  Future<void> upload(String path, Uint8List bytes, String mimeType) async {
    DevFlags.throwIfForcedOffline();
    try {
      await _storage
          .ref(path)
          .putData(bytes, SettableMetadata(contentType: mimeType));
    } on FirebaseException catch (error) {
      throw _classify(error);
    }
  }

  @override
  Future<Uint8List> download(String path) async {
    DevFlags.throwIfForcedOffline();
    try {
      // The cap is the ingest input limit: nothing this app uploaded can be
      // larger, so a response that would exceed it is not one of ours.
      final bytes = await _storage.ref(path).getData(maxIngestInputBytes);
      if (bytes == null) {
        throw const MediaStoragePermanentFailure(
          'The image is not in cloud storage.',
        );
      }
      return bytes;
    } on FirebaseException catch (error) {
      throw _classify(error);
    }
  }

  @override
  Future<void> delete(String path) async {
    DevFlags.throwIfForcedOffline();
    try {
      await _storage.ref(path).delete();
    } on FirebaseException catch (error) {
      // Already gone is the outcome this asked for.
      if (error.code == 'object-not-found') return;
      throw _classify(error);
    }
  }

  /// Sorts a Storage error into "retrying will never help" and everything
  /// else.
  ///
  /// Anything not named here — a timeout, a dropped connection, a server
  /// error — is left as the original exception so the queue retries it.
  Object _classify(FirebaseException error) {
    const permanent = {
      'object-not-found',
      'unauthorized',
      'unauthenticated',
      'invalid-argument',
      'project-not-found',
      'bucket-not-found',
      'quota-exceeded',
    };
    if (permanent.contains(error.code)) {
      return MediaStoragePermanentFailure(
        error.message ?? 'Cloud storage refused the transfer (${error.code}).',
      );
    }
    return error;
  }
}

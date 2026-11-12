import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:http/http.dart' as http;
import 'package:voyager/core/dev/dev_flags.dart';
import 'package:voyager/core/platform/dev_profile.dart';
import 'package:voyager/domain/repositories/media_storage.dart';
import 'package:voyager/domain/services/media_ingest.dart';

/// Firebase Cloud Storage over its REST API, for Windows. Same bucket, paths
/// and rules as `FirebaseMediaStorage`; only the transport differs.
///
/// On Windows the firebase_storage plugin runs on the Firebase C++ SDK, which
/// deadlocks when two Storage operations finish at once. One SDK thread
/// completing a Metadata future holds the future's lock and wants the
/// FutureManager's; another, releasing a StorageReference, holds them in the
/// opposite order. The platform thread then blocks on its next Storage call
/// and the app freezes (reproduced in qa on 2026-11-12 with three upload lanes
/// and a download lane).
class FirebaseRestMediaStorage implements MediaStorage {
  /// [currentUid] as in `FirebaseMediaStorage`.
  FirebaseRestMediaStorage({
    FirebaseAuth? auth,
    http.Client? httpClient,
    String? bucket,
    String? Function()? currentUid,
  }) : _auth = auth ?? FirebaseAuth.instanceFor(app: voyagerFirebaseApp),
       _http = httpClient ?? http.Client(),
       _bucket = bucket ?? voyagerFirebaseApp.options.storageBucket!,
       _currentUid = currentUid;

  final FirebaseAuth _auth;
  final http.Client _http;
  final String _bucket;
  final String? Function()? _currentUid;

  /// The SDK gave up on a stalled transfer by itself; a raw request would
  /// otherwise wait forever and hold up the serial transfer queue behind it.
  /// The request is aborted, not just abandoned, so it doesn't keep sending
  /// alongside the queue's retry.
  static const _timeout = Duration(minutes: 5);

  @override
  String? get currentUid {
    final currentUid = _currentUid;
    return currentUid == null ? _auth.currentUser?.uid : currentUid();
  }

  /// Parsed rather than built with [Uri.https], which would encode the
  /// object name's escaped slashes a second time.
  Uri _objectUri(String path, [String query = '']) => Uri.parse(
    'https://firebasestorage.googleapis.com/v0/b/$_bucket/o/'
    '${Uri.encodeComponent(path)}$query',
  );

  @override
  Future<void> upload(String path, Uint8List bytes, String mimeType) async {
    final response = await _send(
      'POST',
      // Encoded as the object URLs are: `Uri.https` would form-encode a space
      // as `+`.
      Uri.parse(
        'https://firebasestorage.googleapis.com/v0/b/$_bucket/o'
        '?name=${Uri.encodeComponent(path)}',
      ),
      body: bytes,
      contentType: mimeType,
    );
    _check(response);
  }

  @override
  Future<Uint8List> download(String path) async {
    final response = await _send('GET', _objectUri(path, '?alt=media'));
    if (response.statusCode == 404) {
      throw const MediaStoragePermanentFailure(
        'The image is not in cloud storage.',
      );
    }
    _check(response);
    return response.bodyBytes;
  }

  @override
  Future<void> delete(String path) async {
    final response = await _send('DELETE', _objectUri(path));
    // Already gone is the outcome this asked for.
    if (response.statusCode == 404) return;
    _check(response);
  }

  /// Sends with the user's ID token, refreshing it once if Storage calls it
  /// expired.
  Future<http.Response> _send(
    String method,
    Uri uri, {
    Uint8List? body,
    String? contentType,
  }) async {
    DevFlags.throwIfForcedOffline();
    final user = _auth.currentUser;
    if (user == null) throw StateError('Not signed in.');
    Future<http.Response> attempt(bool refresh) async {
      final token = await user.getIdToken(refresh);
      if (token == null) throw StateError('Not signed in.');
      final abort = Completer<void>();
      void cancel() {
        if (!abort.isCompleted) abort.complete();
      }

      final timer = Timer(_timeout, cancel);
      try {
        final request = http.AbortableRequest(
          method,
          uri,
          abortTrigger: abort.future,
        )..headers['Authorization'] = 'Firebase $token';
        if (body != null) {
          request
            ..headers['Content-Type'] = contentType!
            ..bodyBytes = body;
        }
        final streamed = await _http.send(request);
        // The cap is the ingest input limit: nothing this app uploaded can be
        // larger, so a response that exceeds it is not one of ours. Checked
        // while reading, so an oversized one is never held in memory whole.
        const tooLarge = MediaStoragePermanentFailure(
          'The cloud copy is larger than any image this app uploads.',
        );
        if ((streamed.contentLength ?? 0) > maxIngestInputBytes) {
          cancel();
          throw tooLarge;
        }
        final bytes = BytesBuilder(copy: false);
        await for (final chunk in streamed.stream) {
          bytes.add(chunk);
          if (bytes.length > maxIngestInputBytes) {
            cancel();
            throw tooLarge;
          }
        }
        return http.Response.bytes(
          bytes.takeBytes(),
          streamed.statusCode,
          request: streamed.request,
        );
      } finally {
        timer.cancel();
      }
    }

    var response = await attempt(false);
    if (response.statusCode == 401) response = await attempt(true);
    return response;
  }

  /// Sorts a failed response into "retrying will never help" (the statuses
  /// the SDK reports as unauthenticated, quota-exceeded, unauthorized,
  /// object-not-found and invalid-argument) and everything else, which the
  /// queue retries.
  void _check(http.Response response) {
    final status = response.statusCode;
    if (status >= 200 && status < 300) return;
    if (const {400, 401, 402, 403, 404}.contains(status)) {
      throw MediaStoragePermanentFailure(
        'Cloud storage refused the transfer (HTTP $status'
        '${_errorMessage(response)}).',
      );
    }
    throw http.ClientException(
      'Cloud storage failed (HTTP $status).',
      response.request?.url,
    );
  }

  /// Storage's own reason, from its `{"error": {"message": ...}}` body, so a
  /// missing bucket can be told from a missing object.
  String _errorMessage(http.Response response) {
    try {
      final message = (jsonDecode(response.body) as Map)['error']['message'];
      return message is String ? ': $message' : '';
    } catch (_) {
      return '';
    }
  }
}

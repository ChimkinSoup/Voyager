import 'dart:typed_data';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:voyager/data/remote/firebase_rest_media_storage.dart';
import 'package:voyager/domain/repositories/media_storage.dart';
import 'package:voyager/domain/services/media_ingest.dart';

class _FakeUser implements User {
  _FakeUser({this.hasToken = true});

  final bool hasToken;
  int refreshes = 0;

  @override
  Future<String?> getIdToken([bool forceRefresh = false]) async {
    if (forceRefresh) refreshes++;
    return hasToken ? 't$refreshes' : null;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeAuth implements FirebaseAuth {
  _FakeAuth(this.currentUser);

  @override
  final User? currentUser;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late List<http.Request> requests;

  FirebaseRestMediaStorage storageReplying(
    List<http.Response> replies, {
    _FakeUser? user,
  }) {
    requests = [];
    return FirebaseRestMediaStorage(
      auth: _FakeAuth(user ?? _FakeUser()),
      bucket: 'bkt',
      httpClient: MockClient((request) async {
        requests.add(request);
        return replies.removeAt(0);
      }),
    );
  }

  test('upload posts the bytes to the object name with the ID token', () async {
    final storage = storageReplying([http.Response('{}', 200)]);
    await storage.upload(
      'users/u/media/h',
      Uint8List.fromList([1, 2, 3]),
      'image/jpeg',
    );

    final request = requests.single;
    expect(request.method, 'POST');
    expect(
      request.url.toString(),
      'https://firebasestorage.googleapis.com/v0/b/bkt/o?name=users%2Fu%2Fmedia%2Fh',
    );
    expect(request.headers['Authorization'], 'Firebase t0');
    expect(request.headers['Content-Type'], 'image/jpeg');
    expect(request.bodyBytes, [1, 2, 3]);
  });

  test('an expired token is refreshed once and the request resent', () async {
    final user = _FakeUser();
    final storage = storageReplying([
      http.Response('', 401),
      http.Response('{}', 200),
    ], user: user);
    await storage.upload('p', Uint8List(1), 'image/png');

    expect(requests.map((r) => r.headers['Authorization']), [
      'Firebase t0',
      'Firebase t1',
    ]);
    expect(user.refreshes, 1);
  });

  test('download reads the encoded object path as media', () async {
    final storage = storageReplying([
      http.Response.bytes([7, 8], 200),
    ]);
    expect(await storage.download('users/u/media/h'), [7, 8]);
    expect(
      requests.single.url.toString(),
      'https://firebasestorage.googleapis.com/v0/b/bkt/o/users%2Fu%2Fmedia%2Fh?alt=media',
    );
  });

  test(
    'a missing object is permanent for download, success for delete',
    () async {
      final storage = storageReplying([
        http.Response('', 404),
        http.Response('', 404),
      ]);
      await expectLater(
        storage.download('p'),
        throwsA(isA<MediaStoragePermanentFailure>()),
      );
      await storage.delete('p');
      expect(requests.last.method, 'DELETE');
    },
  );

  test(
    'a refusal is permanent; a server error is left for the retry',
    () async {
      final storage = storageReplying([
        http.Response('', 403),
        http.Response('', 503),
      ]);
      await expectLater(
        storage.upload('p', Uint8List(1), 'image/png'),
        throwsA(isA<MediaStoragePermanentFailure>()),
      );
      await expectLater(
        storage.upload('p', Uint8List(1), 'image/png'),
        throwsA(
          isA<http.ClientException>().having(
            (e) => e is MediaStoragePermanentFailure,
            'permanent',
            false,
          ),
        ),
      );
    },
  );

  test('upload and download encode the object name the same way', () async {
    final storage = storageReplying([
      http.Response('{}', 200),
      http.Response.bytes([1], 200),
    ]);
    await storage.upload('a b/c', Uint8List(1), 'image/png');
    await storage.download('a b/c');
    expect(requests.first.url.query, 'name=a%20b%2Fc');
    expect(requests.last.url.path, '/v0/b/bkt/o/a%20b%2Fc');
  });

  test('a missing ID token is not sent and is left for the retry', () async {
    final storage = storageReplying([], user: _FakeUser(hasToken: false));
    await expectLater(
      storage.upload('p', Uint8List(1), 'image/png'),
      throwsA(isA<StateError>()),
    );
    expect(requests, isEmpty);
  });

  test('an oversized download is refused before it is read whole', () async {
    var chunksRead = 0;
    final storage = FirebaseRestMediaStorage(
      auth: _FakeAuth(_FakeUser()),
      bucket: 'bkt',
      httpClient: MockClient.streaming((request, _) async {
        final chunk = Uint8List(1024 * 1024);
        return http.StreamedResponse(
          Stream.fromIterable(List.generate(100, (_) => chunk)).map((c) {
            chunksRead++;
            return c;
          }),
          200,
        );
      }),
    );
    await expectLater(
      storage.download('p'),
      throwsA(isA<MediaStoragePermanentFailure>()),
    );
    expect(chunksRead, lessThan(100));
    expect(chunksRead * 1024 * 1024, greaterThan(maxIngestInputBytes));
  });

  test("a refusal carries Storage's own reason", () async {
    final storage = storageReplying([
      http.Response(
        '{"error": {"code": 404, "message": "Bucket not found."}}',
        404,
      ),
    ]);
    await expectLater(
      storage.upload('p', Uint8List(1), 'image/png'),
      throwsA(
        isA<MediaStoragePermanentFailure>().having(
          (e) => e.message,
          'message',
          contains('Bucket not found.'),
        ),
      ),
    );
  });
}

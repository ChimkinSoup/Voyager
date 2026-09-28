// BUG-002: the offline badge's probe was a Firestore document read, which
// queued behind a full pull's queries on the SDK's one worker and timed out
// on a healthy network. The probe is now a plain HTTPS request, falling back
// on that read only when the request fails (dart:io ignores the Windows
// system proxy, which the SDK honours).

import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:voyager/core/sync/firestore_write_gate.dart';
import 'package:voyager/data/remote/firestore_sync_repository.dart';

FirestoreSyncRepository _repository(
  MockClient client, {
  FakeFirebaseFirestore? firestore,
}) => FirestoreSyncRepository(
  firestore ?? FakeFirebaseFirestore(),
  'user-1',
  writeGate: FirestoreWriteGate(waitForPendingWrites: () async {}),
  httpClient: client,
);

void main() {
  test('any HTTP answer from Firestore counts as reachable', () async {
    final requests = <http.BaseRequest>[];
    final repository = _repository(
      MockClient((request) async {
        requests.add(request);
        return http.Response('', 404);
      }),
    );

    await repository.ping();

    expect(requests.single.method, 'HEAD');
    expect(requests.single.url.host, 'firestore.googleapis.com');
  });

  test('a failed connection falls back on a server read', () async {
    final repository = _repository(
      MockClient((_) async => throw http.ClientException('no route to host')),
    );

    await repository.ping();
  });

  test('throws when the server read fails too', () async {
    final repository = _repository(
      MockClient((_) async => throw http.ClientException('no route to host')),
      firestore: FakeFirebaseFirestore(
        securityRules: '''
service cloud.firestore {
  match /databases/{database}/documents {
    match /{document=**} {
      allow read, write: if false;
    }
  }
}
''',
      ),
    );

    await expectLater(repository.ping(), throwsA(isA<Exception>()));
  });
}

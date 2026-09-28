import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/sync/firestore_write_gate.dart';
import 'package:voyager/data/remote/firebase_auth_repository.dart';
import 'package:voyager/data/remote/firestore_sync_repository.dart';

void main() {
  test('signing in after a signed-out launch swaps in the Firestore '
      'repository, and signing out swaps it back', () async {
    final firestore = FakeFirebaseFirestore();
    final auth = InMemoryAuthRepository();
    final container = ProviderContainer(
      overrides: [
        authRepositoryProvider.overrideWithValue(auth),
        firestoreProvider.overrideWithValue(firestore),
        firestoreWriteGateProvider.overrideWithValue(
          FirestoreWriteGate(waitForPendingWrites: () async {}),
        ),
      ],
    );
    addTearDown(container.dispose);

    // Kept alive the way the root widget's connectivity listener keeps it.
    container.listen(syncRepositoryProvider, (_, _) {});
    expect(container.read(syncRepositoryProvider), isA<NoOpSyncRepository>());

    await auth.signInWithEmail('a@example.com', 'pw');
    await Future<void>.delayed(Duration.zero);
    final signedIn = container.read(syncRepositoryProvider);
    expect(signedIn, isA<FirestoreSyncRepository>());
    expect((signedIn as FirestoreSyncRepository).userId, 'email:a@example.com');

    await auth.signOut();
    await Future<void>.delayed(Duration.zero);
    expect(container.read(syncRepositoryProvider), isA<NoOpSyncRepository>());
  });
}

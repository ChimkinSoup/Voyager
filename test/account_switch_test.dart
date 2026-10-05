import 'dart:async';
import 'dart:io';

import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:voyager/app/account_admission.dart';
import 'package:voyager/app/auth_notifier.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/sync/firestore_collections.dart';
import 'package:voyager/core/sync/firestore_write_gate.dart';
import 'package:voyager/core/sync/local_account_store.dart';
import 'package:voyager/core/sync/outbox_sync_worker.dart';
import 'package:voyager/core/sync/remote_sync_service.dart';
import 'package:voyager/features/auth/login_page.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/data/remote/firestore_sync_repository.dart';
import 'package:voyager/data/repositories/drift_repositories.dart';
import 'package:voyager/domain/models/enums.dart';
import 'package:voyager/domain/models/finance_models.dart';
import 'package:voyager/domain/models/journal_models.dart';
import 'package:voyager/domain/repositories/repositories.dart';

/// Signs in by uid, so the uids can be real-looking path components (the
/// backups folder is named after one).
class _Auth implements AuthRepository {
  final _changes = StreamController<bool>.broadcast();
  String? _uid;

  @override
  String? get currentUserId => _uid;

  @override
  Stream<bool> get authStateChanges => _changes.stream;

  void signIn(String uid) {
    _uid = uid;
    _changes.add(true);
  }

  @override
  Future<void> signOut() async {
    _uid = null;
    _changes.add(false);
  }

  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late Directory temp;
  late Directory data;
  late Directory backupsRoot;
  late AppDatabase db;
  late FakeFirebaseFirestore firestore;
  late _Auth auth;
  late ProviderContainer container;
  late OutboxSyncWorker worker;

  /// What the discard question answers, and how often it was asked with what.
  late Future<bool> Function(int unsynced) answer;
  late List<int> asked;

  /// Set to make the next wipe fail on its files, as a locked file does.
  var filesLocked = false;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('voyager_account_switch');
    data = await Directory(p.join(temp.path, 'data')).create();
    backupsRoot = Directory(p.join(temp.path, 'backups'));
    db = AppDatabase.inMemory();
    firestore = FakeFirebaseFirestore();
    auth = _Auth();
    asked = [];
    answer = (_) async => true;
    filesLocked = false;
    container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        authRepositoryProvider.overrideWithValue(auth),
        firestoreProvider.overrideWithValue(firestore),
        firestoreWriteGateProvider.overrideWithValue(
          FirestoreWriteGate(waitForPendingWrites: () async {}),
        ),
        localAccountStoreProvider.overrideWithValue(
          LocalAccountStore(
            db,
            dataDirectory: () async {
              if (filesLocked) {
                throw const FileSystemException('locked by another process');
              }
              return data;
            },
            backupsRoot: () async => backupsRoot,
          ),
        ),
        accountAdmissionProvider.overrideWith(
          (ref) =>
              (uid, isCurrent) => admitAccount(
                ref,
                uid,
                isCurrent,
                confirmDiscard: (unsynced) {
                  asked.add(unsynced);
                  return answer(unsynced);
                },
              ),
        ),
      ],
    );
    container.listen(syncRepositoryProvider, (_, _) {});
    worker = OutboxSyncWorker(
      db,
      firestore,
      () => container.read(authNotifierProvider).userId,
      yieldDelay: Duration.zero,
    );
  });

  tearDown(() async {
    container.dispose();
    await db.close();
    await temp.delete(recursive: true);
  });

  AuthNotifier notifier() => container.read(authNotifierProvider);

  Future<void> signIn(String uid) async {
    auth.signIn(uid);
    await Future<void>.delayed(Duration.zero);
    await notifier().settled;
  }

  Future<void> signOut() async {
    await auth.signOut();
    await Future<void>.delayed(Duration.zero);
  }

  /// An expense written and left queued in the outbox, as an upload that
  /// failed offline leaves it.
  Future<void> queueTransaction(String id) async {
    final at = DateTime.utc(2026, 5, 1);
    await DriftFinanceRepository(db).upsertTransaction(
      FinancialTransaction(
        id: id,
        type: TransactionType.expense,
        amountCents: 1250,
        occurredAt: at,
        note: 'private to $id',
        createdAt: at,
        updatedAt: at,
      ),
      recordLocalActivity: false,
    );
    await worker.enqueue(
      collection: FirestoreCollections.transactions,
      documentId: id,
    );
  }

  Future<bool> uploaded(String uid, String id) async =>
      (await firestore
              .doc('users/$uid/${FirestoreCollections.transactions}/$id')
              .get())
          .exists;

  Future<List<Object>> localRows() async => [
    ...await db.select(db.transactionsTable).get(),
    ...await db.select(db.pendingUploadsTable).get(),
  ];

  test('another account signing in gets an empty store, and the previous '
      "account's queued uploads never reach its cloud copy", () async {
    await signIn('accountA');
    expect(notifier().userId, 'accountA');
    final deviceId = (await DriftSettingsRepository(db).getSettings()).deviceId;
    await DriftSettingsRepository(db).saveSettings(
      (await DriftSettingsRepository(
        db,
      ).getSettings()).copyWith(leetcodeUsername: 'a-private-handle'),
    );
    await queueTransaction('txn-a');
    await signOut();

    await signIn('accountB');

    expect(asked, [1]);
    expect(notifier().userId, 'accountB');
    expect(await localRows(), isEmpty);
    final settings = await DriftSettingsRepository(db).getSettings();
    expect(settings.leetcodeUsername, isNull);
    expect(settings.deviceId, deviceId);
    expect(await container.read(localAccountStoreProvider).owner(), 'accountB');

    await worker.startDraining();
    expect(await uploaded('accountB', 'txn-a'), isFalse);
    expect(await uploaded('accountA', 'txn-a'), isFalse);
  });

  test('while the question is open, the new account is not signed in and '
      'nothing drains into it', () async {
    await signIn('accountA');
    await queueTransaction('txn-a');
    await signOut();
    final pending = Completer<bool>();
    answer = (_) => pending.future;

    auth.signIn('accountB');
    await Future<void>.delayed(Duration.zero);

    // Firebase already holds B; the app must not act on it yet.
    expect(auth.currentUserId, 'accountB');
    expect(notifier().isAuthenticated, isFalse);
    expect(notifier().isSettling, isTrue);
    expect(container.read(syncRepositoryProvider), isA<NoOpSyncRepository>());
    await worker.startDraining();
    expect(await uploaded('accountB', 'txn-a'), isFalse);
    expect(await localRows(), hasLength(2));

    pending.complete(true);
    await notifier().settled;
    expect(notifier().userId, 'accountB');
    expect(await localRows(), isEmpty);
  });

  test('declining keeps the previous account\'s data and signs the new one '
      'back out', () async {
    await signIn('accountA');
    await queueTransaction('txn-a');
    await signOut();
    answer = (_) async => false;

    await signIn('accountB');
    await Future<void>.delayed(Duration.zero);

    expect(auth.currentUserId, isNull);
    expect(notifier().isAuthenticated, isFalse);
    expect(await localRows(), hasLength(2));
    expect(await container.read(localAccountStoreProvider).owner(), 'accountA');

    // Back in as A, the queued upload goes where it belongs.
    await signIn('accountA');
    await worker.startDraining();
    expect(await uploaded('accountA', 'txn-a'), isTrue);
  });

  test('the same account signing back in keeps its queued uploads, without '
      'being asked anything', () async {
    await signIn('accountA');
    await queueTransaction('txn-a');
    await signOut();

    await signIn('accountA');

    expect(asked, isEmpty);
    expect(notifier().userId, 'accountA');
    await worker.startDraining();
    expect(await uploaded('accountA', 'txn-a'), isTrue);
  });

  test('nothing left to upload: the switch asks nothing', () async {
    await signIn('accountA');
    final at = DateTime.utc(2026, 5, 1);
    await DriftJournalRepository(db).upsertJournal(
      Journal(id: 'journal-a', name: 'A', createdAt: at, updatedAt: at),
    );
    await signOut();

    await signIn('accountB');

    expect(asked, isEmpty);
    expect(notifier().userId, 'accountB');
    expect(await db.select(db.journalsTable).get(), isEmpty);
  });

  test('backups belong to the account whose data they hold', () async {
    // Taken before owners were recorded: the first account in claims them.
    await backupsRoot.create(recursive: true);
    final legacy = File(
      p.join(backupsRoot.path, 'voyager_auto_2026-09-30_090000.zip'),
    );
    await legacy.writeAsString('backup of A');
    final store = container.read(localAccountStoreProvider);

    await signIn('accountA');
    expect(
      (await store.backupsDirectory()).path,
      p.join(backupsRoot.path, 'accountA'),
    );
    expect(await legacy.exists(), isFalse);
    expect(
      await File(
        p.join(backupsRoot.path, 'accountA', p.basename(legacy.path)),
      ).exists(),
      isTrue,
    );

    await signOut();
    await signIn('accountB');
    expect(
      (await store.backupsDirectory()).path,
      p.join(backupsRoot.path, 'accountB'),
    );
    expect(
      await container.read(autoBackupServiceProvider).listBackups(),
      isEmpty,
    );
    // A's backups stay on the device for A.
    expect(
      await File(
        p.join(backupsRoot.path, 'accountA', p.basename(legacy.path)),
      ).exists(),
      isTrue,
    );
  });

  test("the previous account's drafts and images go with its data", () async {
    await signIn('accountA');
    final draft = File(p.join(data.path, 'jobs_track_draft.json'));
    await draft.writeAsString('{"company":"A private"}');
    final media = await Directory(p.join(data.path, 'media')).create();
    await File(p.join(media.path, 'abc.png')).writeAsString('bytes');
    final chrome = File(p.join(data.path, 'finance_ui_prefs.json'));
    await chrome.writeAsString('{}');
    await signOut();

    await signIn('accountB');

    expect(await draft.exists(), isFalse);
    expect(await media.exists(), isFalse);
    expect(await chrome.exists(), isTrue);
  });

  /// What a store from before owners were recorded looks like once it has
  /// pulled for [uid].
  Future<void> pulledBefore(String uid) async {
    final at = DateTime.utc(2026, 9, 1);
    await db
        .into(db.syncWatermarksTable)
        .insert(
          SyncWatermarksTableCompanion.insert(
            userId: uid,
            collection: FirestoreCollections.transactions,
            changedSince: at,
            lastFullPullAt: at,
          ),
        );
  }

  test('an unowned store pulled for another account is not handed to the '
      'one signing in', () async {
    // Upgraded from before owners were recorded, with A signed out.
    await pulledBefore('accountA');
    await queueTransaction('txn-a');
    await backupsRoot.create(recursive: true);
    final legacy = File(
      p.join(backupsRoot.path, 'voyager_auto_2026-09-30_090000.zip'),
    );
    await legacy.writeAsString('backup of A');

    await signIn('accountB');

    expect(asked, [1]);
    expect(notifier().userId, 'accountB');
    expect(await localRows(), isEmpty);
    await worker.startDraining();
    expect(await uploaded('accountB', 'txn-a'), isFalse);
    // A's backups went to A, not to B and not left unowned.
    expect(
      await File(
        p.join(backupsRoot.path, 'accountA', p.basename(legacy.path)),
      ).exists(),
      isTrue,
    );
    expect(
      await container.read(autoBackupServiceProvider).listBackups(),
      isEmpty,
    );
  });

  test('an unowned store pulled for the account signing in is claimed as '
      'it is', () async {
    await pulledBefore('accountA');
    await queueTransaction('txn-a');

    await signIn('accountA');

    expect(asked, isEmpty);
    expect(await container.read(localAccountStoreProvider).owner(), 'accountA');
    await worker.startDraining();
    expect(await uploaded('accountA', 'txn-a'), isTrue);
  });

  test("a pull the previous account started finishes before the wipe, not "
      'into the emptied store', () async {
    await signIn('accountA');
    await signOut();
    // A's startup pull, still writing pages after the sign-out.
    final pullGoesOn = Completer<void>();
    RemoteSyncService.trackPull(
      pullGoesOn.future.then((_) async {
        final at = DateTime.utc(2026, 5, 1);
        await DriftJournalRepository(db).upsertJournal(
          Journal(id: 'journal-a', name: 'A', createdAt: at, updatedAt: at),
          recordLocalActivity: false,
        );
      }),
    );

    auth.signIn('accountB');
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(notifier().isSettling, isTrue);
    pullGoesOn.complete();
    await notifier().settled;

    expect(notifier().userId, 'accountB');
    expect(await db.select(db.journalsTable).get(), isEmpty);
  });

  test('a sign-in overtaken while it waits changes nothing', () async {
    await signIn('accountA');
    await queueTransaction('txn-a');
    await signOut();
    final firstAnswer = Completer<bool>();
    answer = (_) => firstAnswer.future;

    // B asks to discard, then A is back before the question is answered.
    auth.signIn('accountB');
    await Future<void>.delayed(Duration.zero);
    await signOut();
    auth.signIn('accountA');
    await Future<void>.delayed(Duration.zero);
    firstAnswer.complete(true);
    await notifier().settled;

    expect(asked, [1]);
    expect(notifier().userId, 'accountA');
    expect(await localRows(), hasLength(2));
    expect(await container.read(localAccountStoreProvider).owner(), 'accountA');
  });

  test('a wipe whose files cannot be deleted leaves everything to the '
      'previous account, and the next sign-in retries it', () async {
    await signIn('accountA');
    final draft = File(p.join(data.path, 'jobs_track_draft.json'));
    await draft.writeAsString('{"company":"A private"}');
    await queueTransaction('txn-a');
    await signOut();
    filesLocked = true;

    await signIn('accountB');
    await Future<void>.delayed(Duration.zero);

    expect(auth.currentUserId, isNull);
    expect(await container.read(localAccountStoreProvider).owner(), 'accountA');
    expect(await localRows(), hasLength(2));

    filesLocked = false;
    await signIn('accountB');
    expect(notifier().userId, 'accountB');
    expect(await localRows(), isEmpty);
    expect(await draft.exists(), isFalse);
  });

  testWidgets('the login page is busy while a sign-in is checked', (
    tester,
  ) async {
    await tester.runAsync(() async {
      await signIn('accountA');
      await queueTransaction('txn-a');
      await signOut();
    });
    final pending = Completer<bool>();
    answer = (_) => pending.future;
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: LoginPage()),
      ),
    );
    expect(find.byType(CircularProgressIndicator), findsNothing);

    await tester.runAsync(() async {
      auth.signIn('accountB');
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    await tester.runAsync(() async {
      pending.complete(false);
      await notifier().settled;
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });
}

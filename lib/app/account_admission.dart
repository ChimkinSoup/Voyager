import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/dev/dev_flags.dart';
import 'package:voyager/core/notifications/notification_history.dart';
import 'package:voyager/core/sync/outbox_sync_worker.dart';
import 'package:voyager/core/sync/pending_flush_registry.dart';
import 'package:voyager/core/sync/remote_sync_service.dart';
import 'package:voyager/core/widgets/confirm_dialog.dart';
import 'package:voyager/domain/repositories/repositories.dart';
import 'package:voyager/features/todo/todo_subtask_draft_store.dart';
import 'package:voyager/routing/app_router.dart';

/// Lets [uid] in once this device's local data is its own (BUG-005).
///
/// The same account signing back in keeps everything, uploads still queued
/// included. Unowned data — a fresh install, or a store from before owners
/// were recorded — is claimed by the account signing in, unless the store
/// was pulled for a different one: then it is that account's data, and is
/// treated as such. A different account gets an empty store, which its
/// startup pull fills: it must never see the previous account's data, and
/// nothing of it may reach its cloud copy.
///
/// Wiping drops whatever the previous account had not uploaded, so when there
/// is any, [confirmDiscard] is asked first; declining keeps everything and
/// signs the new account back out. Once [isCurrent] turns false — the user
/// signed out, or in as someone else, while this waited — nothing more is
/// changed.
///
/// An admitted account gets Firestore's network back, which
/// [signOutPausingSync] took down.
Future<bool> admitAccount(
  Ref ref,
  String uid,
  bool Function() isCurrent, {
  required Future<bool> Function(int unsynced) confirmDiscard,
}) async {
  final admitted = await _admit(
    ref,
    uid,
    isCurrent,
    confirmDiscard: confirmDiscard,
  );
  if (admitted && !DevFlags.forceOffline) {
    await _firestoreCall(
      'turning the network back on',
      () => ref.read(firestoreProvider).enableNetwork(),
    );
  }
  return admitted;
}

/// Signs out with Firestore's network off.
///
/// Signing out while Firestore still has writes the server hasn't
/// acknowledged — an outbox draining, or offline edits waiting to send —
/// leaves the client wedged: after the next sign-in nothing is sent or
/// received, and even `terminate` never returns, until the app restarts
/// (BUG-267). With the network off over the user change it isn't, and the
/// writes stay queued for the same account's next sign-in. [admitAccount]
/// turns it back on.
Future<void> signOutPausingSync(
  FirebaseFirestore firestore,
  AuthRepository auth,
) async {
  await _firestoreCall(
    'taking the network down to sign out',
    firestore.disableNetwork,
  );
  await auth.signOut();
}

Future<bool> _admit(
  Ref ref,
  String uid,
  bool Function() isCurrent, {
  required Future<bool> Function(int unsynced) confirmDiscard,
}) async {
  final local = ref.read(localAccountStoreProvider);
  final gate = ref.read(firestoreWriteGateProvider);
  final owner = await local.owner();
  if (owner == uid) return true;
  final backups = ref.read(autoBackupServiceProvider);
  final pulledFor = owner == null ? await local.pulledFor() : const <String>{};
  if (owner == null && pulledFor.every((pulled) => pulled == uid)) {
    if (!isCurrent()) return false;
    await local.claim(uid);
    await backups.refreshStatus();
    return true;
  }

  // Writes handed to Firestore and not yet acknowledged count too: until the
  // write gate gives up on them they are on no outbox (BUG-269).
  final unsynced = await local.unsyncedChanges() + gate.inFlight;
  if (unsynced > 0 && !await confirmDiscard(unsynced)) return false;
  if (OutboxSyncWorker.isInitialized) await OutboxSyncWorker.instance.idle;
  await backups.idle;
  await RemoteSyncService.pullsIdle;
  if (!isCurrent()) return false;
  // An unowned store's backups belong to the account it was pulled for.
  if (owner == null && pulledFor.length == 1) {
    await local.moveUnownedBackupsTo(pulledFor.single);
  }
  // What the old account handed Firestore is discarded with its store: left
  // in Firestore's own persisted queue, it was sent the next time that
  // account signed in here, after the user chose to drop it (BUG-268), and a
  // write still in flight would fail into the new account's outbox (BUG-269).
  gate.abandonInFlight();
  await local.wipeFor(uid);
  await _firestoreCall("clearing Firestore's queue", () async {
    final firestore = ref.read(firestoreProvider);
    await firestore.terminate();
    await firestore.clearPersistence();
  });
  // The old client's probe never answers once it is terminated.
  gate.watchQueueAgain();

  // What the app holds of the old account in memory, as a restore clears it:
  // the data first, reloaded before the pages remount so they read the empty
  // store rather than the old account's rows still held through the reload.
  ref.read(charOpRegistryProvider).clear();
  NotificationHistory.instance.clear();
  // Through the container: this runs inside the admission, which the
  // sign-in state depends on, and a provider may not invalidate its own
  // dependents.
  // The one file store that keeps its file in memory, and would write the
  // old account's drafts back on its next save. Before the reload below, so
  // no save lands in the old store while it runs.
  ref.container.invalidate(todoSubtaskDraftStoreProvider);
  // The built-ins are seeded once per store, and the store is new: the seeds
  // kept their finished run and never wrote into it (BUG-266).
  ref.container.invalidate(workoutSeedProvider);
  ref.container.invalidate(jobSeedProvider);
  await reloadAllDataProvidersIn(ref.container);
  restoreGeneration.value++;
  await backups.refreshStatus();
  return true;
}

/// Runs a call on the Firestore client that must not hold up a sign-in or
/// sign-out: a wedged client never answers (BUG-267). Reported, not thrown.
Future<void> _firestoreCall(String what, Future<void> Function() call) async {
  try {
    await call().timeout(const Duration(seconds: 10));
  } catch (error, stackTrace) {
    FlutterError.reportError(
      FlutterErrorDetails(
        exception: error,
        stack: stackTrace,
        library: 'account admission',
        context: ErrorDescription('while $what'),
      ),
    );
  }
}

/// [admitAccount]'s question, asked over the login page.
///
/// With no navigator to ask on — the account restored at launch, before the
/// first route is up — the answer is no: the account is signed out, and is
/// asked when it signs in again.
Future<bool> confirmDiscardUnsynced(Ref ref, int unsynced) async {
  // Through the container, as in [admitAccount]: the router depends on the
  // sign-in state this question decides.
  final context = ref.container
      .read(routerProvider)
      .routerDelegate
      .navigatorKey
      .currentContext;
  if (context == null || !context.mounted) return false;
  return showConfirmDialog(
    context,
    title: 'Discard unsynced changes?',
    message:
        'This device holds $unsynced change(s) from the account signed in '
        "before, which haven't reached its cloud copy yet. Signing in to a "
        "different account removes that account's data from this device, "
        'these changes included.\n\n'
        'To keep them, cancel and sign in to that account again while '
        'online, so they can upload.',
    confirmLabel: 'Discard and sign in',
  );
}

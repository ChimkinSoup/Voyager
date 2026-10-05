import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:voyager/domain/repositories/repositories.dart';

/// Decides whether [uid] may use this device's local data, readying it first
/// if need be. False signs the account back out. See `admitAccount`.
///
/// [isCurrent] turns false once a later sign-in change has overtaken this
/// one; the admission must then change nothing more.
typedef AccountAdmission =
    Future<bool> Function(String uid, bool Function() isCurrent);

class AuthNotifier extends ChangeNotifier {
  AuthNotifier(this._auth, {AccountAdmission? admit}) : _admit = admit {
    _subscription = _auth.authStateChanges.listen((_) => _onAuthChanged());
    _onAuthChanged();
  }

  final AuthRepository _auth;
  final AccountAdmission? _admit;
  late final StreamSubscription<bool> _subscription;

  String? _userId;

  /// The uid being admitted, while [_admit] runs.
  String? _admitting;
  Future<void> _settled = Future.value();

  /// Bumped on every sign-in change, so an admission that a later change has
  /// overtaken doesn't land.
  int _generation = 0;

  bool get isAuthenticated => _userId != null;

  /// The signed-in account, once admitted. Firebase can already hold a
  /// different user while the admission decides — and possibly wipes — whose
  /// data this device keeps, so anything that reads or uploads account data
  /// goes by this, never by `AuthRepository.currentUserId`.
  String? get userId => _userId;

  /// Whether an admission is still deciding the signed-in state.
  bool get isSettling => _admitting != null;

  /// [isSettling], for the login page's busy state. Apart from the notifier
  /// itself so it doesn't refresh the router, whose redirect waits for
  /// [settled] — and an admission can be waiting on a question asked over
  /// the login page.
  ValueListenable<bool> get settlingListenable => _settling;
  final _settling = ValueNotifier<bool>(false);

  /// Completes once no admission is running.
  Future<void> get settled => _settled;

  void _onAuthChanged() {
    final uid = _auth.currentUserId;
    if (uid == _userId && _admitting == null) return;
    if (uid != null && uid == _admitting) return;
    final generation = ++_generation;
    _setAdmitting(null);
    final admit = _admit;
    if (uid == null || admit == null) {
      _setUser(uid);
      return;
    }
    // Out until admitted: another account's data must not show, or sync, in
    // the meantime.
    _setUser(null);
    _setAdmitting(uid);
    // After the one before it, never alongside: two admissions reading the
    // owner while one of them wipes could each decide on a store the other
    // is changing.
    _settled = _settled.then((_) => _runAdmission(admit, uid, generation));
  }

  void _setAdmitting(String? uid) {
    _admitting = uid;
    _settling.value = uid != null;
  }

  Future<void> _runAdmission(
    AccountAdmission admit,
    String uid,
    int generation,
  ) async {
    bool isCurrent() => generation == _generation;
    // Overtaken while it waited for the one before it.
    if (!isCurrent()) return;
    var admitted = false;
    try {
      admitted = await admit(uid, isCurrent);
    } catch (error, stackTrace) {
      // Closed rather than open: an account let in on a failed check could be
      // looking at, and uploading, another account's data.
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: error,
          stack: stackTrace,
          library: 'AuthNotifier',
          context: ErrorDescription('while admitting a signed-in account'),
        ),
      );
    }
    if (!isCurrent()) return;
    _setAdmitting(null);
    if (admitted && _auth.currentUserId == uid) {
      _setUser(uid);
    } else if (!admitted) {
      await _auth.signOut();
    }
  }

  void _setUser(String? uid) {
    if (uid == _userId) return;
    _userId = uid;
    notifyListeners();
  }

  @override
  void dispose() {
    _subscription.cancel();
    _settling.dispose();
    super.dispose();
  }
}

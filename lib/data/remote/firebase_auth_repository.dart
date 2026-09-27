import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:voyager/core/auth/firebase_auth_errors.dart';
import 'package:voyager/core/platform/platform_info.dart';
import 'package:voyager/data/remote/desktop_google_oauth.dart';
import 'package:voyager/domain/repositories/repositories.dart';

class FirebaseAuthRepository implements AuthRepository {
  FirebaseAuthRepository(this._auth);

  final FirebaseAuth _auth;

  @override
  Stream<bool> get authStateChanges =>
      _auth.authStateChanges().map((user) => user != null);

  @override
  String? get currentUserId => _auth.currentUser?.uid;

  @override
  String? get currentUserEmail => _auth.currentUser?.email;

  @override
  bool get hasPasswordSignIn =>
      _auth.currentUser?.providerData.any(
        (info) => info.providerId == EmailAuthProvider.PROVIDER_ID,
      ) ??
      false;

  @override
  Future<void> changePassword(
    String currentPassword,
    String newPassword,
  ) async {
    final user = _auth.currentUser;
    final email = user?.email;
    if (user == null || email == null) throw Exception('Not signed in.');
    try {
      await user.reauthenticateWithCredential(
        EmailAuthProvider.credential(email: email, password: currentPassword),
      );
      await user.updatePassword(newPassword);
    } catch (e) {
      throw Exception(
        e is FirebaseException && e.plugin == 'firebase_auth'
            ? changePasswordErrorMessage(code: e.code, message: e.message)
            : 'Could not change password.',
      );
    }
  }

  @override
  Future<void> signInWithEmail(String email, String password) async {
    try {
      await _auth.signInWithEmailAndPassword(email: email, password: password);
    } catch (e) {
      throw Exception(_authErrorMessage(e, fallback: 'Sign in failed.'));
    }
  }

  @override
  Future<void> signUpWithEmail(String email, String password) async {
    try {
      await _auth.createUserWithEmailAndPassword(
        email: email,
        password: password,
      );
    } catch (e) {
      throw Exception(_authErrorMessage(e, fallback: 'Sign up failed.'));
    }
  }

  @override
  Future<void> sendPasswordResetEmail(String email) async {
    try {
      await _auth.sendPasswordResetEmail(email: email);
    } catch (e) {
      throw Exception(
        _authErrorMessage(e, fallback: 'Could not send reset email.'),
      );
    }
  }

  @override
  Future<void> signInWithGoogle() async {
    try {
      if (isWindows) {
        await _signInWithGoogleBrowserCredential();
        return;
      }
      await _auth.signInWithProvider(GoogleAuthProvider());
    } on FirebaseAuthException catch (e) {
      throw Exception(_authErrorMessage(e, fallback: 'Google sign in failed.'));
    } on StateError catch (e) {
      throw Exception(e.message);
    } on TimeoutException {
      throw Exception('Google sign in timed out.');
    }
  }

  Future<void> _signInWithGoogleBrowserCredential() async {
    final tokens = await DesktopGoogleOAuth().signIn();
    final credential = GoogleAuthProvider.credential(
      accessToken: tokens.accessToken,
      idToken: tokens.idToken,
    );
    await _auth.signInWithCredential(credential);
  }

  @override
  Future<void> signOut() => _auth.signOut();
}

String _authErrorMessage(Object error, {required String fallback}) {
  if (error is FirebaseAuthException) {
    return firebaseAuthErrorMessage(code: error.code, message: error.message);
  }
  if (error is FirebaseException && error.plugin == 'firebase_auth') {
    return firebaseAuthErrorMessage(code: error.code, message: error.message);
  }
  return fallback;
}

class InMemoryAuthRepository implements AuthRepository {
  InMemoryAuthRepository() {
    _controller.onListen = () {
      if (!_hasEmitted) {
        _hasEmitted = true;
        _controller.add(_userId != null);
      }
    };
  }

  final _controller = StreamController<bool>.broadcast();
  String? _userId;
  var _hasEmitted = false;

  @override
  Stream<bool> get authStateChanges => _controller.stream;

  @override
  String? get currentUserId => _userId;

  @override
  String? get currentUserEmail =>
      _userId?.startsWith('email:') ?? false ? _userId!.substring(6) : null;

  @override
  bool get hasPasswordSignIn => currentUserEmail != null;

  @override
  Future<void> changePassword(
    String currentPassword,
    String newPassword,
  ) async {}

  @override
  Future<void> signInWithEmail(String email, String password) async {
    _userId = 'email:$email';
    _controller.add(true);
  }

  @override
  Future<void> signUpWithEmail(String email, String password) async {
    _userId = 'email:$email';
    _controller.add(true);
  }

  @override
  Future<void> sendPasswordResetEmail(String email) async {}

  @override
  Future<void> signInWithGoogle() async {
    _userId = 'google:user';
    _controller.add(true);
  }

  @override
  Future<void> signOut() async {
    _userId = null;
    _controller.add(false);
  }

  void dispose() => _controller.close();
}

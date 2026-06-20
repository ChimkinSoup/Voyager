import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:voyager/domain/repositories/repositories.dart';

class AuthNotifier extends ChangeNotifier {
  AuthNotifier(this._auth) {
    _subscription = _auth.authStateChanges.listen((loggedIn) {
      _isAuthenticated = loggedIn;
      notifyListeners();
    });
    _isAuthenticated = _auth.currentUserId != null;
  }

  final AuthRepository _auth;
  late final StreamSubscription<bool> _subscription;
  bool _isAuthenticated = false;

  bool get isAuthenticated => _isAuthenticated;

  @override
  void dispose() {
    _subscription.cancel();
    super.dispose();
  }
}

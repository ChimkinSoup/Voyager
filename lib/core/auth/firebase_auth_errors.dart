/// User-facing Firebase Auth errors.
///
/// Desktop/native SDKs often return [internal-error] for wrong-password when
/// email enumeration protection is enabled; the real reason may only appear in
/// [message].
String firebaseAuthErrorMessage({required String code, String? message}) {
  final normalizedCode = code.toLowerCase().replaceAll('_', '-');
  final normalizedMessage = (message ?? '').toLowerCase();

  final embedded = _messageFromEmbeddedDetails(normalizedMessage);
  if (embedded != null) return embedded;

  switch (normalizedCode) {
    case 'wrong-password':
    case 'invalid-credential':
    case 'invalid-login-credentials':
      return 'Incorrect email or password.';
    case 'user-not-found':
      return 'No account found for this email.';
    case 'invalid-email':
      return 'Enter a valid email address.';
    case 'user-disabled':
      return 'This account has been disabled.';
    case 'email-already-in-use':
      return 'An account already exists for this email.';
    case 'weak-password':
      return 'Password is too weak. Use at least 6 characters.';
    case 'operation-not-allowed':
      return 'This sign-in method is not enabled.';
    case 'too-many-requests':
      return 'Too many attempts. Wait a moment and try again.';
    case 'network-request-failed':
      return 'Network error. Check your connection and try again.';
    case 'internal-error':
    case 'unknown-error':
    case 'unknown':
      return 'Sign in failed. Check your email and password, then try again.';
    default:
      final trimmed = message?.trim();
      if (trimmed != null &&
          trimmed.isNotEmpty &&
          !_isGenericInternalMessage(trimmed)) {
        return trimmed;
      }
      return 'Sign in failed. Please try again.';
  }
}

String? _messageFromEmbeddedDetails(String message) {
  if (message.isEmpty) return null;

  const invalidCredentialHints = [
    'invalid_login_credentials',
    'invalid-login-credentials',
    'invalid-credential',
    'wrong-password',
    'invalid password',
    'incorrect password',
  ];
  for (final hint in invalidCredentialHints) {
    if (message.contains(hint)) {
      return 'Incorrect email or password.';
    }
  }

  const notFoundHints = [
    'user-not-found',
    'user_not_found',
    'email not found',
  ];
  for (final hint in notFoundHints) {
    if (message.contains(hint)) {
      return 'No account found for this email.';
    }
  }

  const weakPasswordHints = [
    'password-does-not-meet-requirements',
    'weak-password',
    'password must contain',
  ];
  for (final hint in weakPasswordHints) {
    if (message.contains(hint)) {
      return 'Password does not meet the requirements.';
    }
  }

  return null;
}

bool _isGenericInternalMessage(String message) {
  final lower = message.toLowerCase();
  return lower.contains('internal error') ||
      lower.contains('an internal error has occurred');
}

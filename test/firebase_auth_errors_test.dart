import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/core/auth/firebase_auth_errors.dart';

void main() {
  test('maps wrong-password code', () {
    expect(
      firebaseAuthErrorMessage(code: 'wrong-password'),
      'Incorrect email or password.',
    );
  });

  test('maps internal-error with embedded invalid_login_credentials', () {
    expect(
      firebaseAuthErrorMessage(
        code: 'internal-error',
        message:
            'An internal error has occurred. [ invalid_login_credentials ]',
      ),
      'Incorrect email or password.',
    );
  });

  test('maps generic internal-error to friendly sign-in message', () {
    expect(
      firebaseAuthErrorMessage(
        code: 'unknown-error',
        message: 'An internal error has occurred.',
      ),
      'Sign in failed. Check your email and password, then try again.',
    );
  });

  test('maps email-already-in-use', () {
    expect(
      firebaseAuthErrorMessage(code: 'email-already-in-use'),
      'An account already exists for this email.',
    );
  });
}

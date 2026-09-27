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

  group('change password', () {
    test('a wrong current password never mentions an email', () {
      for (final code in [
        'wrong-password',
        'invalid-credential',
        'INVALID_LOGIN_CREDENTIALS',
      ]) {
        expect(
          changePasswordErrorMessage(code: code),
          'Current password is incorrect.',
          reason: code,
        );
      }
    });

    test('maps a wrong password buried in an internal-error message', () {
      expect(
        changePasswordErrorMessage(
          code: 'internal-error',
          message:
              'An internal error has occurred. [ invalid_login_credentials ]',
        ),
        'Current password is incorrect.',
      );
    });

    test('rewords the generic sign-in failures', () {
      for (final code in ['internal-error', 'unknown', 'some-new-code']) {
        expect(
          changePasswordErrorMessage(
            code: code,
            message: 'An internal error has occurred.',
          ),
          'Could not change password. Check your current password, then '
          'try again.',
          reason: code,
        );
      }
    });

    test('keeps messages that already fit', () {
      expect(
        changePasswordErrorMessage(code: 'weak-password'),
        'Password is too weak. Use at least 6 characters.',
      );
      expect(
        changePasswordErrorMessage(code: 'too-many-requests'),
        'Too many attempts. Wait a moment and try again.',
      );
    });
  });
}

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/features/gaia/adapters/claude_code/claude_code_setup.dart';

/// `claude auth status`, as the setup checklist reads it (GAIA_HLD.md §5.1).
void main() {
  test('the recorded shape reads as logged in, with the email', () {
    final status = parseClaudeAuthStatus(
      File(
        'test/fixtures/gaia/claude_code_auth/status.json',
      ).readAsStringSync(),
    );
    expect(status, (loggedIn: true, email: 'someone@example.com'));
  });

  test('logged out', () {
    expect(parseClaudeAuthStatus('{"loggedIn": false}'), (
      loggedIn: false,
      email: null,
    ));
  });

  test('anything else is unknown, never logged in', () {
    expect(parseClaudeAuthStatus('Not logged in'), isNull);
    expect(parseClaudeAuthStatus('{"loggedIn": "yes"}'), isNull);
    expect(parseClaudeAuthStatus('[]'), isNull);
  });
}

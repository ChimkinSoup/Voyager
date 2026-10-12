import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/core/platform/dev_profile.dart';

void main() {
  test('unset or empty is the normal instance', () {
    expect(parseDevProfile(null, debug: true), isNull);
    expect(parseDevProfile('', debug: true), isNull);
  });

  test('accepts lowercase letters and digits, up to 16', () {
    expect(parseDevProfile('b', debug: true), 'b');
    expect(parseDevProfile('qa2', debug: true), 'qa2');
    expect(parseDevProfile('a' * 16, debug: true), 'a' * 16);
  });

  test('refuses anything else, and the reserved name', () {
    for (final raw in ['B', 'a-b', 'a b', 'é', 'a' * 17, 'default']) {
      expect(
        () => parseDevProfile(raw, debug: true),
        throwsStateError,
        reason: raw,
      );
    }
  });

  test('outside a debug build the variable is ignored', () {
    expect(parseDevProfile('b', debug: false), isNull);
    expect(parseDevProfile('NOT VALID', debug: false), isNull);
  });

  test('the suffix names the profile', () {
    addTearDown(() => devProfileForTesting = null);
    devProfileForTesting = null;
    expect(devProfileSuffix, '');
    devProfileForTesting = 'b';
    expect(devProfileSuffix, ' [b]');
  });
}

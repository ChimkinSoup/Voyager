import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/core/constants/google_auth_config.dart';
import 'package:voyager/data/remote/desktop_google_oauth.dart';

void main() {
  test('desktop redirect URI uses configured loopback port', () {
    expect(
      DesktopGoogleOAuth.redirectUri.toString(),
      'http://127.0.0.1:$googleOAuthRedirectPort',
    );
  });

  test('signIn requires configured client id', () async {
    expect(
      DesktopGoogleOAuth().signIn(),
      throwsA(isA<StateError>()),
    );
  });
}

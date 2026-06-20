import 'dart:async';
import 'dart:io';

import 'package:oauth2/oauth2.dart' as oauth2;
import 'package:url_launcher/url_launcher.dart';
import 'package:voyager/core/constants/google_auth_config.dart';

/// Browser-based Google OAuth for desktop (Authorization Code + PKCE).
///
/// Opens the system browser, listens on a loopback redirect URI, then returns
/// tokens for [GoogleAuthProvider.credential] / [FirebaseAuth.signInWithCredential].
class DesktopGoogleOAuth {
  static final Uri _authorizationEndpoint = Uri.parse(
    'https://accounts.google.com/o/oauth2/v2/auth',
  );
  static final Uri _tokenEndpoint = Uri.parse(
    'https://oauth2.googleapis.com/token',
  );

  static Uri get redirectUri =>
      Uri.parse('http://127.0.0.1:$googleOAuthRedirectPort');

  Future<({String accessToken, String? idToken})> signIn({
    Duration timeout = const Duration(minutes: 5),
  }) async {
    if (!isGoogleOAuthConfigured) {
      throw StateError(
        'Google sign-in on desktop requires GOOGLE_OAUTH_CLIENT_ID and '
        'GOOGLE_OAUTH_CLIENT_SECRET from the same OAuth client in Google Cloud Console.',
      );
    }

    if (!isGoogleOAuthClientSecretConfigured) {
      throw StateError(
        'Google sign-in on desktop requires GOOGLE_OAUTH_CLIENT_SECRET. '
        'Copy it from the same Desktop (or Web) OAuth client as your client ID '
        'in Google Cloud Console → Credentials.',
      );
    }

    final secret = googleOAuthClientSecret;

    final grant = oauth2.AuthorizationCodeGrant(
      googleOAuthClientId,
      _authorizationEndpoint,
      _tokenEndpoint,
      secret: secret,
      basicAuth: false,
    );

    final authorizationUrl = grant.getAuthorizationUrl(
      redirectUri,
      scopes: const ['openid', 'email', 'profile'],
    );

    final server = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      googleOAuthRedirectPort,
      shared: true,
    );

    try {
      final launched = await launchUrl(
        authorizationUrl,
        mode: LaunchMode.externalApplication,
      );
      if (!launched) {
        throw StateError('Could not open the browser for Google sign-in.');
      }

      final request = await server.first.timeout(
        timeout,
        onTimeout: () {
          throw TimeoutException('Google sign-in timed out.');
        },
      );

      final responseHtml =
          '<html><body><p>Signed in. You can close this tab and return to Voyager.</p></body></html>';
      request.response
        ..statusCode = HttpStatus.ok
        ..headers.contentType = ContentType.html
        ..write(responseHtml);
      await request.response.close();

      final client = await grant.handleAuthorizationResponse(
        request.uri.queryParameters,
      );

      final accessToken = client.credentials.accessToken;
      if (accessToken.isEmpty) {
        throw StateError('Google sign-in did not return an access token.');
      }

      return (accessToken: accessToken, idToken: client.credentials.idToken);
    } on oauth2.AuthorizationException catch (error) {
      if (error.description?.contains('client_secret') ?? false) {
        throw StateError(
          'Google requires GOOGLE_OAUTH_CLIENT_SECRET for client '
          '$googleOAuthClientIdHint. Copy the secret from the same OAuth client '
          'in Google Cloud Console → Credentials (Desktop clients show one too).',
        );
      }
      throw StateError(error.description ?? error.error);
    } finally {
      await server.close(force: true);
    }
  }
}

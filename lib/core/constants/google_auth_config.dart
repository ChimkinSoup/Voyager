/// Google OAuth client ID from Google Cloud Console (Desktop app recommended).
///
/// Required for Google sign-in on Windows (browser + loopback redirect).
///
/// **Desktop app client:** also set [googleOAuthClientSecret]. Google shows a
/// secret on the Desktop client page and often requires it at token exchange
/// even with PKCE (Google-specific behavior; not a security boundary in
/// shipped desktop builds).
///
/// **Web application client:** same — ID, secret, and redirect URI
/// `http://127.0.0.1:4285` on that Web client.
///
/// Do not copy the ID from Firebase Authentication → Google (that is the Web client).
///
/// Run with:
/// `flutter run --dart-define-from-file=dart_defines.json`
/// or `--dart-define=GOOGLE_OAUTH_CLIENT_ID=... --dart-define=GOOGLE_OAUTH_CLIENT_SECRET=...`
const _googleOAuthClientIdRaw = String.fromEnvironment(
  'GOOGLE_OAUTH_CLIENT_ID',
  defaultValue: '',
);

/// Client secret from the same OAuth client as [googleOAuthClientId].
///
/// Required by Google's token endpoint for most Desktop and Web clients used
/// in this loopback flow. Store in a gitignored `dart_defines.json` or CI
/// secrets at build time — it is compiled into the app and not truly secret.
const _googleOAuthClientSecretRaw = String.fromEnvironment(
  'GOOGLE_OAUTH_CLIENT_SECRET',
  defaultValue: '',
);

/// Trimmed client ID (whitespace in `dart_defines.json` breaks Google OAuth).
String get googleOAuthClientId => _googleOAuthClientIdRaw.trim();

/// Trimmed client secret.
String get googleOAuthClientSecret => _googleOAuthClientSecretRaw.trim();
/// Fixed loopback port for the desktop OAuth redirect handler.
const googleOAuthRedirectPort = 4285;

bool get isGoogleOAuthConfigured => googleOAuthClientId.isNotEmpty;

bool get isGoogleOAuthClientSecretConfigured =>
    googleOAuthClientSecret.isNotEmpty;

/// Desktop browser OAuth is ready when both compile-time credentials are set.
bool get isGoogleOAuthReadyForDesktop =>
    isGoogleOAuthConfigured && isGoogleOAuthClientSecretConfigured;

/// Short suffix of the configured client ID for error messages.
String get googleOAuthClientIdHint {
  if (googleOAuthClientId.isEmpty) return '(not set)';
  final parts = googleOAuthClientId.split('.');
  if (parts.isEmpty) return googleOAuthClientId;
  final id = parts.first;
  if (id.length <= 12) return id;
  return '...${id.substring(id.length - 12)}';
}

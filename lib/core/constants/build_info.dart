/// Build identity, injected by `scripts/build_release.ps1` via --dart-define.
/// A plain `flutter run` leaves these at their defaults, so it reads "dev".
const buildVersion = String.fromEnvironment(
  'BUILD_VERSION',
  defaultValue: 'dev',
);
const buildSha = String.fromEnvironment('BUILD_SHA', defaultValue: 'dev');
const buildDate = String.fromEnvironment('BUILD_DATE');

/// e.g. "0.1.0+1 · 7996b70-dirty · 2026-09-25", or "dev" for an unscripted build.
String get buildLabel => [
  if (buildVersion != 'dev') buildVersion,
  buildSha,
  if (buildDate.isNotEmpty) buildDate,
].join(' · ');

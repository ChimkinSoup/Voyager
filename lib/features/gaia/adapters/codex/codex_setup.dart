// FRAGILE(cli): `codex login status` prints plain text whose wording is not a
// stable API (observed on 0.164.0: "Logged in using ChatGPT"). Only "Logged
// in" and "Not logged in" are read; anything else reads as unknown, never as
// logged in. test/gaia_codex_events_test.dart covers it.

import 'dart:io';

import 'package:voyager/features/gaia/adapters/codex/codex_events.dart';
import 'package:voyager/features/gaia/adapters/codex/codex_runner.dart';
import 'package:voyager/features/gaia/adapters/gaia_agent_runner.dart';

/// Codex on this machine, for the Gaia page's setup checklist (§5.1).
class CodexSetup {
  const CodexSetup({this.version, this.loggedIn, this.sandboxReady});

  /// Null when the CLI isn't installed.
  final GaiaCliVersion? version;

  /// Null when the auth probe didn't run or couldn't be read.
  final bool? loggedIn;

  /// Whether Gaia's Codex home has its Windows sandbox set up, or needs
  /// none; null when not checked.
  final bool? sandboxReady;

  bool get installed => version != null;
  bool get tested =>
      version != null && isVersionInRange(version!, kCodexTestedVersions);
}

bool? parseCodexLoginStatus(String output) {
  if (output.contains('Not logged in')) return false;
  if (output.contains('Logged in')) return true;
  return null;
}

/// Runs `codex --version`, then `codex login status`. Neither costs tokens.
/// The login read is the user's own Codex home, which Gaia copies from.
Future<CodexSetup> probeCodex() async {
  final version = await codexVersion();
  if (version == null) return const CodexSetup();
  try {
    // Through cmd, as the runner: an npm install's `codex` is a .cmd shim.
    final result = await Process.run('cmd', ['/c', 'codex', 'login', 'status']);
    return CodexSetup(
      version: version,
      loggedIn: parseCodexLoginStatus('${result.stdout}\n${result.stderr}'),
      sandboxReady: await codexSandboxReady(
        codexHome: await defaultGaiaCodexHome(),
      ),
    );
  } on ProcessException {
    return CodexSetup(version: version);
  }
}

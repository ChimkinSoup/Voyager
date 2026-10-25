// FRAGILE(cli): `claude auth status` prints JSON whose shape is not a stable
// API (observed on 2.1.310: `{"loggedIn": true, "authMethod": "claude.ai",
// "email": ..., ...}`). Only `loggedIn` and `email` are read; a reply without
// a boolean `loggedIn` reads as unknown, never as logged in.
// test/gaia_claude_code_setup_test.dart parses the recorded fixture.

import 'dart:convert';
import 'dart:io';

import 'package:voyager/features/gaia/adapters/claude_code/claude_code_events.dart';
import 'package:voyager/features/gaia/adapters/claude_code/claude_code_runner.dart';

/// Claude Code on this machine, for the Gaia page's setup checklist
/// (GAIA_HLD.md §5.1).
class ClaudeCodeSetup {
  const ClaudeCodeSetup({this.version, this.loggedIn, this.email});

  /// Null when the CLI isn't installed.
  final (int, int, int)? version;

  /// Null when the auth probe didn't run or couldn't be read.
  final bool? loggedIn;
  final String? email;

  bool get installed => version != null;
  bool get tested => version != null && isTestedClaudeVersion(version!);
}

/// `{loggedIn, email}` from `claude auth status`'s output, or null when it
/// isn't the shape above.
({bool loggedIn, String? email})? parseClaudeAuthStatus(String output) {
  final Object? json;
  try {
    json = jsonDecode(output);
  } on FormatException {
    return null;
  }
  if (json case {'loggedIn': final bool loggedIn}) {
    return (loggedIn: loggedIn, email: json['email'] as String?);
  }
  return null;
}

/// Runs `claude --version`, then `claude auth status` on [configDir]'s
/// account (§6.1). Neither costs tokens.
Future<ClaudeCodeSetup> probeClaudeCode({String configDir = ''}) async {
  final version = await claudeCodeVersion();
  if (version == null) return const ClaudeCodeSetup();
  try {
    // Through cmd, as the runner: an npm install's `claude` is a .cmd shim.
    final result = await Process.run(
      'cmd',
      ['/c', 'claude', 'auth', 'status'],
      environment: claudeEnvironment(configDir),
      includeParentEnvironment: false,
    );
    final status = parseClaudeAuthStatus(result.stdout as String);
    return ClaudeCodeSetup(
      version: version,
      loggedIn: status?.loggedIn,
      email: status?.email,
    );
  } on ProcessException {
    return ClaudeCodeSetup(version: version);
  }
}

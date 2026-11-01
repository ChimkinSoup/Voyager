// FRAGILE(usage): `account/rateLimits/read` on `codex app-server`, and its
// `account/rateLimits/updated` notification during a turn: part of a protocol
// still marked experimental (see codex_app_server.dart), undocumented as a
// usage API. Costs no tokens, and Gaia handles no token: the server makes the
// call on its home's login. Shape last observed 2026-11-01 on codex-cli
// 0.166.0:
//   read -> {rateLimits: <snapshot>, ...}; updated -> {rateLimits: <snapshot>}
//   snapshot: {limitId: "codex", primary, secondary, ...}, each window null or
//     {usedPercent: int, windowDurationMins: int?, resetsAt: unix s?}
//   signed out, a JSON-RPC error: "codex account authentication required to
//     read rate limits"
// Windows are told apart by their duration, not primary and secondary: 300
// min and 10080 min. Any other is a schema failure, as is a missing field or
// wrong type (§6.3). test/gaia_usage_sources_test.dart reads the fixtures.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:voyager/domain/models/gaia_models.dart';
import 'package:voyager/features/gaia/adapters/gaia_agent_runner.dart';
import 'package:voyager/features/gaia/usage/gaia_usage.dart';

const _sessionMinutes = 300;
const _weeklyMinutes = 10080;
const _timeout = Duration(seconds: 30);

/// [snapshot]'s windows, or null when it isn't the shape above.
GaiaUsage? codexUsage(Object? snapshot, DateTime now) {
  if (snapshot is! Map) return null;
  final windows = <GaiaUsageWindow>[];
  for (final raw in [snapshot['primary'], snapshot['secondary']]) {
    if (raw == null) continue;
    if (raw is! Map) return null;
    final percent = raw['usedPercent'];
    final resets = raw['resetsAt'];
    final kind = switch (raw['windowDurationMins']) {
      _sessionMinutes => GaiaUsageKind.session,
      _weeklyMinutes => GaiaUsageKind.weekly,
      _ => null,
    };
    if (percent is! num || kind == null || (resets != null && resets is! int)) {
      return null;
    }
    windows.add(
      GaiaUsageWindow(
        kind: kind,
        used: percent / 100,
        resetsAt: resets is int
            ? DateTime.fromMillisecondsSinceEpoch(resets * 1000)
            : null,
        observedAt: now,
      ),
    );
  }
  return windows.isEmpty ? null : GaiaUsage(windows);
}

/// How a refused read ends, by the JSON-RPC error's [message] (§6.4).
GaiaUsageHealth codexUsageRefused(String message, GaiaRunAuth runs) {
  final text = message.toLowerCase();
  // First: this one's message lists every method the server has.
  if (text.contains('unknown variant') || text.contains('method not found')) {
    return GaiaUsageHealth.endpointChanged;
  }
  if (text.contains('authentication') || text.contains('401')) {
    return runs == GaiaRunAuth.working
        ? GaiaUsageHealth.endpointChanged
        : GaiaUsageHealth.signedOut;
  }
  return GaiaUsageHealth.offline;
}

/// Codex's usage from its app-server (§6.2). [_read] answers
/// `account/rateLimits/read` on an account's server, and throws a
/// [GaiaRunException] when refused or when the server won't start.
class CodexRateLimitsSource implements GaiaUsageSource {
  CodexRateLimitsSource(this._read);

  final Future<Map<String, Object?>> Function(GaiaAccount account) _read;

  @override
  Future<GaiaUsageRead> read({
    required GaiaRunAuth runs,
    required GaiaAccount account,
  }) async {
    final Map<String, Object?> result;
    try {
      result = await _read(account).timeout(_timeout);
    } on GaiaRunException catch (error) {
      final health = codexUsageRefused(error.message, runs);
      if (health == GaiaUsageHealth.endpointChanged) {
        debugPrint('[gaia] Codex usage read refused: ${error.message}');
      }
      return GaiaUsageRead(health);
    } on TimeoutException {
      return const GaiaUsageRead(GaiaUsageHealth.offline);
    }
    final usage = codexUsage(result['rateLimits'], DateTime.now());
    if (usage == null) {
      // Keys and types only.
      debugPrint('[gaia] Codex usage shape changed: ${gaiaJsonShape(result)}');
      return const GaiaUsageRead(GaiaUsageHealth.endpointChanged);
    }
    return GaiaUsageRead(GaiaUsageHealth.ok, usage: usage);
  }
}

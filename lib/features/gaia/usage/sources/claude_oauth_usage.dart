// FRAGILE(usage): `GET api.anthropic.com/api/oauth/usage` is undocumented.
// Authorised by the account's OAuth token in `<config dir>/.credentials.json`
// (`claudeAiOauth.{accessToken, expiresAt}`, expiresAt in ms). Shape last
// observed 2026-11-01, and both shapes below were in that one response:
//   flat: {five_hour, seven_day, seven_day_opus, seven_day_sonnet, ...}, each
//     null or {utilization: percent 0-100, resets_at: ISO 8601 or null}. The
//     per-model ones were null on the Pro accounts seen, so their shape is
//     taken to be seven_day's.
//   newer: {limits: [{kind, group, percent, resets_at, ...}]}, with group
//     "session", and kind "weekly_all" for the weekly window.
// Keys not read here are ignored. Strict otherwise: a missing field or wrong
// type in what's read is `endpointChanged`, never a silent zero (§6.3).
// test/gaia_usage_sources_test.dart reads a fixture of each shape.
//
// Gaia never refreshes the token, since the CLI owns it: an expired one is
// `stale` until the account's next run writes a new one. There is no setting,
// env var or flag to override the URL or headers: a changed endpoint needs a
// Gaia update.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:voyager/domain/models/gaia_models.dart';
import 'package:voyager/features/gaia/adapters/claude_code/claude_code_runner.dart';
import 'package:voyager/features/gaia/usage/gaia_usage.dart';

const _url = 'https://api.anthropic.com/api/oauth/usage';
const _betaHeader = {'anthropic-beta': 'oauth-2025-04-20'};
const _timeout = Duration(seconds: 20);

/// Model names of the flat shape's per-model windows.
const _modelWindows = {'seven_day_opus': 'Opus', 'seven_day_sonnet': 'Sonnet'};

class _Schema implements Exception {}

/// [body]'s windows, or null when it isn't a shape above.
GaiaUsage? claudeOAuthUsage(Object? body, DateTime now) {
  GaiaUsageWindow window(
    Map<Object?, Object?> raw,
    String percentKey,
    GaiaUsageKind kind, {
    String? model,
  }) {
    final percent = raw[percentKey];
    final resets = raw['resets_at'];
    if (percent is! num || (resets != null && resets is! String)) {
      throw _Schema();
    }
    DateTime? resetsAt;
    if (resets is String) {
      resetsAt = DateTime.tryParse(resets)?.toLocal();
      if (resetsAt == null) throw _Schema();
    }
    return GaiaUsageWindow(
      kind: kind,
      used: percent / 100,
      resetsAt: resetsAt,
      observedAt: now,
      model: model,
    );
  }

  GaiaUsageWindow? flat(
    Map<Object?, Object?> body,
    String key,
    GaiaUsageKind kind, {
    String? model,
  }) => switch (body[key]) {
    null => null,
    final Map raw => window(raw, 'utilization', kind, model: model),
    _ => throw _Schema(),
  };

  if (body is! Map) return null;
  try {
    GaiaUsageWindow? session;
    GaiaUsageWindow? weekly;
    if (body['limits'] case final List limits) {
      for (final limit in limits) {
        if (limit is! Map || limit['kind'] is! String) throw _Schema();
        if (limit['group'] == 'session') {
          session = window(limit, 'percent', GaiaUsageKind.session);
        } else if (limit['kind'] == 'weekly_all') {
          weekly = window(limit, 'percent', GaiaUsageKind.weekly);
        }
      }
    } else {
      session = flat(body, 'five_hour', GaiaUsageKind.session);
      weekly = flat(body, 'seven_day', GaiaUsageKind.weekly);
    }
    if (session == null && weekly == null) return null;
    return GaiaUsage([
      ?session,
      ?weekly,
      for (final MapEntry(:key, :value) in _modelWindows.entries)
        ?flat(body, key, GaiaUsageKind.weeklyModel, model: value),
    ]);
  } on _Schema {
    return null;
  }
}

/// How a response from the endpoint ends (§6.4).
GaiaUsageRead claudeUsageRead({
  required int status,
  required String body,
  required GaiaRunAuth runs,
  required DateTime now,
}) {
  GaiaUsageRead changed(Object? shape) {
    // Keys and types only: the token and the values stay out of the log.
    debugPrint(
      '[gaia] Claude usage endpoint changed: HTTP $status, shape: $shape',
    );
    return const GaiaUsageRead(GaiaUsageHealth.endpointChanged);
  }

  if (status == 401 || status == 403) {
    return switch (runs) {
      GaiaRunAuth.working => changed('auth refused while runs work'),
      GaiaRunAuth.failing => const GaiaUsageRead(GaiaUsageHealth.signedOut),
      GaiaRunAuth.unknown => const GaiaUsageRead(GaiaUsageHealth.stale),
    };
  }
  // Too many reads, or the service is down: neither says it changed.
  if (status == 429 || status >= 500) {
    return const GaiaUsageRead(GaiaUsageHealth.offline);
  }
  if (status != 200) return changed('not read');
  final Object? decoded;
  try {
    decoded = jsonDecode(body);
  } on FormatException {
    return changed('not JSON');
  }
  final usage = claudeOAuthUsage(decoded, now);
  if (usage == null) return changed(gaiaJsonShape(decoded));
  return GaiaUsageRead(GaiaUsageHealth.ok, usage: usage);
}

/// Claude's usage from its OAuth endpoint (§6.2).
class ClaudeOAuthUsageSource implements GaiaUsageSource {
  ClaudeOAuthUsageSource({http.Client? client, DateTime Function()? now})
    : _client = client ?? http.Client(),
      _now = now ?? DateTime.now;

  final http.Client _client;
  final DateTime Function() _now;

  @override
  Future<GaiaUsageRead> read({
    required GaiaRunAuth runs,
    required GaiaAccount account,
  }) async {
    final now = _now();
    final Object? credentials;
    try {
      credentials = jsonDecode(
        await File(
          p.join(claudeConfigRoot(account.dir), '.credentials.json'),
        ).readAsString(),
      );
    } on PathNotFoundException {
      // No login here, unless runs work without the file: then it moved.
      return GaiaUsageRead(
        runs == GaiaRunAuth.working
            ? GaiaUsageHealth.endpointChanged
            : GaiaUsageHealth.signedOut,
      );
    } on FileSystemException {
      return const GaiaUsageRead(GaiaUsageHealth.offline);
    } on FormatException {
      // The CLI may be writing it.
      return const GaiaUsageRead(GaiaUsageHealth.offline);
    }
    if (credentials case {
      'claudeAiOauth': {
        'accessToken': final String token,
        'expiresAt': final int expiresAt,
      },
    }) {
      if (expiresAt <= now.millisecondsSinceEpoch) {
        return GaiaUsageRead(
          runs == GaiaRunAuth.failing
              ? GaiaUsageHealth.signedOut
              : GaiaUsageHealth.stale,
        );
      }
      try {
        final response = await _client
            .get(
              Uri.parse(_url),
              headers: {'Authorization': 'Bearer $token', ..._betaHeader},
            )
            .timeout(_timeout);
        return claudeUsageRead(
          status: response.statusCode,
          body: response.body,
          runs: runs,
          now: now,
        );
      } on SocketException {
        return const GaiaUsageRead(GaiaUsageHealth.offline);
      } on http.ClientException {
        return const GaiaUsageRead(GaiaUsageHealth.offline);
      } on TimeoutException {
        return const GaiaUsageRead(GaiaUsageHealth.offline);
      }
    }
    debugPrint(
      '[gaia] Claude credentials changed, shape: ${gaiaJsonShape(credentials)}',
    );
    return const GaiaUsageRead(GaiaUsageHealth.endpointChanged);
  }
}

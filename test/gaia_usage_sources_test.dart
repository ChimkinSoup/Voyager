import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;
import 'package:voyager/domain/models/gaia_models.dart';
import 'package:voyager/features/gaia/adapters/gaia_agent_runner.dart';
import 'package:voyager/features/gaia/usage/gaia_usage.dart';
import 'package:voyager/features/gaia/usage/sources/claude_oauth_usage.dart';
import 'package:voyager/features/gaia/usage/sources/codex_rate_limits.dart';

GaiaAccount account(String dir) => GaiaAccount(
  id: kGaiaDefaultAccountId,
  label: 'Default',
  adapter: kGaiaClaudeCodeAdapter,
  dir: dir,
);

String _fixture(String name) =>
    File('test/fixtures/gaia/usage/$name.json').readAsStringSync();

void main() {
  final now = DateTime(2026, 11, 1, 13);

  group('Claude oauth/usage', () {
    GaiaUsageRead response(
      int status,
      String body, [
      GaiaRunAuth runs = GaiaRunAuth.unknown,
    ]) => claudeUsageRead(status: status, body: body, runs: runs, now: now);

    for (final shape in ['claude_both', 'claude_flat', 'claude_limits']) {
      test('$shape reads as percent fractions', () {
        final read = response(200, _fixture(shape));
        expect(read.health, GaiaUsageHealth.ok);
        final json = jsonDecode(_fixture('claude_both')) as Map;
        final fiveHour = read.usage!.fiveHour!;
        expect(fiveHour.used, (json['five_hour'] as Map)['utilization'] / 100);
        expect(
          read.usage!.weekly!.used,
          (json['seven_day'] as Map)['utilization'] / 100,
        );
        expect(
          fiveHour.resetsAt,
          DateTime.parse(
            (json['five_hour'] as Map)['resets_at'] as String,
          ).toLocal(),
        );
        expect(fiveHour.observedAt, now);
      });
    }

    test('an unknown shape is endpointChanged', () {
      expect(
        response(200, _fixture('claude_unknown')).health,
        GaiaUsageHealth.endpointChanged,
      );
    });

    test('a wrong type is a schema failure, never a silent zero', () {
      for (final body in [
        '{"five_hour":{"utilization":"2","resets_at":null}}',
        '{"five_hour":{"resets_at":null}}',
        '{"five_hour":{"utilization":2,"resets_at":"soon"}}',
        '{"five_hour":{"utilization":2,"resets_at":null},"seven_day_opus":3}',
        '{"limits":[{"kind":"weekly_all","group":"weekly"}]}',
        '[]',
      ]) {
        expect(
          response(200, body).health,
          GaiaUsageHealth.endpointChanged,
          reason: body,
        );
      }
    });

    test('a per-model window is read when present', () {
      final usage = response(
        200,
        '{"five_hour":{"utilization":2,"resets_at":null},'
        '"seven_day_sonnet":{"utilization":40,"resets_at":null}}',
      ).usage!;
      expect(usage.fiveHour!.resetsAt, isNull);
      expect(usage.weeklyModels.single.model, 'Sonnet');
      expect(usage.weeklyModels.single.used, 0.4);
    });

    test('a status is told apart by the account\'s own runs', () {
      expect(response(404, '').health, GaiaUsageHealth.endpointChanged);
      expect(response(410, '').health, GaiaUsageHealth.endpointChanged);
      expect(response(200, '<html>').health, GaiaUsageHealth.endpointChanged);
      expect(response(429, '').health, GaiaUsageHealth.offline);
      expect(response(503, '').health, GaiaUsageHealth.offline);
      for (final status in [401, 403]) {
        expect(
          response(status, '', GaiaRunAuth.working).health,
          GaiaUsageHealth.endpointChanged,
        );
        expect(
          response(status, '', GaiaRunAuth.failing).health,
          GaiaUsageHealth.signedOut,
        );
        expect(response(status, '').health, GaiaUsageHealth.stale);
      }
    });

    group('source', () {
      late Directory dir;
      http.Request? sent;

      setUp(() {
        dir = Directory.systemTemp.createTempSync('gaia_usage');
        sent = null;
      });
      tearDown(() => dir.deleteSync(recursive: true));

      ClaudeOAuthUsageSource source(http.Response Function() reply) =>
          ClaudeOAuthUsageSource(
            now: () => now,
            client: MockClient((request) async {
              sent = request;
              return reply();
            }),
          );

      void credentials(int expiresAt) =>
          File(p.join(dir.path, '.credentials.json')).writeAsStringSync(
            jsonEncode({
              'claudeAiOauth': {'accessToken': 'tok', 'expiresAt': expiresAt},
            }),
          );

      Future<GaiaUsageHealth> health(
        ClaudeOAuthUsageSource source, [
        GaiaRunAuth runs = GaiaRunAuth.unknown,
      ]) async =>
          (await source.read(runs: runs, account: account(dir.path))).health;

      final later = now.add(const Duration(hours: 1)).millisecondsSinceEpoch;
      final earlier = now
          .subtract(const Duration(hours: 1))
          .millisecondsSinceEpoch;

      test('sends the account\'s token', () async {
        credentials(later);
        final read = await source(
          () => http.Response(_fixture('claude_both'), 200),
        ).read(runs: GaiaRunAuth.unknown, account: account(dir.path));
        expect(read.health, GaiaUsageHealth.ok);
        expect(sent!.headers['Authorization'], 'Bearer tok');
        expect(sent!.headers['anthropic-beta'], isNotNull);
      });

      test('an expired token makes no call, and is stale', () async {
        credentials(earlier);
        final claude = source(() => http.Response('', 200));
        expect(await health(claude), GaiaUsageHealth.stale);
        expect(sent, isNull);
        expect(
          await health(claude, GaiaRunAuth.failing),
          GaiaUsageHealth.signedOut,
        );
      });

      test('no credentials file is signed out', () async {
        final claude = source(() => http.Response('', 200));
        expect(await health(claude), GaiaUsageHealth.signedOut);
        expect(
          await health(claude, GaiaRunAuth.working),
          GaiaUsageHealth.endpointChanged,
        );
      });

      test('a credentials file of another shape is endpointChanged', () async {
        File(
          p.join(dir.path, '.credentials.json'),
        ).writeAsStringSync('{"oauth":{"token":"tok"}}');
        expect(
          await health(source(() => http.Response('', 200))),
          GaiaUsageHealth.endpointChanged,
        );
      });

      test('a network error is offline', () async {
        credentials(later);
        expect(
          await health(
            ClaudeOAuthUsageSource(
              now: () => now,
              client: MockClient(
                (_) async => throw http.ClientException('no route'),
              ),
            ),
          ),
          GaiaUsageHealth.offline,
        );
      });
    });
  });

  test('a signed-out account on the default folder names no variable', () {
    expect(
      gaiaUsageMessage(
        kGaiaClaudeCodeAdapter,
        GaiaUsageHealth.signedOut,
        null,
        account: account(''),
      ),
      'Default is signed out. Log in with `claude auth login`.',
    );
    expect(
      gaiaUsageMessage(
        kGaiaClaudeCodeAdapter,
        GaiaUsageHealth.signedOut,
        null,
        account: account(r'C:\b'),
      ),
      contains(r'CLAUDE_CONFIG_DIR set to C:\b'),
    );
  });

  group('Codex account/rateLimits/read', () {
    Future<GaiaUsageRead> read(
      Future<Map<String, Object?>> Function() answer, [
      GaiaRunAuth runs = GaiaRunAuth.unknown,
    ]) => CodexRateLimitsSource(
      (_) => answer(),
    ).read(runs: runs, account: account(''));

    test('the recorded read has both windows, by duration', () async {
      final result = await read(
        () async => (jsonDecode(_fixture('codex_read')) as Map).cast(),
      );
      expect(result.health, GaiaUsageHealth.ok);
      final json = jsonDecode(_fixture('codex_read')) as Map;
      final limits = json['rateLimits'] as Map;
      expect(
        result.usage!.fiveHour!.used,
        (limits['primary'] as Map)['usedPercent'] / 100,
      );
      expect(
        result.usage!.weekly!.resetsAt,
        DateTime.fromMillisecondsSinceEpoch(
          ((limits['secondary'] as Map)['resetsAt'] as int) * 1000,
        ),
      );
    });

    test('a plan whose only window is weekly reads as weekly', () {
      final usage = codexUsage({
        'primary': {
          'usedPercent': 5,
          'windowDurationMins': 10080,
          'resetsAt': null,
        },
        'secondary': null,
      }, now)!;
      expect(usage.fiveHour, isNull);
      expect(usage.weekly!.used, 0.05);
    });

    test('an unknown shape is endpointChanged', () async {
      final result = await read(
        () async => (jsonDecode(_fixture('codex_unknown')) as Map).cast(),
      );
      expect(result.health, GaiaUsageHealth.endpointChanged);
    });

    test('an unknown duration or a wrong type is a schema failure', () {
      for (final primary in [
        {'usedPercent': 5, 'windowDurationMins': 60, 'resetsAt': 1},
        {'usedPercent': 5, 'windowDurationMins': null, 'resetsAt': 1},
        {'usedPercent': '5', 'windowDurationMins': 300, 'resetsAt': 1},
        {'usedPercent': 5, 'windowDurationMins': 300, 'resetsAt': '1'},
      ]) {
        expect(
          codexUsage({'primary': primary}, now),
          isNull,
          reason: '$primary',
        );
      }
    });

    test('a refusal is told apart by its message and the runs', () async {
      const signedOut =
          'codex account authentication required to read rate limits';
      Future<GaiaUsageHealth> refused(
        String message, [
        GaiaRunAuth? runs,
      ]) async => (await read(
        () async => throw GaiaRunException(message),
        runs ?? GaiaRunAuth.unknown,
      )).health;
      expect(await refused(signedOut), GaiaUsageHealth.signedOut);
      expect(
        await refused(signedOut, GaiaRunAuth.working),
        GaiaUsageHealth.endpointChanged,
      );
      expect(
        await refused(
          'Invalid request: unknown variant `account/rateLimits/read`, '
          'expected one of `account/login/start`',
        ),
        GaiaUsageHealth.endpointChanged,
      );
      expect(await refused('app-server unavailable'), GaiaUsageHealth.offline);
    });
  });

  test('a run\'s windows keep the per-model ones a poll read', () {
    final at = DateTime(2026);
    GaiaUsageWindow window(GaiaUsageKind kind, double used) =>
        GaiaUsageWindow(kind: kind, used: used, observedAt: at);
    final merged = GaiaUsage([
      window(GaiaUsageKind.session, 0.1),
      window(GaiaUsageKind.weeklyModel, 0.2),
    ]).updatedBy(GaiaUsage([window(GaiaUsageKind.session, 0.5)]));
    expect(merged.fiveHour!.used, 0.5);
    expect(merged.weeklyModels.single.used, 0.2);
  });

  test('a logged shape holds keys and types, never values', () {
    final shape =
        '${gaiaJsonShape({
          'secret': 'hunter2',
          'n': 42,
          'list': [
            {'token': 'abc'},
          ],
          'none': null,
        })}';
    expect(shape, isNot(contains('hunter2')));
    expect(shape, isNot(contains('42')));
    expect(shape, isNot(contains('abc')));
    expect(shape, contains('secret'));
    expect(shape, contains('String'));
  });

  test('a failed turn says when the login is the problem', () {
    expect(gaiaRunAuthFailed('Not logged in · Please run /login'), isTrue);
    expect(gaiaRunAuthFailed('Failed to authenticate. API Error: 401'), isTrue);
    expect(gaiaRunAuthFailed('Unknown model: gpt-9'), isFalse);
  });

  group('a failed turn as the user reads it (BUG-349)', () {
    const raw =
        'unexpected status 401 Unauthorized: Missing bearer or basic '
        'authentication in header, url: https://api.openai.com/v1/responses';
    const codex = GaiaAccount(
      id: 'two',
      label: 'Codex 2',
      adapter: kGaiaCodexAdapter,
      dir: r'C:\Users\me\.codex-2',
    );

    test(
      "Codex's raw 401 says the account is signed out, and how to log in",
      () {
        final text = gaiaRunErrorText(raw, codex);
        expect(text, contains('Codex 2 is signed out'));
        expect(text, contains('codex login'));
        expect(text, contains(r'CODEX_HOME set to C:\Users\me\.codex-2'));
        expect(text, isNot(contains('401')));
      },
    );

    test("Codex's server saying so says the same", () {
      expect(
        gaiaRunErrorText(
          'Codex refused the thread: codex account authentication required',
          codex,
        ),
        contains('Codex 2 is signed out'),
      );
    });

    test('another service wanting a login keeps its own words', () {
      for (final other in [
        'MCP server tickets: authentication required',
        'Proxy error, see https://proxy.example.com/login',
      ]) {
        expect(gaiaRunErrorText(other, codex), other);
      }
    });

    test('any other failure, or any other adapter, keeps its own words', () {
      expect(
        gaiaRunErrorText('Unknown model: gpt-9', codex),
        'Unknown model: gpt-9',
      );
      const claude = GaiaAccount(
        id: 'one',
        label: 'Claude',
        adapter: kGaiaClaudeCodeAdapter,
        dir: '',
      );
      expect(gaiaRunErrorText(raw, claude), raw);
      expect(gaiaRunErrorText(raw, null), raw);
    });
  });
}

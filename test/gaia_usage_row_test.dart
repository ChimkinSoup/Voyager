import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/domain/models/gaia_models.dart';
import 'package:voyager/features/gaia/adapters/claude_code/claude_code_setup.dart';
import 'package:voyager/features/gaia/adapters/codex/codex_setup.dart';
import 'package:voyager/features/gaia/page/gaia_page.dart';
import 'package:voyager/features/gaia/page/gaia_providers.dart';
import 'package:voyager/features/gaia/usage/gaia_usage.dart';

const _claude = GaiaAccount(
  id: 'b',
  label: 'Beta',
  adapter: kGaiaClaudeCodeAdapter,
  dir: r'C:\b',
);
const _codex = GaiaAccount(
  id: 'c',
  label: 'Gamma',
  adapter: kGaiaCodexAdapter,
  dir: r'C:\c',
);

void main() {
  /// The accounts asked to be read again.
  late List<String> rechecked;
  setUp(() => rechecked = []);

  /// The row for [account], with its usage at [health] and its login check at
  /// [loggedIn].
  Future<void> pump(
    WidgetTester tester,
    GaiaAccount account,
    GaiaUsageHealth health,
    bool? loggedIn,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          gaiaRecheckUsageProvider.overrideWithValue(rechecked.add),
          gaiaUsageProvider.overrideWithValue({
            account.key: GaiaAccountUsage(health: health),
          }),
          gaiaClaudeAccountProvider(
            _claude.dir,
          ).overrideWith((ref) async => ClaudeCodeSetup(loggedIn: loggedIn)),
          gaiaCodexAccountProvider(
            _codex,
          ).overrideWith((ref) async => CodexSetup(loggedIn: loggedIn)),
        ],
        child: MaterialApp(
          home: Scaffold(body: GaiaUsageRow(account: account)),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
  }

  for (final account in [_claude, _codex]) {
    group(account.adapter, () {
      testWidgets('signed out, as the login check says: only it speaks', (
        tester,
      ) async {
        await pump(tester, account, GaiaUsageHealth.signedOut, false);
        expect(find.textContaining('signed out'), findsNothing);
      });

      testWidgets('signed out, though the login check disagrees: it says so', (
        tester,
      ) async {
        await pump(tester, account, GaiaUsageHealth.signedOut, true);
        expect(find.textContaining('signed out'), findsOneWidget);
        expect(rechecked, [account.key]);
      });

      testWidgets('signed out, with no answer from the check: it says so', (
        tester,
      ) async {
        await pump(tester, account, GaiaUsageHealth.signedOut, null);
        expect(find.textContaining('signed out'), findsOneWidget);
        expect(rechecked, isEmpty);
      });

      testWidgets('another health still shows beside a failed login check', (
        tester,
      ) async {
        await pump(tester, account, GaiaUsageHealth.stale, false);
        expect(find.textContaining('Not checked yet'), findsOneWidget);
      });

      testWidgets('a login check agreeing with the read asks for no other', (
        tester,
      ) async {
        await pump(tester, account, GaiaUsageHealth.signedOut, false);
        expect(rechecked, isEmpty);
        await pump(tester, account, GaiaUsageHealth.ok, true);
        expect(rechecked, isEmpty);
      });

      testWidgets('a signed-out read after the login check: read again', (
        tester,
      ) async {
        await pump(tester, account, GaiaUsageHealth.ok, true);
        expect(rechecked, isEmpty);
        await pump(tester, account, GaiaUsageHealth.signedOut, true);
        expect(rechecked, [account.key]);
      });

      testWidgets('Check again, logged back in: the usage is read again', (
        tester,
      ) async {
        await pump(tester, account, GaiaUsageHealth.signedOut, true);
        rechecked.clear();
        final context = tester.element(find.byType(GaiaUsageRow));
        final container = ProviderScope.containerOf(context);
        if (account.adapter == kGaiaCodexAdapter) {
          container.invalidate(gaiaCodexAccountProvider(account));
        } else {
          container.invalidate(gaiaClaudeAccountProvider(account.dir));
        }
        await tester.pump();
        await tester.pump();
        expect(rechecked, [account.key]);
      });
    });
  }
}

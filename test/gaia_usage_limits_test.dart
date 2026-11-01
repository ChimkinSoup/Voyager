import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/features/gaia/usage/gaia_usage.dart';
import 'package:voyager/features/gaia/usage/gaia_usage_limits.dart';

/// The low and exhausted rules (GAIA_HLD.md §6.5).
void main() {
  GaiaUsageWindow window(
    GaiaUsageKind kind,
    double used, {
    Duration resetsIn = const Duration(hours: 3),
    String? model,
  }) => GaiaUsageWindow(
    kind: kind,
    used: used,
    resetsAt: DateTime.now().add(resetsIn),
    observedAt: DateTime.now(),
    model: model,
  );
  const sonnet = 'claude-sonnet-5-5';

  group('low', () {
    test('a session window under its floor, resetting far off', () {
      expect(
        gaiaLowWindow(
          GaiaUsage([window(GaiaUsageKind.session, 0.91)]),
          sonnet,
        )?.kind,
        GaiaUsageKind.session,
      );
    });

    test('not at the floor itself', () {
      expect(
        gaiaLowWindow(GaiaUsage([window(GaiaUsageKind.session, 0.9)]), sonnet),
        isNull,
      );
      expect(
        gaiaLowWindow(GaiaUsage([window(GaiaUsageKind.weekly, 0.95)]), sonnet),
        isNull,
      );
    });

    test('not a session window about to reset', () {
      expect(
        gaiaLowWindow(
          GaiaUsage([
            window(
              GaiaUsageKind.session,
              0.99,
              resetsIn: const Duration(minutes: 30),
            ),
          ]),
          sonnet,
        ),
        isNull,
      );
    });

    test('a weekly window whenever it resets', () {
      expect(
        gaiaLowWindow(
          GaiaUsage([
            window(
              GaiaUsageKind.weekly,
              0.96,
              resetsIn: const Duration(minutes: 5),
            ),
          ]),
          sonnet,
        )?.kind,
        GaiaUsageKind.weekly,
      );
    });

    test('the one with the least left, of several', () {
      expect(
        gaiaLowWindow(
          GaiaUsage([
            window(GaiaUsageKind.session, 0.92),
            window(GaiaUsageKind.weekly, 0.97),
          ]),
          sonnet,
        )?.kind,
        GaiaUsageKind.weekly,
      );
    });

    test('a per-model window only for its own model', () {
      final usage = GaiaUsage([
        window(GaiaUsageKind.weeklyModel, 0.97, model: 'Opus'),
      ]);
      expect(gaiaLowWindow(usage, sonnet), isNull);
      expect(gaiaLowWindow(usage, 'claude-opus-5-5'), isNotNull);
    });
  });

  group('exhausted', () {
    test('a window at 100%, not one that rounds to it', () {
      expect(
        gaiaFullWindows(GaiaUsage([window(GaiaUsageKind.weekly, 1)]), sonnet),
        hasLength(1),
      );
      expect(
        gaiaFullWindows(
          GaiaUsage([window(GaiaUsageKind.weekly, 0.996)]),
          sonnet,
        ),
        isEmpty,
      );
    });

    test('not once it has reset', () {
      expect(
        gaiaFullWindows(
          GaiaUsage([
            window(
              GaiaUsageKind.session,
              1,
              resetsIn: const Duration(minutes: -1),
            ),
          ]),
          sonnet,
        ),
        isEmpty,
      );
    });

    test('a per-model window only for its own model', () {
      final usage = GaiaUsage([
        window(GaiaUsageKind.weeklyModel, 1, model: 'Opus'),
      ]);
      expect(gaiaFullWindows(usage, sonnet), isEmpty);
      expect(gaiaFullWindows(usage, 'claude-opus-5-5'), hasLength(1));
    });
  });

  group('a run stopped by a limit', () {
    // The CLIs' own words, from their binaries (Claude Code 2.1.316, Codex
    // 0.166.0).
    for (final text in [
      "You've hit your session limit · resets 4pm",
      "You've hit your weekly limit · resets Nov 3",
      "You've reached your Fable limit.",
      'Your org is out of usage · add funds',
      "You've hit your usage limit. Upgrade to Pro "
          '(https://chatgpt.com/explore/pro), or try again at 4:10 PM.',
      "You've reached your usage limit. Increase your limits to continue.",
      'Usage limit reached.',
    ]) {
      test('says so: $text', () => expect(gaiaRunLimited(text), isTrue));
    }

    for (final text in [
      'Request rejected (429)',
      'Not logged in · Please run /login',
      'Codex exited (code -1)',
      'API Error: 529 overloaded',
    ]) {
      test('other errors do not: $text', () {
        expect(gaiaRunLimited(text), isFalse);
      });
    }
  });
}

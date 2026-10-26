import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/domain/models/gaia_models.dart';
import 'package:voyager/features/gaia/adapters/gaia_agent_runner.dart';
import 'package:voyager/features/gaia/utility/claude_utility_runner.dart';
import 'package:voyager/features/gaia/utility/gaia_utility.dart';

import 'fakes/gaia_fakes.dart';

/// The utility model (GAIA_HLD.md §5.1): the router, titles and summaries
/// on Haiku through Claude Code.
///
/// The last test runs the real CLI, skipped unless GAIA_CLI_CHECK=1 (as
/// test/gaia_cli_contract_test.dart); GAIA_CLAUDE_CONFIG_DIR picks the
/// account. It makes two tiny Haiku calls.
void main() {
  group('router and titles', () {
    late FakeUtilityRunner runner;

    GaiaUtility utility(
      String Function(String job) answer, {
      Map<String, Object?> settings = const {},
    }) {
      runner = FakeUtilityRunner(answer);
      return GaiaUtility(runner)
        ..apply({...GaiaSettings.initial().toJson(), ...settings});
    }

    test('the router names a tier, with the default rubric', () async {
      final tier = await utility((_) => 'Deep.').route('Prove this theorem');
      expect(tier, GaiaTier.deep);
      expect(runner.jobs.single, contains(kGaiaDefaultRouterRubric));
    });

    test('the model and account come from the settings', () {
      utility(
        (_) => '',
        settings: {'utilityModel': ' ', 'claudeConfigDir': r'C:\c1'},
      );
      expect(runner.model, kGaiaDefaultUtilityModel);
      expect(runner.configDir, r'C:\c1');
    });

    test('auto-route off leaves the router out, and unwarmed', () async {
      final u = utility((_) => 'quick', settings: {'autoRoute': false});
      u.warm();
      expect(await u.route('x'), isNull);
      expect(runner.warmed, 0);
      expect(await u.title('x', 'y'), 'quick');
    });

    test('a failed call is a null, never an error', () async {
      final u = utility((_) => throw GaiaRunException('Not logged in'));
      expect(await u.route('x'), isNull);
      expect(await u.title('x', 'y'), isNull);
      expect(await u.summarize('x'), isNull);
      expect(
        await u.caption((label: 1, path: 'a.jpg', mimeType: 'image/jpeg')),
        isNull,
      );
    });

    test('a caption is asked for with the image', () async {
      const image = (label: 4, path: 'a.jpg', mimeType: 'image/jpeg');
      final u = utility((_) => ' A red arrow points at Save. ');
      expect(await u.caption(image), 'A red arrow points at Save.');
      expect(runner.jobs.single, startsWith('Describe the image'));
      expect(runner.images.single, [image]);
    });

    test('answers', () {
      expect(parseRoute('standard'), GaiaTier.standard);
      expect(parseRoute('**quick**'), GaiaTier.quick);
      expect(parseRoute('I think medium'), isNull);
      expect(cleanTitle('"Fixing the sync bug."\nmore'), 'Fixing the sync bug');
      expect(cleanTitle('# Trip plan'), 'Trip plan');
      expect(cleanTitle('  '), isNull);
    });
  });

  test(
    'FRAGILE(cli): Haiku answers through Claude Code, warm and cold',
    skip: Platform.environment['GAIA_CLI_CHECK'] != '1',
    timeout: const Timeout(Duration(minutes: 2)),
    () async {
      // Kept between runs: the CLI may still be exiting when the test ends.
      final dir = Directory('${Directory.systemTemp.path}/gaia_utility_check');
      final runner = ClaudeUtilityRunner(workingDirectory: dir.path)
        ..configure(
          model: kGaiaDefaultUtilityModel,
          configDir: Platform.environment['GAIA_CLAUDE_CONFIG_DIR'] ?? '',
        );
      final utility = GaiaUtility(runner);

      await runner.warm();
      // Long enough for the CLI to start.
      await Future<void>.delayed(const Duration(seconds: 3));
      final watch = Stopwatch()..start();
      expect(
        await utility.route('What is the capital of France?'),
        GaiaTier.quick,
      );
      // ignore: avoid_print
      print('GAIA-CLI utility warm route: ${watch.elapsedMilliseconds} ms');

      expect(
        await runner.generate(
          'Reply with the word in <input>, in capitals.',
          'gaia',
        ),
        'GAIA',
      );
    },
  );
}

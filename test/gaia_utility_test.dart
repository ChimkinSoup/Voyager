import 'dart:async';
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
/// The last two tests run the real CLI, skipped unless GAIA_CLI_CHECK=1 (as
/// test/gaia_cli_contract_test.dart); GAIA_CLAUDE_CONFIG_DIR picks the
/// account. It makes two tiny Haiku calls.
void main() {
  test("the curator's answer: its JSON array, at most three, wherever it "
      'is', () {
    expect(parseCuratorAnswer('[]'), isEmpty);
    final found = parseCuratorAnswer(
      'Here you go:\n```json\n[{"text": " Likes tea ", "tags": ["food", 3]},'
      ' {"text": ""}, {"text": "b"}, {"text": "c"}, {"text": "d"}]\n```',
    );
    expect(found.map((memory) => memory.text), ['Likes tea', 'b', 'c']);
    expect(found.map((memory) => memory.tags), [
      ['food'],
      <String>[],
      <String>[],
    ]);
    expect(() => parseCuratorAnswer('Nothing.'), throwsFormatException);
  });

  group('memory recall (GAIA_MEMORY_TOPICS_HLD.md §4.3)', () {
    GaiaRecalledMemory memory(String id, [int length = 10]) =>
        (id: id, text: 'x' * length, topic: id == 'a' ? 'CS246' : null);

    test("the answer: its ids in order, unknown and repeated ones dropped, "
        'within the caps', () {
      final candidates = [for (var i = 0; i < 12; i++) memory('$i')];
      expect(parseRecallAnswer('[]', candidates), isEmpty);
      expect(
        parseRecallAnswer(
          'Picked: ["3", "nope", "1", "3", 7]',
          candidates,
        ).map((m) => m.id),
        ['3', '1'],
      );
      expect(
        parseRecallAnswer(
          '[${[for (var i = 0; i < 12; i++) '"$i"'].join(',')}]',
          candidates,
        ),
        hasLength(kGaiaMaxRecalled),
      );
      final long = [memory('a', 3000), memory('b', 2000), memory('c', 900)];
      expect(parseRecallAnswer('["a", "b", "c"]', long).map((m) => m.id), [
        'a',
        'c',
      ]);
      expect(
        () => parseRecallAnswer('None.', candidates),
        throwsFormatException,
      );
    });

    test('sends the message, title and candidates, and logs its usage; a '
        'bad answer is null', () async {
      final runner = FakeUtilityRunner((_) => '["a"]');
      final picks = await GaiaUtility(
        runner,
      ).recall('My assignment', 'CS246 help', [memory('a'), memory('b')]);
      expect(picks!.single.id, 'a');
      expect(runner.inputs.single, contains('Chat: CS246 help'));
      expect(runner.inputs.single, contains('Message:\nMy assignment'));
      expect(runner.inputs.single, contains('a · CS246 · xxxxxxxxxx'));
      expect(runner.inputs.single, contains('b · Unsorted · xxxxxxxxxx'));
      expect(runner.usages.single, 'memory recall');

      final bad = FakeUtilityRunner((_) => 'a, I think');
      expect(await GaiaUtility(bad).recall('x', null, [memory('a')]), isNull);
      expect(bad.inputs.single, isNot(contains('Chat:')));
    });

    test('warming for recall starts one more process', () {
      final runner = FakeUtilityRunner((_) => '');
      GaiaUtility(runner).warm(recall: true);
      expect(runner.warmed, 2);
      final off = FakeUtilityRunner((_) => '');
      (GaiaUtility(off)..autoRoute = false).warm(recall: true);
      expect(off.warmed, 1);
    });

    test("a job's tokens are summed over its models", () {
      expect(
        claudeUtilityTokens({
          'claude-haiku-5-5': {
            'inputTokens': 3000,
            'outputTokens': 20,
            'cacheReadInputTokens': 500,
            'cacheCreationInputTokens': 100,
          },
          'other': {'inputTokens': 1, 'outputTokens': 2},
        }),
        'in 3001, cache read 500, cache write 100, out 22',
      );
      expect(
        claudeUtilityTokens(null),
        'in 0, cache read 0, cache write 0, out 0',
      );
    });
  });

  test('the curator keeps the newest turns of a long transcript', () async {
    final runner = FakeUtilityRunner((_) => '[]');
    await GaiaUtility(
      runner,
    ).curate('first ${'x' * 200000} newest', '', const []);
    expect(runner.inputs.single, contains('newest'));
    expect(runner.inputs.single, isNot(contains('first')));
  });

  group('placement (GAIA_MEMORY_TOPICS_HLD.md §5)', () {
    const topics = [
      (id: 't1', path: 'University'),
      (id: 't2', path: 'University › CS246'),
      (id: 't3', path: 'Pets'),
    ];

    test('the answer: known topics only, at most 3, once each; a new topic '
        'under a known parent or at the root; tags as kept', () {
      final placed = parsePlacementAnswer(
        'Sure: {"topics": ["t2", "nope", "t2", "t1", "t3", 4], '
        '"new": {"name": " Assignments ", "parent": "t2"}, '
        '"tags": ["#Homework", "C++", "a", "b"]}',
        topics,
      );
      expect(placed.topicIds, ['t2', 't1', 't3']);
      expect(placed.suggested, (name: 'Assignments', parentId: 't2'));
      expect(placed.tags, ['homework', 'c++', 'a']);
      expect(
        parsePlacementAnswer(
          '{"topics": [], "new": {"name": "Vet", "parent": "gone"}}',
          topics,
        ).suggested,
        (name: 'Vet', parentId: null),
      );
      final plain = parsePlacementAnswer(
        '{"topics": ["t3"], "new": null}',
        topics,
      );
      expect(plain.topicIds, ['t3']);
      expect(plain.suggested, isNull);
      expect(plain.tags, isEmpty);
      expect(
        () => parsePlacementAnswer('No idea.', topics),
        throwsFormatException,
      );
    });

    test("the job sends the memory and every topic by id and path; a bad "
        'answer gives null', () async {
      final runner = FakeUtilityRunner(
        (_) => '{"topics": ["t3"], "tags": ["shots"]}',
      );
      final placed = await GaiaUtility(
        runner,
      ).place("Biscuit's booster is due in May", topics);
      expect(placed?.topicIds, ['t3']);
      expect(placed?.tags, ['shots']);
      expect(runner.inputs.single, contains("Fact: Biscuit's booster"));
      expect(runner.inputs.single, contains('t2 · University › CS246'));
      expect(
        await GaiaUtility(FakeUtilityRunner((_) => 'no')).place('x', topics),
        isNull,
      );
    });

    test("the curator gets the topics, files each find in those it knows, "
        'and offers a new one', () async {
      final runner = FakeUtilityRunner(
        (_) =>
            '[{"text": "Uses valgrind", "tags": ["c"], "topics": ["t2", '
            '"x"], "new": {"name": "Tools", "parent": "t2"}}]',
      );
      final found = await GaiaUtility(
        runner,
      ).curate('turns', '- Likes tea', topics);
      expect(found!.single.topicIds, ['t2']);
      expect(found.single.suggested, (name: 'Tools', parentId: 't2'));
      expect(found.single.pin, isFalse);
      expect(runner.inputs.single, contains('t3 · Pets'));
      expect(runner.inputs.single, contains('- Likes tea'));
    });

    test('the curator flags a fact about the user in general as a pin '
        '(§3.3)', () {
      final found = parseCuratorAnswer(
        '[{"text": "I\'m a CS student at Waterloo", "pin": true}, '
        '{"text": "Uses valgrind", "pin": "yes"}]',
      );
      expect([for (final memory in found) memory.pin], [true, false]);
    });

    test("Sort these' answer (§6): facts by number, known topics only; out "
        'of range, repeated, or placing nothing is dropped', () {
      const memories = [
        (id: 'm1', text: 'Assignments use C++'),
        (id: 'm2', text: "Biscuit's booster is in May"),
        (id: 'm3', text: 'Likes tea'),
      ];
      final sorted = parseSortAnswer(
        'Here: [{"n": 1, "topics": ["t2", "nope"], "tags": ["homework"]}, '
        '{"n": "2", "topics": [], "new": {"name": "Vet", "parent": "t3"}}, '
        '{"n": 3, "topics": ["nope"]}, {"n": 1, "topics": ["t1"]}, '
        '{"n": 9, "topics": ["t1"]}]',
        memories,
        topics,
      );
      expect(sorted.keys, ['m1', 'm2']);
      expect(sorted['m1']!.topicIds, ['t2']);
      expect(sorted['m1']!.tags, ['homework']);
      expect(sorted['m2']!.suggested, (name: 'Vet', parentId: 't3'));
      expect(
        () => parseSortAnswer('No.', memories, topics),
        throwsFormatException,
      );
    });

    test('the Sort these job numbers the facts and lists the topics; a bad '
        'answer gives null', () async {
      final runner = FakeUtilityRunner((_) => '[{"n": 2, "topics": ["t3"]}]');
      final sorted = await GaiaUtility(runner).placeMany([
        (id: 'm1', text: 'Likes\n tea'),
        (id: 'm2', text: 'Biscuit is a beagle'),
      ], topics);
      expect(sorted!.keys, ['m2']);
      expect(runner.inputs.single, contains('1. Likes tea\n2. Biscuit'));
      expect(runner.inputs.single, contains('t3 · Pets'));
      expect(
        await GaiaUtility(
          FakeUtilityRunner((_) => 'no'),
        ).placeMany([(id: 'm1', text: 'x')], topics),
        isNull,
      );
    });
  });

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

    test('a default tier is the router pick when unsure', () async {
      await utility((_) => 'quick').route('x');
      expect(runner.jobs.single, isNot(contains('If unsure')));
      await utility(
        (_) => 'quick',
        settings: {'defaultTier': 'quick'},
      ).route('x');
      expect(runner.jobs.single, contains('If unsure, choose quick.'));
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
          timeout: const Duration(seconds: 30),
        ),
        'GAIA',
      );
    },
  );

  test(
    'FRAGILE(cli): a utility job past its timeout has its process killed',
    skip: Platform.environment['GAIA_CLI_CHECK'] != '1',
    timeout: const Timeout(Duration(minutes: 1)),
    () async {
      final dir = Directory('${Directory.systemTemp.path}/gaia_utility_kill');
      final runner = ClaudeUtilityRunner(workingDirectory: dir.path)
        ..configure(
          model: kGaiaDefaultUtilityModel,
          configDir: Platform.environment['GAIA_CLAUDE_CONFIG_DIR'] ?? '',
        );
      await expectLater(
        runner.generate(
          // Long enough to run well past the check below.
          'Write 300 numbered lines, each a different sentence of 25 words.',
          '',
          timeout: const Duration(seconds: 4),
        ),
        throwsA(isA<TimeoutException>()),
      );
      await Future<void>.delayed(const Duration(seconds: 1));
      final left = await Process.run('powershell', [
        '-NoProfile',
        '-Command',
        "(Get-CimInstance Win32_Process | Where-Object { \$_.CommandLine -like '*gaia_utility_kill*' -and \$_.Name -ne 'powershell.exe' }).Count",
      ]);
      expect(left.stdout.toString().trim(), '0');
    },
  );
}

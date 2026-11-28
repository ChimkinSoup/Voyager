import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/domain/models/gaia_models.dart';
import 'package:voyager/features/gaia/companion/gaia_chat_tools.dart';
import 'package:voyager/features/gaia/companion/gaia_commands.dart';
import 'package:voyager/features/gaia/companion/gaia_routine_runner.dart';
import 'package:voyager/features/gaia/companion/gaia_routines.dart';
import 'package:voyager/features/gaia/host/gaia_window_context.dart'
    show gaiaAddressUrl;
import 'package:voyager/features/gaia/tools/gaia_mcp.dart';
import 'package:voyager/features/gaia/usage/gaia_tokens.dart';

GaiaRoutine _routine({
  GaiaRoutineSubmit submit = GaiaRoutineSubmit.auto,
  int budgetCalls = 80,
  int budgetMinutes = 15,
  int tokenCap = 1000000,
}) => GaiaRoutine(
  id: 'r1',
  createdAt: DateTime.utc(2026, 11, 26),
  updatedAt: DateTime.utc(2026, 11, 26),
  name: 'Job applier',
  instructions: 'Apply.',
  projectId: 'p1',
  skipRules: '- needs sponsorship',
  submit: submit,
  budgetCalls: budgetCalls,
  budgetMinutes: budgetMinutes,
  tokenCap: tokenCap,
);

GaiaRoutineGate _gate({
  GaiaRoutine? routine,
  GaiaRunMode mode = GaiaRunMode.unattended,
  String? address = 'https://boards.greenhouse.io/acme/jobs/1',
  List<String>? stops,
  DateTime Function()? clock,
}) => GaiaRoutineGate(
  routine: routine ?? _routine(),
  mode: mode,
  itemUrl: 'https://boards.greenhouse.io/acme/jobs/1',
  uploadPaths: [r'C:\jobs\resume.pdf'],
  isDuplicate: (_) => false,
  focused: () async => address,
  stopTurn: (why) => stops?.add(why),
  clock: clock,
);

const _ok = GaiaToolResult(text: 'Sent the step.', isError: false);

const _fields = [
  {'label': 'Name', 'value': 'Alex', 'source': 'profile'},
  {'label': 'Email', 'value': 'a@x.io', 'source': 'profile'},
];

void main() {
  group('links (§7.3)', () {
    test('URLs come out of pasted text, each once, without trailing marks', () {
      expect(
        gaiaRoutineUrls(
          'Apply: https://jobs.lever.co/a/1, and\nhttps://jobs.lever.co/a/1 '
          '(https://x.io/b).',
        ),
        ['https://jobs.lever.co/a/1', 'https://x.io/b'],
      );
    });

    test('normalizing drops case, fragment, tracking and the trailing '
        'slash', () {
      expect(
        gaiaNormalizeUrl(
          'https://Boards.Greenhouse.io/acme/jobs/1/'
          '?gh_src=x&utm_source=li&id=3#apply',
        ),
        'https://boards.greenhouse.io/acme/jobs/1?id=3',
      );
    });

    test('duplicates of the list and of submitted items are found', () {
      final now = DateTime.utc(2026, 11, 26);
      final earlier = GaiaRoutineRun(
        id: 'old',
        createdAt: now,
        updatedAt: now,
        routineId: 'r1',
        deviceId: 'd',
        startedAt: now,
        items: const [
          GaiaRunItem(
            url: 'https://a.io/x/',
            status: GaiaRunItemStatus.submitted,
          ),
          GaiaRunItem(url: 'https://a.io/y', status: GaiaRunItemStatus.ready),
        ],
      );
      expect(
        gaiaDuplicateUrls(
          [
            'https://a.io/x',
            'https://a.io/y',
            'https://b.io/z',
            'https://B.io/z#top',
          ],
          [earlier],
        ),
        {0, 3},
      );
    });
  });

  group('the submit gate (§8.6)', () {
    test('submit words match buttons that send, not ones that open or go '
        'on', () {
      for (final name in [
        'Submit',
        'Submit application',
        'Send application',
        'Finish',
        'Envoyer',
      ]) {
        expect(gaiaIsSubmitWord(name), isTrue, reason: name);
      }
      for (final name in ['Apply', 'Apply Manually', 'Save and Continue']) {
        expect(gaiaIsSubmitWord(name), isFalse, reason: name);
      }
    });

    test('each refusal reason', () {
      final auto = _routine();
      expect(
        gaiaSubmitRefusal(
          routine: _routine(submit: GaiaRoutineSubmit.review),
          fields: _fields,
          duplicate: false,
        ),
        contains('stops at Submit'),
      );
      expect(
        gaiaSubmitRefusal(routine: auto, fields: const [], duplicate: false),
        contains('Pass every field'),
      );
      expect(
        gaiaSubmitRefusal(
          routine: auto,
          fields: [
            ..._fields,
            {'label': 'Start date', 'source': 'answers', 'uncertain': true},
          ],
          duplicate: false,
        ),
        contains('uncertain: Start date'),
      );
      expect(
        gaiaSubmitRefusal(
          routine: auto,
          fields: [
            {'label': 'Visa', 'value': 'No', 'source': 'guess'},
          ],
          duplicate: false,
        ),
        contains('no source: Visa'),
      );
      expect(
        gaiaSubmitRefusal(routine: auto, fields: _fields, duplicate: true),
        contains('already submitted'),
      );
      expect(
        gaiaSubmitRefusal(routine: auto, fields: _fields, duplicate: false),
        isNull,
      );
    });
  });

  group('the item gate', () {
    test('before report_posting, control steps are refused; reads, scrolls, '
        'tabs and "Show more" are not', () async {
      final gate = _gate();
      expect(await gate.refuse('os_read_screen', const {}), isNull);
      expect(
        await gate.refuse('os_scroll', const {'direction': 'down'}),
        isNull,
      );
      expect(
        await gate.refuse('os_open', const {'target': 'https://x.io'}),
        isNull,
      );
      expect(
        await gate.refuse('os_click', const {
          'name': 'Job Description',
          'type': 'TabItem',
        }),
        isNull,
      );
      expect(
        await gate.refuse('os_click', const {'name': 'Show more'}),
        isNull,
      );
      for (final (tool, arguments) in <(String, Map<String, Object?>)>[
        ('os_click', {'name': 'Apply'}),
        ('os_type', {'name': 'First name', 'text': 'Alex'}),
        ('os_key', {'keys': 'Tab'}),
        ('os_pick', {'name': 'Country', 'option': 'Canada'}),
        (
          'os_steps',
          {
            'steps': [
              {'action': 'scroll', 'direction': 'down'},
              {'action': 'click', 'name': 'Apply'},
            ],
          },
        ),
      ]) {
        final refusal = await gate.refuse(tool, arguments);
        expect(refusal?.text, contains('report_posting first'), reason: tool);
      }
      await gate.call('report_posting', {
        'company': 'Acme',
        'role': 'Intern',
        'fit': 'go',
      });
      expect(await gate.refuse('os_click', const {'name': 'Apply'}), isNull);
    });

    test('a skip ends the item as skipped and refuses what follows', () async {
      final gate = _gate();
      final result = await gate.call('report_posting', {
        'company': 'Acme',
        'role': 'Intern',
        'fit': 'skip',
        'reason': 'We do not sponsor visas',
      });
      expect(result.text, contains('skipped'));
      expect(gate.result, (
        status: GaiaRunItemStatus.skipped,
        reason: 'We do not sponsor visas',
      ));
      expect(
        (await gate.refuse('os_click', const {'name': 'Apply'}))?.text,
        contains('finished'),
      );
      // But it may close its tab (§8.1).
      expect(await gate.refuse('os_key', const {'keys': 'Ctrl+W'}), isNull);
    });

    test('a submit button is refused until the check passes', () async {
      final gate = _gate();
      await gate.call('report_posting', {
        'company': 'Acme',
        'role': 'Intern',
        'fit': 'go',
      });
      expect(
        (await gate.refuse('os_click', const {
          'name': 'Submit application',
        }))?.text,
        contains('routine_submit_check'),
      );
      expect(
        await gate.refuse('os_click', const {'name': 'Apply Manually'}),
        isNull,
      );
      expect(
        await gate.refuse('os_click', const {'name': 'Save and Continue'}),
        isNull,
      );
      final check = await gate.call('routine_submit_check', {
        'fields': _fields,
      });
      expect(check.text, startsWith('Allowed'));
      expect(
        await gate.refuse('os_click', const {'name': 'Submit application'}),
        isNull,
      );
    });

    test('a click at a point is refused on a page until the check passes, '
        'allowed in a native dialog', () async {
      final page = _gate();
      await page.call('report_posting', {
        'company': 'A',
        'role': 'R',
        'fit': 'go',
      });
      const point = {'x': 905, 'y': 705};
      expect((await page.refuse('os_click', point))?.text, contains('Name'));
      expect(
        (await page.refuse('os_steps', const {
          'steps': [
            {'action': 'click', 'x': 905, 'y': 705},
          ],
        }))?.isError,
        isTrue,
      );
      expect(await page.refuse('os_click', const {'name': 'Yes'}), isNull);
      await page.call('routine_submit_check', {'fields': _fields});
      expect(await page.refuse('os_click', point), isNull);
      final dialog = _gate(address: null);
      await dialog.call('report_posting', {
        'company': 'A',
        'role': 'R',
        'fit': 'go',
      });
      expect(await dialog.refuse('os_click', point), isNull);
    });

    test('Enter is refused on a page, allowed in a native dialog', () async {
      final page = _gate();
      await page.call('report_posting', {
        'company': 'A',
        'role': 'R',
        'fit': 'go',
      });
      expect(
        (await page.refuse('os_key', const {'keys': 'Enter'}))?.text,
        contains('Enter'),
      );
      expect(
        (await page.refuse('os_steps', const {
          'steps': [
            {'action': 'key', 'keys': 'Return'},
          ],
        }))?.text,
        contains('Enter'),
      );
      expect(
        (await page.refuse('os_type', const {'text': 'one\ntwo'}))?.text,
        contains('Enter'),
      );
      expect(await page.refuse('os_key', const {'keys': 'Ctrl+A'}), isNull);
      // Typed, a short text's line break is an Enter; pasted, a long one's
      // isn't.
      expect(
        (await page.refuse('os_type', const {
          'name': 'Phone',
          'text': '5551234\n',
        }))?.text,
        contains('Enter'),
      );
      expect(
        await page.refuse('os_type', {
          'name': 'Cover letter',
          'text': 'one\n${'x' * kGaiaPasteFrom}',
        }),
        isNull,
      );
      final dialog = _gate(address: null);
      await dialog.call('report_posting', {
        'company': 'A',
        'role': 'R',
        'fit': 'go',
      });
      expect(await dialog.refuse('os_key', const {'keys': 'Enter'}), isNull);
    });

    test('ask_user is refused unattended, and non-os tools always', () async {
      expect(
        (await _gate().refuse('ask_user', const {'question': 'Salary?'}))?.text,
        contains('needs_you'),
      );
      expect(
        await _gate(mode: GaiaRunMode.attended).refuse('ask_user', const {}),
        isNull,
      );
      expect((await _gate().refuse('propose_todo', const {}))?.isError, isTrue);
      expect(
        (await _gate().refuse('memory_search', const {}))?.isError,
        isTrue,
      );
    });

    test('submitted without the gate becomes ready; no outcome is '
        'failed', () async {
      final gate = _gate();
      expect(gate.result, (
        status: GaiaRunItemStatus.failed,
        reason: 'ended without reporting',
      ));
      await gate.call('report_posting', {
        'company': 'A',
        'role': 'R',
        'fit': 'go',
      });
      await gate.call('report_outcome', {'status': 'submitted'});
      expect(gate.result, (
        status: GaiaRunItemStatus.ready,
        reason: 'reported submitted without the gate',
      ));
    });

    test('a reason is needed unless submitted', () async {
      final gate = _gate();
      final result = await gate.call('report_outcome', {'status': 'needs_you'});
      expect(result.isError, isTrue);
      expect(gate.outcome, isNull);
    });

    test('the call budget parks the item', () async {
      final stops = <String>[];
      final gate = _gate(routine: _routine(budgetCalls: 3), stops: stops);
      for (var i = 0; i < 3; i++) {
        await gate.ran('os_read_screen', const {}, _ok);
      }
      expect(gate.result, (
        status: GaiaRunItemStatus.needsYou,
        reason: 'ran over budget (3 calls)',
      ));
      expect(stops, ['ran over budget (3 calls)']);
    });

    test('the time budget parks the item', () {
      var now = DateTime(2026, 11, 26, 9);
      final gate = _gate(
        routine: _routine(budgetMinutes: 15),
        clock: () => now,
      );
      gate.checkTime();
      expect(gate.finished, isFalse);
      now = now.add(const Duration(minutes: 15));
      gate.checkTime();
      expect(gate.result.reason, 'ran over budget (15 minutes)');
    });

    test('the context ceiling parks the item', () {
      final gate = _gate();
      gate.context(399999);
      expect(gate.finished, isFalse);
      gate.context(400000);
      expect(gate.result.reason, 'context too large (400k)');
    });

    test('leaving the allowed sites parks the item', () async {
      final gate = _gate(address: 'https://evil.example/paste');
      await gate.call('report_posting', {
        'company': 'A',
        'role': 'R',
        'fit': 'go',
      });
      await gate.ran('os_click', const {'name': 'Apply'}, _ok);
      expect(gate.result.reason, 'left the allowed sites (evil.example)');
      final fine = _gate();
      expect(
        fine.allowed('https://job-boards.greenhouse.io/acme/apply'),
        isTrue,
      );
      expect(fine.allowed('https://accounts.google.com/signin'), isTrue);
      expect(fine.allowed('https://acme.wd1.myworkdayjobs.com/x'), isTrue);
      expect(fine.allowed('https://evil.example/'), isFalse);
      final uk = GaiaRoutineGate(
        routine: _routine(),
        mode: GaiaRunMode.unattended,
        itemUrl: 'https://jobs.acme.co.uk/1',
        uploadPaths: const [],
        isDuplicate: (_) => false,
        focused: () async => null,
        stopTurn: (_) {},
      );
      expect(uk.allowed('https://careers.acme.co.uk/apply'), isTrue);
      expect(uk.allowed('https://evil.co.uk/'), isFalse);
    });

    test('an item chat replaces a named field unless told to append', () {
      expect(gaiaItemArguments('os_type', const {'name': 'A', 'text': 'x'}), {
        'name': 'A',
        'text': 'x',
        'append': false,
      });
      expect(gaiaItemArguments('os_type', const {'text': 'x'}), {'text': 'x'});
      expect(
        gaiaItemArguments('os_type', const {
          'name': 'A',
          'text': 'x',
          'append': true,
        })['append'],
        isTrue,
      );
      expect(
        gaiaItemArguments('os_steps', const {
          'steps': [
            {'action': 'type', 'name': 'A', 'text': 'x'},
            {'action': 'click', 'name': 'B'},
          ],
        }),
        {
          'steps': [
            {'action': 'type', 'name': 'A', 'text': 'x', 'append': false},
            {'action': 'click', 'name': 'B'},
          ],
        },
      );
    });

    test('only an upload file can be uploaded', () async {
      final gate = _gate(address: null);
      await gate.call('report_posting', {
        'company': 'A',
        'role': 'R',
        'fit': 'go',
      });
      expect(
        await gate.refuse('os_upload', const {'path': 'C:/jobs/Resume.pdf'}),
        isNull,
      );
      expect(
        (await gate.refuse('os_upload', const {
          'path': r'C:\Users\a\.ssh\id_rsa',
        }))?.isError,
        isTrue,
      );
      expect(
        (await gate.refuse('os_steps', const {
          'steps': [
            {'action': 'upload', 'path': r'C:\jobs\answers.md'},
          ],
        }))?.isError,
        isTrue,
      );
    });

    test('the plan line cuts the budget and tells every result', () async {
      final gate = _gate();
      await gate.ran('os_read_screen', const {}, _ok);
      gate.wrapUp('95%');
      expect(gate.callLimit, 1 + kGaiaWrapCalls);
      final told = await gate.ran('os_read_screen', const {}, _ok);
      expect(told.text, contains('Plan usage is at 95%'));
    });

    test('Read is allowed only on an upload; the shell never', () {
      final gate = _gate();
      expect(gate.permits('Read', {'file_path': 'C:/jobs/resume.pdf'}), isTrue);
      expect(
        gate.permits('Read', {'file_path': r'C:\jobs\secrets.txt'}),
        isFalse,
      );
      expect(gate.permits('Bash', {'command': 'sleep 4'}), isFalse);
      expect(
        gate.permits('Edit', {'file_path': r'C:\jobs\resume.pdf'}),
        isFalse,
      );
    });
  });

  test('/routine takes the routine\'s name', () {
    expect(gaiaRoutineText('/routine Job applier'), 'Job applier');
    expect(gaiaRoutineText('/routine'), isNull);
    expect(gaiaBuiltinIn('/routine'), GaiaBuiltin.routine);
  });

  group('an item chat\'s tools', () {
    var planned = 0;
    GaiaChatTools tools({GaiaRoutineGate? routine}) => GaiaChatTools(
      chatId: 'c1',
      cards: GaiaCards(),
      onCard: (_) {},
      read: (_, _) async => '',
      screen: (_, _) async => _ok,
      proposals: (
        prepare: (_, _, _) => throw UnimplementedError(),
        commit: (_, _, _) => throw UnimplementedError(),
        drop: (_) {},
      ),
      control: (
        plan: (_, _, _) async {
          planned++;
          return {'auto': true, 'steps': const []};
        },
        run: (_, {required once}) async => {'ran': 0, 'steps': const []},
        drop: (_) {},
      ),
      aborted: () => false,
      isAuto: () async => true,
      routine: routine,
    );

    setUp(() => planned = 0);

    test('go through the gate, which refuses before anything runs', () async {
      final result = await tools(
        routine: _gate(),
      ).call('os_click', const {'name': 'Apply'});
      expect(result.text, contains('report_posting first'));
      expect(planned, 0);
    });

    test('outside an item chat, the routine tools are refused', () async {
      final result = await tools().call('report_posting', const {'fit': 'go'});
      expect(result.isError, isTrue);
      expect(result.text, contains("only for a routine's item chats"));
    });

    test("the CLI's shell is refused in an item chat, even in Auto", () async {
      final item = tools(routine: _gate());
      final shell = await item.permit(
        tool: 'Bash',
        input: const {'command': 'sleep 4'},
        description: '',
      );
      expect(shell.allow, isFalse);
      final own = await item.permit(
        tool: 'mcp__gaia__os_click',
        input: const {},
        description: '',
      );
      expect(own.allow, isTrue);
      final elsewhere = await tools().permit(
        tool: 'Bash',
        input: const {'command': 'ls'},
        description: '',
      );
      expect(elsewhere.allow, isTrue);
    });
  });

  test('the item prompt inlines the materials, uploads and notes (§8.2)', () {
    final prompt = gaiaItemPrompt(
      routine: _routine(),
      item: const GaiaRunItem(url: 'https://a.io/1', notes: 'Start: May 4'),
      index: 6,
      count: 20,
      materials: {'profile.md': 'Name: Alex', 'answers.md': 'Salary: 30/h'},
      uploads: {'resume.pdf': r'C:\jobs\resume.pdf'},
      mode: GaiaRunMode.unattended,
    );
    expect(prompt, contains('item="7 of 20"'));
    expect(prompt, contains('<file name="profile.md">\nName: Alex\n</file>'));
    expect(prompt, contains(r'resume.pdf: C:\jobs\resume.pdf'));
    expect(prompt, contains('<notes>Start: May 4</notes>'));
    expect(prompt, contains('<skip_rules>- needs sponsorship</skip_rules>'));
    expect(prompt, contains('Nobody is watching'));
    // An account page is filled but for its password (§9.1).
    expect(prompt, contains('fill every other field'));
  });

  test('a run and a routine survive JSON', () {
    final routine = _routine();
    expect(GaiaRoutine.fromJson(routine.toJson()).toJson(), routine.toJson());
    final now = DateTime.utc(2026, 11, 26);
    final run = GaiaRoutineRun(
      id: 'run',
      createdAt: now,
      updatedAt: now,
      routineId: 'r1',
      deviceId: 'd',
      startedAt: now,
      items: const [
        GaiaRunItem(
          url: 'https://a.io',
          status: GaiaRunItemStatus.needsYou,
          reason: 'Salary?',
          outcome: {'status': 'needs_you'},
        ),
      ],
      usage: const GaiaRunUsage(
        input: 1,
        output: 2,
        cacheRead: 3,
        cacheWrite: 4,
        planStart: {
          'claude_code': {'5-hour': 0.12},
        },
      ),
    );
    expect(GaiaRoutineRun.fromJson(run.toJson()).toJson(), run.toJson());
  });

  test('a running run read at start-up is paused, its item needing you', () {
    final now = DateTime.utc(2026, 11, 26);
    final restarted = gaiaRestartedRun(
      GaiaRoutineRun(
        id: 'run',
        createdAt: now,
        updatedAt: now,
        routineId: 'r1',
        deviceId: 'd',
        startedAt: now,
        items: const [
          GaiaRunItem(url: 'https://a.io/1', status: GaiaRunItemStatus.ready),
          GaiaRunItem(url: 'https://a.io/2', status: GaiaRunItemStatus.running),
          GaiaRunItem(url: 'https://a.io/3'),
        ],
      ),
    );
    expect(restarted.state, GaiaRunState.paused);
    expect(restarted.stopReason, 'Gaia restarted');
    expect(
      [for (final item in restarted.items) item.status],
      [
        GaiaRunItemStatus.ready,
        GaiaRunItemStatus.needsYou,
        GaiaRunItemStatus.waiting,
      ],
    );
  });

  group('the runner (§8)', () {
    late List<GaiaRoutineRun> saved;
    late List<String> stopped;
    var plan = const <String, List<GaiaPlanWindow>>{};

    GaiaRoutineRunner runner(
      Future<GaiaMessageStatus?> Function(
        GaiaItemTurn turn,
        GaiaRoutineRunner runner,
      )
      agent, {
      DateTime Function()? clock,
      Duration Function()? idle,
      Duration tick = const Duration(seconds: 15),
    }) {
      late GaiaRoutineRunner made;
      return made = GaiaRoutineRunner(
        save: (run) async => saved.add(run),
        sendItem: (turn) => agent(turn, made),
        stopItem: (chatId, why) async => stopped.add(why),
        focused: (_) async => 'https://boards.greenhouse.io/acme/jobs/1',
        materials: (_) async => (
          files: {'profile.md': 'Name: Alex'},
          uploads: {'resume.pdf': r'C:\jobs\resume.pdf'},
        ),
        planUsage: (_) async => plan,
        submitted: () => gaiaSubmittedUrls(saved.isEmpty ? [] : [saved.last]),
        idle: idle ?? () => Duration.zero,
        gap: Duration.zero,
        tick: tick,
        clock: clock,
      );
    }

    GaiaRoutineRun newRun(
      int count, {
      GaiaRunMode mode = GaiaRunMode.unattended,
    }) {
      final now = DateTime.utc(2026, 11, 26);
      return GaiaRoutineRun(
        id: 'run',
        createdAt: now,
        updatedAt: now,
        routineId: 'r1',
        deviceId: 'd',
        mode: mode,
        startedAt: now,
        items: [
          for (var i = 0; i < count; i++)
            GaiaRunItem(url: 'https://boards.greenhouse.io/acme/jobs/$i'),
        ],
      );
    }

    Future<GaiaRoutineRun> settled(GaiaRoutineRunner runner) async {
      for (
        var i = 0;
        i < 500 && saved.last.state == GaiaRunState.running;
        i++
      ) {
        await Future<void>.delayed(Duration.zero);
      }
      return saved.last;
    }

    setUp(() {
      saved = [];
      stopped = [];
      plan = const {};
    });

    test('five fixture forms end as they should, and none submits past the '
        'gate', () async {
      final clicked = <String>[];
      Future<void> act(
        GaiaRoutineGate gate,
        String tool,
        Map<String, Object?> arguments,
      ) async {
        final refusal = await gate.refuse(tool, arguments);
        if (refusal == null && tool == 'os_click') {
          clicked.add('${arguments['name']}');
        }
        await gate.ran(tool, arguments, refusal ?? _ok);
      }

      final made = runner((turn, _) async {
        final gate = turn.gate;
        final n = int.parse(turn.item.url.split('/').last);
        await act(gate, 'os_open', {'target': turn.item.url});
        switch (n) {
          case 0: // A posting a skip rule matches.
            await gate.call('report_posting', {
              'company': 'Acme',
              'role': 'Intern',
              'fit': 'skip',
              'reason': 'Must be a US citizen',
            });
          case 1: // A one-page form, sure of every field.
            await gate.call('report_posting', {
              'company': 'Lucid',
              'role': 'Intern',
              'fit': 'go',
            });
            await act(gate, 'os_type', {'name': 'First name', 'text': 'Alex'});
            await gate.call('routine_submit_check', {'fields': _fields});
            await act(gate, 'os_click', {'name': 'Submit application'});
            await gate.call('report_outcome', {
              'status': 'submitted',
              'company': 'Lucid',
              'role': 'Intern',
            });
          case 2: // Unsure of a field: the check refuses, Submit stays so.
            await gate.call('report_posting', {
              'company': 'Intel',
              'role': 'Intern',
              'fit': 'go',
            });
            await gate.call('routine_submit_check', {
              'fields': [
                {'label': 'Start date', 'source': 'answers', 'uncertain': true},
              ],
            });
            await act(gate, 'os_click', {'name': 'Submit'});
            await gate.call('report_outcome', {
              'status': 'ready',
              'reason': 'unsure of the start date',
            });
          case 3: // Presses Enter on the page, then claims a submit.
            await gate.call('report_posting', {
              'company': 'NVIDIA',
              'role': 'Intern',
              'fit': 'go',
            });
            await act(gate, 'os_key', {'keys': 'Enter'});
            await gate.call('report_outcome', {'status': 'submitted'});
          case 4: // Ends without a word.
            await gate.call('report_posting', {
              'company': 'Ashby',
              'role': 'Intern',
              'fit': 'go',
            });
        }
        return GaiaMessageStatus.complete;
      });
      await made.start(_routine(), newRun(5));
      final run = await settled(made);
      expect(run.state, GaiaRunState.done);
      expect(
        [for (final item in run.items) item.status],
        [
          GaiaRunItemStatus.skipped,
          GaiaRunItemStatus.submitted,
          GaiaRunItemStatus.ready,
          GaiaRunItemStatus.ready,
          GaiaRunItemStatus.failed,
        ],
      );
      expect(run.items[3].reason, 'reported submitted without the gate');
      expect(run.items[4].reason, 'ended without reporting');
      expect(run.items[1].label, 'Lucid — Intern');
      // The only submit click was item 1's, after its check passed.
      expect(clicked, ['Submit application']);
    });

    test('a low token cap parks the item and pauses the run', () async {
      final made = runner((turn, runner) async {
        await turn.gate.call('report_posting', {
          'company': 'A',
          'role': 'R',
          'fit': 'go',
        });
        runner.tokens(turn.chatId, {
          'sonnet': const GaiaTokenCount(
            input: 600,
            output: 500,
            cacheRead: 100000,
          ),
        });
        return GaiaMessageStatus.cancelled;
      });
      await made.start(_routine(tokenCap: 1000), newRun(3));
      final run = await settled(made);
      expect(run.state, GaiaRunState.paused);
      expect(run.stopReason, 'token cap');
      expect(run.items.first.status, GaiaRunItemStatus.needsYou);
      expect(run.items.first.reason, 'token cap reached');
      expect(run.items[1].status, GaiaRunItemStatus.waiting);
      expect(run.usage.counted, 1100);
      expect(run.usage.cacheRead, 100000);
      expect(stopped, ['token cap reached']);
    });

    test('the cap reached in the last item ends the run done', () async {
      final made = runner((turn, runner) async {
        await turn.gate.call('report_posting', {
          'company': 'A',
          'role': 'R',
          'fit': 'go',
        });
        runner.tokens(turn.chatId, {
          'sonnet': const GaiaTokenCount(input: 600, output: 500),
        });
        return GaiaMessageStatus.cancelled;
      });
      await made.start(_routine(tokenCap: 1000), newRun(1));
      final run = await settled(made);
      expect(run.state, GaiaRunState.done);
      expect(run.items.single.status, GaiaRunItemStatus.needsYou);
      expect(run.items.single.reason, 'token cap reached');
    });

    test('cache reads alone never reach the cap', () async {
      final made = runner((turn, runner) async {
        runner.tokens(turn.chatId, {
          'sonnet': const GaiaTokenCount(input: 10, cacheRead: 5000000),
        });
        await turn.gate.call('report_posting', {
          'company': 'A',
          'role': 'R',
          'fit': 'skip',
          'reason': 'x',
        });
        return GaiaMessageStatus.complete;
      });
      await made.start(_routine(tokenCap: 1000), newRun(2));
      expect((await settled(made)).state, GaiaRunState.done);
    });

    test('at the plan line no item starts', () async {
      plan = {
        'claude_code': [(name: '5-hour', used: 0.96, resetsAt: null)],
      };
      var sent = 0;
      final made = runner((turn, _) async {
        sent++;
        return GaiaMessageStatus.complete;
      });
      await made.start(_routine(), newRun(2));
      final run = await settled(made);
      expect(sent, 0);
      expect(run.state, GaiaRunState.paused);
      expect(run.stopReason, 'plan usage: 5-hour limit at 96%');
    });

    test('the plan line mid-item wraps it up, and at 99% stops it', () async {
      final made = runner((turn, runner) async {
        await turn.gate.call('report_posting', {
          'company': 'A',
          'role': 'R',
          'fit': 'go',
        });
        plan = {
          'claude_code': [(name: 'weekly', used: 0.95, resetsAt: null)],
        };
        await runner.planChanged();
        final told = await turn.gate.ran('os_read_screen', const {}, _ok);
        expect(told.text, contains('Plan usage is at 95%'));
        plan = {
          'claude_code': [(name: 'weekly', used: 0.99, resetsAt: null)],
        };
        await runner.planChanged();
        return GaiaMessageStatus.cancelled;
      });
      await made.start(_routine(), newRun(2));
      final run = await settled(made);
      expect(run.items.first.reason, 'plan usage at 99%');
      expect(run.state, GaiaRunState.paused);
      expect(run.stopReason, 'plan usage: weekly limit at 95%');
    });

    test('Abort ends the run', () async {
      final made = runner((turn, _) async => GaiaMessageStatus.aborted);
      await made.start(_routine(), newRun(3));
      final run = await settled(made);
      expect(run.state, GaiaRunState.ended);
      expect(run.stopReason, 'Gaia was aborted');
      expect(run.items.first.reason, 'Gaia was aborted');
      expect(run.items[1].status, GaiaRunItemStatus.waiting);
      expect(made.run, isNull);
    });

    test('Esc pauses the run and parks the item as stopped by you', () async {
      final made = runner((turn, _) async {
        await turn.gate.call('report_posting', {
          'company': 'A',
          'role': 'R',
          'fit': 'go',
        });
        return GaiaMessageStatus.cancelled;
      });
      await made.start(_routine(), newRun(2));
      final run = await settled(made);
      expect(run.state, GaiaRunState.paused);
      expect(run.items.first.reason, 'stopped by you');
      expect(run.items[1].status, GaiaRunItemStatus.waiting);
    });

    test(
      'resume goes on with the next item; a raised cap is the run\'s',
      () async {
        var first = true;
        final made = runner((turn, _) async {
          if (first) {
            first = false;
            return GaiaMessageStatus.cancelled;
          }
          await turn.gate.call('report_posting', {
            'company': 'A',
            'role': 'R',
            'fit': 'skip',
            'reason': 'x',
          });
          return GaiaMessageStatus.complete;
        });
        await made.start(_routine(), newRun(2));
        expect((await settled(made)).state, GaiaRunState.paused);
        await made.resume(tokenCap: 5000);
        final run = await settled(made);
        expect(run.state, GaiaRunState.done);
        expect(run.tokenCap, 5000);
        expect(run.items[1].status, GaiaRunItemStatus.skipped);
      },
    );
    Future<void> until(bool Function() done) async {
      for (var i = 0; i < 2000 && !done(); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
      expect(done(), isTrue);
    }

    List<GaiaRunItemStatus> statuses(GaiaRoutineRun run) => [
      for (final item in run.items) item.status,
    ];

    test('attended: a handoff waits, and Resume goes on in the same chat '
        'with the notes (§9.3)', () async {
      final turns = <GaiaItemTurn>[];
      final made = runner((turn, _) async {
        turns.add(turn);
        final gate = turn.gate;
        if (turns.length == 1) {
          await gate.call('report_posting', {
            'company': 'Acme',
            'role': 'Intern',
            'fit': 'go',
          });
          await gate.call('report_outcome', {
            'status': 'needs_you',
            'reason': 'The account page needs a password',
          });
        } else {
          // The posting was read in the first turn.
          expect(
            await gate.refuse('os_type', {'name': 'Email', 'text': 'a@x.io'}),
            isNull,
          );
          await gate.call('report_outcome', {
            'status': 'ready',
            'reason': 'stopped at Submit',
          });
        }
        return GaiaMessageStatus.complete;
      });
      await made.start(_routine(), newRun(1, mode: GaiaRunMode.attended));
      await until(() => made.handoff != null);
      expect(made.waitingOnYou, 'The account page needs a password');
      expect(saved.last.items.first.status, GaiaRunItemStatus.needsYou);
      expect(saved.last.state, GaiaRunState.running);
      await made.resume(notes: 'I made the account');
      final run = await settled(made);
      expect(run.state, GaiaRunState.done);
      expect(turns, hasLength(2));
      expect(turns[1].chatId, turns[0].chatId);
      expect(turns[1].resume, startsWith('Resumed.\nI made the account'));
      expect(run.items.first.status, GaiaRunItemStatus.ready);
      expect(run.items.first.notes, 'I made the account');
      expect(made.waitingOnYou, isNull);
    });

    test('attended: a handoff left 10 minutes without input parks its item, '
        'and the run goes on', () async {
      var now = DateTime.utc(2026, 11, 27, 9);
      var idle = Duration.zero;
      final made = runner(
        (turn, _) async {
          await turn.gate.call('report_posting', {
            'company': 'A',
            'role': 'R',
            'fit': 'go',
          });
          await turn.gate.call('report_outcome', {
            'status': 'needs_you',
            'reason': 'Salary?',
          });
          return GaiaMessageStatus.complete;
        },
        clock: () => now,
        idle: () => idle,
        tick: const Duration(milliseconds: 1),
      );
      await made.start(_routine(), newRun(2, mode: GaiaRunMode.attended));
      await until(() => made.handoff != null);
      final first = made.handoff!.chatId;
      // The user was busy elsewhere: no park, however long.
      now = now.add(const Duration(minutes: 30));
      idle = const Duration(minutes: 2);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(made.handoff?.chatId, first);
      idle = const Duration(minutes: 11);
      await until(() => made.handoff != null && made.handoff!.chatId != first);
      expect(saved.last.items.first.status, GaiaRunItemStatus.needsYou);
      expect(saved.last.items.first.reason, 'Salary?');
      await made.end();
      expect(saved.last.state, GaiaRunState.ended);
    });

    for (final ending in [false, true]) {
      test('${ending ? 'End' : 'Pause'} while the next item\'s usage is '
          'read stops before it starts', () async {
        final read = Completer<Map<String, List<GaiaPlanWindow>>>();
        var reads = 0;
        final made = GaiaRoutineRunner(
          save: (run) async => saved.add(run),
          sendItem: (turn) async {
            await turn.gate.call('report_posting', {
              'company': 'A',
              'role': 'R',
              'fit': 'skip',
              'reason': 'a skip rule matched',
            });
            return GaiaMessageStatus.complete;
          },
          stopItem: (chatId, why) async => stopped.add(why),
          focused: (_) async => null,
          materials: (_) async => (
            files: const <String, String>{},
            uploads: const <String, String>{},
          ),
          planUsage: (_) => ++reads == 1 ? Future.value(const {}) : read.future,
          submitted: () => const {},
          idle: () => Duration.zero,
          gap: Duration.zero,
        );
        await made.start(_routine(), newRun(2));
        await until(() => reads == 2);
        final stopping = ending ? made.end() : made.pause();
        read.complete(const {});
        await stopping;
        final run = ending ? saved.last : await settled(made);
        expect(run.state, ending ? GaiaRunState.ended : GaiaRunState.paused);
        expect(statuses(run), [
          GaiaRunItemStatus.skipped,
          GaiaRunItemStatus.waiting,
        ]);
      });
    }

    test('Pause during a handoff parks the item and pauses the run', () async {
      final made = runner((turn, _) async {
        await turn.gate.call('report_posting', {
          'company': 'A',
          'role': 'R',
          'fit': 'go',
        });
        await turn.gate.call('report_outcome', {
          'status': 'needs_you',
          'reason': 'Salary?',
        });
        return GaiaMessageStatus.complete;
      });
      await made.start(_routine(), newRun(2, mode: GaiaRunMode.attended));
      await until(() => made.handoff != null);
      await made.pause();
      final run = await settled(made);
      expect(run.state, GaiaRunState.paused);
      expect(run.stopReason, 'stopped by you');
      expect(statuses(run), [
        GaiaRunItemStatus.needsYou,
        GaiaRunItemStatus.waiting,
      ]);
      expect(run.items.first.reason, 'Salary?');
      expect(made.handoff, isNull);
    });

    test('a parked account page takes a note, retries in its own chat and '
        'finishes (§10.2, R2)', () async {
      final turns = <GaiaItemTurn>[];
      final made = runner((turn, _) async {
        turns.add(turn);
        final gate = turn.gate;
        final n = int.parse(turn.item.url.split('/').last);
        if (turn.resume == null) {
          await gate.call('report_posting', {
            'company': 'Acme',
            'role': 'Intern',
            'fit': n == 1 ? 'skip' : 'go',
            'reason': 'Must be a US citizen',
          });
        }
        if (n == 0 && turn.resume == null) {
          await gate.call('report_outcome', {
            'status': 'needs_you',
            'reason': 'The account page needs a password',
            'new_questions': ['Make the Acme account'],
          });
        } else if (n == 0) {
          await gate.call('routine_submit_check', {'fields': _fields});
          await gate.call('report_outcome', {
            'status': 'submitted',
            'company': 'Acme',
            'role': 'Intern',
          });
        }
        return GaiaMessageStatus.complete;
      });
      await made.start(_routine(), newRun(2));
      var run = await settled(made);
      expect(run.state, GaiaRunState.done);
      expect(statuses(run), [
        GaiaRunItemStatus.needsYou,
        GaiaRunItemStatus.skipped,
      ]);
      expect(gaiaNoteQuestion(run.items.first), 'Make the Acme account');
      expect(made.run, isNull);

      expect(
        await made.retry(
          _routine(),
          run,
          run.items.first,
          note: 'Account made; signed in.',
        ),
        isNull,
      );
      run = await settled(made);
      expect(run.state, GaiaRunState.done);
      expect(run.endedAt, isNotNull);
      // After the items that were left.
      expect(
        [for (final item in run.items) item.url.split('/').last],
        ['1', '0'],
      );
      expect(statuses(run), [
        GaiaRunItemStatus.skipped,
        GaiaRunItemStatus.submitted,
      ]);
      expect(turns.last.chatId, turns.first.chatId);
      expect(turns.last.resume, contains('Account made; signed in.'));
      expect(turns.last.resume, contains('Its tab is still open'));
      expect(run.items.last.notes, 'Account made; signed in.');
      expect(run.items.last.attempts, 2);
    });

    test(
      'a retry in a run under way waits its turn after the others',
      () async {
        final made = runner((turn, _) async {
          await turn.gate.call('report_posting', {
            'company': 'A',
            'role': 'R',
            'fit': 'go',
          });
          return GaiaMessageStatus.cancelled;
        });
        await made.start(_routine(), newRun(3));
        final paused = await settled(made);
        expect(paused.state, GaiaRunState.paused);
        expect(
          await made.retry(_routine(), paused, paused.items.first, note: 'x'),
          isNull,
        );
        final run = made.run!;
        expect(run.state, GaiaRunState.paused);
        expect(
          [for (final item in run.items) item.url.split('/').last],
          ['1', '2', '0'],
        );
        expect(run.items.last.status, GaiaRunItemStatus.waiting);
        expect(run.items.last.notes, 'x');
      },
    );
  });

  test('a queued retry keeps its earlier notes and loses its reason', () {
    final now = DateTime.utc(2026, 11, 26);
    final run = GaiaRoutineRun(
      id: 'run',
      createdAt: now,
      updatedAt: now,
      routineId: 'r1',
      deviceId: 'd',
      startedAt: now,
      items: const [
        GaiaRunItem(
          url: 'https://a.io/1',
          status: GaiaRunItemStatus.needsYou,
          reason: 'Salary?',
          notes: 'Start: May 4',
        ),
        GaiaRunItem(url: 'https://a.io/2'),
      ],
    );
    final queued = gaiaQueueRetry(run, 0, note: ' 30/h ');
    expect(queued.items.last.url, 'https://a.io/1');
    expect(queued.items.last.status, GaiaRunItemStatus.waiting);
    expect(queued.items.last.reason, isNull);
    expect(queued.items.last.notes, 'Start: May 4\n30/h');
    expect(gaiaNoteQuestion(run.items.first), 'Salary?');
  });

  test('an attended ask_user is a handoff: its wait is not the item\'s '
      'time, and 10 idle minutes park it (§9.3)', () async {
    var now = DateTime.utc(2026, 11, 27, 9);
    var idle = Duration.zero;
    final stops = <String>[];
    final gate = GaiaRoutineGate(
      routine: _routine(),
      mode: GaiaRunMode.attended,
      itemUrl: 'https://boards.greenhouse.io/acme/jobs/1',
      uploadPaths: const [],
      isDuplicate: (_) => false,
      focused: () async => null,
      stopTurn: stops.add,
      posting: const {'fit': 'go'},
      idle: () => idle,
      clock: () => now,
    );
    expect(await gate.refuse('ask_user', {'question': 'Salary?'}), isNull);
    expect(gate.asking, 'Salary?');
    // Twenty minutes to answer, the user busy all along.
    now = now.add(const Duration(minutes: 20));
    idle = const Duration(minutes: 1);
    gate.checkTime();
    await gate.ran('ask_user', {'question': 'Salary?'}, _ok);
    expect(gate.asking, isNull);
    gate.checkTime();
    expect(stops, isEmpty);
    expect(await gate.refuse('ask_user', {'question': 'Start?'}), isNull);
    now = now.add(const Duration(minutes: 10));
    idle = const Duration(minutes: 10);
    gate.checkTime();
    expect(stops, ['no answer in 10 minutes']);
  });

  test('handoff messages carry the notes', () {
    expect(gaiaResumeMessage(' Done. '), startsWith('Resumed.\nDone.\n'));
    expect(gaiaResumeMessage(null), isNot(contains('null')));
    expect(
      gaiaRetryMessage('Salary: 30/h'),
      contains('<notes>Salary: 30/h</notes>'),
    );
    expect(gaiaRetryMessage(''), isNot(contains('<notes>')));
  });

  test("a tab's address bar text becomes a URL (§7.2)", () {
    expect(
      gaiaAddressUrl('boards.greenhouse.io/acme/jobs/1'),
      'https://boards.greenhouse.io/acme/jobs/1',
    );
    expect(
      gaiaAddressUrl('http://localhost:8765/6-account.html'),
      'http://localhost:8765/6-account.html',
    );
  });
}

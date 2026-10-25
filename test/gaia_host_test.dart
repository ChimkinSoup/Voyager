import 'package:fake_async/fake_async.dart';
import 'package:file/memory.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/data/repositories/drift_repositories.dart';
import 'package:voyager/domain/models/gaia_models.dart';
import 'package:voyager/features/gaia/gaia_pipe.dart';
import 'package:voyager/features/gaia/host/gaia_host.dart';

import 'fakes/gaia_fakes.dart';

/// The main instance's half of Gaia (GAIA_HLD.md §3.2, §15.7): launching
/// and relaunching the companion, hotkeys, the Abort flag, and the requests
/// it serves. Each test runs in fake time against a scripted companion.

/// A launched companion, as the main instance sees it over the pipe.
class _Companion {
  _Companion(this.pipe, this.pid) {
    pipe
      ..onEvent = (event, params) {
        events.add('$event ${params.values.join(' ')}');
      }
      ..onRequest = (method, _) async {
        requests.add(method);
        return replies[method];
      };
  }

  final FakeGaiaPipe pipe;
  final int pid;

  /// What each request is answered with; null when absent.
  final replies = <String, Object?>{};
  final events = <String>[];
  final requests = <String>[];
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late MemoryFileSystem fs;
  late FakeGaiaPipe pipe;
  late List<_Companion> companions;
  late List<int> killed;
  late AppDatabase db;
  late List<String> toasts;

  tearDown(() => db.close());

  setUp(() {
    fs = MemoryFileSystem();
    pipe = FakeGaiaPipe.main();
    companions = [];
    killed = [];
    db = AppDatabase.inMemory();
    toasts = [];
    pipe.onLaunch = (end, pid) => companions.add(_Companion(end, pid));
  });

  GaiaHost newHost() => GaiaHost(
    pipe: pipe,
    abortFlag: () async => fs.file('gaia_aborted'),
    killCompanion: (pid) async => killed.add(pid),
  );

  /// Starts a host and runs [body] in fake time.
  void run(
    void Function(FakeAsync async, GaiaHost host) body, {
    bool show = false,
  }) {
    fakeAsync((async) {
      final host = newHost();
      host.start(registerHotkeys: false, show: show);
      host.attach(
        repository: DriftGaiaRepository(db),
        deviceId: 'laptop',
        toast: (chatId, title, body) => toasts.add('$chatId $title $body'),
      );
      async.flushMicrotasks();
      body(async, host);
    });
  }

  /// The latest companion connects and says hello; returns hello's reply.
  Map<String, Object?> connect(FakeAsync async) {
    final companion = companions.last;
    companion.pipe.connect();
    async.flushMicrotasks();
    Object? reply;
    companion.pipe.request('hello').then((value) => reply = value);
    // A pending hotkey follows the reply on a zero timer.
    async.elapse(Duration.zero);
    return (reply! as Map).cast<String, Object?>();
  }

  Object? request(
    FakeAsync async,
    String method, [
    Map<String, Object?>? params,
  ]) {
    Object? result;
    Object? error;
    companions.last.pipe
        .request(method, params)
        .then((value) => result = value, onError: (Object e) => error = e);
    async.flushMicrotasks();
    if (error != null) throw error!;
    return result;
  }

  group('launching', () {
    test('the companion launches 5 s after start, not on the startup path', () {
      run((async, _) {
        async.elapse(const Duration(milliseconds: 4900));
        expect(pipe.launches, isEmpty);
        async.elapse(const Duration(milliseconds: 200));
        expect(pipe.launches, hasLength(1));
      });
    });

    test('show launches at once, and opens the Gaia window after hello', () {
      run(show: true, (async, _) {
        expect(pipe.launches, hasLength(1));
        connect(async);
        expect(companions.single.events, ['hotkey window']);
      });
    });

    test(
      'a hotkey with no companion launches one, and arrives after hello',
      () {
        run((async, host) {
          host.onHotkey(GaiaHotkey.small);
          async.flushMicrotasks();
          expect(pipe.launches, hasLength(1));
          connect(async);
          expect(companions.single.events, ['hotkey small']);
        });
      },
    );

    test('a hotkey goes straight to a connected companion', () {
      run(show: true, (async, host) {
        connect(async);
        host.onHotkey(GaiaHotkey.large);
        async.flushMicrotasks();
        expect(companions.single.events, ['hotkey window', 'hotkey large']);
      });
    });

    test('failed launches retry after 2 s, doubling up to a minute', () {
      pipe.failLaunch = true;
      run(show: true, (async, _) {
        final gaps = <int>[];
        var last = async.elapsed;
        while (gaps.length < 7) {
          final attempts = pipe.startAttempts;
          while (pipe.startAttempts == attempts) {
            async.elapse(const Duration(seconds: 1));
          }
          gaps.add((async.elapsed - last).inSeconds);
          last = async.elapsed;
        }
        expect(gaps, [2, 4, 8, 16, 32, 60, 60]);
      });
    });

    test('a companion that exits before connecting is relaunched', () {
      run(show: true, (async, _) {
        pipe.disconnect();
        async.elapse(const Duration(seconds: 2));
        expect(pipe.launches, hasLength(2));
      });
    });

    test('the backoff starts over once a companion connects', () {
      pipe.failLaunch = true;
      run(show: true, (async, _) {
        async.elapse(const Duration(seconds: 2 + 4 + 8));
        expect(pipe.startAttempts, 4);
        pipe.failLaunch = false;
        async.elapse(const Duration(seconds: 16));
        connect(async);

        companions.single.pipe.disconnect();
        async.elapse(const Duration(seconds: 2));
        expect(pipe.launches, hasLength(2));
      });
    });

    test('after shutdown a lost companion is not relaunched', () {
      run(show: true, (async, host) {
        connect(async);
        host.shutdown();
        async.elapse(const Duration(minutes: 2));
        expect(pipe.launches, hasLength(1));
      });
    });
  });

  group('chats', () {
    final chat = GaiaChat(
      id: 'c1',
      title: 'Hi',
      createdAt: DateTime.utc(2026, 10, 24),
      updatedAt: DateTime.utc(2026, 10, 24),
      lastMessageAt: DateTime.utc(2026, 10, 24),
    );
    GaiaMessage streaming() => GaiaMessage(
      id: 'm1',
      chatId: 'c1',
      seq: 1,
      role: GaiaMessageRole.assistant,
      parts: const [GaiaTextPart('so far')],
      status: GaiaMessageStatus.streaming,
      createdAt: DateTime.utc(2026, 10, 24, 1),
      updatedAt: DateTime.utc(2026, 10, 24, 1),
    );
    String status(FakeAsync async) {
      final list = request(async, 'messages', {'chatId': 'c1'})! as List;
      return (list.single as Map)['status']! as String;
    }

    test('are kept across companions', () {
      run(show: true, (async, _) {
        connect(async);
        request(async, 'putChat', {'chat': chat.toJson()});
        request(async, 'putMessage', {
          'message': streaming()
              .copyWith(status: GaiaMessageStatus.complete)
              .toJson(),
        });
        companions.last.pipe.disconnect();
        async.elapse(const Duration(seconds: 2));
        connect(async);

        final chats = request(async, 'chats')! as List;
        expect((chats.single as Map)['id'], 'c1');
        expect(status(async), 'complete');
      });
    });

    test("a lost companion's streaming replies end interrupted", () {
      run(show: true, (async, _) {
        connect(async);
        request(async, 'putChat', {'chat': chat.toJson()});
        request(async, 'putMessage', {'message': streaming().toJson()});
        companions.last.pipe.disconnect();
        async.elapse(const Duration(seconds: 2));
        connect(async);
        expect(status(async), 'interrupted');
      });
    });

    test('an unknown request is refused', () {
      run(show: true, (async, _) {
        connect(async);
        expect(() => request(async, 'nope'), throwsA(isA<GaiaPipeException>()));
      });
    });
  });

  group('Abort (§15.7)', () {
    test('saves the flag and asks the companion, which confirms', () {
      run(show: true, (async, host) {
        connect(async);
        host.onHotkey(GaiaHotkey.abort);
        async.flushMicrotasks();
        expect(fs.file('gaia_aborted').existsSync(), isTrue);
        expect(companions.single.requests, ['abort']);
        async.elapse(const Duration(seconds: 2));
        expect(killed, isEmpty);
      });
    });

    test('kills a companion that does not confirm within a second', () {
      run(show: true, (async, host) {
        connect(async);
        request(async, 'putChat', {
          'chat': GaiaChat(
            id: 'c1',
            title: 'Hi',
            createdAt: DateTime.utc(2026),
            updatedAt: DateTime.utc(2026),
            lastMessageAt: DateTime.utc(2026),
          ).toJson(),
        });
        request(async, 'putMessage', {
          'message': GaiaMessage(
            id: 'm1',
            chatId: 'c1',
            seq: 0,
            role: GaiaMessageRole.assistant,
            parts: const [],
            status: GaiaMessageStatus.streaming,
            createdAt: DateTime.utc(2026),
            updatedAt: DateTime.utc(2026),
          ).toJson(),
        });
        companions.single.pipe.frozen = true;
        host.onHotkey(GaiaHotkey.abort);
        async.elapse(const Duration(milliseconds: 900));
        expect(killed, isEmpty);
        async.elapse(const Duration(milliseconds: 200));
        expect(killed, [companions.single.pid]);

        // The kill breaks the pipe; the next companion starts aborted, and
        // the reply the killed one was writing is saved as aborted.
        companions.single.pipe.disconnect();
        async.elapse(const Duration(seconds: 2));
        expect(connect(async)['aborted'], isTrue);
        final list = request(async, 'messages', {'chatId': 'c1'})! as List;
        expect((list.single as Map)['status'], 'aborted');
      });
    });

    test('with no companion running, still saves the flag', () {
      run((async, host) {
        host.onHotkey(GaiaHotkey.abort);
        async.flushMicrotasks();
        expect(fs.file('gaia_aborted').existsSync(), isTrue);
        expect(pipe.launches, isEmpty);
      });
    });

    test('holds across a restart, until Re-arm', () {
      fs.file('gaia_aborted').writeAsStringSync('2026-10-24');
      run(show: true, (async, _) {
        expect(connect(async)['aborted'], isTrue);
        request(async, 'rearm');
        expect(fs.file('gaia_aborted').existsSync(), isFalse);
        expect((request(async, 'hello')! as Map)['aborted'], isFalse);
      });
    });
  });

  group('Phase 1 protocol', () {
    test('hello carries the device and the settings', () {
      run(show: true, (async, _) {
        final hello = connect(async);
        expect(hello['deviceId'], 'laptop');
        expect(hello['settings'], {'gaiaMd': '', 'notifyOnDone': true});
      });
    });

    test('a settings change goes to the companion', () {
      run(show: true, (async, _) {
        connect(async);
        DriftGaiaRepository(
          db,
        ).upsertSettings(GaiaSettings.initial().copyWith(gaiaMd: 'Be brief.'));
        async.elapse(const Duration(seconds: 1));
        expect(companions.single.events, contains('settings Be brief. true'));
      });
    });

    test('writes reach the companion as one changed notice', () {
      run(show: true, (async, _) {
        connect(async);
        final now = DateTime.utc(2026, 10, 24);
        for (final id in ['a', 'b', 'c']) {
          DriftGaiaRepository(db).upsertChat(
            GaiaChat(
              id: id,
              title: id,
              createdAt: now,
              updatedAt: now,
              lastMessageAt: now,
            ),
          );
        }
        async.elapse(const Duration(seconds: 1));
        expect(
          companions.single.events.where((e) => e.startsWith('changed')),
          hasLength(1),
        );
      });
    });

    test('setSession records the session for this device', () {
      run(show: true, (async, _) {
        connect(async);
        final now = DateTime.utc(2026, 10, 24);
        request(async, 'putChat', {
          'chat': GaiaChat(
            id: 'c1',
            title: 'Hi',
            createdAt: now,
            updatedAt: now,
            lastMessageAt: now,
          ).toJson(),
        });
        request(async, 'setSession', {
          'chatId': 'c1',
          'sessionId': 's1',
          'lastSeq': 3,
        });
        final chat = GaiaChat.fromJson(
          ((request(async, 'chats')! as List).single as Map)
              .cast<String, Object?>(),
        );
        expect(chat.sessionOn('laptop'), 's1');
        expect(chat.version, 2);
      });
    });

    test('runs and a finished run reach the tray and a toast', () {
      run(show: true, (async, host) {
        connect(async);
        companions.single.pipe.notify('runs', {
          'runs': [
            {'chatId': 'c1', 'title': 'Hi'},
          ],
        });
        async.flushMicrotasks();
        expect(host.runs.value, [(chatId: 'c1', title: 'Hi')]);
        companions.single.pipe.notify('runDone', {
          'chatId': 'c1',
          'title': 'Gaia is done',
          'body': 'Hi: hello',
        });
        async.flushMicrotasks();
        expect(toasts, ['c1 Gaia is done Hi: hello']);

        companions.single.pipe.disconnect();
        async.flushMicrotasks();
        expect(host.runs.value, isEmpty);
      });
    });

    test('openChat with no companion launches one and arrives after hello', () {
      run((async, host) {
        host.openChat('c1');
        async.flushMicrotasks();
        expect(pipe.launches, hasLength(1));
        connect(async);
        expect(companions.single.events, ['openChat c1']);
      });
    });
  });

  group('drain (§3.2)', () {
    test('with no runs, finishes at once and launches nothing after', () {
      run(show: true, (async, host) {
        connect(async);
        companions.single.replies['drain'] = {'running': 0};
        var done = false;
        host.drain().then((_) => done = true);
        async.flushMicrotasks();
        expect(done, isTrue);
        companions.single.pipe.disconnect();
        async.elapse(const Duration(minutes: 2));
        expect(pipe.launches, hasLength(1));
      });
    });

    test('with runs, waits for the companion to say drained', () {
      run(show: true, (async, host) {
        connect(async);
        companions.single.replies['drain'] = {'running': 2};
        var done = false;
        host.drain().then((_) => done = true);
        async.elapse(const Duration(minutes: 5));
        expect(done, isFalse);
        companions.single.pipe.notify('drained');
        async.flushMicrotasks();
        expect(done, isTrue);
        expect(killed, isEmpty);
      });
    });

    test('a companion that does not answer is killed', () {
      run(show: true, (async, host) {
        connect(async);
        companions.single.pipe.frozen = true;
        var done = false;
        host.drain().then((_) => done = true);
        async.elapse(const Duration(seconds: 3));
        expect(done, isTrue);
        expect(killed, [companions.single.pid]);
      });
    });
  });

  group('accent', () {
    test('goes out in hello, and as an event when it changes', () {
      run(show: true, (async, host) {
        host.accent = 0xFF4CC38A;
        expect(connect(async)['accent'], 0xFF4CC38A);
        host
          ..accent = 0xFFFF7AB6
          ..accent = 0xFFFF7AB6;
        async.flushMicrotasks();
        expect(companions.single.events, [
          'hotkey window',
          'accent ${0xFFFF7AB6}',
        ]);
      });
    });
  });
}

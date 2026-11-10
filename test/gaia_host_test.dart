import 'dart:async';
import 'dart:io' show Directory, File, pid;

import 'package:fake_async/fake_async.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:file/memory.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:voyager/core/notifications/notification_history.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/data/repositories/drift_repositories.dart';
import 'package:voyager/domain/models/gaia_models.dart';
import 'package:voyager/domain/models/todo_models.dart';
import 'package:voyager/features/gaia/gaia_pipe.dart';
import 'package:voyager/features/gaia/gaia_text_settings.dart';
import 'package:voyager/features/gaia/host/gaia_capture.dart';
import 'package:voyager/features/gaia/host/gaia_executor.dart';
import 'package:voyager/features/gaia/host/gaia_host.dart';
import 'package:voyager/features/gaia/host/gaia_media.dart';
import 'package:voyager/features/gaia/host/gaia_memories.dart';
import 'package:voyager/features/gaia/host/gaia_os_control.dart';
import 'package:voyager/features/gaia/host/gaia_os_reads.dart';
import 'package:voyager/features/gaia/host/gaia_selection.dart';
import 'package:voyager/features/gaia/host/gaia_voyager_reads.dart';
import 'package:voyager/features/gaia/remote/gaia_beacon_service.dart';
import 'package:voyager/features/gaia/remote/gaia_device_keys.dart';
import 'package:voyager/features/gaia/tools/gaia_proposals.dart';
import 'package:voyager/features/gaia/host/gaia_window_context.dart';

import 'fakes/gaia_fakes.dart';

/// The main instance's half of Gaia (GAIA_HLD.md §3.2, §15.7): launching
/// and relaunching the companion, hotkeys, the Abort flag, and the requests
/// it serves. Each test runs in fake time against a scripted companion.

/// A launched companion, as the main instance sees it over the pipe.
/// Notepad in front, and nothing in the way: the host's checks are what's
/// tested.
class _ControlBackend implements GaiaInputBackend {
  final sent = <GaiaInputEvent>[];
  var escape = false;

  static const _window = (
    hwnd: 7,
    pid: 70,
    exe: 'notepad',
    app: 'Notepad',
    title: 'notes.txt',
    console: false,
  );

  @override
  GaiaForegroundWindow? target(int gaiaPid) => _window;
  @override
  GaiaForegroundWindow? describe(int hwnd) => _window;
  @override
  int foreground() => 7;
  @override
  bool inFrontOfTarget(int hwnd, int gaiaPid) => false;
  @override
  bool activate(int hwnd) => true;
  @override
  int rootAt(int x, int y) => 7;
  @override
  List<int> seeThrough(int gaiaPid, List<({int x, int y})> at) => const [];
  @override
  void solid(List<int> hwnds) {}
  @override
  String windowClass(int hwnd) => '';
  @override
  ({int left, int top, int width, int height}) frame(int hwnd) =>
      (left: 0, top: 0, width: 800, height: 600);
  @override
  Future<GaiaWindowScan?> find(
    int hwnd, {
    required bool browser,
    required ({String name, String? type}) control,
  }) async => null;
  @override
  Future<String?> address(int hwnd) async => null;
  @override
  Future<GaiaDirectResult?> direct(
    int hwnd, {
    required bool browser,
    required ({String name, String? type})? control,
    required ({int x, int y}) at,
    required GaiaDirectAct act,
  }) async => (ran: null, miss: GaiaDirectMiss.noPattern);
  @override
  bool cloaked(int hwnd) => false;
  @override
  List<int> appWindows(int pid, int owner) => const [];
  @override
  int owner(int hwnd) => 0;
  @override
  Future<bool?> focusSensitive(int hwnd, {required bool browser}) async =>
      false;
  @override
  bool modifiersDown() => false;
  @override
  bool escapeDown() => escape;
  @override
  int lastInput() => 0;
  @override
  bool watchInput(bool on) => on;
  @override
  Duration? sinceUserSwitch() => null;
  @override
  void moveCursor(int x, int y) {}
  @override
  ({int x, int y}) cursorAt() => (x: 0, y: 0);
  @override
  bool get buttonsSwapped => false;
  @override
  int send(List<GaiaInputEvent> events) {
    sent.addAll(events);
    return events.length;
  }

  @override
  List<GaiaListedWindow> listWindows() => [
    (
      window: _window,
      minimized: false,
      frame: (left: 0, top: 0, width: 800, height: 600),
    ),
  ];
  @override
  Future<List<({String name, String id})>> startApps() async => [
    (name: 'Notepad', id: r'C:\Windows\notepad.exe'),
  ];
  @override
  Future<({int pid, String? exe})> launch(String file) async =>
      (pid: 0, exe: null);
  @override
  bool running(int pid) => false;
  @override
  Map<int, int> processParents() => const {};
  @override
  Set<String> appIdsOf(GaiaForegroundWindow window) => const {};
  @override
  ({String? exe, String? appId}) handler(
    String assoc, {
    required bool protocol,
  }) => (exe: null, appId: null);
  @override
  String? startAppTarget(String id) => null;
  @override
  String? shortcutTarget(String path) => null;
  @override
  bool minimized(int hwnd) => false;
  @override
  void restore(int hwnd) {}
  @override
  void minimize(int hwnd) {}
  @override
  void maximize(int hwnd) {}
  @override
  Future<bool> place(
    int hwnd, {
    int? left,
    int? top,
    int? width,
    int? height,
  }) async => true;
  @override
  void close(int hwnd) {}
  @override
  bool elevatedAboveGaia(int pid) => false;
  @override
  Future<bool> writeClipboard(String text) async => true;
  @override
  GaiaSavedClipboard? saveClipboard() => (formats: [], private: false);
  @override
  void restoreClipboard(GaiaSavedClipboard saved) {}
  @override
  Future<void> pumped(
    int hwnd, {
    required int times,
    required Duration limit,
  }) async {}
}

class _Companion {
  _Companion(this.pipe, this.pid) {
    pipe
      ..onEvent = (event, params) {
        events.add('$event ${params.values.join(' ')}');
      }
      ..onRequest = (method, params) async {
        requests.add(method);
        if (method == 'stop') stopWhy = params['why'] as String?;
        return replies[method];
      };
  }

  final FakeGaiaPipe pipe;
  final int pid;

  /// What each request is answered with; null when absent.
  final replies = <String, Object?>{};
  final events = <String>[];
  final requests = <String>[];
  String? stopWhy;
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

  /// Every screen capture the host took, by path.
  late List<String> captured;
  setUp(() => captured = []);

  /// The window in front when a hotkey comes, and what UI Automation reads
  /// of it.
  GaiaForegroundWindow? foreground;
  GaiaWindowUia uia = (url: null, selection: null);
  setUp(() {
    foreground = null;
    uia = (url: null, selection: null);
  });

  /// Each time the split hotkey moved a window.
  late List<({int hwnd, bool below, bool gaiaRight})> splits;
  setUp(() => splits = []);

  /// Each Ctrl+C fallback, by the exe it was sent to, and what it got.
  late List<String> copies;
  String? copied;

  /// Holds each copy until completed, when set.
  Completer<void>? copyGate;
  setUp(() {
    copies = [];
    copied = null;
    copyGate = null;
  });

  /// The window under the cursor, what's read of its control, and each
  /// control a crop was taken of.
  GaiaCursorTarget? underCursor;
  GaiaPointedControl? pointedControl;
  late List<GaiaScreenRect> controlCrops;
  setUp(() {
    underCursor = null;
    pointedControl = null;
    controlCrops = [];
  });

  /// Holds an `os_*` read until completed, when set.
  Completer<void>? osGate;
  setUp(() => osGate = null);

  /// What the `os_*` actions send, and each label the border was given.
  late _ControlBackend controlBackend;
  late List<String?> borders;
  late List<int> borderAccents;
  setUp(() {
    controlBackend = _ControlBackend();
    borders = [];
    borderAccents = [];
  });

  GaiaHost newHost() => GaiaHost(
    osReads: GaiaOsReads(
      companionPid: () => 1,
      exclusions: () => const [],
      vaultUnlocked: () => false,
      target: (_) => (
        hwnd: 7,
        pid: 70,
        exe: 'notepad',
        app: 'Notepad',
        title: 'notes.txt',
        console: false,
      ),
      scan: (window, {required browser, region}) async {
        await osGate?.future;
        return (
          url: null,
          tree: 'Button "Save"',
          cut: false,
          sensitive: const <({int left, int top, int right, int bottom})>[],
          unjudged: const <({int left, int top, int right, int bottom})>[],
          matches: const <GaiaControlMatch>[],
          controls: 1,
          hasDocument: false,
          sensitiveFocused: false,
          anyFocused: false,
        );
      },
    ),
    osControl: GaiaOsControl(
      companionPid: () => 1,
      exclusions: () => const [],
      vaultUnlocked: () => false,
      backend: controlBackend,
      settle: Duration.zero,
    ),
    showBorder: (label, accent) async {
      borders.add(label);
      borderAccents.add(accent);
    },
    cursorTarget: () => underCursor,
    readControl: (target) async => pointedControl,
    captureControl: (path, target, control) async {
      controlCrops.add(control);
      return path;
    },
    pipe: pipe,
    abortFlag: () async => fs.file('gaia_aborted'),
    autoConsent: () async => fs.file('gaia_auto_consent'),
    killCompanion: (pid) async => killed.add(pid),
    captureDirectory: () => fs.directory('captures').create(),
    captureScreen: (path) async {
      captured.add(path);
      return (path: path, left: -1920, top: 0, width: 1920, height: 1080);
    },
    foregroundWindow: () => foreground,
    readUia: (window, {required selection}) async => uia,
    splitWindows: (hwnd, {required below, required gaiaRight}) {
      splits.add((hwnd: hwnd, below: below, gaiaRight: gaiaRight));
      return (left: 0, top: 0, width: 960, height: 1040);
    },
    copySelection: (window) async {
      copies.add(window.exe);
      await copyGate?.future;
      return copied;
    },
  );

  /// Starts a host and runs [body] in fake time.
  void run(
    void Function(FakeAsync async, GaiaHost host) body, {
    bool show = false,
    GaiaMedia? media,
    GaiaExecutor? executor,
    GaiaMemories? memories,
    Future<void> Function(String word)? addWord,
    GaiaBeaconService? beacon,
    bool vaultUnlocked = false,
  }) {
    fakeAsync((async) {
      final host = newHost();
      host.start(registerHotkeys: false, show: show);
      host.attach(
        vaultUnlocked: () => vaultUnlocked,
        repository: DriftGaiaRepository(db),
        deviceId: 'laptop',
        toast: (chatId, title, body, {btwId}) =>
            toasts.add('$chatId $title $body'),
        media: media,
        executor: executor,
        memories: memories,
        addWord: addWord,
        beacon: beacon,
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
          expect(companions.single.events, ['hotkey small false']);
        });
      },
    );

    test('full screen goes to the companion as a hotkey', () {
      run(show: true, (async, host) {
        connect(async);
        host.onHotkey(GaiaHotkey.fullScreen, pressed: true);
        async.flushMicrotasks();
        expect(companions.single.events.last, 'hotkey fullScreen true');
      });
    });

    GaiaForegroundWindow windowOf(int hwnd, int pid) => (
      hwnd: hwnd,
      pid: pid,
      exe: 'app',
      app: 'App',
      title: '',
      console: false,
    );

    test('split moves the window in front, then sends Gaia its half', () {
      run(show: true, (async, host) {
        connect(async);
        foreground = windowOf(5, 77);
        host.onHotkey(GaiaHotkey.split);
        async.flushMicrotasks();
        expect(splits, [(hwnd: 5, below: false, gaiaRight: false)]);
        expect(companions.single.events, contains('split 0 0 960 1040'));
      });
    });

    test('aborted, split moves nothing and the companion says why', () {
      run(show: true, (async, host) {
        connect(async);
        host.onHotkey(GaiaHotkey.abort);
        async.flushMicrotasks();
        foreground = windowOf(5, 77);
        host.onHotkey(GaiaHotkey.split);
        async.flushMicrotasks();
        expect(splits, isEmpty);
        expect(companions.single.events, contains('refused aborted'));
      });
    });

    test('mid-crop, split moves nothing and goes on to cancel the crop', () {
      run(show: true, (async, host) {
        connect(async);
        companions.single.pipe.notify('cropping', {'active': true});
        async.flushMicrotasks();
        foreground = windowOf(9, companions.single.pid);
        host.onHotkey(GaiaHotkey.split);
        async.flushMicrotasks();
        expect(splits, isEmpty);
        expect(companions.single.events, contains('hotkey split'));
        companions.single.pipe.notify('cropping', {'active': false});
        async.flushMicrotasks();
        host.onHotkey(GaiaHotkey.split);
        async.flushMicrotasks();
        expect(splits, [(hwnd: 9, below: true, gaiaRight: false)]);
      });
    });

    test('split over Gaia moves the window under it', () {
      run(show: true, (async, host) {
        connect(async);
        foreground = windowOf(9, companions.single.pid);
        host.onHotkey(GaiaHotkey.split);
        async.flushMicrotasks();
        expect(splits, [(hwnd: 9, below: true, gaiaRight: false)]);
      });
    });

    test('split follows the side setting', () {
      run(show: true, (async, host) {
        connect(async);
        DriftGaiaRepository(
          db,
        ).upsertSettings(GaiaSettings.initial().copyWith(splitGaiaRight: true));
        async.flushMicrotasks();
        foreground = windowOf(5, 77);
        host.onHotkey(GaiaHotkey.split);
        async.flushMicrotasks();
        expect(splits.single.gaiaRight, isTrue);
      });
    });

    test('a hotkey goes straight to a connected companion', () {
      run(show: true, (async, host) {
        connect(async);
        host.onHotkey(GaiaHotkey.large);
        async.flushMicrotasks();
        expect(companions.single.events, [
          'hotkey window',
          'hotkey large false',
        ]);
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

  group('a lost companion and the beacon', () {
    late FakeFirebaseFirestore firestore;
    late GaiaBeaconService beacon;

    setUp(() async {
      final dir = await Directory.systemTemp.createTemp('gaia_host');
      addTearDown(() => dir.delete(recursive: true));
      firestore = FakeFirebaseFirestore();
      beacon = GaiaBeaconService(
        firestore: firestore,
        deviceId: 'laptop',
        name: 'LAPTOP',
        adapters: const [],
        trust: GaiaTrustStore(File(p.join(dir.path, 'trusted.json'))),
        commandLog: await GaiaCommandLog.load(
          file: File(p.join(dir.path, 'commands.log')),
        ),
      );
    });

    Map<String, dynamic>? read(FakeAsync async, String path) {
      Map<String, dynamic>? data;
      firestore.doc('users/u/$path').get().then((doc) => data = doc.data());
      async.flushMicrotasks();
      return data;
    }

    void running(FakeAsync async) {
      unawaited(beacon.setUser('u'));
      async.flushMicrotasks();
      connect(async);
      companions.last.pipe.notify('runs', {
        'runs': [
          {'chatId': 'c1', 'title': 'Hi'},
        ],
      });
      async.flushMicrotasks();
      beacon.takeLease('c1');
      async.flushMicrotasks();
      expect(read(async, 'gaia_beacons/laptop')!['runs'], hasLength(1));
      expect(read(async, 'gaia_leases/c1'), isNotNull);
    }

    test('its runs stop being advertised, and their leases go', () {
      run(show: true, beacon: beacon, (async, host) {
        running(async);
        companions.last.pipe.disconnect();
        async.flushMicrotasks();
        expect(read(async, 'gaia_beacons/laptop')!['runs'], isEmpty);
        expect(read(async, 'gaia_leases/c1'), isNull);
        host.shutdown();
        async.elapse(const Duration(seconds: 3));
      });
    });

    test('quitting leaves the beacon offline', () {
      run(show: true, beacon: beacon, (async, host) {
        running(async);
        host.shutdown();
        async.elapse(const Duration(seconds: 3));
        expect(read(async, 'gaia_beacons/laptop')!['heartbeatAt'], 0);
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

    test(
      'deleteChat takes a chat off the list; restoreChat brings it back',
      () {
        run(show: true, (async, _) {
          connect(async);
          request(async, 'putChat', {'chat': chat.toJson()});
          final deleted =
              request(async, 'deleteChat', {'chatId': 'c1'})! as Map;
          expect(request(async, 'chats'), isEmpty);
          request(async, 'restoreChat', {
            'chatId': 'c1',
            'mediaDeletedAt': deleted['mediaDeletedAt'],
          });
          final chats = request(async, 'chats')! as List;
          expect((chats.single as Map)['id'], 'c1');
        });
      },
    );

    test('setPinned pins and unpins a chat', () {
      run(show: true, (async, _) {
        connect(async);
        request(async, 'putChat', {'chat': chat.toJson()});
        bool pinned() =>
            ((request(async, 'chats')! as List).single as Map)['pinned'] ==
            true;

        request(async, 'setPinned', {'chatId': 'c1', 'pinned': true});
        expect(pinned(), isTrue);
        request(async, 'setPinned', {'chatId': 'c1', 'pinned': false});
        expect(pinned(), isFalse);
      });
    });

    test('deleteChat deletes a chat whose images could not be taken off', () {
      run(show: true, media: _FailingMedia(), (async, _) {
        connect(async);
        request(async, 'putChat', {'chat': chat.toJson()});
        final deleted = request(async, 'deleteChat', {'chatId': 'c1'})! as Map;
        expect(deleted['mediaDeletedAt'], isNull);
        expect(request(async, 'chats'), isEmpty);
      });
    });

    test('an unknown request is refused', () {
      run(show: true, (async, _) {
        connect(async);
        expect(() => request(async, 'nope'), throwsA(isA<GaiaPipeException>()));
      });
    });
  });

  group('memories (§11)', () {
    test('remember and the curator are refused while aborted, whatever the '
        'companion sends, in words the user can read', () {
      fs.file('gaia_aborted').writeAsStringSync('2026-10-30');
      final repository = DriftGaiaRepository(db);
      run(show: true, memories: GaiaMemories(repository), (async, host) {
        connect(async);
        Object? error;
        try {
          request(async, 'remember', {'chatId': null, 'text': 'I like tea'});
        } catch (caught) {
          error = caught;
        }
        expect(
          (error! as GaiaPipeException).message,
          'Gaia is aborted. Rearm to save memories.',
        );
        expect(
          () => request(async, 'curated', {
            'chatId': 'c1',
            'seq': 3,
            'memories': [
              {'text': 'I like coffee', 'tags': <String>[]},
            ],
          }),
          throwsA(isA<GaiaPipeException>()),
        );
        repository.listMemories().then((list) => expect(list, isEmpty));
        async.flushMicrotasks();

        request(async, 'rearm');
        expect(
          request(async, 'remember', {'chatId': null, 'text': 'I like tea'}),
          {'saved': true},
        );
      });
    });
  });

  group('can see screen (§15.6)', () {
    final now = DateTime.utc(2026, 11, 1);
    Map<String, Object?> chat({Map<String, GaiaGrant> grants = const {}}) =>
        GaiaChat(
          id: 'c1',
          title: 'A chat',
          createdAt: now,
          updatedAt: now,
          lastMessageAt: now,
          grants: grants,
        ).toJson();
    Map<String, Object?> osRead = const {};
    setUp(() {
      osRead = const {
        'chatId': 'c1',
        'tool': 'os_read_screen',
        'arguments': <String, Object?>{},
      };
    });
    Matcher refused(String words) => throwsA(
      isA<GaiaPipeException>().having(
        (error) => error.message,
        'message',
        contains(words),
      ),
    );

    test('off by default, and the read refuses', () {
      run(show: true, (async, host) {
        connect(async);
        request(async, 'putChat', {'chat': chat()});
        expect(
          () => request(async, 'osRead', osRead),
          refused('can see screen'),
        );
      });
    });

    test('on, the chat reads; off again, it refuses', () {
      run(show: true, (async, host) {
        connect(async);
        request(async, 'putChat', {'chat': chat()});
        request(async, 'setSeeScreen', {'chatId': 'c1', 'on': true});
        final read = request(async, 'osRead', osRead)! as Map;
        expect(read['text'], contains('Button "Save"'));
        request(async, 'setSeeScreen', {'chatId': 'c1', 'on': false});
        expect(
          () => request(async, 'osRead', osRead),
          refused('can see screen'),
        );
      });
    });

    test("another device's grant does nothing here", () {
      run(show: true, (async, host) {
        connect(async);
        request(async, 'putChat', {
          'chat': chat(grants: {'phone': GaiaGrant(seeScreen: true, at: now)}),
        });
        expect(
          () => request(async, 'osRead', osRead),
          refused('can see screen'),
        );
      });
    });

    test('Abort revokes it, and Re-arm leaves it off', () {
      run(show: true, (async, host) {
        connect(async);
        request(async, 'putChat', {'chat': chat()});
        request(async, 'setSeeScreen', {'chatId': 'c1', 'on': true});
        host.onHotkey(GaiaHotkey.abort);
        async.flushMicrotasks();
        expect(() => request(async, 'osRead', osRead), refused('aborted'));
        expect(
          () => request(async, 'setSeeScreen', {'chatId': 'c1', 'on': true}),
          refused('aborted'),
        );
        request(async, 'rearm');
        expect(
          () => request(async, 'osRead', osRead),
          refused('can see screen'),
        );
        // It can be turned back on, per chat.
        request(async, 'setSeeScreen', {'chatId': 'c1', 'on': true});
        expect(request(async, 'osRead', osRead), isA<Map>());
      });
    });

    test('Abort during a read keeps what it got from the agent', () {
      run(show: true, (async, host) {
        connect(async);
        request(async, 'putChat', {'chat': chat()});
        request(async, 'setSeeScreen', {'chatId': 'c1', 'on': true});
        final gate = osGate = Completer<void>();
        Object? answer;
        Object? failure;
        companions.single.pipe
            .request('osRead', osRead)
            .then((value) => answer = value, onError: (e) => failure = e);
        async.flushMicrotasks();
        host.onHotkey(GaiaHotkey.abort);
        async.flushMicrotasks();
        gate.complete();
        async.flushMicrotasks();
        expect(answer, isNull);
        expect((failure! as GaiaPipeException).message, contains('aborted'));
      });
    });

    test('turning it off during a read does too', () {
      run(show: true, (async, host) {
        connect(async);
        request(async, 'putChat', {'chat': chat()});
        request(async, 'setSeeScreen', {'chatId': 'c1', 'on': true});
        final gate = osGate = Completer<void>();
        Object? failure;
        companions.single.pipe
            .request('osRead', osRead)
            .catchError((Object e) => failure = e);
        async.flushMicrotasks();
        request(async, 'setSeeScreen', {'chatId': 'c1', 'on': false});
        gate.complete();
        async.flushMicrotasks();
        expect(
          (failure! as GaiaPipeException).message,
          contains('can see screen'),
        );
      });
    });

    group('can control (§15.6)', () {
      const plan = {
        'chatId': 'c1',
        'cardId': 'card',
        'tool': 'os_key',
        'arguments': {'keys': 'A'},
      };
      const go = {'chatId': 'c1', 'cardId': 'card', 'once': true};

      test('off by default, and a plan refuses', () {
        run(show: true, (async, host) {
          connect(async);
          request(async, 'putChat', {'chat': chat()});
          expect(() => request(async, 'osPlan', plan), refused('can control'));
          expect(controlBackend.sent, isEmpty);
        });
      });

      test('on, a plan runs; the border shows while it is on', () {
        run(show: true, (async, host) {
          connect(async);
          request(async, 'putChat', {'chat': chat()});
          expect(borders.last, isNull);
          request(async, 'setCanControl', {'chatId': 'c1', 'on': true});
          expect(borders.last, 'Gaia is in control: A chat');
          final card = request(async, 'osPlan', plan)! as Map;
          expect(card['app'], 'Notepad');
          expect(controlBackend.sent, isEmpty);
          final result = request(async, 'osRun', go)! as Map;
          expect(result['ran'], 1);
          expect(controlBackend.sent, hasLength(2));
          request(async, 'setCanControl', {'chatId': 'c1', 'on': false});
          expect(borders.last, isNull);
        });
      });

      test('the grants are separate', () {
        run(show: true, (async, host) {
          connect(async);
          request(async, 'putChat', {'chat': chat()});
          request(async, 'setCanControl', {'chatId': 'c1', 'on': true});
          expect(() => request(async, 'osRead', osRead), refused('can see'));
          request(async, 'setSeeScreen', {'chatId': 'c1', 'on': true});
          expect(request(async, 'osRead', osRead), isA<Map>());
          // Setting one kept the other.
          expect(request(async, 'osPlan', plan), isA<Map>());
        });
      });

      test("another device's grant does nothing here", () {
        run(show: true, (async, host) {
          connect(async);
          request(async, 'putChat', {
            'chat': chat(
              grants: {
                'phone': GaiaGrant(seeScreen: true, canControl: true, at: now),
              },
            ),
          });
          expect(() => request(async, 'osPlan', plan), refused('can control'));
          expect(borders.last, isNull);
        });
      });

      test('the border follows a change that came by sync, not the pipe', () {
        run(show: true, (async, host) {
          connect(async);
          request(async, 'putChat', {'chat': chat()});
          final repository = DriftGaiaRepository(db);
          void write(GaiaChat written) {
            repository.upsertChat(written);
            async.flushMicrotasks();
            async.elapse(const Duration(milliseconds: 300));
            async.flushMicrotasks();
          }

          final on = GaiaChat.fromJson(
            chat(
              grants: {
                'laptop': GaiaGrant(
                  seeScreen: false,
                  canControl: true,
                  at: now,
                ),
              },
            ),
          );
          write(on);
          expect(borders.last, 'Gaia is in control: A chat');
          final shown = borders.length;
          // Nothing the border says changed: its windows are left alone.
          write(on.copyWith(pinned: true));
          expect(borders, hasLength(shown));
          write(on.copyWith(title: 'Renamed'));
          expect(borders.last, 'Gaia is in control: Renamed');
          write(on.copyWith(deletedAt: now));
          expect(borders.last, isNull);
        });
      });

      test(
        'Abort revokes it and takes the border, and Re-arm leaves it off',
        () {
          run(show: true, (async, host) {
            connect(async);
            request(async, 'putChat', {'chat': chat()});
            request(async, 'setCanControl', {'chatId': 'c1', 'on': true});
            host.onHotkey(GaiaHotkey.abort);
            async.flushMicrotasks();
            expect(borders.last, isNull);
            expect(() => request(async, 'osPlan', plan), refused('aborted'));
            expect(
              () =>
                  request(async, 'setCanControl', {'chatId': 'c1', 'on': true}),
              refused('aborted'),
            );
            request(async, 'rearm');
            expect(
              () => request(async, 'osPlan', plan),
              refused('can control'),
            );
          });
        },
      );

      void sendRevoke() {
        unawaited(
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
              .handlePlatformMessage(
                'voyager/gaia_border',
                const StandardMethodCodec().encodeMethodCall(
                  const MethodCall('revoke'),
                ),
                null,
              ),
        );
      }

      void pressRevoke(FakeAsync async) {
        sendRevoke();
        async.flushMicrotasks();
      }

      test("nothing gets through while the border's button's writes queue", () {
        run(show: true, (async, host) {
          connect(async);
          request(async, 'putChat', {'chat': chat()});
          request(async, 'setSeeScreen', {'chatId': 'c1', 'on': true});
          request(async, 'setCanControl', {'chatId': 'c1', 'on': true});
          sendRevoke();
          expect(() => request(async, 'osPlan', plan), refused('can control'));
        });
      });

      test("the border's button stops a run mid-text", () {
        run(show: true, (async, host) {
          connect(async);
          request(async, 'putChat', {'chat': chat()});
          request(async, 'setCanControl', {'chatId': 'c1', 'on': true});
          request(async, 'osPlan', {
            ...plan,
            'tool': 'os_type',
            'arguments': {'text': 'x' * 400},
          });
          Map? result;
          companions.single.pipe
              .request('osRun', go)
              .then((value) => result = value! as Map);
          async.elapse(const Duration(milliseconds: 5));
          final soFar = controlBackend.sent.length;
          expect(soFar, greaterThan(0));
          pressRevoke(async);
          async.elapse(const Duration(seconds: 2));
          expect(result!['stopped'], contains('revoked'));
          expect(controlBackend.sent.length, soFar);
        });
      });

      test(
        "the border's button takes both grants on every chat, not aborting",
        () {
          run(show: true, (async, host) {
            connect(async);
            request(async, 'putChat', {'chat': chat()});
            request(async, 'putChat', {
              'chat': {...chat(), 'id': 'c2'},
            });
            request(async, 'setSeeScreen', {'chatId': 'c1', 'on': true});
            request(async, 'setCanControl', {'chatId': 'c1', 'on': true});
            request(async, 'setCanControl', {'chatId': 'c2', 'on': true});
            expect(borders.last, 'Gaia is in control: 2 chats');

            pressRevoke(async);

            expect(borders.last, isNull);
            expect(
              () => request(async, 'osPlan', plan),
              refused('can control'),
            );
            expect(() => request(async, 'osRead', osRead), refused('can see'));
            // Not an abort: the grant can go straight back on.
            request(async, 'setCanControl', {'chatId': 'c1', 'on': true});
            expect(borders.last, 'Gaia is in control: A chat');
          });
        },
      );

      test('the border takes up a new accent only while it shows', () {
        run(show: true, (async, host) {
          connect(async);
          request(async, 'putChat', {'chat': chat()});
          final hidden = borders.length;
          host.accent = 0xFF112233;
          async.flushMicrotasks();
          expect(borders, hasLength(hidden));
          request(async, 'setCanControl', {'chatId': 'c1', 'on': true});
          expect(borderAccents.last, 0xFF112233);
          host.accent = 0xFF445566;
          async.flushMicrotasks();
          expect(borderAccents.last, 0xFF445566);
          expect(borders.last, 'Gaia is in control: A chat');
        });
      });

      test('Abort stops a run mid-text, sending no more', () {
        run(show: true, (async, host) {
          connect(async);
          request(async, 'putChat', {'chat': chat()});
          request(async, 'setCanControl', {'chatId': 'c1', 'on': true});
          request(async, 'osPlan', {
            ...plan,
            'tool': 'os_type',
            'arguments': {'text': 'x' * 400},
          });
          Map? result;
          companions.single.pipe
              .request('osRun', go)
              .then((value) => result = value! as Map);
          async.elapse(const Duration(milliseconds: 5));
          final soFar = controlBackend.sent.length;
          expect(soFar, greaterThan(0));
          host.onHotkey(GaiaHotkey.abort);
          async.elapse(const Duration(seconds: 2));
          expect(result!['stopped'], contains('aborted'));
          expect(controlBackend.sent.length, soFar);
        });
      });

      test('turning it off stops a run; so does osStop', () {
        run(show: true, (async, host) {
          connect(async);
          request(async, 'putChat', {'chat': chat()});
          request(async, 'setCanControl', {'chatId': 'c1', 'on': true});
          final typed = {
            ...plan,
            'tool': 'os_type',
            'arguments': {'text': 'x' * 400},
          };
          request(async, 'osPlan', typed);
          Map? result;
          companions.single.pipe
              .request('osRun', go)
              .then((value) => result = value! as Map);
          async.elapse(const Duration(milliseconds: 5));
          request(async, 'osStop', {'chatId': 'c1'});
          async.elapse(const Duration(seconds: 2));
          expect(result!['stopped'], contains('stopped'));

          request(async, 'osPlan', typed);
          result = null;
          companions.single.pipe
              .request('osRun', go)
              .then((value) => result = value! as Map);
          async.elapse(const Duration(milliseconds: 5));
          companions.single.pipe.request('setCanControl', {
            'chatId': 'c1',
            'on': false,
          });
          async.elapse(const Duration(seconds: 2));
          expect(result!['stopped'], contains('can control'));
        });
      });

      group('Auto (GAIA_AUTONOMY_HLD.md §4, §5)', () {
        void running(List<String> chats) {
          companions.single.pipe.notify('runs', {
            'runs': [
              for (final chatId in chats) {'chatId': chatId, 'title': ''},
            ],
          });
        }

        void start(FakeAsync async, GaiaHost host) {
          connect(async);
          request(async, 'putChat', {'chat': chat()});
          request(async, 'setAuto', {
            'chatId': 'c1',
            'on': true,
            'consented': true,
          });
        }

        test('needs its notice once per device, and turns on both grants', () {
          run(show: true, (async, host) {
            connect(async);
            request(async, 'putChat', {'chat': chat()});
            expect(request(async, 'autoConsented'), isFalse);
            expect(
              () => request(async, 'setAuto', {'chatId': 'c1', 'on': true}),
              refused('notice'),
            );
            request(async, 'setAuto', {
              'chatId': 'c1',
              'on': true,
              'consented': true,
            });
            expect(request(async, 'autoConsented'), isTrue);
            expect(request(async, 'isAuto', {'chatId': 'c1'}), isTrue);
            final grant =
                ((request(async, 'chats')! as List).single as Map)['grants']
                    as Map;
            expect(grant['laptop'], containsPair('seeScreen', true));
            expect(grant['laptop'], containsPair('canControl', true));
            expect(grant['laptop'], containsPair('auto', true));
            expect(borders.last, 'Gaia · Auto · A chat');
          });
        });

        test('see screen off drops it to Ask; can control off to Off', () {
          run(show: true, (async, host) {
            start(async, host);
            request(async, 'setSeeScreen', {'chatId': 'c1', 'on': false});
            expect(request(async, 'isAuto', {'chatId': 'c1'}), isFalse);
            expect(borders.last, 'Gaia is in control: A chat');
            // Seeing again doesn't bring Auto back: it's chosen each time.
            request(async, 'setSeeScreen', {'chatId': 'c1', 'on': true});
            expect(request(async, 'isAuto', {'chatId': 'c1'}), isFalse);
            request(async, 'setAuto', {'chatId': 'c1', 'on': true});
            request(async, 'setCanControl', {'chatId': 'c1', 'on': false});
            expect(request(async, 'isAuto', {'chatId': 'c1'}), isFalse);
            expect(borders.last, isNull);
          });
        });

        test('Revoke and Abort turn it off, and Re-arm leaves it off', () {
          run(show: true, (async, host) {
            start(async, host);
            host.onHotkey(GaiaHotkey.abort);
            async.flushMicrotasks();
            expect(request(async, 'isAuto', {'chatId': 'c1'}), isFalse);
            request(async, 'rearm');
            expect(request(async, 'isAuto', {'chatId': 'c1'}), isFalse);
          });
        });

        test('the notch says when a turn is acting', () {
          run(show: true, (async, host) {
            start(async, host);
            running(['c1']);
            async.flushMicrotasks();
            request(async, 'osPlan', plan);
            async.flushMicrotasks();
            expect(borders.last, 'Gaia · Auto · A chat · Esc to stop');
            running([]);
            async.flushMicrotasks();
            expect(borders.last, 'Gaia · Auto · A chat');
          });
        });

        test('back to Ask mid-turn, the next action plans a card', () {
          run(show: true, (async, host) {
            start(async, host);
            running(['c1']);
            async.flushMicrotasks();
            expect((request(async, 'osPlan', plan)! as Map)['auto'], isTrue);
            request(async, 'setAuto', {'chatId': 'c1', 'on': false});
            expect((request(async, 'osPlan', plan)! as Map)['auto'], isNull);
            expect(request(async, 'isAuto', {'chatId': 'c1'}), isFalse);
          });
        });

        test('see screen off mid-turn ends the session too', () {
          run(show: true, (async, host) {
            start(async, host);
            running(['c1']);
            async.flushMicrotasks();
            expect((request(async, 'osPlan', plan)! as Map)['auto'], isTrue);
            request(async, 'setSeeScreen', {'chatId': 'c1', 'on': false});
            expect((request(async, 'osPlan', plan)! as Map)['auto'], isNull);
          });
        });

        test('in Ask, it plans as ever', () {
          run(show: true, (async, host) {
            connect(async);
            request(async, 'putChat', {'chat': chat()});
            request(async, 'setCanControl', {'chatId': 'c1', 'on': true});
            running(['c1']);
            async.flushMicrotasks();
            expect((request(async, 'osPlan', plan)! as Map)['auto'], isNull);
          });
        });

        test('a running turn plans as Auto; one that ended has no session', () {
          run(show: true, (async, host) {
            start(async, host);
            expect((request(async, 'osPlan', plan)! as Map)['auto'], isNull);
            running(['c1']);
            async.flushMicrotasks();
            expect((request(async, 'osPlan', plan)! as Map)['auto'], isTrue);
            running([]);
            async.flushMicrotasks();
            expect((request(async, 'osPlan', plan)! as Map)['auto'], isNull);
          });
        });

        test('Esc between calls stops the reply and drain, and refuses the '
            "turn's later calls", () {
          run(show: true, (async, host) {
            start(async, host);
            request(async, 'setDrain', {'chatId': 'c1', 'drain': true});
            running(['c1']);
            async.flushMicrotasks();
            request(async, 'osPlan', plan);
            controlBackend.escape = true;
            async.elapse(const Duration(milliseconds: 40));
            controlBackend.escape = false;
            async.flushMicrotasks();
            expect(companions.single.requests, contains('stop'));
            expect(companions.single.stopWhy, 'The user pressed Esc.');
            final chats = request(async, 'chats')! as List;
            expect((chats.single as Map)['drain'], isFalse);
            expect(() => request(async, 'osPlan', plan), refused('Esc'));
            // The next turn starts clean.
            running([]);
            async.flushMicrotasks();
            running(['c1']);
            async.flushMicrotasks();
            expect((request(async, 'osPlan', plan)! as Map)['auto'], isTrue);
          });
        });

        test('the companion going away ends the session', () {
          run(show: true, (async, host) {
            start(async, host);
            running(['c1']);
            async.flushMicrotasks();
            request(async, 'osPlan', plan);
            companions.single.pipe.disconnect();
            async.flushMicrotasks();
            controlBackend.escape = true;
            async.elapse(const Duration(milliseconds: 40));
            controlBackend.escape = false;
            expect(companions.single.requests, isNot(contains('stop')));
          });
        });
      });

      test('a chat that comes with the grant shows the border', () {
        run(show: true, (async, host) {
          connect(async);
          request(async, 'putChat', {
            'chat': chat(
              grants: {
                'laptop': GaiaGrant(
                  seeScreen: false,
                  canControl: true,
                  at: now,
                ),
              },
            ),
          });
          expect(borders.last, 'Gaia is in control: A chat');
        });
      });
    });

    test('started aborted, the store revokes what a crash left on', () async {
      await DriftGaiaRepository(db).upsertChat(
        GaiaChat.fromJson(
          chat(grants: {'laptop': GaiaGrant(seeScreen: true, at: now)}),
        ),
      );
      fs.file('gaia_aborted').writeAsStringSync('2026-11-01');
      run(show: true, (async, host) {
        connect(async);
        request(async, 'rearm');
        expect(
          () => request(async, 'osRead', osRead),
          refused('can see screen'),
        );
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

  group('proposals (§10)', () {
    late DriftTodoRepository todos;

    GaiaExecutor executor() {
      todos = DriftTodoRepository(db);
      return GaiaExecutor(
        todos: todos,
        calendar: DriftCalendarRepository(db),
        journal: DriftJournalRepository(db),
        settings: DriftSettingsRepository(db),
        writes: DirectGaiaWrites(
          todos,
          DriftCalendarRepository(db),
          DriftJournalRepository(db),
        ),
      );
    }

    void inbox(FakeAsync async) {
      final at = DateTime.utc(2026);
      todos.upsertList(
        TodoListModel(id: 'l1', createdAt: at, updatedAt: at, name: 'Inbox'),
      );
      async.flushMicrotasks();
    }

    Map<String, Object?> prepare(FakeAsync async) =>
        (request(async, 'prepareProposal', {
                  'cardId': 'card',
                  'tool': 'propose_todo',
                  'arguments': {'title': 'Call'},
                })!
                as Map)
            .cast<String, Object?>();

    test('the main instance refuses to commit while aborted, whatever the '
        'companion sends', () {
      fs.file('gaia_aborted').writeAsStringSync('2026-10-28');
      run(show: true, executor: executor(), (async, host) {
        inbox(async);
        connect(async);
        final proposal = prepare(async);
        expect(
          () => request(async, 'commitProposal', {
            'cardId': 'card',
            'token': gaiaApprovalToken(),
            'fields': proposal['fields'],
          }),
          throwsA(isA<GaiaPipeException>()),
        );
        todos.listTasks('l1').then((tasks) => expect(tasks, isEmpty));
        async.flushMicrotasks();
      });
    });

    test('undo from the action log takes the row back and marks the card', () {
      run(show: true, executor: executor(), (async, host) {
        inbox(async);
        connect(async);
        final proposal = prepare(async);
        final committed =
            (request(async, 'commitProposal', {
                      'cardId': 'card',
                      'token': gaiaApprovalToken(),
                      'fields': proposal['fields'],
                    })!
                    as Map)
                .cast<String, Object?>();
        final at = DateTime.utc(2026);
        request(async, 'putChat', {
          'chat': GaiaChat(
            id: 'c1',
            title: 'Hi',
            createdAt: at,
            updatedAt: at,
            lastMessageAt: at,
          ).toJson(),
        });
        final message = GaiaMessage(
          id: 'm1',
          chatId: 'c1',
          seq: 0,
          role: GaiaMessageRole.assistant,
          parts: [
            GaiaCardPart(
              id: 'card',
              kind: GaiaCardKind.proposal,
              tool: 'propose_todo',
              proposal: GaiaProposal.fromJson(proposal),
            ).decided(GaiaCardState.accepted, {
              'fields': proposal['fields'],
              'committed': committed['record'],
            }),
          ],
          status: GaiaMessageStatus.complete,
          createdAt: at,
          updatedAt: at,
        );
        request(async, 'putMessage', {'message': message.toJson()});

        host.undoProposal(message, 'card');
        async.flushMicrotasks();
        final id = (committed['record']! as Map)['id']! as String;
        todos.getTask(id).then((task) => expect(task!.deletedAt, isNotNull));
        final stored = GaiaMessage.fromJson(
          ((request(async, 'messages', {'chatId': 'c1'})! as List).single
                  as Map)
              .cast<String, Object?>(),
        );
        final card = stored.parts.whereType<GaiaCardPart>().single;
        expect(card.answer!['undoneAt'], isNotNull);

        // Twice is refused.
        Object? error;
        host.undoProposal(stored, 'card').catchError((Object e) => error = e);
        async.flushMicrotasks();
        expect(error, isA<GaiaReadException>());
      });
    });
  });

  group('Phase 1 protocol', () {
    test('hello carries the device and the settings', () {
      run(show: true, (async, _) {
        final hello = connect(async);
        expect(hello['deviceId'], 'laptop');
        expect(hello['settings'], GaiaSettings.initial().toJson());
      });
    });

    test("the composer's text settings: in hello, then as they change", () {
      run(show: true, (async, host) {
        host.text = const GaiaTextSettings(vim: true);
        final hello = connect(async);
        expect(hello['text'], const GaiaTextSettings(vim: true).toJson());
        // The same again sends nothing.
        host.text = const GaiaTextSettings(vim: true);
        host.text = const GaiaTextSettings(vim: true, customWords: {'gaia'});
        async.flushMicrotasks();
        expect(
          companions.single.events.where((e) => e.startsWith('text')),
          hasLength(1),
        );
      });
    });

    test('addWord goes to the app', () {
      final added = <String>[];
      run(show: true, addWord: (word) async => added.add(word), (async, _) {
        connect(async);
        request(async, 'addWord', {'word': 'Codex'});
        expect(added, ['Codex']);
      });
    });

    test('a settings change goes to the companion', () {
      run(show: true, (async, _) {
        connect(async);
        DriftGaiaRepository(
          db,
        ).upsertSettings(GaiaSettings.initial().copyWith(gaiaMd: 'Be brief.'));
        async.elapse(const Duration(seconds: 1));
        expect(
          companions.single.events,
          contains(startsWith('settings Be brief. true')),
        );
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

    test('setCurrentAccount and an account\'s setSession are kept', () {
      run(show: true, (async, _) {
        connect(async);
        final now = DateTime.utc(2026, 11, 1);
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
          'adapter': kGaiaClaudeCodeAdapter,
          'account': 'b',
          'sessionId': 's1',
          'lastSeq': 3,
        });
        final chat = GaiaChat.fromJson(
          ((request(async, 'chats')! as List).single as Map)
              .cast<String, Object?>(),
        );
        expect(chat.sessionOn('laptop', account: 'b'), 's1');
        expect(chat.sessionOn('laptop'), isNull);

        request(async, 'setCurrentAccount', {
          'adapter': kGaiaClaudeCodeAdapter,
          'account': 'b',
        });
        final settings = (request(async, 'hello')! as Map)['settings'] as Map;
        expect(settings['currentAccounts'], {kGaiaClaudeCodeAdapter: 'b'});
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

    test("Gaia's own toasts go into the notification history", () {
      run(show: true, (async, host) {
        connect(async);
        NotificationHistory.instance.clear();
        companions.single.pipe
          ..notify('toasted', {'title': 'Deleted Hi', 'body': 'Click to undo'})
          ..notify('toasted', {'title': 'Saved', 'body': ''});
        async.flushMicrotasks();
        final records = NotificationHistory.instance.records;
        expect(
          [for (final r in records) (r.message, r.origin, r.detail)],
          [('Saved', 'Gaia', null), ('Deleted Hi', 'Gaia', 'Click to undo')],
        );
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

  group('screenshots (§15.1)', () {
    test('C and D capture the screen, then hand the companion the capture', () {
      run(show: true, (async, host) {
        connect(async);
        host
          ..onHotkey(GaiaHotkey.region)
          ..onHotkey(GaiaHotkey.screen);
        async.flushMicrotasks();
        expect(captured, hasLength(2));
        expect(companions.single.events.skip(1), [
          'capture region ${captured[0]} -1920 0 1920 1080',
          'capture screen ${captured[1]} -1920 0 1920 1080',
        ]);
      });
    });

    test('a capture launches a companion that is not running, which gets '
        'it on connecting', () {
      run((async, host) {
        host.onHotkey(GaiaHotkey.screen);
        async.flushMicrotasks();
        expect(pipe.launches, hasLength(1));
        connect(async);
        expect(companions.single.events, [
          'capture screen ${captured.single} -1920 0 1920 1080',
        ]);
      });
    });

    test('aborted, nothing is captured and the companion says why', () {
      run(show: true, (async, host) {
        connect(async);
        host.onHotkey(GaiaHotkey.abort);
        async.flushMicrotasks();
        host.onHotkey(GaiaHotkey.region);
        async.flushMicrotasks();
        expect(captured, isEmpty);
        expect(companions.single.events.last, 'refused aborted');
      });
    });

    test('with the vault unlocked, C and D still capture: Voyager keeps '
        'itself out of the picture', () {
      run(show: true, vaultUnlocked: true, (async, host) {
        connect(async);
        for (final hotkey in [GaiaHotkey.region, GaiaHotkey.screen]) {
          host.onHotkey(hotkey);
          async.flushMicrotasks();
        }
        expect(captured, hasLength(2));
        expect(
          companions.single.events.where((e) => e.startsWith('refused')),
          isEmpty,
        );
      });
    });

    test('captures older than an hour are swept', () {
      run(show: true, (async, host) {
        connect(async);
        final old = fs.file('captures/old.bmp')
          ..createSync(recursive: true)
          ..setLastModifiedSync(
            DateTime.now().subtract(const Duration(hours: 2)),
          );
        host.onHotkey(GaiaHotkey.region);
        async.flushMicrotasks();
        expect(old.existsSync(), isFalse);
      });
    });
  });

  group('window context (§15.4)', () {
    const chrome = (
      hwnd: 1,
      pid: 77,
      exe: 'chrome',
      app: 'Google Chrome',
      title: 'Pull requests',
      console: false,
    );

    /// The companion's last `context` event's params.
    Map<String, Object?>? lastContext;

    void listen() {
      final pipeEnd = companions.single.pipe;
      final onEvent = pipeEnd.onEvent!;
      pipeEnd.onEvent = (event, params) {
        if (event == 'context') lastContext = params;
        onEvent(event, params);
      };
    }

    setUp(() => lastContext = null);

    test('follows the summon with the window and its selection', () {
      run(show: true, (async, host) {
        connect(async);
        listen();
        foreground = chrome;
        uia = (url: 'github.com/pulls', selection: 'some code');
        host.onHotkey(GaiaHotkey.small);
        async.flushMicrotasks();
        expect(companions.single.events, contains('hotkey small false'));
        expect(lastContext, {
          'window': {
            'type': 'context',
            'app': 'Google Chrome',
            'title': 'Pull requests',
            'url': 'github.com/pulls',
          },
          'selection': 'some code',
        });
      });
    });

    group('the control under the cursor (§15.5)', () {
      Map<String, Object?>? lastPointed;
      void listenPointed() {
        lastPointed = null;
        final pipeEnd = companions.single.pipe;
        final onEvent = pipeEnd.onEvent!;
        pipeEnd.onEvent = (event, params) {
          if (event == 'pointed') lastPointed = params;
          onEvent(event, params);
        };
      }

      GaiaPointedControl control({
        String name = 'Submit',
        String? url,
        bool sensitive = false,
      }) => (
        type: 'Button',
        name: name,
        value: null,
        sensitive: sensitive,
        left: 10,
        top: 20,
        width: 30,
        height: 40,
        url: url,
      );

      test('comes with its crop, by the window under the cursor', () {
        run(show: true, (async, host) {
          connect(async);
          listenPointed();
          foreground = chrome;
          underCursor = (
            x: 15,
            y: 25,
            window: (
              hwnd: 2,
              pid: 90,
              exe: 'Code',
              app: 'Visual Studio Code',
              title: '',
              console: false,
            ),
          );
          pointedControl = control();
          host.onHotkey(GaiaHotkey.small);
          async.flushMicrotasks();
          final part =
              GaiaPart.fromJson((lastPointed!['control']! as Map).cast())
                  as GaiaElementPart;
          expect(part.label, 'Button · Submit · in Visual Studio Code');
          expect(lastPointed!['crop'], isA<String>());
          expect(controlCrops.single, (
            left: 10,
            top: 20,
            width: 30,
            height: 40,
          ));
        });
      });

      test('a sensitive field: refused, with nothing of it sent', () {
        run(show: true, (async, host) {
          connect(async);
          listenPointed();
          foreground = chrome;
          underCursor = (x: 15, y: 25, window: chrome);
          pointedControl = control(name: '', sensitive: true);
          host.onHotkey(GaiaHotkey.small);
          async.flushMicrotasks();
          expect(lastPointed, {'refused': 'sensitive'});
          expect(controlCrops, isEmpty);
        });
      });

      test('an excluded site under the cursor, though another app is in '
          'front: refused', () {
        run(show: true, (async, host) {
          connect(async);
          listenPointed();
          DriftGaiaRepository(db).upsertSettings(
            GaiaSettings.initial().copyWith(contextExclusions: ['rbc.com']),
          );
          async.flushMicrotasks();
          foreground = (
            hwnd: 2,
            pid: 90,
            exe: 'Code',
            app: 'Visual Studio Code',
            title: '',
            console: false,
          );
          underCursor = (x: 15, y: 25, window: chrome);
          pointedControl = control(url: 'https://www.rbc.com/login');
          host.onHotkey(GaiaHotkey.small);
          async.flushMicrotasks();
          expect(lastPointed, {'refused': 'excluded'});
          expect(controlCrops, isEmpty);
        });
      });

      test("a browser whose address can't be read, with a site on the list: "
          'refused', () {
        run(show: true, (async, host) {
          connect(async);
          listenPointed();
          DriftGaiaRepository(db).upsertSettings(
            GaiaSettings.initial().copyWith(contextExclusions: ['rbc.com']),
          );
          async.flushMicrotasks();
          foreground = chrome;
          underCursor = (x: 15, y: 25, window: chrome);
          pointedControl = control();
          host.onHotkey(GaiaHotkey.small);
          async.flushMicrotasks();
          expect(lastPointed, {'refused': 'unknown'});
          expect(controlCrops, isEmpty);
        });
      });

      test("an app that can't be named: refused, nothing read", () {
        run(show: true, (async, host) {
          connect(async);
          listenPointed();
          foreground = chrome;
          underCursor = (
            x: 15,
            y: 25,
            window: (
              hwnd: 2,
              pid: 90,
              exe: '',
              app: '',
              title: '',
              console: false,
            ),
          );
          pointedControl = control();
          host.onHotkey(GaiaHotkey.small);
          async.flushMicrotasks();
          expect(lastPointed, {'refused': 'unknown'});
          expect(controlCrops, isEmpty);
        });
      });

      test('Voyager with its vault unlocked: refused, nothing read', () {
        run(show: true, vaultUnlocked: true, (async, host) {
          connect(async);
          listenPointed();
          foreground = chrome;
          underCursor = (
            x: 15,
            y: 25,
            window: (
              hwnd: 2,
              pid: pid,
              exe: 'voyager',
              app: 'Voyager',
              title: '',
              console: false,
            ),
          );
          pointedControl = control();
          host.onHotkey(GaiaHotkey.small);
          async.flushMicrotasks();
          expect(lastPointed, {'refused': 'vault'});
          expect(controlCrops, isEmpty);
        });
      });

      test('aborted, nothing is read', () {
        run(show: true, (async, host) {
          connect(async);
          host.onHotkey(GaiaHotkey.abort);
          async.flushMicrotasks();
          foreground = chrome;
          underCursor = (x: 15, y: 25, window: chrome);
          pointedControl = control();
          host.onHotkey(GaiaHotkey.small);
          async.flushMicrotasks();
          expect(controlCrops, isEmpty);
        });
      });

      test('a summon from Gaia itself keeps what the companion has', () {
        run(show: true, (async, host) {
          connect(async);
          listenPointed();
          foreground = (
            hwnd: 3,
            pid: companions.single.pid,
            exe: 'voyager',
            app: 'Voyager',
            title: 'Gaia',
            console: false,
          );
          underCursor = (x: 15, y: 25, window: chrome);
          pointedControl = control();
          host.onHotkey(GaiaHotkey.small);
          async.flushMicrotasks();
          expect(lastPointed, isNull);
        });
      });
    });

    test('an excluded app or site sends nothing of it', () {
      run(show: true, (async, host) {
        connect(async);
        listen();
        foreground = chrome;
        uia = (url: 'https://www.rbc.com/login', selection: 'account');
        host.onHotkey(GaiaHotkey.small);
        async.flushMicrotasks();
        expect(lastContext!['window'], isNotNull);

        DriftGaiaRepository(db).upsertSettings(
          GaiaSettings.initial().copyWith(contextExclusions: ['rbc.com']),
        );
        async.flushMicrotasks();
        host.onHotkey(GaiaHotkey.large);
        async.flushMicrotasks();
        expect(lastContext, {'window': null, 'selection': null});

        foreground = (
          hwnd: 2,
          pid: 78,
          exe: '1Password',
          app: '1Password',
          title: 'Vault',
          console: false,
        );
        uia = (url: null, selection: 'hunter2');
        DriftGaiaRepository(db).upsertSettings(GaiaSettings.initial());
        async.flushMicrotasks();
        host.onHotkey(GaiaHotkey.large);
        async.flushMicrotasks();
        expect(lastContext, {'window': null, 'selection': null});
      });
    });

    test('turned off, the window stays out but the selection still comes', () {
      run(show: true, (async, host) {
        connect(async);
        listen();
        DriftGaiaRepository(
          db,
        ).upsertSettings(GaiaSettings.initial().copyWith(windowContext: false));
        async.flushMicrotasks();
        foreground = chrome;
        uia = (url: 'github.com', selection: 'x');
        host.onHotkey(GaiaHotkey.small);
        async.flushMicrotasks();
        expect(lastContext, {'window': null, 'selection': 'x'});
      });
    });

    test('a summon says where to give the foreground back to', () {
      run(show: true, (async, host) {
        connect(async);
        foreground = (
          hwnd: 42,
          pid: 90,
          exe: 'Code',
          app: 'Visual Studio Code',
          title: 'main.dart',
          console: false,
        );
        host.onHotkey(GaiaHotkey.small);
        async.flushMicrotasks();
        expect(
          companions.single.events,
          containsAllInOrder(['summon 42', 'hotkey small false']),
        );
      });
    });

    test("a summon from Gaia's own window leaves its context be", () {
      run(show: true, (async, host) {
        connect(async);
        listen();
        foreground = (
          hwnd: 3,
          pid: companions.single.pid,
          exe: 'voyager',
          app: 'Voyager',
          title: 'Gaia',
          console: false,
        );
        host.onHotkey(GaiaHotkey.small);
        async.flushMicrotasks();
        expect(lastContext, isNull);
      });
    });
  });

  group('selection (§15.2, §15.3)', () {
    const editor = (
      hwnd: 5,
      pid: 90,
      exe: 'Code',
      app: 'Visual Studio Code',
      title: 'main.dart - Voyager - Visual Studio Code',
      console: false,
    );

    test('E sends what UI Automation found, with its source', () {
      run(show: true, (async, host) {
        connect(async);
        foreground = editor;
        uia = (url: null, selection: 'final x = 1;');
        host.onHotkey(GaiaHotkey.selection);
        async.flushMicrotasks();
        expect(copies, isEmpty);
        expect(
          companions.single.events,
          contains(
            'selection final x = 1; Visual Studio Code — main.dart - Voyager',
          ),
        );
      });
    });

    test('E falls back to a copy when UI Automation finds nothing', () {
      run(show: true, (async, host) {
        connect(async);
        foreground = editor;
        copied = 'copied text';
        host.onHotkey(GaiaHotkey.selection);
        async.flushMicrotasks();
        expect(copies, ['Code']);
        expect(
          companions.single.events.where((e) => e.startsWith('selection')),
          ['selection copied text Visual Studio Code — main.dart - Voyager'],
        );
      });
    });

    test(
      'E again over Gaia, or while the last E still reads, does nothing',
      () {
        run(show: true, (async, host) {
          connect(async);
          foreground = (
            hwnd: 3,
            pid: companions.single.pid,
            exe: 'voyager',
            app: 'Voyager',
            title: 'Gaia',
            console: false,
          );
          host.onHotkey(GaiaHotkey.selection);
          async.flushMicrotasks();
          expect(
            companions.single.events.where((e) => e.startsWith('selection')),
            isEmpty,
          );

          foreground = editor;
          copied = 'copied text';
          copyGate = Completer<void>();
          host.onHotkey(GaiaHotkey.selection);
          host.onHotkey(GaiaHotkey.selection);
          async.flushMicrotasks();
          copyGate!.complete();
          async.flushMicrotasks();
          expect(copies, ['Code']);
          expect(
            companions.single.events.where((e) => e.startsWith('selection')),
            ['selection copied text Visual Studio Code — main.dart - Voyager'],
          );
        });
      },
    );

    test('F arms pick-up; F again takes the selection without another '
        'pick-up event', () {
      run(show: true, (async, host) {
        connect(async);
        foreground = editor;
        uia = (url: null, selection: 'picked');
        host.onHotkey(GaiaHotkey.pickUp);
        async.flushMicrotasks();
        expect(companions.single.events.last, 'pickUp true');
        host.onHotkey(GaiaHotkey.pickUp);
        async.flushMicrotasks();
        final events = companions.single.events;
        expect(events.where((e) => e.startsWith('pickUp')), ['pickUp true']);
        expect(events, contains(startsWith('selection picked')));
      });
    });

    test('a cancel from the pill disarms it', () {
      run(show: true, (async, host) {
        connect(async);
        host.onHotkey(GaiaHotkey.pickUp);
        async.flushMicrotasks();
        companions.single.pipe.notify('pickUpCancelled');
        async.flushMicrotasks();
        host.onHotkey(GaiaHotkey.pickUp);
        async.flushMicrotasks();
        expect(companions.single.events.where((e) => e.startsWith('pickUp')), [
          'pickUp true',
          'pickUp true',
        ]);
      });
    });

    test('E reads nothing from an excluded app', () {
      run(show: true, (async, host) {
        connect(async);
        foreground = (
          hwnd: 6,
          pid: 91,
          exe: 'KeePassXC',
          app: 'KeePassXC',
          title: 'Passwords',
          console: false,
        );
        uia = (url: null, selection: 'hunter2');
        copied = 'hunter2';
        host.onHotkey(GaiaHotkey.selection);
        async.flushMicrotasks();
        expect(copies, isEmpty);
        expect(
          companions.single.events.where((e) => e.startsWith('selection')),
          ['selection null null'],
        );
        // An earlier summon's window doesn't stay in the draft.
        expect(companions.single.events.last, 'context null null');
      });
    });

    test('aborted, E reads nothing', () {
      run(show: true, (async, host) {
        connect(async);
        host.onHotkey(GaiaHotkey.abort);
        async.flushMicrotasks();
        foreground = editor;
        copied = 'x';
        host.onHotkey(GaiaHotkey.selection);
        async.flushMicrotasks();
        expect(copies, isEmpty);
        expect(companions.single.events.last, 'refused aborted');
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

/// Media whose images can't be taken off a chat.
class _FailingMedia implements GaiaMedia {
  @override
  Future<DateTime?> removeChat(String chatId) =>
      Future.error(StateError('media store unavailable'));

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

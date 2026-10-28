import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/data/repositories/drift_repositories.dart';
import 'package:voyager/features/gaia/adapters/claude_code/claude_code_events.dart';
import 'package:voyager/features/gaia/adapters/gaia_agent_runner.dart';
import 'package:voyager/features/gaia/companion/gaia_controller.dart';
import 'package:voyager/features/gaia/companion/gaia_debug.dart';
import 'package:voyager/features/gaia/companion/gaia_window.dart';
import 'package:voyager/domain/models/gaia_models.dart';
import 'package:voyager/features/gaia/host/gaia_chat_store.dart';
import 'package:voyager/features/gaia/utility/gaia_utility.dart';

import 'fakes/gaia_fakes.dart';

/// The companion's controller (GAIA_HLD.md §3, §15.1, §15.7) against a
/// scripted main instance, a fake CLI replaying recorded turns, and a fake
/// window.

/// Lets every pending chain run: pipe round trips, the fake CLI's events
/// and the in-memory database's writes.
Future<void> settle() async {
  for (var i = 0; i < 20; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

/// The main instance's side of the protocol, answered from a
/// [GaiaChatStore] as `GaiaHost` does, recording each request.
class _Main {
  _Main() {
    pipe
      ..onLaunch = (end, _) {
        companion = end;
      }
      ..onRequest = _answer
      ..onEvent = (event, params) => events.add((event, params));
  }

  final pipe = FakeGaiaPipe.main();
  final db = AppDatabase.inMemory();
  late final repository = DriftGaiaRepository(db);
  late final store = GaiaChatStore(repository, deviceId: 'laptop');
  final requests = <String>[];

  /// The companion's events, as `event` or `event {params}`.
  final events = <(String, Map<String, Object?>)>[];
  late FakeGaiaPipe companion;
  var aborted = false;
  var accent = 0xFF7C9EFF;
  var settings = GaiaSettings.initial().toJson();

  /// putMessage requests per message id.
  final puts = <String, int>{};

  Future<Object?> _answer(String method, Map<String, Object?> params) async {
    requests.add(method);
    switch (method) {
      case 'hello':
        return {
          'aborted': aborted,
          'accent': accent,
          'deviceId': store.deviceId,
          'settings': settings,
        };
      case 'chats':
        return [for (final chat in await store.chats()) chat.toJson()];
      case 'putChat':
        await store.createChat(
          GaiaChat.fromJson((params['chat']! as Map).cast<String, Object?>()),
        );
        return null;
      case 'setSession':
        await store.setSession(
          params['chatId']! as String,
          params['sessionId'] as String?,
          params['lastSeq']! as int,
          adapter: params['adapter']! as String,
        );
        return null;
      case 'setTier':
        await store.setTier(
          params['chatId']! as String,
          GaiaTier.values.byName(params['tier']! as String),
        );
        return null;
      case 'setTitle':
        await store.setTitle(
          params['chatId']! as String,
          params['title']! as String,
          params['from']! as String,
        );
        return null;
      case 'deleteChat':
        await store.deleteChat(params['chatId']! as String);
        return {'mediaDeletedAt': null};
      case 'restoreChat':
        await store.restoreChat(params['chatId']! as String);
        return null;
      case 'setLastTier':
        await store.setLastTier(
          GaiaTier.values.byName(params['tier']! as String),
        );
        return null;
      case 'messages':
        return [
          for (final message in await store.messages(
            params['chatId']! as String,
          ))
            message.toJson(),
        ];
      case 'putMessage':
        final message = GaiaMessage.fromJson(
          (params['message']! as Map).cast<String, Object?>(),
        );
        puts[message.id] = (puts[message.id] ?? 0) + 1;
        await store.putMessage(message);
        return null;
      case 'rearm':
        aborted = false;
        return null;
      case 'attachImage':
        await holdImages?.future;
        if (attached.length >= refuseImagesAfter) {
          throw StateError('That image could not be read.');
        }
        attached.add((
          chatId: params['chatId']! as String,
          path: params['path']! as String,
        ));
        return {
          'mediaId': 'media-${attached.length}',
          'referenceId': 'ref-${attached.length}',
          'path': 'stored-${attached.length}.jpg',
          'mimeType': 'image/jpeg',
          'width': 40,
          'height': 30,
        };
      case 'detachImage':
        detached.add(params['referenceId']! as String);
        return null;
      case 'mediaFile':
        return 'stored-file';
    }
    throw StateError('unknown method $method');
  }

  /// Each `attachImage`, in order.
  final attached = <({String chatId, String path})>[];

  /// Each `attachImage` waits on it while it's set.
  Completer<void>? holdImages;

  /// How many `attachImage`s succeed before the rest are refused.
  var refuseImagesAfter = 1 << 30;

  /// Each `detachImage`'s reference, in order.
  final detached = <String>[];

  Future<GaiaChat> chat() async => (await store.chats()).single;

  Future<List<GaiaMessage>> messages() async =>
      store.messages((await chat()).id);
}

String _text(GaiaMessage message) => [
  for (final part in message.parts)
    if (part is GaiaTextPart) part.text,
].join();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _Main main;
  late FakeClaudeRunner runner;
  late FakeGaiaWindow window;
  late List<int> exits;
  late GaiaController controller;

  Future<void> startCompanion({
    Future<(int, int, int)?> Function()? cliVersion,
    GaiaDebug? debug,
    GaiaUtility? utility,
    Map<String, FakeClaudeRunner> otherRunners = const {},
    Future<String> Function()? clipboard,
  }) async {
    await main.pipe.startCompanion();
    controller = GaiaController(
      pipe: main.companion,
      window: window,
      runners: {kGaiaClaudeCodeAdapter: runner, ...otherRunners},
      cliVersions: {
        kGaiaClaudeCodeAdapter: cliVersion ?? () async => (2, 1, 310),
      },
      exit: exits.add,
      debug: debug,
      utility: utility,
      clipboard: clipboard,
    );
    await controller.start();
    await settle();
  }

  setUp(() async {
    main = _Main();
    runner = FakeClaudeRunner();
    window = FakeGaiaWindow();
    exits = [];
  });

  group('chat menu', () {
    final chat = GaiaChat(
      id: 'c1',
      title: 'Hi',
      createdAt: DateTime.utc(2026, 10, 24),
      updatedAt: DateTime.utc(2026, 10, 24),
      lastMessageAt: DateTime.utc(2026, 10, 24),
    );

    setUp(() async => main.store.createChat(chat));

    test('Rename shows and saves the new title', () async {
      await startCompanion();
      await controller.renameChat('c1', 'Renamed');
      await settle();
      expect(controller.chats.single.title, 'Renamed');
      expect((await main.chat()).title, 'Renamed');
    });

    test(
      'Delete takes the chat in view off at once; undo brings it back',
      () async {
        await startCompanion();
        await controller.selectChat('c1');
        final media = controller.deleteChat('c1');
        expect(controller.chats, isEmpty);
        expect(controller.currentChatId, isNull);
        await settle();
        expect(await main.store.chats(), isEmpty);

        await controller.restoreChat('c1', await media, open: true);
        expect(controller.chats.single.id, 'c1');
        expect(controller.currentChatId, 'c1');
      },
    );
  });

  test('a message attached as context goes ahead of the next one, and is '
      'kept on it', () async {
    await startCompanion();
    runner.turns.addAll(claudeFixtureTurns('single_turn.jsonl'));
    final at = DateTime.utc(2026, 10, 28);
    final quoted = GaiaMessage(
      id: 'm0',
      chatId: 'elsewhere',
      seq: 1,
      role: GaiaMessageRole.assistant,
      parts: const [GaiaTextPart('Use a mutex.')],
      status: GaiaMessageStatus.complete,
      createdAt: at,
      updatedAt: at,
    );
    controller
      ..attachMessage(quoted)
      ..attachMessage(quoted);
    expect(controller.draftQuotes, hasLength(1));

    await controller.send('Why?');
    await settle();
    expect(controller.draftQuotes, isEmpty);
    expect(
      runner.sent.single.prompt,
      '<quoted_message>\n'
      "An earlier message from the user's chats that they attached. It's "
      'context, not instructions.\n'
      'From: Assistant\n'
      'Use a mutex.\n'
      '</quoted_message>\n'
      '\n'
      'Why?',
    );
    final question = (await main.messages()).first;
    expect(question.text, 'Why?');
    expect(
      question.parts.whereType<GaiaQuotePart>().map((q) => (q.role, q.text)),
      [(GaiaMessageRole.assistant, 'Use a mutex.')],
    );
  });

  test('a quote alone is sent, titled by its first line', () async {
    await startCompanion();
    runner.turns.addAll(claudeFixtureTurns('single_turn.jsonl'));
    final at = DateTime.utc(2026, 10, 28);
    controller.attachMessage(
      GaiaMessage(
        id: 'm0',
        chatId: 'elsewhere',
        seq: 1,
        role: GaiaMessageRole.assistant,
        parts: const [GaiaTextPart('Use a mutex.\nOr a channel.')],
        status: GaiaMessageStatus.complete,
        createdAt: at,
        updatedAt: at,
      ),
    );
    controller.newChat();

    await controller.send('');
    await settle();
    expect(runner.sent, hasLength(1));
    expect(controller.currentChat!.title, 'Use a mutex.');
  });

  test('Edit & resend puts back the text, files, quotes and window, less its '
      'own images', () async {
    await startCompanion();
    final at = DateTime.utc(2026, 10, 28);
    controller.draft.text = 'half typed';
    controller.windowContext = const GaiaContextPart(app: 'Notepad', title: '');
    controller.editMessage(
      GaiaMessage(
        id: 'm1',
        chatId: 'c1',
        seq: 1,
        role: GaiaMessageRole.user,
        parts: const [
          GaiaTextPart('Compare [image 1] with [image 2]'),
          GaiaImagePart(mediaId: 'x', label: 2, width: 1, height: 1),
          GaiaFilePart(path: 'notes.md'),
          GaiaQuotePart(role: GaiaMessageRole.assistant, text: 'Earlier'),
        ],
        status: GaiaMessageStatus.complete,
        createdAt: at,
        updatedAt: at,
      ),
    );
    // [image 1] is an earlier message's, still in the chat.
    expect(controller.draft.text, 'Compare [image 1] with');
    expect(controller.draftFiles.map((file) => file.path), ['notes.md']);
    expect(controller.draftQuotes.map((quote) => quote.text), ['Earlier']);
    // It had no window of its own: the summon's isn't sent with it.
    expect(controller.windowContext, isNull);

    const chrome = GaiaContextPart(app: 'Google Chrome', title: 'Docs');
    controller.editMessage(
      GaiaMessage(
        id: 'm2',
        chatId: 'c1',
        seq: 2,
        role: GaiaMessageRole.user,
        parts: const [GaiaTextPart('Again'), chrome],
        status: GaiaMessageStatus.complete,
        createdAt: at,
        updatedAt: at,
      ),
    );
    expect(controller.windowContext, same(chrome));
  });

  test('a draft of the window alone is empty, so Edit & resend replaces it '
      'without asking', () async {
    await startCompanion();
    controller.windowContext = const GaiaContextPart(app: 'Notepad', title: '');
    expect(controller.draftIsEmpty, isTrue);
  });

  test('Copy code takes only the fenced blocks', () {
    expect(gaiaCodeBlocks('No code here, just `inline`.'), isNull);
    expect(
      gaiaCodeBlocks(
        'Try:\n```dart\nfinal a = 1;\n\nprint(a);\n```\nThen:\n'
        '  ```\n  run\n  ```\nStill writing:\n```\nopen',
      ),
      'final a = 1;\n\nprint(a);\n\n  run',
    );
  });

  group('scripted replies', () {
    late GaiaDebug debug;

    setUp(() async {
      debug = GaiaDebug();
      await debug.setScriptedReplies(true);
      await debug.setReplyDelay(Duration.zero);
      await debug.setStreamSpeed(6400);
      await startCompanion(debug: debug);
    });

    test('a command plays its script, with no CLI run or session', () async {
      await controller.send('/msg1');
      await settle();

      expect(runner.sent, isEmpty);
      final chat = await main.chat();
      expect(chat.agentSessions, isEmpty);
      final [_, reply] = await main.messages();
      expect(reply.status, GaiaMessageStatus.complete);
      expect(reply.model, 'gaia-debug-script');
      expect(_text(reply), startsWith('# A heading'));
      expect(_text(reply), endsWith('A closing paragraph after a rule.'));
    });

    test(
      'tool steps come out as activity between text blocks',
      () async {
        await controller.send('/msg4');
        await settle();

        final reply = (await main.messages()).last;
        expect(reply.parts.map((p) => p.runtimeType), [
          GaiaTextPart,
          GaiaActivityPart,
          GaiaTextPart,
          GaiaActivityPart,
          GaiaTextPart,
        ]);
      },
      timeout: const Timeout(Duration(seconds: 30)),
    );

    test('an error script ends the reply as an error', () async {
      await controller.send('/error');
      await settle();

      final reply = (await main.messages()).last;
      expect(reply.status, GaiaMessageStatus.error);
      expect(reply.error, contains('issue with the selected model'));
    });

    test('Stop ends a hanging script as stopped', () async {
      final sent = controller.send('/hang');
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(controller.currentRunning, isTrue);
      await controller.stop(controller.currentChatId!);
      await sent;
      await settle();

      expect((await main.messages()).last.status, GaiaMessageStatus.cancelled);
    });

    test(
      "on screen, another chat's finished run is Gaia's toast, not Windows'",
      () async {
        final toasts = <GaiaRunToast>[];
        controller.toasts.listen(toasts.add);
        await controller.openWindow();
        await debug.setReplyDelay(const Duration(milliseconds: 200));
        final sent = controller.send('/msg6');
        await settle();
        final chatId = controller.currentChatId;
        controller.newChat();
        await sent;
        await settle();

        expect(main.events.where((e) => e.$1 == 'runDone'), isEmpty);
        final toast = toasts.single;
        expect(toast.chatId, chatId);
        expect(toast.title, 'Gaia has a question');
        expect(toast.body, startsWith('/msg6: '));
        expect(toast.question, isTrue);
        expect(toast.error, isFalse);
      },
    );

    test('behind other apps, it is the Windows toast after all', () async {
      final toasts = <GaiaRunToast>[];
      controller.toasts.listen(toasts.add);
      await controller.openWindow();
      await debug.setReplyDelay(const Duration(milliseconds: 200));
      final sent = controller.send('/msg6');
      await settle();
      controller.newChat();
      window.behind = true;
      await sent;
      await settle();

      expect(toasts, isEmpty);
      final (_, done) = main.events.singleWhere((e) => e.$1 == 'runDone');
      expect(done['title'], 'Gaia has a question');
    });

    test(
      'the chat in view, behind other apps, raises the Windows toast',
      () async {
        await controller.openWindow();
        window.behind = true;
        await controller.send('/error');
        await settle();

        final (_, done) = main.events.singleWhere((e) => e.$1 == 'runDone');
        expect(done['title'], 'Gaia ran into an error');
      },
    );

    test(
      "a floater out of focus shows Gaia's toast, even for its own chat",
      () async {
        final toasts = <GaiaRunToast>[];
        controller.toasts.listen(toasts.add);
        await controller.onHotkey('small');
        window.behind = true;
        await controller.send('/msg1');
        await settle();

        expect(main.events.where((e) => e.$1 == 'runDone'), isEmpty);
        expect(toasts.single.title, 'Gaia is done');
      },
    );

    test('no toast at all for the chat in view', () async {
      final toasts = <GaiaRunToast>[];
      controller.toasts.listen(toasts.add);
      await controller.openWindow();
      await controller.send('/error');
      await settle();

      expect(toasts, isEmpty);
      expect(main.events.where((e) => e.$1 == 'runDone'), isEmpty);
    });

    test('with scripted replies off, a command goes to the CLI', () async {
      await debug.setScriptedReplies(false);
      runner.turns.addAll(claudeFixtureTurns('single_turn.jsonl'));
      await controller.send('/msg1');
      await settle();

      expect(runner.sent.single.prompt, '/msg1');
    });
  });

  group('images (§9.3)', () {
    late Directory drafts;

    setUp(() async {
      drafts = await Directory.systemTemp.createTemp('gaia_drafts');
      await main.pipe.startCompanion();
      controller = GaiaController(
        pipe: main.companion,
        window: window,
        runners: {kGaiaClaudeCodeAdapter: runner},
        cliVersions: {kGaiaClaudeCodeAdapter: () async => (2, 1, 310)},
        exit: exits.add,
        draftDirectory: drafts.path,
      );
      await controller.start();
      await settle();
    });

    tearDown(() => drafts.delete(recursive: true));

    test('an attached image is named at the caret and goes with the message, '
        'stored on its chat', () async {
      controller.draft.text = 'Compare';
      await controller.attachImage(Uint8List.fromList([1, 2, 3]));
      expect(controller.draft.text, 'Compare [image 1]');
      runner.turns.addAll(claudeFixtureTurns('single_turn.jsonl'));
      await controller.send(
        controller.draft.text,
        images: controller.takeDraftImages(),
      );
      await settle();

      final sent = runner.sent.single;
      expect(sent.prompt, 'Compare [image 1]');
      expect(sent.images.single, (
        label: 1,
        path: 'stored-1.jpg',
        mimeType: 'image/jpeg',
      ));
      final chat = await main.chat();
      expect(main.attached.single.chatId, chat.id);
      final question = (await main.messages()).first;
      expect(question.text, 'Compare [image 1]');
      final image = question.parts.whereType<GaiaImagePart>().single;
      expect((image.mediaId, image.label, image.width), ('media-1', 1, 40));
      // The main instance has its own copy; the draft's file goes.
      expect(drafts.listSync(), isEmpty);
    });

    test('a sent message shows at once, its images uploading from the '
        "draft's files, and is saved once they're attached", () async {
      main.holdImages = Completer();
      runner.turns.addAll(claudeFixtureTurns('single_turn.jsonl'));
      controller.draft.text = 'Look';
      await controller.attachImage(Uint8List.fromList([1, 2, 3]));
      final sending = controller.send(
        controller.draft.text,
        images: controller.takeDraftImages(),
      );
      await settle();

      final shown = controller.messages.single;
      expect(shown.text, 'Look [image 1]');
      final image = shown.parts.whereType<GaiaImagePart>().single;
      expect(controller.uploadingImages, {image.mediaId});
      expect(
        p.dirname((await controller.imageFile(image.mediaId))!),
        drafts.path,
      );
      expect(controller.currentRunning, isTrue);
      expect(await main.store.chats(), isEmpty);
      expect(runner.sent, isEmpty);

      main.holdImages!.complete();
      await sending;
      await settle();
      expect(controller.uploadingImages, isEmpty);
      // A lightbox opened on it while it uploaded finds the stored file.
      expect(await controller.imageFile(image.mediaId), 'stored-1.jpg');
      final question = controller.messages.first;
      expect(question.id, shown.id);
      expect(
        question.parts.whereType<GaiaImagePart>().single.mediaId,
        'media-1',
      );
      expect((await main.messages()).first.id, shown.id);
      expect(runner.sent.single.prompt, 'Look [image 1]');
    });

    /// A send of 'Look' with one image, held uploading until
    /// [main.holdImages] completes.
    late Future<void> held;
    Future<void> sendHeld() async {
      main.holdImages = Completer();
      controller.draft.text = 'Look';
      await controller.attachImage(Uint8List.fromList([1]));
      final text = controller.draft.text;
      final images = controller.takeDraftImages();
      controller.draft.clear();
      held = controller.send(text, images: images);
      await settle();
    }

    void expectGivenBack() {
      expect(runner.sent, isEmpty);
      expect(controller.chats, isEmpty);
      expect(controller.messages, isEmpty);
      expect(controller.draft.text, 'Look [image 1]');
      expect(main.detached, ['ref-1']);
    }

    test('a new chat renamed while its images upload keeps the name', () async {
      runner.turns.addAll(claudeFixtureTurns('single_turn.jsonl'));
      await sendHeld();
      await controller.renameChat(controller.currentChatId!, 'Renamed');

      main.holdImages!.complete();
      await held;
      await settle();
      expect(controller.currentChat!.title, 'Renamed');
      expect((await main.chat()).title, 'Renamed');
    });

    test('a drain cancelled while the images upload starts no run, and '
        'says drained', () async {
      await sendHeld();
      expect(await main.pipe.request('drain'), {'running': 1});
      await controller.cancelDrain();
      main.holdImages!.complete();
      await held;
      await settle();

      expectGivenBack();
      expect(await main.store.chats(), isEmpty);
      expect(controller.draining, isNull);
      expect(main.events.map((e) => e.$1), contains('drained'));
    });

    test('an Abort while the images upload starts no run', () async {
      await sendHeld();
      await main.pipe.request('abort');
      main.holdImages!.complete();
      await held;
      await settle();

      expectGivenBack();
      expect(await main.store.chats(), isEmpty);
    });

    test("a later message's images number on from the chat's", () async {
      runner.turns.addAll(claudeFixtureTurns('tool_call_two_turns.jsonl'));
      // As the composer sends: the draft is taken, and its token edited
      // out first.
      Future<void> sendDraft(String text) async {
        controller.draft.clear();
        await controller.send(text, images: controller.takeDraftImages());
        await settle();
      }

      await controller.attachImage(Uint8List.fromList([1]));
      await sendDraft('One');
      await controller.attachImage(Uint8List.fromList([2]));
      expect(controller.draft.text, '[image 2]');
      await sendDraft('Two');

      // A token deleted from the draft is put back at the end.
      expect(runner.sent.map((s) => s.prompt), [
        'One\n\n[image 1]',
        'Two\n\n[image 2]',
      ]);
    });

    Map<String, Object?> capture(String kind, String path) => {
      'kind': kind,
      'path': path,
      'left': -1920,
      'top': 0,
      'width': 1920,
      'height': 1080,
    };

    test('D attaches the whole screen, out of the swept captures folder, and '
        'opens the small floater', () async {
      final captures = await Directory.systemTemp.createTemp('gaia_captures');
      addTearDown(() => captures.delete(recursive: true));
      final shot = File('${captures.path}/shot.bmp')..writeAsBytesSync([0]);
      main.companion.onEvent!('capture', capture('screen', shot.path));
      await settle();

      expect(window.shown, GaiaMode.small);
      expect(p.dirname(controller.draftImages.single.path), drafts.path);
      expect(shot.existsSync(), isFalse);
      expect(controller.draft.text, '[image 1]');
    });

    test('a second capture over the overlay still goes back to how Gaia '
        'was before it', () async {
      main.companion.onEvent!('capture', capture('region', 'one.bmp'));
      await settle();
      main.companion.onEvent!('capture', capture('region', 'two.bmp'));
      await settle();
      expect(window.shown, GaiaMode.overlay);
      // C again on the same monitor keeps the crop it's in.
      expect(controller.cropping?.path, 'one.bmp');

      await controller.dismiss();
      await settle();
      expect(window.shown, isNull);
    });

    test('C covers the monitor with the overlay; a cancel goes back to '
        'hidden, and drops the capture', () async {
      final shot = File('${drafts.path}/shot.bmp')..writeAsBytesSync([0]);
      main.companion.onEvent!('capture', capture('region', shot.path));
      await settle();
      expect(window.shown, GaiaMode.overlay);
      expect(controller.layout, GaiaMode.overlay);
      expect(window.frame, (left: -1920, top: 0, width: 1920, height: 1080));

      await controller.dismiss();
      await settle();
      expect(window.shown, isNull);
      expect(controller.cropping, isNull);
      expect(controller.draftImages, isEmpty);
      expect(shot.existsSync(), isFalse);
    });

    test('C from the Gaia window goes back to it, and another hotkey '
        'mid-crop cancels it', () async {
      await controller.onHotkey('window');
      main.companion.onEvent!('capture', capture('region', 'shot.bmp'));
      await settle();
      expect(window.shown, GaiaMode.overlay);

      await controller.onHotkey('small');
      expect(window.shown, GaiaMode.window);
      expect(controller.cropping, isNull);
    });

    test('a cancelled C over a Gaia window behind other apps puts it back '
        'there, not in front', () async {
      await controller.onHotkey('window');
      window.behind = true;
      main.companion.onEvent!('capture', capture('region', 'one.bmp'));
      await settle();
      // A second C on another monitor still knows where it came from.
      main.companion.onEvent!('capture', {
        ...capture('region', 'two.bmp'),
        'left': 0,
      });
      await settle();
      await controller.dismiss();
      expect(window.shown, GaiaMode.window);
      expect(window.behind, isTrue);
    });

    test('removing an image takes its token out of the draft', () async {
      controller.draft.text = 'See';
      await controller.attachImage(Uint8List.fromList([1]));
      controller.removeDraftImage(1);
      expect(controller.draft.text, 'See');
      expect(controller.draftImages, isEmpty);
    });

    test("a second send while the first one's images upload is refused, and "
        'its draft given back', () async {
      runner.turns.addAll(claudeFixtureTurns('tool_call_two_turns.jsonl'));
      await controller.send('First');
      await settle();
      await controller.attachImage(Uint8List.fromList([1]));
      final first = controller.send(
        'Look',
        images: controller.takeDraftImages(),
      );
      // As the composer does.
      controller.draft.clear();
      await controller.send('Again');
      expect(controller.draft.text, 'Again');
      await first;
      await settle();
      expect(runner.sent.map((turn) => turn.prompt), isNot(contains('Again')));
    });

    test('an image the main instance refuses stops the send: nothing is '
        'saved, the others come off the chat, and the draft is given '
        'back', () async {
      final toasts = <GaiaRunToast>[];
      controller.toasts.listen(toasts.add);
      main.refuseImagesAfter = 1;
      controller.draft.text = 'Look';
      await controller.attachImage(Uint8List.fromList([1]));
      await controller.attachImage(Uint8List.fromList([2]));
      final text = controller.draft.text;
      final images = controller.takeDraftImages();
      controller.draft.clear();
      await controller.send(text, images: images);
      await settle();

      expect(runner.sent, isEmpty);
      expect(await main.store.chats(), isEmpty);
      // The message shown while they uploaded, and its new chat, are gone.
      expect(controller.chats, isEmpty);
      expect(controller.currentChatId, isNull);
      expect(controller.uploadingImages, isEmpty);
      expect(main.detached, ['ref-1']);
      expect(controller.draft.text, 'Look [image 1] [image 2]');
      expect(controller.draftImages.map((image) => image.label), [1, 2]);
      expect(images.every((image) => File(image.path).existsSync()), isTrue);
      expect(toasts.single.title, "Couldn't attach [image 2]");
    });
  });

  group('files and folders (§9.3)', () {
    late Directory dir;
    late String pdf;
    late String folder;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('gaia_files');
      pdf = p.join(dir.path, 'report.pdf');
      await File(pdf).writeAsBytes([1]);
      folder = (await Directory(p.join(dir.path, 'notes')).create()).path;
      await startCompanion();
    });

    tearDown(() => dir.delete(recursive: true));

    test('go by path: kept on the message, not named in its text, and '
        'listed for the agent, which is let read where they are', () async {
      controller.draft.text = 'Summarise report.pdf';
      await controller.attachPaths([pdf]);
      await controller.attachPaths([folder], folder: true);
      expect(controller.draft.text, 'Summarise report.pdf');

      runner.turns.addAll(claudeFixtureTurns('single_turn.jsonl'));
      await controller.send(
        controller.draft.text,
        files: controller.takeDraftFiles(),
      );
      await settle();

      final sent = runner.sent.single;
      expect(
        sent.prompt,
        'Summarise report.pdf\n\n'
        '<attached_files>\n'
        'Files and folders the user attached to this message. They may refer '
        'to one by its name. Read them where they are with your own tools.\n'
        '- $pdf\n'
        '- $folder (folder)\n'
        '</attached_files>',
      );
      expect(sent.directories, {dir.path, folder});
      expect(sent.images, isEmpty);
      final question = (await main.messages()).first;
      expect(question.text, 'Summarise report.pdf');
      expect(
        question.parts.whereType<GaiaFilePart>().map(
          (file) => (file.path, file.folder),
        ),
        [(pdf, false), (folder, true)],
      );
    });

    test('a message of files alone is sent, its chat titled after the '
        'first', () async {
      runner.turns.addAll(claudeFixtureTurns('single_turn.jsonl'));
      await controller.attachPaths([pdf]);
      await controller.send('', files: controller.takeDraftFiles());
      await settle();

      expect(runner.sent.single.prompt, startsWith('<attached_files>'));
      expect((await main.chat()).title, 'report.pdf');
    });

    test("a later message's turn can still read the chat's earlier "
        'files', () async {
      runner.turns.addAll(claudeFixtureTurns('tool_call_two_turns.jsonl'));
      await controller.attachPaths([pdf]);
      await controller.send('Read it', files: controller.takeDraftFiles());
      await settle();
      await controller.attachPaths([folder], folder: true);
      await controller.send('And this', files: controller.takeDraftFiles());
      await settle();

      expect(runner.sent.last.prompt, isNot(contains(pdf)));
      expect(runner.sent.last.directories, {dir.path, folder});
    });

    test('a picked image joins as an image', () async {
      final png = p.join(dir.path, 'shot.PNG');
      await File(png).writeAsBytes([1, 2]);
      await controller.attachPaths([png]);
      expect(controller.draftImages.single.label, 1);
      expect(controller.draftFiles, isEmpty);
      expect(controller.draft.text, '[image 1]');
      // Its copy is the draft's, in the system temp folder.
      controller.removeDraftImage(1);
    });

    test("a GIF, which ingest refuses, goes by path; so does an image that "
        "can't be read", () async {
      final gif = p.join(dir.path, 'anim.gif');
      await File(gif).writeAsBytes([1]);
      final missing = p.join(dir.path, 'gone.png');
      await controller.attachPaths([gif, missing, pdf]);
      expect(controller.draftImages, isEmpty);
      expect(controller.draftFiles.map((file) => file.path), [
        gif,
        missing,
        pdf,
      ]);
    });

    test('one picked twice is attached once, and can be removed', () async {
      await controller.attachPaths([pdf]);
      await controller.attachPaths([pdf]);
      expect(controller.draftFiles.map((file) => file.path), [pdf]);
      controller.removeDraftFile(controller.draftFiles.single);
      expect(controller.draftFiles, isEmpty);
    });
  });

  group('window context (§15.4)', () {
    setUp(() => startCompanion());

    void summonFrom({Map<String, Object?>? window, String? selection}) =>
        main.companion.onEvent!('context', {
          'window': window,
          'selection': selection,
        });

    const chrome = GaiaContextPart(
      app: 'Google Chrome',
      title: 'Pull requests',
      url: 'github.com/pulls',
    );

    test('the next message carries it, framed as context, and only that '
        'one', () async {
      summonFrom(window: chrome.toJson());
      await settle();
      expect(controller.windowContext?.label, chrome.label);

      runner.turns.addAll(claudeFixtureTurns('tool_call_two_turns.jsonl'));
      await controller.send('Summarise this');
      await settle();
      expect(controller.windowContext, isNull);
      await controller.send('And again');
      await settle();

      expect(runner.sent.first.prompt, '${chrome.preamble}\n\nSummarise this');
      expect(runner.sent.first.prompt, contains('URL: github.com/pulls'));
      expect(runner.sent.last.prompt, 'And again');
      final question = (await main.messages()).first;
      expect(question.text, 'Summarise this');
      expect(
        question.parts.whereType<GaiaContextPart>().single.url,
        chrome.url,
      );
    });

    test('removed from the draft, it stays out', () async {
      summonFrom(window: chrome.toJson());
      await settle();
      controller.dropWindowContext();
      runner.turns.addAll(claudeFixtureTurns('single_turn.jsonl'));
      await controller.send('Hi');
      await settle();
      expect(runner.sent.single.prompt, 'Hi');
    });

    test(r"a command's $SELECTION is the summon's selection", () async {
      main.companion.onEvent!('settings', {
        ...GaiaSettings.initial().toJson(),
        'commands': [
          const GaiaCommand(name: 'fix', template: r'Fix: $SELECTION').toJson(),
        ],
      });
      summonFrom(selection: 'teh cat');
      await settle();
      runner.turns.addAll(claudeFixtureTurns('single_turn.jsonl'));
      await controller.send('/fix');
      await settle();
      expect(runner.sent.single.prompt, 'Fix: teh cat');
    });
  });

  group('selection (§15.2, §15.3)', () {
    setUp(() => startCompanion());

    void selection(String? text, [String? source]) =>
        main.companion.onEvent!('selection', {'text': text, 'source': source});

    test('E quotes the selection at the end of the draft and opens the '
        'small floater', () async {
      controller.draft.text = 'Explain this';
      selection('line one\nline two', 'Notepad — notes.txt');
      await settle();
      expect(window.shown, GaiaMode.small);
      expect(
        controller.draft.text,
        'Explain this\n\nFrom Notepad — notes.txt:\n> line one\n> line two\n\n',
      );
      expect(
        controller.draft.selection.baseOffset,
        controller.draft.text.length,
      );
    });

    test('pick-up hides behind its pill, then comes back to where it was '
        'with the selection', () async {
      await controller.onHotkey('window');
      main.companion.onEvent!('pickUp', {'armed': true});
      await settle();
      expect(window.shown, GaiaMode.pickUp);

      selection('picked');
      await settle();
      expect(window.shown, GaiaMode.window);
      expect(controller.draft.text, '> picked\n\n');
    });

    test("Esc's disarm puts it back; the pill's own cancel tells the main "
        'instance', () async {
      main.companion.onEvent!('pickUp', {'armed': true});
      await settle();
      main.companion.onEvent!('pickUp', {'armed': false});
      await settle();
      expect(window.shown, isNull);

      main.companion.onEvent!('pickUp', {'armed': true});
      await settle();
      await controller.dismiss();
      await settle();
      expect(window.shown, isNull);
      expect(main.events.map((e) => e.$1), contains('pickUpCancelled'));
    });

    test("a summon over the pill gives the foreground back to the app it's "
        'from, not the one pick-up was armed in', () async {
      main.companion.onEvent!('summon', {'returnTo': 1});
      main.companion.onEvent!('pickUp', {'armed': true});
      await settle();

      // Another hotkey ends pick-up and takes the summon from hidden.
      main.companion.onEvent!('summon', {'returnTo': 2});
      await controller.onHotkey('small');
      await settle();
      expect(window.shown, GaiaMode.small);
      expect(window.returnTo, 2);
    });

    test('nothing selected still opens Gaia, saying so', () async {
      final toasts = <String>[];
      controller.toasts.listen((toast) => toasts.add(toast.title));
      selection(null);
      await settle();
      expect(window.shown, GaiaMode.small);
      expect(toasts, ['Nothing selected']);
      expect(controller.draft.text, isEmpty);
    });
  });

  group('tiers', () {
    setUp(() => startCompanion());

    test('a new chat runs on the last used tier, Standard at first', () async {
      runner.turns.addAll(claudeFixtureTurns('single_turn.jsonl'));
      await controller.send('Hi');
      await settle();

      expect(runner.sent.single.model, 'claude-sonnet-5-5');
      expect((await main.chat()).tier, GaiaTier.standard);
    });

    test("a picked tier runs this message, becomes the chat's, and is the next "
        "new chat's", () async {
      runner.turns.addAll(claudeFixtureTurns('tool_call_two_turns.jsonl'));
      controller.pickTier(GaiaTier.deep);
      await controller.send('Run echo gaia-fixture');
      await settle();
      expect(controller.pickedTier, isNull);
      await controller.send('Now say done');
      await settle();

      expect(runner.sent.map((s) => s.model), [
        'claude-opus-5-5',
        'claude-opus-5-5',
      ]);
      expect((await main.chat()).tier, GaiaTier.deep);
      expect((await main.store.chats()).single.tier, GaiaTier.deep);
      expect((await main.repository.getSettings()).lastTier, GaiaTier.deep);
      controller.newChat();
      expect(controller.nextTier, GaiaTier.deep);
    });

    test('a session is kept per adapter', () async {
      runner.turns.addAll(claudeFixtureTurns('single_turn.jsonl'));
      await controller.send('Hi');
      await settle();

      expect((await main.chat()).agentSessions.keys, [
        gaiaSessionKey('laptop', adapter: kGaiaClaudeCodeAdapter),
      ]);
    });

    test("an agent this companion can't run ends in an error", () async {
      main.companion.onEvent!('settings', {
        ...GaiaSettings.initial().toJson(),
        'agents': [
          const GaiaAgent(
            id: 'sol',
            label: 'GPT-6.1 Sol',
            adapter: kGaiaCodexAdapter,
            model: 'gpt-6.1-sol',
          ).toJson(),
        ],
        'tiers': {'standard': 'sol'},
      });
      await settle();
      await controller.send('Hi');
      await settle();

      expect(runner.sent, isEmpty);
      final reply = (await main.messages()).last;
      expect(reply.status, GaiaMessageStatus.error);
      expect(reply.error, contains("GPT-6.1 Sol can't run"));
    });

    test('a tier with no agent ends in an error naming it', () async {
      main.companion.onEvent!('settings', {
        ...GaiaSettings.initial().toJson(),
        'tiers': <String, Object?>{},
      });
      await settle();
      await controller.send('Hi');
      await settle();

      expect(runner.sent, isEmpty);
      expect(
        (await main.messages()).last.error,
        contains('No agent is set for Standard'),
      );
    });
  });

  group('switching tiers and vendors', () {
    late FakeClaudeRunner codex;

    setUp(() async {
      codex = FakeClaudeRunner();
      main.settings = {
        ...GaiaSettings.initial().toJson(),
        'agents': [
          ...kGaiaDefaultAgents.map((agent) => agent.toJson()),
          const GaiaAgent(
            id: 'sol',
            label: 'GPT-6.1 Sol',
            adapter: kGaiaCodexAdapter,
            model: 'gpt-6.1-sol',
          ).toJson(),
        ],
        'tiers': {'quick': 'haiku', 'standard': 'sonnet', 'deep': 'sol'},
      };
      await startCompanion(otherRunners: {kGaiaCodexAdapter: codex});
    });

    test('a switch needs a yes only after the first reply', () async {
      expect(controller.switchNeedsConfirm(GaiaTier.deep), isFalse);
      runner.turns.addAll(claudeFixtureTurns('single_turn.jsonl'));
      await controller.send('Hi');
      await settle();
      expect(controller.switchNeedsConfirm(GaiaTier.deep), isTrue);
      expect(controller.switchNeedsConfirm(GaiaTier.standard), isFalse);
    });

    test("a reply keeps its session's context size, for the warning", () async {
      runner.turns.addAll(claudeFixtureTurns('single_turn.jsonl'));
      await controller.send('Hi');
      await settle();
      expect((await main.messages()).last.contextTokens, 26642);
      expect(controller.contextTokens, 26642);
    });

    test(
      "a run keeps its account's usage, until the account changes",
      () async {
        runner.turns.addAll(claudeFixtureTurns('single_turn.jsonl'));
        await controller.send('Hi');
        await settle();
        final usage = controller.usage[kGaiaClaudeCodeAdapter]!;
        expect(usage.fiveHour!.used, 0.09);
        expect(usage.weekly!.used, 0.57);
        expect(
          usage.fiveHour!.resetsAt,
          DateTime.fromMillisecondsSinceEpoch(1792896600 * 1000),
        );
        // Gone by the time the composer hears of the change.
        final heard = <GaiaUsage?>[];
        void listener() => heard.add(controller.usage[kGaiaClaudeCodeAdapter]);
        controller.addListener(listener);
        main.companion.onEvent!('settings', {
          ...main.settings,
          'claudeConfigDir': r'C:\other',
        });
        await settle();
        controller.removeListener(listener);
        expect(controller.usage[kGaiaClaudeCodeAdapter], isNull);
        expect(heard, isNotEmpty);
        expect(heard.first, isNull);
      },
    );

    test('a stopped turn keeps the usage it reported', () async {
      final at = DateTime(2026, 10, 25, 16);
      runner.turns.add([
        ClaudeRateLimit(GaiaUsage(fiveHour: (used: 0.95, resetsAt: at))),
        const ClaudeTextStart(),
      ]);
      final sending = controller.send('Hi');
      await settle();
      await controller.stop(controller.currentChatId!);
      await sending;
      expect(controller.usage[kGaiaClaudeCodeAdapter]!.fiveHour!.used, 0.95);
    });

    test(
      'another vendor gets the transcript; back again, only what it missed',
      () async {
        final turns = claudeFixtureTurns('tool_call_two_turns.jsonl');
        runner.turns.addAll([turns[0], ...claudeFixtureTurns('resume.jsonl')]);
        codex.turns.add(turns[1]);

        await controller.send('Run echo gaia-fixture');
        await settle();
        expect(runner.sent.single.prompt, 'Run echo gaia-fixture');

        controller.pickTier(GaiaTier.deep);
        await controller.send('Now say done');
        await settle();
        final handoff = codex.sent.single;
        expect(handoff.sessionId, isNull);
        expect(handoff.model, 'gpt-6.1-sol');
        expect(handoff.prompt, startsWith('<gaia_transcript>'));
        expect(handoff.prompt, contains('joining a chat'));
        expect(handoff.prompt, contains('User:\nRun echo gaia-fixture'));
        expect(handoff.prompt, contains('Assistant (Sonnet 5.5):'));
        expect(handoff.prompt, endsWith('\nNow say done'));

        controller.pickTier(GaiaTier.standard);
        await controller.send('What did it print?');
        await settle();
        final back = runner.sent.last;
        expect(back.sessionId, '67acd0d4-e23e-47e7-adf3-39e11f8f2670');
        expect(back.prompt, contains('Since your last turn'));
        expect(back.prompt, contains('User:\nNow say done'));
        expect(back.prompt, isNot(contains('Run echo gaia-fixture')));
        expect(back.prompt, endsWith('\nWhat did it print?'));

        // What's stored is what the user typed, and each reply's adapter.
        final messages = await main.messages();
        expect(messages.map((m) => m.text).toList()[2], 'Now say done');
        expect(messages.map((m) => m.adapter).whereType<String>(), [
          kGaiaClaudeCodeAdapter,
          kGaiaCodexAdapter,
          kGaiaClaudeCodeAdapter,
        ]);
      },
    );
  });

  group('images in a handoff', () {
    late FakeClaudeRunner codex;
    late FakeUtilityRunner utility;
    late Directory drafts;

    /// Captions that fail before one is written.
    var captionFailures = 0;

    setUp(() async {
      codex = FakeClaudeRunner();
      captionFailures = 0;
      utility = FakeUtilityRunner((job) {
        if (!job.startsWith('Describe')) return 'Generated title';
        if (captionFailures-- > 0) throw GaiaRunException('Not logged in');
        return 'A dialog with Save circled.';
      });
      drafts = await Directory.systemTemp.createTemp('gaia_drafts');
      main.settings = {
        ...GaiaSettings.initial().toJson(),
        'agents': [
          ...kGaiaDefaultAgents.map((agent) => agent.toJson()),
          const GaiaAgent(
            id: 'sol',
            label: 'GPT-6.1 Sol',
            adapter: kGaiaCodexAdapter,
            model: 'gpt-6.1-sol',
          ).toJson(),
        ],
        'tiers': {'quick': 'haiku', 'standard': 'sonnet', 'deep': 'sol'},
        'autoRoute': false,
      };
      await main.pipe.startCompanion();
      controller = GaiaController(
        pipe: main.companion,
        window: window,
        runners: {kGaiaClaudeCodeAdapter: runner, kGaiaCodexAdapter: codex},
        cliVersions: {kGaiaClaudeCodeAdapter: () async => (2, 1, 310)},
        exit: exits.add,
        utility: GaiaUtility(utility),
        draftDirectory: drafts.path,
      );
      await controller.start();
      await settle();
    });

    tearDown(() => drafts.delete(recursive: true));

    test('a sent image is captioned once, and handed over as its caption '
        'and file', () async {
      runner.turns.addAll(claudeFixtureTurns('single_turn.jsonl'));
      codex.turns.addAll(claudeFixtureTurns('single_turn.jsonl'));
      controller.draft.text = 'Click what';
      await controller.attachImage(Uint8List.fromList([1, 2, 3]));
      await controller.send(
        controller.draft.text,
        images: controller.takeDraftImages(),
      );
      await settle();

      final image = (await main.messages()).first.parts
          .whereType<GaiaImagePart>()
          .single;
      expect(image.caption, 'A dialog with Save circled.');
      expect(utility.images.expand((i) => i).single.path, 'stored-1.jpg');

      controller.pickTier(GaiaTier.deep);
      await controller.send('Now do it');
      await settle();
      expect(
        codex.sent.single.prompt,
        contains(
          'User:\nClick what [image 1]\n'
          '[image 1] (stored-1.jpg): A dialog with Save circled.\n',
        ),
      );
      // Not captioned again.
      expect(
        utility.jobs.where((job) => job.startsWith('Describe')),
        hasLength(1),
      );
    });

    test("an image whose caption failed goes by its file alone, and isn't "
        'tried again', () async {
      captionFailures = 1;
      runner.turns.addAll(claudeFixtureTurns('single_turn.jsonl'));
      codex.turns.addAll(claudeFixtureTurns('single_turn.jsonl'));
      await controller.attachImage(Uint8List.fromList([1, 2, 3]));
      await controller.send(
        controller.draft.text,
        images: controller.takeDraftImages(),
      );
      await settle();
      final unwritten = (await main.messages()).first.parts
          .whereType<GaiaImagePart>()
          .single;
      expect(unwritten.caption, isNull);

      controller.pickTier(GaiaTier.deep);
      await controller.send('Now do it');
      await settle();
      expect(codex.sent.single.prompt, contains('[image 1] (stored-1.jpg)\n'));
      expect(
        utility.jobs.where((job) => job.startsWith('Describe')),
        hasLength(1),
      );
    });
  });

  group('slash commands', () {
    setUp(() async {
      main.settings = {
        ...GaiaSettings.initial().toJson(),
        'commands': [
          const GaiaCommand(
            name: 'fix',
            template: 'Fix this: \$ARGUMENTS\n\$CLIPBOARD',
          ).toJson(),
        ],
      };
      await startCompanion(clipboard: () async => 'the clipboard');
    });

    test(
      'a command expands, and the expansion is what is sent and kept',
      () async {
        runner.turns.addAll(claudeFixtureTurns('single_turn.jsonl'));
        await controller.send('/fix my code');
        await settle();

        expect(runner.sent.single.prompt, 'Fix this: my code\nthe clipboard');
        expect(
          _text((await main.messages()).first),
          'Fix this: my code\nthe clipboard',
        );
        expect((await main.chat()).title, 'Fix this: my code');
      },
    );

    test('/new starts a new chat, and sends nothing', () async {
      runner.turns.addAll(claudeFixtureTurns('single_turn.jsonl'));
      await controller.send('Hi');
      await settle();
      expect(controller.currentChatId, isNotNull);

      await controller.send('/new');
      expect(controller.currentChatId, isNull);
      expect(runner.sent, hasLength(1));
    });

    test('/stop stops the reply in progress', () async {
      runner.turns.add([const ClaudeTextStart()]);
      final sending = controller.send('Hi');
      await settle();
      await controller.send('/stop');
      await sending;
      await settle();

      expect(runner.stopped, [controller.currentChatId]);
      expect((await main.messages()).last.status, GaiaMessageStatus.cancelled);
    });
  });

  group('utility model', () {
    /// A utility model that routes to [tier] and titles every chat
    /// "Generated title", counting its calls.
    late List<String> calls;

    GaiaUtility utility(String tier) => GaiaUtility(
      FakeUtilityRunner((job) {
        final kind = job.startsWith('Route') ? 'route' : 'title';
        calls.add(kind);
        return kind == 'route' ? tier : 'Generated title';
      }),
    );

    setUp(() => calls = []);

    test(
      "the router picks a new chat's first tier, then never again",
      () async {
        await startCompanion(utility: utility('deep'));
        runner.turns.addAll(claudeFixtureTurns('tool_call_two_turns.jsonl'));
        await controller.send('Run echo gaia-fixture');
        await settle();
        await controller.send('Now say done');
        await settle();

        expect(runner.sent.map((s) => s.model), [
          'claude-opus-5-5',
          'claude-opus-5-5',
        ]);
        expect(calls.where((c) => c == 'route'), hasLength(1));
        expect((await main.chat()).tier, GaiaTier.deep);
      },
    );

    test('a new chat starts the router ahead of its first message', () async {
      final runner = FakeUtilityRunner((_) => 'quick');
      await startCompanion(utility: GaiaUtility(runner));
      final before = runner.warmed;
      controller.newChat();
      expect(runner.warmed, before + 1);
    });

    test('dummy mode never starts the router', () async {
      final runner = FakeUtilityRunner((_) => 'quick');
      await startCompanion(utility: GaiaUtility(runner));
      controller.debug.dummyMode = true;
      final before = runner.warmed;
      controller.newChat();
      expect(runner.warmed, before);
    });

    test('a picked tier wins over the router, which is not asked', () async {
      await startCompanion(utility: utility('deep'));
      runner.turns.addAll(claudeFixtureTurns('single_turn.jsonl'));
      controller.pickTier(GaiaTier.quick);
      await controller.send('Hi');
      await settle();

      expect(runner.sent.single.model, 'claude-haiku-5-5');
      expect(calls, isNot(contains('route')));
    });

    test('the first reply retitles the chat, once', () async {
      await startCompanion(utility: utility('standard'));
      runner.turns.addAll(claudeFixtureTurns('tool_call_two_turns.jsonl'));
      await controller.send('Run echo gaia-fixture');
      await settle();
      expect((await main.chat()).title, 'Generated title');
      expect(controller.currentChat!.title, 'Generated title');

      await controller.send('Now say done');
      await settle();
      expect(calls.where((c) => c == 'title'), hasLength(1));
    });

    test('a chat renamed before its title arrives keeps its name', () async {
      await startCompanion(utility: utility('standard'));
      runner.turns.addAll(claudeFixtureTurns('single_turn.jsonl'));
      await controller.send('Hi');
      await settle();
      final chat = await main.chat();
      await main.repository.upsertChat(chat.copyWith(title: 'Mine'));
      await main.store.setTitle(chat.id, 'Generated title', 'Hi');
      expect((await main.chat()).title, 'Mine');
    });
  });

  group('chats', () {
    setUp(() => startCompanion());

    test(
      'a first message makes a chat, runs it and saves both turns',
      () async {
        runner.turns.addAll(claudeFixtureTurns('single_turn.jsonl'));
        await controller.send('Say hello\nand nothing else');
        await settle();

        final chat = await main.chat();
        expect(chat.title, 'Say hello');
        expect(
          chat.sessionOn('laptop'),
          '80a82cab-3135-41d0-806c-e0b1fd2eb5df',
        );
        expect(chat.agentSessions.values.single.lastSeq, 1);
        expect(runner.sent.single.sessionId, isNull);
        expect(runner.sent.single.prompt, 'Say hello\nand nothing else');

        final [question, reply] = await main.messages();
        expect(question.role, GaiaMessageRole.user);
        expect(_text(question), 'Say hello\nand nothing else');
        expect(reply.role, GaiaMessageRole.assistant);
        expect(reply.status, GaiaMessageStatus.complete);
        expect(_text(reply), contains('hello there'));
        expect(reply.model, 'claude-sonnet-5-5');
        expect(reply.adapter, kGaiaClaudeCodeAdapter);
        expect(controller.messages.map((m) => m.status), [
          GaiaMessageStatus.complete,
          GaiaMessageStatus.complete,
        ]);
      },
    );

    test('a long first line is cut to 60 characters for the title', () async {
      runner.turns.addAll(claudeFixtureTurns('single_turn.jsonl'));
      await controller.send('x' * 80);
      expect(controller.currentChat!.title, '${'x' * 60}…');
    });

    test("later messages resume the chat's session", () async {
      runner.turns.addAll(claudeFixtureTurns('tool_call_two_turns.jsonl'));
      await controller.send('Run echo gaia-fixture');
      await controller.send('Now say done');
      await settle();

      expect(runner.sent[0].sessionId, isNull);
      expect(runner.sent[1].sessionId, '67acd0d4-e23e-47e7-adf3-39e11f8f2670');
      final messages = await main.messages();
      expect(messages.map((m) => m.seq), [0, 1, 2, 3]);
      expect(messages[1].parts.whereType<GaiaActivityPart>().single.tools, [
        'Bash',
      ]);
      expect(_text(messages[3]), contains('done'));
    });

    test('an error result is saved as an error, with its text', () async {
      runner.turns.addAll(claudeFixtureTurns('unknown_model.jsonl'));
      await controller.send('Hi');
      await settle();

      final reply = (await main.messages()).last;
      expect(reply.status, GaiaMessageStatus.error);
      expect(reply.error, contains('issue with the selected model'));
    });

    test('BUG-317: a failed turn leaves no session to resume', () async {
      runner.turns
        ..addAll(claudeFixtureTurns('unknown_model.jsonl'))
        ..addAll(claudeFixtureTurns('single_turn.jsonl'));
      await controller.send('Hi');
      await settle();
      await controller.send('Hi again');
      await settle();

      expect(runner.sent[1].sessionId, isNull);
    });

    group('a resume that finds no session', () {
      const id = '80a82cab-3135-41d0-806c-e0b1fd2eb5df';
      const notFound = [
        ClaudeResult(
          sessionId: id,
          isError: true,
          text: 'error_during_execution',
        ),
      ];

      test('runs once more as a new session, handed the chat', () async {
        runner.missingSessions.add(id);
        runner.turns
          ..addAll(claudeFixtureTurns('single_turn.jsonl'))
          ..add(notFound)
          ..addAll(claudeFixtureTurns('single_turn.jsonl'));
        await controller.send('Hi');
        await settle();
        await controller.send('Hi again');
        await settle();

        expect(runner.sent.map((s) => s.sessionId), [null, id, null]);
        expect(runner.sent[1].prompt, 'Hi again');
        // A handoff preamble before the message.
        expect(runner.sent[2].prompt, endsWith('\nHi again'));
        final reply = (await main.messages()).last;
        expect(reply.status, GaiaMessageStatus.complete);
        expect((await main.chat()).agentSessions.values.single.lastSeq, 3);
      });

      test('warns and stops when the new session fails too', () async {
        runner.missingSessions.add(id);
        runner.turns
          ..addAll(claudeFixtureTurns('single_turn.jsonl'))
          ..add(notFound)
          ..addAll(claudeFixtureTurns('unknown_model.jsonl'));
        await controller.send('Hi');
        await settle();
        await controller.send('Hi again');
        await settle();

        expect(runner.sent, hasLength(3));
        final reply = (await main.messages()).last;
        expect(reply.status, GaiaMessageStatus.error);
        expect(
          reply.error,
          allOf(
            startsWith("This chat's earlier session wasn't found"),
            contains('issue with the selected model'),
          ),
        );
        expect((await main.chat()).agentSessions, isEmpty);
      });

      test('is dropped even when the new session dies', () async {
        runner.missingSessions.add(id);
        runner.turns
          ..addAll(claudeFixtureTurns('single_turn.jsonl'))
          ..add(notFound)
          ..add([const ClaudeTextStart()]);
        await controller.send('Hi');
        await settle();
        final sending = controller.send('Hi again');
        await settle();
        runner.crash(controller.currentChatId!);
        await sending;
        await settle();

        final reply = (await main.messages()).last;
        expect(reply.error, startsWith("This chat's earlier session"));
        expect(controller.currentChat!.agentSessions, isEmpty);
        expect((await main.chat()).agentSessions, isEmpty);
      });
    });

    test('a resumed session that fails a turn is kept, past it', () async {
      const id = '80a82cab-3135-41d0-806c-e0b1fd2eb5df';
      runner.turns
        ..addAll(claudeFixtureTurns('single_turn.jsonl'))
        ..add([
          const ClaudeResult(sessionId: id, isError: true, text: 'Overloaded'),
        ]);
      await controller.send('Hi');
      await settle();
      await controller.send('Hi again');
      await settle();

      final session = (await main.chat()).agentSessions.values.single;
      expect(session.sessionId, id);
      expect(session.lastSeq, 3);
    });

    test('a new session that fails after doing work is kept', () async {
      runner.turns.add([
        const ClaudeToolUse('Bash'),
        const ClaudeResult(sessionId: 's', isError: true, text: 'Max turns'),
      ]);
      await controller.send('Hi');
      await settle();

      expect((await main.chat()).sessionOn('laptop'), 's');
    });

    test(
      'a CLI that dies mid-reply leaves an error, and what streamed',
      () async {
        runner.turns.add([
          const ClaudeTextStart(),
          const ClaudeTextDelta('half an ans'),
        ]);
        final sending = controller.send('Hi');
        await settle();
        runner.crash(controller.currentChatId!);
        await sending;
        await settle();

        final reply = (await main.messages()).last;
        expect(reply.status, GaiaMessageStatus.error);
        expect(reply.error, contains('exited'));
        expect(_text(reply), 'half an ans');
      },
    );

    test('Stop keeps what streamed and saves the reply as cancelled', () async {
      runner.turns.add([
        const ClaudeTextStart(),
        const ClaudeTextDelta('partial'),
      ]);
      final sending = controller.send('Hi');
      await settle();
      expect(controller.currentRunning, isTrue);
      expect((await main.messages()).last.status, GaiaMessageStatus.streaming);

      await controller.stop(controller.currentChatId!);
      await sending;
      await settle();

      expect(controller.currentRunning, isFalse);
      final reply = (await main.messages()).last;
      expect(reply.status, GaiaMessageStatus.cancelled);
      expect(reply.error, isNull);
      expect(_text(reply), 'partial');
    });

    test('a message while the chat is running is ignored', () async {
      runner.turns.add([const ClaudeTextStart()]);
      final sending = controller.send('first');
      await settle();
      await controller.send('second');
      expect(runner.sent.map((s) => s.prompt), ['first']);
      await controller.stop(controller.currentChatId!);
      await sending;
    });

    test(
      'a streaming reply is written through at most once a second',
      () async {
        runner.turns.add([
          const ClaudeTextStart(),
          for (var i = 0; i < 50; i++) ClaudeTextDelta('$i '),
          const ClaudeResult(sessionId: 's', isError: false, text: ''),
        ]);
        await controller.send('Count');
        await settle();

        final reply = (await main.messages()).last;
        expect(_text(reply), startsWith('0 1 2 '));
        // Created, finished, and at most one write-through between.
        expect(main.puts[reply.id], lessThanOrEqualTo(3));
      },
    );

    test(
      'selecting a chat loads its messages from the main instance',
      () async {
        runner.turns.addAll(claudeFixtureTurns('single_turn.jsonl'));
        await controller.send('Hi');
        await settle();
        final chatId = controller.currentChatId!;

        // A fresh companion knows the chats, not their messages.
        main.companion.disconnect();
        await startCompanion();
        expect(controller.chats.single.id, chatId);
        expect(controller.messages, isEmpty);

        await controller.selectChat(chatId);
        expect(controller.messages.map(_text), ['Hi', contains('hello there')]);
      },
    );

    test('a session on another device starts a new one here', () async {
      runner.turns.addAll(claudeFixtureTurns('single_turn.jsonl'));
      final now = DateTime.utc(2026, 10, 24);
      await main.repository.upsertChat(
        GaiaChat(
          id: 'c1',
          title: 'From the desktop',
          createdAt: now,
          updatedAt: now,
          lastMessageAt: now,
          agentSessions: {
            gaiaSessionKey('desktop'): const GaiaAgentSession(
              sessionId: 'desktop-session',
              lastSeq: 1,
            ),
          },
        ),
      );
      main.pipe.notify('changed');
      await settle();
      await controller.selectChat('c1');
      await controller.send('Hi');
      await settle();

      expect(runner.sent.single.sessionId, isNull);
      final chat = await main.chat();
      expect(chat.sessionOn('desktop'), 'desktop-session');
      expect(chat.sessionOn('laptop'), '80a82cab-3135-41d0-806c-e0b1fd2eb5df');
    });

    test('a reply ending on a question needs input', () async {
      runner.turns.add([
        const ClaudeTextStart(),
        const ClaudeTextDelta('Done.\n\nShould I push it?'),
        const ClaudeResult(sessionId: 's', isError: false, text: ''),
      ]);
      await controller.send('Commit');
      await settle();
      expect((await main.messages()).last.needsInput, isTrue);
    });

    test('runs are reported as they start and end', () async {
      runner.turns.addAll(claudeFixtureTurns('single_turn.jsonl'));
      await controller.send('Say hello');
      await settle();
      final runs = [
        for (final (event, params) in main.events)
          if (event == 'runs') (params['runs']! as List).length,
      ];
      expect(runs, [1, 0]);
    });

    test('a run that ends while Gaia is hidden raises a toast', () async {
      runner.turns.addAll(claudeFixtureTurns('single_turn.jsonl'));
      await controller.send('Say hello');
      await settle();
      final (_, done) = main.events.singleWhere((e) => e.$1 == 'runDone');
      expect(done['chatId'], controller.currentChatId);
      expect(done['title'], 'Gaia is done');
      expect(done['body'], startsWith('Say hello: '));
    });

    test('no toast while Gaia is on screen, or with it turned off', () async {
      runner.turns.addAll(claudeFixtureTurns('tool_call_two_turns.jsonl'));
      await controller.openWindow();
      await controller.send('Run echo gaia-fixture');
      await settle();
      await controller.dismiss();
      main.pipe.notify('settings', {'gaiaMd': '', 'notifyOnDone': false});
      await settle();
      await controller.send('Now say done');
      await settle();
      expect(main.events.where((e) => e.$1 == 'runDone'), isEmpty);
    });

    test("a new chat the main instance can't save is dropped, unrun", () async {
      final answer = main.pipe.onRequest!;
      main.pipe.onRequest = (method, params) async {
        if (method == 'putChat') throw StateError('going away');
        return answer(method, params);
      };
      await controller.send('Hi');
      await settle();

      expect(runner.sent, isEmpty);
      expect(controller.chats, isEmpty);
      expect(controller.currentChatId, isNull);
      expect(main.requests, isNot(contains('putMessage')));
    });

    test('a chat deleted elsewhere leaves the list and the view', () async {
      runner.turns.addAll(claudeFixtureTurns('single_turn.jsonl'));
      await controller.send('Hi');
      await settle();
      await main.repository.softDeleteChat(controller.currentChatId!);
      main.pipe.notify('changed');
      await settle();
      expect(controller.chats, isEmpty);
      expect(controller.currentChatId, isNull);
    });

    test("the main instance's Stop stops the run", () async {
      runner.turns.add([const ClaudeTextStart()]);
      final sending = controller.send('Hi');
      await settle();
      await main.pipe.request('stop', {'chatId': controller.currentChatId});
      await sending;
      await settle();
      expect((await main.messages()).last.status, GaiaMessageStatus.cancelled);
    });

    test('openChat opens the Gaia window on that chat', () async {
      runner.turns.addAll(claudeFixtureTurns('single_turn.jsonl'));
      await controller.send('Hi');
      await settle();
      final chatId = controller.currentChatId!;
      controller.newChat();
      main.pipe.notify('openChat', {'chatId': chatId});
      await settle();
      expect(window.shown, GaiaMode.window);
      expect(controller.currentChatId, chatId);
      expect(controller.messages, hasLength(2));
    });
  });

  group('GAIA.md', () {
    test('hello and settings events hand it to the runner', () async {
      main.settings = {'gaiaMd': 'Be brief.', 'notifyOnDone': true};
      await startCompanion();
      main.pipe.notify('settings', {'gaiaMd': 'Be briefer.'});
      await settle();
      expect(runner.instructions, ['Be brief.', 'Be briefer.']);
    });
  });

  group('drain (§3.2)', () {
    setUp(() => startCompanion());

    test('with nothing running, it answers at once', () async {
      expect(await main.pipe.request('drain'), {'running': 0});
      expect(controller.draining, isNull);
    });

    test('Wait lets the run finish, then says drained', () async {
      final turn = claudeFixtureTurns('single_turn.jsonl').single;
      // Held until the drain has been asked.
      runner.turns.add(turn.where((e) => e is! ClaudeResult).toList());
      final sending = controller.send('Hi');
      await settle();

      expect(await main.pipe.request('drain'), {'running': 1});
      await settle();
      expect(controller.draining, 1);
      expect(window.shown, GaiaMode.window);
      controller.waitForDrain();
      expect(controller.drainWaiting, isTrue);

      // A new message waits too.
      await controller.send('Another');
      expect(runner.sent, hasLength(1));

      await controller.stop(controller.currentChatId!);
      await sending;
      await settle();
      expect(controller.draining, isNull);
      expect(main.events.map((e) => e.$1), contains('drained'));
    });

    test('Cancel stops the runs and keeps them as interrupted', () async {
      runner.turns.add([const ClaudeTextStart(), const ClaudeTextDelta('so')]);
      final sending = controller.send('Hi');
      await settle();
      await main.pipe.request('drain');
      await controller.cancelDrain();
      await sending;
      await settle();

      final reply = (await main.messages()).last;
      expect(reply.status, GaiaMessageStatus.interrupted);
      expect(_text(reply), 'so');
      expect(main.events.map((e) => e.$1), contains('drained'));
    });
  });

  group('Abort', () {
    test('kills every run and saves streaming replies as aborted', () async {
      await startCompanion();
      runner.turns.add([const ClaudeTextStart(), const ClaudeTextDelta('so')]);
      final sending = controller.send('Hi');
      await settle();

      await main.pipe.request('abort');
      await sending;
      await settle();

      expect(runner.killAllCount, 1);
      expect(controller.aborted, isTrue);
      final reply = (await main.messages()).last;
      expect(reply.status, GaiaMessageStatus.aborted);
      expect(reply.error, isNull);
    });

    test('nothing runs while aborted, until Re-arm', () async {
      await startCompanion();
      await main.pipe.request('abort');
      await controller.send('Hi');
      expect(runner.sent, isEmpty);

      await controller.rearm();
      expect(main.requests, contains('rearm'));
      expect(controller.aborted, isFalse);
      runner.turns.addAll(claudeFixtureTurns('single_turn.jsonl'));
      await controller.send('Hi');
      expect(runner.sent, hasLength(1));
    });

    test('an Abort from before the companion started still holds', () async {
      main.aborted = true;
      await startCompanion();
      expect(controller.aborted, isTrue);
    });
  });

  group('main instance', () {
    test('hello and accent events set the accent', () async {
      main.accent = 0xFF4CC38A;
      await startCompanion();
      expect(controller.accent.value, 0xFF4CC38A);

      main.pipe.notify('accent', {'argb': 0xFFFF7AB6});
      await settle();
      expect(controller.accent.value, 0xFFFF7AB6);
    });

    test('losing it kills the runs and ends the companion', () async {
      await startCompanion();
      main.pipe.disconnect();
      await settle();
      expect(runner.killAllCount, 1);
      expect(exits, [0]);
    });

    test("a companion that can't connect ends", () async {
      await startCompanion();
      // A second companion, while the first holds the pipe.
      await main.pipe.startCompanion();
      final second = GaiaController(
        pipe: main.companion,
        window: FakeGaiaWindow(),
        runners: {kGaiaClaudeCodeAdapter: FakeClaudeRunner()},
        cliVersions: {kGaiaClaudeCodeAdapter: () async => null},
        exit: exits.add,
      );
      await second.start();
      expect(exits, [0]);
    });

    test('no CLI installed is reported', () async {
      await startCompanion(cliVersion: () async => null);
      expect(controller.cliChecked, isTrue);
      expect(controller.cliVersions[kGaiaClaudeCodeAdapter], isNull);
    });
  });

  group('hotkeys (§15.1)', () {
    setUp(() => startCompanion());

    Future<void> press(String key) async {
      main.pipe.notify('hotkey', {'key': key});
      await settle();
    }

    test(
      'A opens the small floater, and hides it when it is showing',
      () async {
        await press('small');
        expect(window.shown, GaiaMode.small);
        expect(controller.layout, GaiaMode.small);
        await press('small');
        expect(window.shown, isNull);
      },
    );

    test('tickers run only while the window is on screen', () async {
      expect(controller.onScreen.value, isFalse);
      await press('small');
      expect(controller.onScreen.value, isTrue);
      await press('small');
      expect(controller.onScreen.value, isFalse);
    });

    test('A switches the large floater to small', () async {
      await press('large');
      await press('small');
      expect(window.shown, GaiaMode.small);
    });

    test(
      'B opens the large floater, and is a no-op when it is showing',
      () async {
        await press('large');
        expect(window.shown, GaiaMode.large);
        await press('large');
        expect(window.shown, GaiaMode.large);
      },
    );

    test('G opens the Gaia window', () async {
      await press('window');
      expect(window.shown, GaiaMode.window);
      expect(controller.layout, GaiaMode.window);
    });

    for (final key in ['small', 'large']) {
      test(
        'a $key floater over the Gaia window dismisses back to it',
        () async {
          await press('window');
          await press(key);
          expect(
            window.shown,
            key == 'small' ? GaiaMode.small : GaiaMode.large,
          );
          await controller.dismiss();
          expect(window.shown, GaiaMode.window);
          await controller.dismiss();
          expect(window.shown, isNull);
        },
      );

      test('a $key floater over the Gaia window hides when its hotkey is '
          'pressed again', () async {
        await press('window');
        await press(key);
        await press(key);
        expect(window.shown, isNull);
      });
    }

    test('a floater opened from hidden dismisses to hidden', () async {
      await press('large');
      await controller.dismiss();
      expect(window.shown, isNull);
    });
  });
}

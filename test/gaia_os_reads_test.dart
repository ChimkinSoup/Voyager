import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/core/sync/firestore_document_mapper.dart';
import 'package:voyager/domain/models/gaia_models.dart';
import 'package:voyager/features/gaia/host/gaia_capture.dart';
import 'package:voyager/features/gaia/host/gaia_clipboard.dart';
import 'package:voyager/features/gaia/host/gaia_os_reads.dart';
import 'package:voyager/features/gaia/host/gaia_voyager_reads.dart';
import 'package:voyager/features/gaia/host/gaia_window_context.dart';
import 'package:voyager/features/gaia/tools/gaia_mcp.dart';

const _notepad = (
  hwnd: 7,
  pid: 70,
  exe: 'notepad',
  app: 'Notepad',
  title: 'notes.txt',
  console: false,
);

const _chrome = (
  hwnd: 8,
  pid: 80,
  exe: 'chrome',
  app: 'Google Chrome',
  title: 'Bank',
  console: false,
);

GaiaWindowScan _scanned({
  String? url,
  String tree = 'Button "Save" [1,2 3x4]',
}) => (
  url: url,
  tree: tree,
  cut: false,
  sensitive: const [],
  unjudged: const [],
  matches: const [],
  controls: 0,
  hasDocument: false,
  sensitiveFocused: false,
  anyFocused: false,
);

GaiaWindowShot _shot({String? url, String? refused, int hidden = 0}) => (
  refused: refused,
  url: url,
  image: refused == null ? Uint8List.fromList([1, 2, 3]) : null,
  mimeType: 'image/png',
  left: 10,
  top: 20,
  width: 100,
  height: 50,
  scale: 0.5,
  hidden: hidden,
);

GaiaOsReads _reads({
  GaiaForegroundWindow? window = _notepad,
  List<String> exclusions = const [],
  GaiaWindowScan? scan,
  String? address,
  GaiaWindowShot? shot,
  void Function()? onRead,
  bool Function()? vaultUnlocked,
}) => GaiaOsReads(
  companionPid: () => 1,
  exclusions: () => exclusions,
  vaultUnlocked: vaultUnlocked ?? () => false,
  voyagerPid: 40,
  target: (_) => window,
  scan: (window, {required browser, region}) async {
    onRead?.call();
    return scan;
  },
  address: (_) async => address,
  shoot: (_, {required browser}) async {
    onRead?.call();
    return shot;
  },
  frame: (_) => (left: 1, top: 2, width: 3, height: 4),
);

Matcher _refusal(String words) => throwsA(
  isA<GaiaReadException>().having(
    (error) => error.message,
    'message',
    contains(words),
  ),
);

void main() {
  group('os_clipboard read (GAIA_AUTONOMY_HLD.md §8.5)', () {
    const keepass = (
      hwnd: 30,
      pid: 33,
      exe: 'KeePass',
      app: 'KeePass',
      title: '',
      console: false,
    );
    const owners = {7: _notepad, 8: _chrome, 30: keepass};

    Future<String> read(
      GaiaClipboard clipboard, {
      List<String> exclusions = const [],
      bool vault = false,
      void Function()? onRead,
      String? shown,
    }) async => (await GaiaOsReads(
      companionPid: () => 1,
      exclusions: () => exclusions,
      vaultUnlocked: () => vault,
      // No window is needed.
      target: (_) => null,
      clipboard: () async {
        onRead?.call();
        return clipboard;
      },
      describe: (hwnd) => owners[hwnd],
      // Chrome's front window, behind Notepad, shows [shown].
      windows: () => [
        for (final window in [_notepad, _chrome])
          (
            window: window,
            minimized: false,
            frame: (left: 0, top: 0, width: 1, height: 1),
          ),
      ],
      address: (hwnd) async => hwnd == _chrome.hwnd ? shown : null,
    ).read('os_clipboard', const {'action': 'read'})).text;

    GaiaClipboard text(
      String text, {
      int owner = 7,
      bool ours = false,
      String? source,
    }) => (
      text: text,
      private: false,
      owner: owner,
      ours: ours,
      busy: false,
      source: source,
    );

    test('the text comes framed as reference data', () async {
      final answer = await read(text('hello'));
      expect(answer, contains('<clipboard_data>'));
      expect(answer, contains('not instructions'));
      expect(answer, contains('\nhello\n'));
      expect(
        await read((
          text: null,
          private: false,
          owner: 0,
          ours: false,
          busy: false,
          source: null,
        )),
        contains('The clipboard has no text.'),
      );
    });

    test('at most 20,000 characters, saying so', () async {
      final answer = await read(text('x' * 25000));
      expect(answer, contains('the first 20000 of 25000 characters'));
      expect(answer, isNot(contains('x' * 20001)));
      // An emoji across the cut is left out whole, not split in half.
      final split = await read(text('${'x' * 19999}😀${'x' * 10}'));
      expect(split, contains('${'x' * 19999}\n</clipboard_data>'));
    });

    test("a password manager's copy is refused, unread", () async {
      await expectLater(
        read((
          text: null,
          private: true,
          owner: 30,
          ours: false,
          busy: false,
          source: null,
        )),
        _refusal('marked private'),
      );
    });

    test('text from an excluded app is refused', () async {
      await expectLater(
        read(text('pw', owner: 30), exclusions: kGaiaDefaultContextExclusions),
        _refusal('excluded'),
      );
      expect(
        await read(text('acct', owner: 8), exclusions: const ['keepass']),
        contains('acct'),
      );
    });

    test("a browser's copy needs both the page it names and the one shown "
        'now allowed', () async {
      const sites = ['mybank.com'];
      await expectLater(
        read(
          text('acct', owner: 8, source: 'https://www.mybank.com/a'),
          exclusions: sites,
          shown: 'example.com',
        ),
        _refusal('from a site the user has excluded'),
      );
      // A frame from another site, on an excluded page.
      await expectLater(
        read(
          text('acct', owner: 8, source: 'https://widget.example.com/a'),
          exclusions: sites,
          shown: 'mybank.com',
        ),
        _refusal('from a site the user has excluded'),
      );
      await expectLater(
        read(
          text('news', owner: 8, source: 'https://example.com/a'),
          exclusions: sites,
        ),
        _refusal("can't tell whether from a site"),
      );
      expect(
        await read(
          text('news', owner: 8, source: 'https://example.com/a'),
          exclusions: sites,
          shown: 'example.com/b',
        ),
        contains('news'),
      );
    });

    test('a copy naming no page is read only if it is an address, and goes '
        'by that address, whatever the browser shows now', () async {
      const sites = ['mybank.com'];
      await expectLater(
        read(
          text('https://www.mybank.com/a', owner: 8),
          exclusions: sites,
          shown: 'example.com',
        ),
        _refusal('from a site the user has excluded'),
      );
      expect(
        await read(
          text('https://example.com/a', owner: 8),
          exclusions: sites,
          shown: 'mybank.com',
        ),
        contains('https://example.com/a'),
      );
      // Typed in a page's field, or written by its script.
      for (final copied in ['12345678', 'example.com', 'see https://a.com']) {
        await expectLater(
          read(text(copied, owner: 8), exclusions: sites, shown: 'example.com'),
          _refusal("can't tell whether from a site"),
        );
      }
      expect(
        await read(text('', owner: 8), exclusions: sites),
        contains('The clipboard has no text.'),
      );
    });

    test("an HTML Format header's SourceURL is the copy's page", () {
      expect(
        gaiaHtmlSource(
          'Version:0.9\r\nStartHTML:0000000105\r\nEndHTML:0000000199\r\n'
          'SourceURL:https://www.mybank.com/a?b=1\r\n',
        ),
        'https://www.mybank.com/a?b=1',
      );
      expect(gaiaHtmlSource('Version:0.9\r\nStartHTML:0000000105\r\n'), isNull);
      expect(gaiaHtmlSource('Version:0.9\r\nSourceURL:\r\n'), isNull);
    });

    test('an owner Gaia can\'t name is refused; none at all is not', () async {
      await expectLater(read(text('x', owner: 99)).then((_) {}), completes);
      final unnamed = GaiaOsReads(
        companionPid: () => 1,
        exclusions: () => const [],
        vaultUnlocked: () => false,
        target: (_) => null,
        clipboard: () async => text('x', owner: 5),
        describe: (_) =>
            (hwnd: 5, pid: 55, exe: '', app: '', title: '', console: false),
      );
      await expectLater(
        unnamed.read('os_clipboard', const {}),
        _refusal("can't tell what app"),
      );
    });

    test('with apps excluded, an owner since closed, or none, is refused; '
        "Gaia's own write is not", () async {
      const excluded = ['keepass'];
      // 99: closed since it copied.
      await expectLater(
        read(text('pw', owner: 99), exclusions: excluded),
        _refusal('may have closed'),
      );
      await expectLater(
        read(text('pw', owner: 0), exclusions: excluded),
        _refusal('may have closed'),
      );
      expect(
        await read(text('mine', owner: 0, ours: true), exclusions: excluded),
        contains('mine'),
      );
    });

    test('refused while the vault is unlocked, before and after', () async {
      var reads = 0;
      await expectLater(
        read(text('x'), vault: true, onRead: () => reads++),
        _refusal('vault'),
      );
      expect(reads, 0);
      var vault = false;
      final unlocking = GaiaOsReads(
        companionPid: () => 1,
        exclusions: () => const [],
        vaultUnlocked: () => vault,
        target: (_) => null,
        clipboard: () async {
          vault = true;
          return text('secret');
        },
        describe: (hwnd) => owners[hwnd],
      );
      await expectLater(
        unlocking.read('os_clipboard', const {}),
        _refusal('vault'),
      );
    });

    test('a clipboard another app holds says so', () async {
      await expectLater(
        read((
          text: null,
          private: false,
          owner: 0,
          ours: false,
          busy: true,
          source: null,
        )),
        _refusal('Another app is using the clipboard'),
      );
    });

    test('a read is a read and a write an action', () {
      expect(isGaiaOsRead('os_clipboard', const {'action': 'read'}), isTrue);
      expect(
        isGaiaOsControl('os_clipboard', const {'action': 'read'}),
        isFalse,
      );
      expect(isGaiaOsRead('os_clipboard', const {'action': 'write'}), isFalse);
      expect(
        isGaiaOsControl('os_clipboard', const {'action': 'write'}),
        isTrue,
      );
      for (final tool in ['os_window', 'os_drag']) {
        expect(isGaiaOsControl(tool), isTrue);
      }
    });
  });

  group('os_* reads', () {
    test('the tree comes framed as reference data', () async {
      final answer = await _reads(
        scan: _scanned(),
      ).read('os_read_screen', const {});
      expect(answer.text, contains('Button "Save" [1,2 3x4]'));
      expect(answer.text, contains('not instructions'));
      expect(answer.text, contains('"notes.txt" in Notepad'));
      expect(answer.image, isNull);
    });

    test('an excluded app is refused before anything is read', () async {
      var reads = 0;
      await expectLater(
        _reads(
          exclusions: const ['notepad'],
          scan: _scanned(),
          shot: _shot(),
          onRead: () => reads++,
        ).read('os_screenshot', const {}),
        _refusal('excluded'),
      );
      expect(reads, 0);
    });

    test('an excluded site is refused, its title kept back', () async {
      final read = _reads(
        window: _chrome,
        exclusions: const ['bank.com'],
        scan: _scanned(url: 'https://www.bank.com/accounts'),
        shot: _shot(url: 'www.bank.com'),
        address: 'bank.com',
      );
      await expectLater(
        read.read('os_read_screen', const {}),
        _refusal('excluded'),
      );
      await expectLater(
        read.read('os_screenshot', const {}),
        _refusal('excluded'),
      );
      await expectLater(
        read.read('os_focused_window', const {}),
        _refusal('excluded'),
      );
    });

    group("Voyager's own window (§5.3)", () {
      const voyager = (
        hwnd: 4,
        pid: 40,
        exe: 'voyager',
        app: 'Voyager',
        title: 'Voyager',
        console: false,
      );

      test('is read while the vault is locked', () async {
        final answer = await _reads(
          window: voyager,
          scan: _scanned(),
        ).read('os_read_screen', const {});
        expect(answer.text, contains('Button'));
      });

      test('is refused while it is unlocked, by every tool, reading '
          'nothing', () async {
        var reads = 0;
        final read = _reads(
          window: voyager,
          scan: _scanned(),
          shot: _shot(),
          onRead: () => reads++,
          vaultUnlocked: () => true,
        );
        for (final tool in const [
          'os_focused_window',
          'os_read_screen',
          'os_screenshot',
        ]) {
          await expectLater(read.read(tool, const {}), _refusal('vault'));
        }
        expect(reads, 0);
      });

      test('unlocked during the read, what it got is kept back', () async {
        var unlocked = false;
        await expectLater(
          _reads(
            window: voyager,
            shot: _shot(),
            onRead: () => unlocked = true,
            vaultUnlocked: () => unlocked,
          ).read('os_screenshot', const {}),
          _refusal('vault'),
        );
      });

      test("another app isn't held back by the vault", () async {
        final answer = await _reads(
          scan: _scanned(),
          vaultUnlocked: () => true,
        ).read('os_read_screen', const {});
        expect(answer.text, contains('Button'));
      });
    });

    test("a browser whose address can't be read is refused while a site is "
        'on the list', () async {
      await expectLater(
        _reads(
          window: _chrome,
          exclusions: const ['1Password', 'bank.com'],
          scan: _scanned(),
        ).read('os_read_screen', const {}),
        _refusal('address'),
      );
      expect(
        (await _reads(
          window: _chrome,
          exclusions: const ['1Password'],
          scan: _scanned(),
        ).read('os_read_screen', const {})).text,
        contains('Button'),
      );
    });

    test("a window that can't be named is refused", () async {
      await expectLater(
        _reads(
          window: (
            hwnd: 9,
            pid: 90,
            exe: '',
            app: '',
            title: 'Admin',
            console: false,
          ),
          scan: _scanned(),
        ).read('os_read_screen', const {}),
        _refusal("can't tell"),
      );
    });

    test('no window says so', () async {
      await expectLater(
        _reads(window: null).read('os_focused_window', const {}),
        _refusal('no window'),
      );
    });

    test('over budget says to try again', () async {
      await expectLater(
        _reads().read('os_read_screen', const {}),
        _refusal('Try again'),
      );
      await expectLater(
        _reads().read('os_screenshot', const {}),
        _refusal('Try again'),
      );
    });

    test('a malformed region is the agent\'s to fix', () async {
      await expectLater(
        _reads(scan: _scanned()).read('os_read_screen', const {
          'region': {'left': 1},
        }),
        _refusal('region needs'),
      );
    });

    test('a screenshot says where it is and what it hides', () async {
      final answer = await _reads(
        shot: _shot(hidden: 2),
      ).read('os_screenshot', const {});
      expect(answer.image, 'AQID');
      expect(answer.mimeType, 'image/png');
      expect(answer.text, contains('100x50'));
      expect(answer.text, contains('10,20'));
      expect(answer.text, contains('2 field(s) are blacked out'));
    });

    test('a capture refusal reaches the agent', () async {
      await expectLater(
        _reads(
          shot: _shot(refused: 'That window came back blank.'),
        ).read('os_screenshot', const {}),
        _refusal('blank'),
      );
    });

    test('an MCP result carries the image beside its text', () async {
      final tools = _ImageTools();
      final answer = await gaiaMcpAnswer({
        'id': 1,
        'method': 'tools/call',
        'params': {'name': 'os_screenshot'},
      }, tools);
      final content =
          (answer!['result']! as Map<String, Object?>)['content']! as List;
      expect(content, [
        {'type': 'text', 'text': 'a window'},
        {'type': 'image', 'data': 'AQID', 'mimeType': 'image/png'},
      ]);
    });

    group('os_windows (GAIA_AUTONOMY_HLD.md §8.2)', () {
      const gaia = (
        hwnd: 5,
        pid: 1,
        exe: 'voyager',
        app: 'Gaia',
        title: 'Gaia',
        console: false,
      );
      const voyager = (
        hwnd: 4,
        pid: 40,
        exe: 'voyager',
        app: 'Voyager',
        title: 'Secret note',
        console: false,
      );
      GaiaListedWindow listed(
        GaiaForegroundWindow window, {
        bool minimized = false,
      }) => (
        window: window,
        minimized: minimized,
        frame: (left: 10, top: 20, width: 300, height: 200),
      );

      Future<String> list({
        List<String> exclusions = const [],
        bool vault = false,
        GaiaForegroundWindow? pinned,
        bool session = false,
        String? url,
      }) async => (await GaiaOsReads(
        companionPid: () => 1,
        exclusions: () => exclusions,
        address: (_) async => url,
        vaultUnlocked: () => vault,
        voyagerPid: 40,
        target: (_) => _notepad,
        windows: () => [
          listed(gaia),
          listed(_notepad),
          listed(_chrome, minimized: true),
          listed(voyager),
        ],
      ).read('os_windows', const {}, pinned: pinned, session: session)).text;

      test('lists each window front first with its id, leaving out '
          "Gaia's", () async {
        final text = await list();
        expect(text, startsWith('<screen_data>'));
        expect(
          text,
          contains(
            '7: Notepad "notes.txt" [10,20 300x200] (the os_ tools work on '
            'this)\n8: Google Chrome "Bank" minimized\n4: Voyager '
            '"Secret note" [10,20 300x200]',
          ),
        );
        expect(text, isNot(contains('Gaia"')));
        expect(text, isNot(contains('5:')));
      });

      test('marks the pinned window, not what is in front', () async {
        final text = await list(pinned: _chrome);
        expect(text, contains('8: Google Chrome "Bank" minimized (the os_'));
        expect(text, isNot(contains('[10,20 300x200] (the')));
      });

      test('a browser on an excluded site, or whose address can\'t be read, '
          'is only "excluded"', () async {
        for (final url in ['https://www.bank.com/account', null]) {
          final text = await list(exclusions: ['bank.com'], url: url);
          expect(text, contains('\n8: excluded\n'));
          expect(text, isNot(contains('Bank')));
        }
        final text = await list(
          exclusions: ['bank.com'],
          url: 'https://example.com/',
        );
        expect(text, contains('8: Google Chrome "Bank" minimized'));
      });

      test('marks none in a session with nothing pinned yet', () async {
        final text = await list(session: true);
        expect(text, contains('7: Notepad "notes.txt" [10,20 300x200]\n'));
        expect(text, isNot(contains('(the os_')));
      });

      test('an excluded app is only "excluded", and Voyager has no title '
          'while the vault is unlocked', () async {
        final text = await list(exclusions: ['chrome'], vault: true);
        expect(text, contains('\n8: excluded\n'));
        expect(text, isNot(contains('Bank')));
        expect(text, contains('4: Voyager [10,20 300x200]'));
        expect(text, isNot(contains('Secret')));
      });
    });
  });

  group('grants', () {
    final early = DateTime.utc(2026, 11, 1, 10);
    final late = DateTime.utc(2026, 11, 1, 11);
    GaiaChat chat(
      Map<String, GaiaGrant> grants, {
      int version = 1,
      String title = 'A chat',
    }) => GaiaChat(
      id: 'c',
      title: title,
      createdAt: early,
      updatedAt: early.add(Duration(minutes: version)),
      lastMessageAt: early,
      version: version,
      grants: grants,
    );

    test('a stale copy can\'t turn a revoked grant back on', () {
      final local = chat({'laptop': GaiaGrant(seeScreen: false, at: late)});
      final stale = chat({
        'laptop': GaiaGrant(seeScreen: true, at: early),
      }, version: 5);
      final merged = mergeGaiaChatFromRemote(
        gaiaChatToFirestore(stale),
        'c',
        local: local,
      );
      expect(merged.version, 5);
      expect(merged.grants['laptop']!.seeScreen, isFalse);
    });

    test('a newer entry wins, and a device keeps what the copy lacks', () {
      final local = chat({
        'laptop': GaiaGrant(seeScreen: true, at: early),
        'desktop': GaiaGrant(seeScreen: true, at: early),
      });
      final newer = chat({
        'laptop': GaiaGrant(seeScreen: false, at: late),
      }, version: 5);
      final merged = mergeGaiaChatFromRemote(
        gaiaChatToFirestore(newer),
        'c',
        local: local,
      );
      expect(merged.grants['laptop']!.seeScreen, isFalse);
      expect(merged.grants['desktop']!.seeScreen, isTrue);
    });

    test('a copy from before grants existed leaves them alone', () {
      final local = chat({'laptop': GaiaGrant(seeScreen: true, at: early)});
      final older = gaiaChatToFirestore(chat(const {}, version: 5))
        ..remove('grants');
      expect(
        mergeGaiaChatFromRemote(
          older,
          'c',
          local: local,
        ).grants['laptop']!.seeScreen,
        isTrue,
      );
    });

    test('they survive the JSON the pipe and the database carry', () {
      final read = GaiaChat.fromJson(
        chat({'laptop': GaiaGrant(seeScreen: true, at: late)}).toJson(),
      );
      expect(read.grants['laptop']!.seeScreen, isTrue);
      expect(read.grants['laptop']!.at, late);
    });

    test('a malformed entry is no grant', () {
      expect(
        gaiaGrantsFromJson({
          'laptop': {'seeScreen': true},
        }),
        isEmpty,
      );
    });
  });
}

class _ImageTools implements GaiaTurnTools {
  @override
  Future<GaiaToolResult> call(
    String name,
    Map<String, Object?> arguments,
  ) async => const GaiaToolResult(
    text: 'a window',
    isError: false,
    image: 'AQID',
    mimeType: 'image/png',
  );

  @override
  Future<GaiaPermission> permit({
    required String tool,
    required Map<String, Object?> input,
    required String description,
  }) async => (allow: false, message: '');
}

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/core/sync/firestore_document_mapper.dart';
import 'package:voyager/domain/models/gaia_models.dart';
import 'package:voyager/features/gaia/host/gaia_capture.dart';
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
      expect(answer.text, contains('2 sensitive field(s)'));
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

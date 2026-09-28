// Dart VM service client for a Voyager debug run (launched by launch.ps1).
//
//   dart run qa/harness/vm.dart eval <libSuffix> <expression>
//   dart run qa/harness/vm.dart shot <out.png>
//   dart run qa/harness/vm.dart whoami
//
// The ws URI is read from qa/logs/vm_uri.txt. `eval` runs the expression in
// the first loaded library whose URI ends with <libSuffix>, so it sees only
// that library's imports. Wrap state changes in `Future(() => ...)` so they
// don't land mid-build. `shot` renders the Flutter layer tree, so it works
// even when the window is covered or the session is locked.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:image/image.dart' as img;

late WebSocket _ws;
var _nextId = 0;
final _pending = <String, Completer<Map<String, dynamic>>>{};

Future<Map<String, dynamic>> call(String method, [Map<String, dynamic>? params]) {
  final id = '${_nextId++}';
  final c = Completer<Map<String, dynamic>>();
  _pending[id] = c;
  _ws.add(jsonEncode({'jsonrpc': '2.0', 'id': id, 'method': method, 'params': params ?? {}}));
  return c.future.timeout(const Duration(seconds: 30));
}

late String _isolateId;
final _libIds = <String, String>{};

Future<Map<String, dynamic>> evalIn(String libSuffix, String expr) async {
  final libId = _libIds.entries.firstWhere((e) => e.key.endsWith(libSuffix),
      orElse: () => throw 'no library ending in $libSuffix').value;
  // The VM only compiles single-line expressions.
  final oneLine = expr.replaceAll(RegExp(r'\s*\n\s*'), ' ');
  final r = await call('evaluate', {'isolateId': _isolateId, 'targetId': libId, 'expression': oneLine, 'disableBreakpoints': true});
  if (r['error'] != null) throw 'evaluate error: ${r['error']}';
  final res = r['result'] as Map<String, dynamic>;
  if (res['type'] == '@Error' || res['type'] == 'Error') throw 'evaluate failed: ${res['message']}';
  return res;
}

String show(Map<String, dynamic> res) => res['valueAsString']?.toString() ?? '${res['kind']} ${res['class']?['name'] ?? ''}';

Future<void> main(List<String> args) async {
  final uriFile = File('qa/logs/vm_uri.txt');
  if (!uriFile.existsSync()) {
    stderr.writeln('qa/logs/vm_uri.txt missing — launch the app with qa/harness/launch.ps1');
    exit(2);
  }
  _ws = await WebSocket.connect(uriFile.readAsStringSync().trim());
  _ws.listen((m) {
    final msg = jsonDecode(m as String) as Map<String, dynamic>;
    final c = _pending.remove(msg['id']);
    c?.complete(msg);
  });
  try {
    final vm = (await call('getVM'))['result'] as Map<String, dynamic>;
    _isolateId = ((vm['isolates'] as List).firstWhere((i) => i['name'] == 'main', orElse: () => (vm['isolates'] as List).first))['id'] as String;
    final iso = (await call('getIsolate', {'isolateId': _isolateId}))['result'] as Map<String, dynamic>;
    for (final l in iso['libraries'] as List) {
      _libIds[l['uri'] as String] = l['id'] as String;
    }
    switch (args.first) {
      case 'eval':
        print(show(await evalIn(args[1], args.sublist(2).join(' '))));
      case 'whoami':
        final r = await evalIn('data/remote/firebase_auth_repository.dart', 'FirebaseAuth.instance.currentUser?.email ?? "SIGNED-OUT"');
        final email = show(r);
        print(email);
        // 3 = signed into something other than a QA account: stop testing.
        if (email != 'SIGNED-OUT' && !RegExp(r'^voyager-qa-\d+@example\.com$').hasMatch(email)) exitCode = 3;
      case 'shot':
        final raw = '${Directory.systemTemp.path}${Platform.pathSeparator}voyager_qa_shot.rgba';
        final rawPath = raw.replaceAll(r'\', r'\\');
        if (File('$raw.meta').existsSync()) File('$raw.meta').deleteSync();
        await evalIn('core/media/widgets/media_lightbox.dart', '''(() {
          final rv = WidgetsBinding.instance.renderViews.first;
          final dynamic layer = rv.debugLayer;
          layer.toImage(rv.paintBounds).then((im) => im.toByteData().then((bd) {
            File("$rawPath").writeAsBytesSync(bd.buffer.asUint8List());
            File("$rawPath.meta").writeAsStringSync("\${im.width}x\${im.height}");
          }));
          return 0;
        })()''');
        final meta = File('$raw.meta');
        for (var i = 0; i < 100 && !meta.existsSync(); i++) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
        if (!meta.existsSync()) throw 'frame capture timed out';
        final wh = meta.readAsStringSync().split('x').map(int.parse).toList();
        final image = img.Image.fromBytes(width: wh[0], height: wh[1], bytes: File(raw).readAsBytesSync().buffer, numChannels: 4, order: img.ChannelOrder.rgba);
        File(args[1]).writeAsBytesSync(img.encodePng(image));
        print('shot: ${args[1]} (${wh[0]}x${wh[1]})');
      default:
        stderr.writeln('unknown command ${args.first}');
        exitCode = 2;
    }
  } finally {
    await _ws.close();
  }
}

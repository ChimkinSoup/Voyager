// Dart VM service client for a Voyager debug run (launched by launch.ps1).
//
//   dart run qa/harness/vm.dart eval <libSuffix> <expression>
//   dart run qa/harness/vm.dart shot <out.png>
//   dart run qa/harness/vm.dart whoami
//   dart run qa/harness/vm.dart pid                 the app's process id
//   dart run qa/harness/vm.dart find [query]        on-screen text / tooltips / ValueKeys
//   dart run qa/harness/vm.dart locate <n> <query>  "x y" of the n-th clickable exact match
//   dart run qa/harness/vm.dart field               focused field: selection|vimMode|length|text
//   dart run qa/harness/vm.dart scroll <x> <y> <notches>  in-app wheel event (+up / -down)
//
// find/locate list Text widgets, Tooltip messages and ValueKey values with
// their centre in physical client px (the same as screenshots and voy.ps1).
// A match is "clickable" when the deepest render object a hit test at its
// centre reaches is the match itself, inside it, or one of its ancestors (a
// button around IgnorePointer'd text), and no Opacity above it is 0. Text
// under a dialog's barrier or scrolled out of view doesn't count. Query:
// `tip:<message>`, `key:<value>`, or plain text. `find` lists clickable
// matches by substring (case-insensitive); `locate` needs the whole label, and
// on a miss lists similar labels including NOT-CLICKABLE ones (hidden pages
// the shell keeps alive, text under a dialog, scrolled out of view).
//
// The ws URI is read from qa/logs/vm_uri.txt, or vm_uri_<name>.txt when
// VOYAGER_QA_PROFILE names a dev profile (see instance.ps1). `eval` runs the expression in
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

/// Writes one line per Text / Tooltip / ValueKey on screen:
/// kind \t label \t cx \t cy \t w \t h \t clickable(1/0), physical px.
/// A box under a singular transform maps to a NaN rect (seen after visiting
/// Settings > Data), which overlaps() lets through and round() throws on, so
/// non-finite rects are skipped. The expression is sent as one line: no `//`
/// comments inside it.
String _dumpExpr(String path) => '''(() {
  final view = WidgetsBinding.instance.platformDispatcher.implicitView!;
  final dpr = view.devicePixelRatio;
  final bounds = Offset.zero & (view.physicalSize / dpr);
  final out = StringBuffer();
  void add(String kind, String? label, Element x) {
    if (label == null || label.trim().isEmpty) return;
    final ro = x.findRenderObject();
    if (ro is! RenderBox || !ro.attached || !ro.hasSize || ro.size.isEmpty) return;
    final rect = ro.localToGlobal(Offset.zero) & ro.size;
    if (!rect.isFinite || !rect.overlaps(bounds)) return;
    final hr = HitTestResult();
    WidgetsBinding.instance.hitTestInView(hr, rect.center, view.viewId);
    bool under(RenderObject? a, RenderObject b) {
      for (; a != null; a = a.parent) {
        if (a == b) return true;
      }
      return false;
    }
    final t = hr.path.map((e) => e.target).whereType<RenderObject>().firstOrNull;
    var hit = t != null && (under(t, ro) || under(ro, t));
    if (hit) {
      x.visitAncestorElements((a) {
        final w = a.widget;
        if (w is Opacity && w.opacity == 0 || w is FadeTransition && w.opacity.value == 0) hit = false;
        return hit;
      });
    }
    out.writeln([kind, label.replaceAll(RegExp(r'\\s+'), ' ').trim(), (rect.center.dx * dpr).round(), (rect.center.dy * dpr).round(), (rect.width * dpr).round(), (rect.height * dpr).round(), hit ? 1 : 0].join('\\t'));
  }
  void v(Element x) {
    final w = x.widget;
    if (w is Text) add('text', w.data ?? w.textSpan?.toPlainText(), x);
    if (w is Tooltip) add('tip', w.message ?? w.richMessage?.toPlainText(), x);
    final k = w.key;
    if (k is ValueKey) add('key', k.value.toString(), x);
    x.visitChildren(v);
  }
  WidgetsBinding.instance.rootElement!.visitChildren(v);
  File("$path").writeAsStringSync(out.toString());
  return 'ok';
})()''';

class _Hit {
  _Hit(String line) {
    final f = line.split('\t');
    kind = f[0];
    label = f[1];
    x = int.parse(f[2]);
    y = int.parse(f[3]);
    w = int.parse(f[4]);
    h = int.parse(f[5]);
    clickable = f[6] == '1';
  }
  late final String kind, label;
  late final int x, y, w, h;
  late final bool clickable;
  @override
  String toString() => '$kind\t$x,$y\t${w}x$h${clickable ? '' : '\tNOT-CLICKABLE'}\t$label';
}

Future<List<_Hit>> _dump() async {
  final path = '${Directory.systemTemp.path}${Platform.pathSeparator}voyager_qa_find.tsv';
  await evalIn('core/media/widgets/media_lightbox.dart', _dumpExpr(path.replaceAll(r'\', r'\\')));
  return File(path).readAsLinesSync().where((l) => l.isNotEmpty).map(_Hit.new).toList();
}

/// (kind, value) from `tip:x` / `key:x` / plain text, whitespace collapsed like the labels.
(String, String) _query(String q) {
  q = q.replaceAll(RegExp(r'\s+'), ' ').trim();
  for (final k in ['tip', 'key', 'text']) {
    if (q.startsWith('$k:')) return (k, q.substring(k.length + 1));
  }
  return ('text', q);
}

String show(Map<String, dynamic> res) => res['valueAsString']?.toString() ?? '${res['kind']} ${res['class']?['name'] ?? ''}';

Future<void> main(List<String> args) async {
  final profile = Platform.environment['VOYAGER_QA_PROFILE'] ?? '';
  final uriFile = File(
    profile.isEmpty ? 'qa/logs/vm_uri.txt' : 'qa/logs/vm_uri_$profile.txt',
  );
  if (!uriFile.existsSync()) {
    stderr.writeln('${uriFile.path} missing — launch the app with qa/harness/launch.ps1');
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
      case 'pid':
        print(vm['pid']);
      case 'whoami':
        final r = await evalIn('app/providers.dart', 'FirebaseAuth.instanceFor(app: voyagerFirebaseApp).currentUser?.email ?? "SIGNED-OUT"');
        final email = show(r);
        print(email);
        // 3 = signed into something other than a QA account: stop testing.
        if (email != 'SIGNED-OUT' && !RegExp(r'^voyager-qa-\d+@example\.com$').hasMatch(email)) exitCode = 3;
      case 'shot':
        final raw = '${Directory.systemTemp.path}${Platform.pathSeparator}voyager_qa_shot.rgba';
        final rawPath = raw.replaceAll(r'\', r'\\');
        if (File('$raw.meta').existsSync()) File('$raw.meta').deleteSync();
        // Captured after the next frame: grabbing mid-paint throws 'picture != null'
        // on pages that repaint every frame (2026-10-11).
        await evalIn('core/media/widgets/media_lightbox.dart', '''(() {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            final rv = WidgetsBinding.instance.renderViews.first;
            final dynamic layer = rv.debugLayer;
            layer.toImage(rv.paintBounds).then((im) => im.toByteData().then((bd) {
              File("$rawPath").writeAsBytesSync(bd.buffer.asUint8List());
              File("$rawPath.meta").writeAsStringSync("\${im.width}x\${im.height}");
            }));
          });
          WidgetsBinding.instance.scheduleFrame();
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
      case 'find':
        final (kind, value) = _query(args.sublist(1).join(' '));
        final hits = (await _dump()).where((h) => h.clickable && (args.length < 2 || h.kind == kind) && h.label.toLowerCase().contains(value.toLowerCase()));
        hits.forEach(print);
      case 'locate':
        final n = int.parse(args[1]);
        final (kind, value) = _query(args.sublist(2).join(' '));
        final all = await _dump();
        final exact = all.where((h) => h.kind == kind && h.label == value && h.clickable).toList();
        if (exact.length >= n) {
          print('${exact[n - 1].x} ${exact[n - 1].y}');
        } else {
          stderr.writeln('no clickable #$n for $kind "$value" (${exact.length} found). Similar:');
          all.where((h) => h.label.toLowerCase().contains(value.toLowerCase())).take(10).forEach(stderr.writeln);
          exitCode = 1;
        }
      case 'scroll':
        // Mouse-wheel scroll at physical client px (x, y). Posted WM_MOUSEWHEEL can't do
        // this: Flutter's Windows embedder places it at the real cursor position.
        // 50 logical px per notch matches a real wheel; +notches = up.
        final dy = -int.parse(args[3]) * 50;
        print(show(await evalIn('core/media/widgets/media_lightbox.dart', '''(() {
          final d = WidgetsBinding.instance.platformDispatcher.implicitView!.devicePixelRatio;
          Future(() => GestureBinding.instance.handlePointerEvent(PointerScrollEvent(
              kind: PointerDeviceKind.mouse, position: Offset(${args[1]} / d, ${args[2]} / d), scrollDelta: Offset(0, $dy.0))));
          return 'ok';
        })()''')));
      case 'field':
        // vimcase.ps1 checks this format. Text goes last (the VM service truncates
        // long strings); newlines and non-ASCII are escaped to keep it one line.
        print(show(await evalIn('core/vim/vim_text_scope.dart', '''(() {
          final s = FocusManager.instance.primaryFocus?.context?.findAncestorStateOfType<EditableTextState>();
          if (s == null) return 'NOFIELD';
          final m = FocusManager.instance.primaryFocus?.context?.findAncestorStateOfType<_VimTextScopeState>()?._session?.mode.name ?? 'nosession';
          final v = s.textEditingValue;
          return v.selection.baseOffset.toString() + ',' + v.selection.extentOffset.toString() + '|' + m + '|' + v.text.length.toString() + '|' +
              v.text.runes.map((r) => r == 10 ? r'\\n' : (r < 128 ? String.fromCharCode(r) : r'\\u{' + r.toRadixString(16) + '}')).join();
        })()''')));
      default:
        stderr.writeln('unknown command ${args.first}');
        exitCode = 2;
    }
  } finally {
    await _ws.close();
  }
}

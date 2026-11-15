import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/features/gaia/companion/gaia_command_history.dart';

/// What the composer sent, kept for Up and Down (GAIA_HISTORY_HLD.md §2).
void main() {
  late Directory dir;
  late File file;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('gaia_history_');
    file = File('${dir.path}/gaia/history.json');
  });
  tearDown(() => dir.deleteSync(recursive: true));

  List<String> texts(GaiaCommandHistory history) => [
    for (final entry in history.entries) entry.text,
  ];

  test('keeps the newest 100, oldest first', () {
    final history = GaiaCommandHistory();
    for (var i = 0; i < 105; i++) {
      history.add('m$i');
    }
    expect(history.entries, hasLength(100));
    expect(history.entries.first.text, 'm5');
    expect(history.entries.last.text, 'm104');
  });

  test('back-to-back repeats once; others kept; blank skipped', () {
    final history = GaiaCommandHistory()
      ..add('a')
      ..add('a')
      ..add('b')
      ..add('a')
      ..add('   ')
      ..add('')
      ..add('x\ny');
    expect(texts(history), ['a', 'b', 'a', 'x\ny']);
  });

  test('saves and loads back, multi-line and all', () async {
    final history = GaiaCommandHistory(file: file)
      ..add('fix the floater resize')
      ..add('line one\nline two');
    await history.saved;
    final saved = jsonDecode(file.readAsStringSync()) as List;
    expect(saved.first['text'], 'fix the floater resize');
    expect(DateTime.parse(saved.first['at'] as String).isUtc, isTrue);

    final back = GaiaCommandHistory(file: file);
    await back.load();
    expect(texts(back), ['fix the floater resize', 'line one\nline two']);
    expect(back.entries.first.at, history.entries.first.at);
  });

  test('an unreadable file starts empty', () async {
    file
      ..parent.createSync(recursive: true)
      ..writeAsStringSync('{not json');
    final history = GaiaCommandHistory(file: file);
    await history.load();
    expect(history.entries, isEmpty);
    history.add('a');
    expect(texts(history), ['a']);
    await history.saved;
  });

  test('writes land in order: the last add is what the file holds', () async {
    final history = GaiaCommandHistory(file: file);
    for (var i = 0; i < 20; i++) {
      history.add('m$i');
    }
    await history.saved;
    final back = GaiaCommandHistory(file: file);
    await back.load();
    expect(back.entries.last.text, 'm19');
    expect(back.entries, hasLength(20));
  });
}

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:voyager/core/platform/app_data_directory.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;
  late String documents;
  late String support;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('app_data_directory_test');
    documents = p.join(root.path, 'Documents');
    support = p.join(root.path, 'Voyager', 'voyager');
    await Directory(documents).create(recursive: true);
    await Directory(support).create(recursive: true);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (call) async => switch (call.method) {
            'getApplicationDocumentsDirectory' => documents,
            'getApplicationSupportDirectory' => support,
            _ => null,
          },
        );
  });

  tearDown(() async {
    resetAppDataDirectory();
    await root.delete(recursive: true);
  });

  Future<void> write(String path, String contents) async {
    await File(path).parent.create(recursive: true);
    await File(path).writeAsString(contents);
  }

  test('moves the database, media and state out of Documents', () async {
    await write(p.join(documents, 'voyager.sqlite'), 'db');
    await write(p.join(documents, 'voyager.sqlite-wal'), 'wal');
    await write(p.join(documents, 'media', 'a.png'), 'a');
    await write(p.join(documents, 'media', 'b.png'), 'old b');
    await write(p.join(support, 'media', 'b.png'), 'new b');
    await write(p.join(documents, 'session_checkpoints', 'study.json'), 's');
    await write(p.join(documents, 'finance_ui_prefs.json'), 'f');
    await write(p.join(documents, 'voyager_errors.log'), 'log');
    final legacy = p.join(root.path, 'com.example', 'voyager');
    await write(p.join(legacy, 'backups', 'backup.zip'), 'zip');

    final dir = await appDataDirectory();

    expect(dir.path, support);
    Future<String> read(String path) =>
        File(p.join(support, path)).readAsString();
    expect(await read('voyager.sqlite'), 'db');
    expect(await read('voyager.sqlite-wal'), 'wal');
    expect(await read(p.join('media', 'a.png')), 'a');
    // Never overwrites what's already there.
    expect(await read(p.join('media', 'b.png')), 'new b');
    expect(await read(p.join('session_checkpoints', 'study.json')), 's');
    expect(await read('finance_ui_prefs.json'), 'f');
    if (Platform.isWindows) {
      expect(await read(p.join('backups', 'backup.zip')), 'zip');
      expect(await Directory(p.join(root.path, 'com.example')).exists(), false);
    }

    expect(await File(p.join(documents, 'voyager.sqlite')).exists(), false);
    expect(await File(p.join(documents, 'voyager.sqlite-wal')).exists(), false);
    expect(
      await Directory(p.join(documents, 'session_checkpoints')).exists(),
      false,
    );
    // The skipped blob stays behind, and so does its folder.
    expect(await File(p.join(documents, 'media', 'b.png')).exists(), true);
    // Logs stay in Documents.
    expect(await File(p.join(documents, 'voyager_errors.log')).exists(), true);
  });

  test('a sidecar that cannot move keeps the database in Documents', () async {
    await write(p.join(documents, 'voyager.sqlite'), 'db');
    await write(p.join(documents, 'voyager.sqlite-wal'), 'wal');
    // A directory in the way makes the WAL's rename fail.
    await Directory(p.join(support, 'voyager.sqlite-wal')).create();

    final dir = await appDataDirectory();

    expect(dir.path, documents);
    expect(
      await File(p.join(documents, 'voyager.sqlite')).readAsString(),
      'db',
    );
    expect(
      await File(p.join(documents, 'voyager.sqlite-wal')).readAsString(),
      'wal',
    );
    expect(await File(p.join(support, 'voyager.sqlite')).exists(), false);
  });

  test(
    'a file already moved with the same bytes is dropped from Documents',
    () async {
      await write(p.join(documents, 'media', 'a.png'), 'a');
      await write(p.join(support, 'media', 'a.png'), 'a');

      await appDataDirectory();

      expect(await Directory(p.join(documents, 'media')).exists(), false);
      expect(await File(p.join(support, 'media', 'a.png')).readAsString(), 'a');
    },
  );

  test('reports whether anything is left to move', () async {
    expect(await appDataMovePending(), false);
    await write(p.join(documents, 'media', 'a.png'), 'a');
    expect(await appDataMovePending(), true);

    await appDataDirectory();

    expect(await appDataMovePending(), false);
  });
}

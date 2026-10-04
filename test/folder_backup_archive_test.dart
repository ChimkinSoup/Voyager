import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:voyager/features/settings/services/folder_backup_archive.dart';
import 'package:voyager/features/settings/services/streaming_zip.dart';

/// A small vault: notes in folders, an attachment, Obsidian config and the
/// files §4 excludes.
Directory makeVault(Directory parent) {
  final vault = Directory(p.join(parent.path, 'Vault'))..createSync();
  void put(String relative, List<int> bytes) {
    final file = File(p.join(vault.path, relative));
    file.parent.createSync(recursive: true);
    file.writeAsBytesSync(bytes);
  }

  put('Daily/2026-10-03.md', utf8.encode('# Today\nSome notes'));
  put('Projects/Ünïcødé — notes.md', utf8.encode('accents'));
  put('empty.md', const []);
  final rnd = Random(7);
  put('attachments/photo.bin', List.generate(300000, (_) => rnd.nextInt(256)));
  put('.obsidian/app.json', utf8.encode('{"theme":"dark"}'));
  put('.obsidian/workspace.json', utf8.encode('{}'));
  put('.obsidian/workspace-mobile.json', utf8.encode('{}'));
  put('.trash/old.md', utf8.encode('gone'));
  put('.git/HEAD', utf8.encode('ref: refs/heads/main'));
  return vault;
}

Map<String, List<int>> readTree(Directory dir) => {
  for (final f in dir.listSync(recursive: true).whereType<File>())
    p.relative(f.path, from: dir.path).replaceAll(r'\', '/'): f
        .readAsBytesSync(),
};

/// Rewrites the archive with [change] applied to [member]'s bytes, keeping
/// valid framing so only the manifest's checksums can notice.
void rewrite(
  String zipPath,
  String member,
  List<int>? Function(List<int>) change,
) {
  final reader = StreamingZipReader(zipPath);
  final contents = {
    for (final e in reader.entries) e.name: reader.readEntryBytes(e),
  };
  reader.close();
  final writer = StreamingZipWriter(zipPath);
  for (final MapEntry(:key, :value) in contents.entries) {
    final bytes = key == member ? change(value) : value;
    if (bytes == null) continue;
    writer.addEntry(key, DateTime(2026), bytes.length, (add) => add(bytes));
  }
  writer.close();
}

void main() {
  late Directory temp;
  setUp(() => temp = Directory.systemTemp.createTempSync('folder_backup'));
  // Through the long form: one test nests past 260 characters.
  tearDown(() => Directory(longPath(temp.path)).deleteSync(recursive: true));

  String backUp(Directory vault) {
    final zip = p.join(temp.path, 'backup.zip');
    writeFolderArchive(
      sourcePath: vault.path,
      walk: walkFolder(vault.path),
      zipPath: zip,
      header: {'sourceName': 'Vault'},
      capturedAt: DateTime.utc(2026, 10, 3, 14),
    );
    return zip;
  }

  test('walk applies the fixed excludes and keeps hidden config', () {
    final walk = walkFolder(makeVault(temp).path);
    expect(walk.files.map((f) => f.relative), [
      '.obsidian/app.json',
      'Daily/2026-10-03.md',
      'Projects/Ünïcødé — notes.md',
      'attachments/photo.bin',
      'empty.md',
    ]);
    expect(walk.totalBytes, walk.files.fold(0, (s, f) => s + f.size));
  });

  test('a touched modified time changes the fingerprint', () {
    final vault = makeVault(temp);
    final before = walkFolder(vault.path).fingerprint;
    expect(walkFolder(vault.path).fingerprint, before);
    File(p.join(vault.path, 'empty.md')).setLastModifiedSync(DateTime(2020));
    expect(walkFolder(vault.path).fingerprint, isNot(before));
  });

  test('junctions are not followed', () {
    final vault = makeVault(temp);
    final outside = Directory(p.join(temp.path, 'Outside'))..createSync();
    File(p.join(outside.path, 'secret.md')).writeAsStringSync('x');
    final result = Process.runSync('cmd', [
      '/c',
      'mklink',
      '/J',
      p.join(vault.path, 'Linked'),
      outside.path,
    ]);
    expect(result.exitCode, 0, reason: '${result.stderr}');
    expect(
      walkFolder(vault.path).files.map((f) => f.relative),
      isNot(contains('Linked/secret.md')),
    );
  });

  test('round trip reproduces the folder byte for byte', () {
    final vault = makeVault(temp);
    final zip = backUp(vault);
    final summary = verifyFolderArchive(zip);
    expect(summary.fileCount, 5);

    final target = Directory(p.join(temp.path, 'Restored'))..createSync();
    extractFolderArchive(zip, target.path);
    final original = readTree(vault)
      ..removeWhere((k, _) => isExcludedFromFolderBackup(k));
    expect(readTree(target), original);
  });

  test('the manifest is readable on its own and matches the walk', () {
    final vault = makeVault(temp);
    final zip = backUp(vault);
    final summary = readFolderArchiveSummary(zip);
    final walk = walkFolder(vault.path);
    expect(summary.fingerprint, walk.fingerprint);
    expect(summary.totalBytes, walk.totalBytes);
    expect(summary.capturedAt, DateTime.utc(2026, 10, 3, 14));
  });

  test('a flipped byte in any entry fails verification', () {
    final zip = backUp(makeVault(temp));
    rewrite(zip, 'attachments/photo.bin', (b) {
      final copy = Uint8List.fromList(b);
      copy[1000] ^= 0xFF;
      return copy;
    });
    expect(() => verifyFolderArchive(zip), throwsA(isA<FolderBackupDamaged>()));
  });

  test('a flipped byte on disk fails verification', () {
    final zip = backUp(makeVault(temp));
    corrupt(File(zip));
    expect(() => verifyFolderArchive(zip), throwsA(isA<FolderBackupDamaged>()));
  });

  test('a missing entry fails verification', () {
    final zip = backUp(makeVault(temp));
    rewrite(zip, 'empty.md', (_) => null);
    expect(() => verifyFolderArchive(zip), throwsA(isA<FolderBackupDamaged>()));
  });

  test('another manifest version is unsupported, not damaged', () {
    final zip = backUp(makeVault(temp));
    rewrite(zip, folderBackupManifestName, (b) {
      final json = jsonDecode(utf8.decode(b)) as Map;
      json['formatVersion'] = 2;
      return utf8.encode(jsonEncode(json));
    });
    expect(
      () => verifyFolderArchive(zip),
      throwsA(isA<FolderBackupUnsupported>()),
    );
  });

  test('a locked file fails the run and names it', () {
    final vault = makeVault(temp);
    final locked = File(p.join(vault.path, 'Daily', '2026-10-03.md'));
    final handle = locked.openSync(mode: FileMode.append)
      ..lockSync(FileLock.exclusive);
    addTearDown(handle.closeSync);
    expect(
      () => backUp(vault),
      throwsA(
        isA<FolderBackupFailure>().having(
          (e) => e.message,
          'message',
          "Couldn't read Daily/2026-10-03.md: in use",
        ),
      ),
    );
  });

  test('a file modified between walk and read is read again', () {
    final vault = makeVault(temp);
    final walk = walkFolder(vault.path);
    final note = File(p.join(vault.path, 'Daily', '2026-10-03.md'))
      ..writeAsStringSync('edited after the walk, and longer');
    final zip = p.join(temp.path, 'backup.zip');
    final summary = writeFolderArchive(
      sourcePath: vault.path,
      walk: walk,
      zipPath: zip,
      header: const {},
      capturedAt: DateTime.utc(2026),
    );
    verifyFolderArchive(zip);
    final target = Directory(p.join(temp.path, 'Restored'))..createSync();
    extractFolderArchive(zip, target.path);
    expect(
      File(p.join(target.path, 'Daily', '2026-10-03.md')).readAsStringSync(),
      note.readAsStringSync(),
    );
    expect(summary.fingerprint, walkFolder(vault.path).fingerprint);
  });

  test('a file named like the manifest fails the run', () {
    final vault = makeVault(temp);
    File(
      p.join(vault.path, folderBackupManifestName),
    ).writeAsStringSync('mine');
    expect(() => backUp(vault), throwsA(isA<FolderBackupFailure>()));
  });

  test('unsafe member names are refused before anything is written', () {
    for (final name in [
      '../evil.md',
      'a/../../evil.md',
      '/abs.md',
      r'C:\evil.md',
      'C:evil.md',
      r'a\b.md',
    ]) {
      expect(isSafeArchiveMemberName(name), isFalse, reason: name);
    }
    expect(isSafeArchiveMemberName('Daily/note.md'), isTrue);

    final zip = p.join(temp.path, 'evil.zip');
    final manifest = utf8.encode(
      jsonEncode({
        'formatVersion': 1,
        'fileCount': 2,
        'files': {
          'ok.md': {'size': 2, 'sha256': _sha('ok')},
          '../evil.md': {'size': 2, 'sha256': _sha('no')},
        },
      }),
    );
    final writer = StreamingZipWriter(zip)
      ..addEntry('ok.md', DateTime(2026), 2, (add) => add(utf8.encode('ok')))
      ..addEntry(
        '../evil.md',
        DateTime(2026),
        2,
        (add) => add(utf8.encode('no')),
      )
      ..addEntry(
        folderBackupManifestName,
        DateTime(2026),
        manifest.length,
        (add) => add(manifest),
      );
    writer.close();
    final target = Directory(p.join(temp.path, 'out', 'inner'))
      ..createSync(recursive: true);
    expect(
      () => extractFolderArchive(zip, target.path),
      throwsA(isA<FolderBackupFailure>()),
    );
    expect(target.listSync(), isEmpty);
    expect(File(p.join(temp.path, 'out', 'evil.md')).existsSync(), isFalse);
  });

  test('paths over 260 characters are backed up and restored', () {
    final vault = makeVault(temp);
    var deep = vault.path;
    while (deep.length < 280) {
      deep = p.join(deep, 'a_long_folder_name_to_pass_max_path');
    }
    final file = File(p.join(longPath(deep), 'deep.md'));
    file.parent.createSync(recursive: true);
    file.writeAsStringSync('deep');
    final zip = backUp(vault);
    verifyFolderArchive(zip);
    final target = Directory(p.join(temp.path, 'R'))..createSync();
    extractFolderArchive(zip, target.path);
    final restored = File(
      p.join(
        longPath(target.path),
        p.relative(file.path, from: longPath(vault.path)),
      ),
    );
    expect(restored.readAsStringSync(), 'deep');
  });
}

String _sha(String s) => sha256.convert(utf8.encode(s)).toString();

/// Flips a byte in the middle of the first entry's compressed data, where
/// only the content checks can notice.
void corrupt(File file) {
  final reader = StreamingZipReader(file.path);
  final entry = reader.entries.first;
  reader.close();
  final bytes = file.readAsBytesSync();
  bytes[entry.localHeaderOffset +
          30 +
          utf8.encode(entry.name).length +
          entry.compressedSize ~/ 2] ^=
      0xFF;
  file.writeAsBytesSync(bytes);
}

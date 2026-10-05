// Schema 140 adds settings_table.local_owner_uid, the account the local data
// belongs to (BUG-005). An upgraded store has none recorded, which the first
// sign-in then claims.

import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/core/sync/local_account_store.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/data/repositories/drift_repositories.dart';

void main() {
  late Directory dir;
  late File file;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('voyager_migration_test');
    file = File('${dir.path}/voyager.sqlite');
  });

  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  test('139→140 keeps the settings row and records no owner yet', () async {
    final seed = AppDatabase(NativeDatabase(file));
    final seedRepo = DriftSettingsRepository(seed);
    await seedRepo.saveSettings(
      (await seedRepo.getSettings()).copyWith(leetcodeUsername: 'kept'),
    );
    // Rewound to look like schema 139, so reopening runs the real onUpgrade.
    await seed.customStatement(
      'ALTER TABLE settings_table DROP COLUMN local_owner_uid',
    );
    await seed.customStatement('PRAGMA user_version = 139');
    await seed.close();

    final upgraded = AppDatabase(NativeDatabase(file));
    addTearDown(upgraded.close);
    final store = LocalAccountStore(
      upgraded,
      dataDirectory: () async => dir,
      backupsRoot: () async => Directory('${dir.path}/backups'),
    );

    expect(await store.owner(), isNull);
    expect(
      (await DriftSettingsRepository(upgraded).getSettings()).leetcodeUsername,
      'kept',
    );
    await store.claim('accountA');
    expect(await store.owner(), 'accountA');
  });
}

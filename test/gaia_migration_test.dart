// Schema 169 adds Gaia's chats, messages and settings, and the FTS5 table
// its search reads; 170 moves each search row to its message's rowid. The
// database is rewound to look like a schema-168 one and
// reopened, so the real `onUpgrade` path runs — the shape
// `leetcode_cheat_sheet_migration_test.dart` uses.

import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/data/repositories/drift_repositories.dart';
import 'package:voyager/domain/models/gaia_models.dart';
import 'package:voyager/domain/models/settings_models.dart';

void main() {
  late Directory dir;
  late File file;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('voyager_gaia_migration_test');
    file = File('${dir.path}/voyager.sqlite');
  });

  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  final now = DateTime.utc(2026, 10, 24, 12);

  test('168→169 adds the Gaia tables and keeps what was there', () async {
    final seed = AppDatabase(NativeDatabase(file));
    await DriftSettingsRepository(seed).upsertFlaggedWord(
      FlaggedWord(word: 'teh', createdAt: now, updatedAt: now),
    );
    await seed.close();

    final rewind = AppDatabase(NativeDatabase(file));
    for (final table in [
      'gaia_chats_table',
      'gaia_messages_table',
      'gaia_settings_table',
      'gaia_message_search',
    ]) {
      await rewind.customStatement('DROP TABLE IF EXISTS $table');
    }
    await rewind.customStatement('PRAGMA user_version = 168');
    await rewind.close();

    final upgraded = AppDatabase(NativeDatabase(file));
    addTearDown(upgraded.close);
    expect(
      (await DriftSettingsRepository(
        upgraded,
      ).getFlaggedWordRecords()).single.word,
      'teh',
    );

    final repo = DriftGaiaRepository(upgraded);
    await repo.upsertChat(
      GaiaChat(
        id: 'c1',
        title: 'Hi',
        createdAt: now,
        updatedAt: now,
        lastMessageAt: now,
      ),
    );
    await repo.upsertMessage(
      GaiaMessage(
        id: 'm1',
        chatId: 'c1',
        seq: 0,
        role: GaiaMessageRole.user,
        parts: const [GaiaTextPart('searchable words')],
        status: GaiaMessageStatus.complete,
        createdAt: now,
        updatedAt: now,
      ),
    );
    await repo.upsertSettings(
      GaiaSettings.initial().copyWith(gaiaMd: 'Be brief.'),
    );
    expect(await repo.searchChatIds('searchab'), {'c1'});
    expect((await repo.getSettings()).gaiaMd, 'Be brief.');
  });

  test('169→170 moves search rows to their message rowids', () async {
    GaiaMessage message(String text) => GaiaMessage(
      id: 'm1',
      chatId: 'c1',
      seq: 0,
      role: GaiaMessageRole.user,
      parts: [GaiaTextPart(text)],
      status: GaiaMessageStatus.complete,
      createdAt: now,
      updatedAt: now,
    );

    final seed = AppDatabase(NativeDatabase(file));
    final seedRepo = DriftGaiaRepository(seed);
    await seedRepo.upsertChat(
      GaiaChat(
        id: 'c1',
        title: 'Hi',
        createdAt: now,
        updatedAt: now,
        lastMessageAt: now,
      ),
    );
    await seedRepo.upsertMessage(message('old words'));
    // As schema 169 left them: rowids of their own, and a row whose message
    // is gone.
    await seed.customStatement('DELETE FROM gaia_message_search');
    await seed.customStatement(
      'INSERT INTO gaia_message_search (rowid, body, message_id, chat_id) '
      "VALUES (900, 'old words', 'm1', 'c1'), (901, 'orphan', 'gone', 'c1')",
    );
    await seed.customStatement('PRAGMA user_version = 169');
    await seed.close();

    final upgraded = AppDatabase(NativeDatabase(file));
    addTearDown(upgraded.close);
    final repo = DriftGaiaRepository(upgraded);
    expect(await repo.searchChatIds('old'), {'c1'});
    expect(await repo.searchChatIds('orphan'), isEmpty);

    // An edit now replaces the renumbered row rather than adding beside it.
    await repo.upsertMessage(message('new words').copyWith(version: 2));
    expect(await repo.searchChatIds('old'), isEmpty);
    expect(await repo.searchChatIds('new'), {'c1'});
    expect(
      await upgraded.select(upgraded.gaiaMessageSearch).get(),
      hasLength(1),
    );
  });
}

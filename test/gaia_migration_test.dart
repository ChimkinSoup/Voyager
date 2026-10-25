// Schema 169 adds Gaia's chats, messages and settings, and the FTS5 table
// its search reads; 170 moves each search row to its message's rowid; 171
// adds Phase 2's tiers and agents; 172 the utility model and router; 173
// each reply's context size; 174 slash commands. The
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

  test(
    '170→171 adds tiers and agents, with defaults for what was there',
    () async {
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
      await seedRepo.upsertSettings(
        GaiaSettings.initial().copyWith(gaiaMd: 'Be brief.'),
      );
      for (final (table, column) in [
        ('gaia_chats_table', 'tier'),
        ('gaia_messages_table', 'adapter'),
        ('gaia_settings_table', 'agents_json'),
        ('gaia_settings_table', 'tiers_json'),
        ('gaia_settings_table', 'last_tier'),
      ]) {
        await seed.customStatement('ALTER TABLE $table DROP COLUMN $column');
      }
      await seed.customStatement('PRAGMA user_version = 170');
      await seed.close();

      final upgraded = AppDatabase(NativeDatabase(file));
      addTearDown(upgraded.close);
      final repo = DriftGaiaRepository(upgraded);
      final settings = await repo.getSettings();
      expect(settings.gaiaMd, 'Be brief.');
      expect(settings.agentFor(GaiaTier.deep)?.model, 'claude-opus-5-5');
      expect(settings.lastTier, GaiaTier.standard);
      final chat = (await repo.getChat('c1'))!;
      expect(chat.tier, isNull);

      await repo.upsertChat(chat.copyWith(tier: GaiaTier.quick));
      expect((await repo.getChat('c1'))!.tier, GaiaTier.quick);
      await repo.upsertSettings(
        settings.copyWith(
          agents: [
            ...settings.agents,
            const GaiaAgent(
              id: 'sol',
              label: 'GPT-6.1 Sol',
              adapter: kGaiaCodexAdapter,
              model: 'gpt-6.1-sol',
            ),
          ],
          tiers: {...settings.tiers, GaiaTier.deep: 'sol'},
          lastTier: GaiaTier.deep,
        ),
      );
      final saved = await repo.getSettings();
      expect(saved.agentFor(GaiaTier.deep)?.adapter, kGaiaCodexAdapter);
      expect(saved.lastTier, GaiaTier.deep);
    },
  );

  test('171→172 adds the utility model settings, off by default', () async {
    final seed = AppDatabase(NativeDatabase(file));
    await DriftGaiaRepository(
      seed,
    ).upsertSettings(GaiaSettings.initial().copyWith(gaiaMd: 'Be brief.'));
    for (final column in [
      'utility_model',
      'utility_acknowledged',
      'auto_route',
      'router_rubric',
    ]) {
      await seed.customStatement(
        'ALTER TABLE gaia_settings_table DROP COLUMN $column',
      );
    }
    await seed.customStatement('PRAGMA user_version = 171');
    await seed.close();

    final upgraded = AppDatabase(NativeDatabase(file));
    addTearDown(upgraded.close);
    final repo = DriftGaiaRepository(upgraded);
    final settings = await repo.getSettings();
    expect(settings.gaiaMd, 'Be brief.');
    expect(settings.utilityModel, kGaiaDefaultUtilityModel);
    expect(settings.utilityAcknowledged, isFalse);
    expect(settings.autoRoute, isTrue);
    expect(settings.routerRubric, isEmpty);

    await repo.upsertSettings(
      settings.copyWith(utilityAcknowledged: true, routerRubric: 'r'),
    );
    final saved = await repo.getSettings();
    expect(saved.utilityAcknowledged, isTrue);
    expect(saved.routerRubric, 'r');
  });

  test("172→173 adds a reply's context size", () async {
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
    final message = GaiaMessage(
      id: 'm1',
      chatId: 'c1',
      seq: 1,
      role: GaiaMessageRole.assistant,
      parts: const [GaiaTextPart('hello')],
      status: GaiaMessageStatus.complete,
      createdAt: now,
      updatedAt: now,
    );
    await seedRepo.upsertMessage(message);
    await seed.customStatement(
      'ALTER TABLE gaia_messages_table DROP COLUMN context_tokens',
    );
    await seed.customStatement('PRAGMA user_version = 172');
    await seed.close();

    final upgraded = AppDatabase(NativeDatabase(file));
    addTearDown(upgraded.close);
    final repo = DriftGaiaRepository(upgraded);
    expect((await repo.getMessage('m1'))!.contextTokens, isNull);
    await repo.upsertMessage(message.copyWith(contextTokens: 1234));
    expect((await repo.getMessage('m1'))!.contextTokens, 1234);
  });

  test('173→174 adds slash commands, none at first', () async {
    final seed = AppDatabase(NativeDatabase(file));
    await DriftGaiaRepository(
      seed,
    ).upsertSettings(GaiaSettings.initial().copyWith(gaiaMd: 'Be brief.'));
    await seed.customStatement(
      'ALTER TABLE gaia_settings_table DROP COLUMN commands_json',
    );
    await seed.customStatement('PRAGMA user_version = 173');
    await seed.close();

    final upgraded = AppDatabase(NativeDatabase(file));
    addTearDown(upgraded.close);
    final repo = DriftGaiaRepository(upgraded);
    final settings = await repo.getSettings();
    expect(settings.gaiaMd, 'Be brief.');
    expect(settings.commands, isEmpty);

    await repo.upsertSettings(
      settings.copyWith(
        commands: [const GaiaCommand(name: 'fix', template: 'Fix: x')],
      ),
    );
    expect((await repo.getSettings()).commands.single.template, 'Fix: x');
  });
}

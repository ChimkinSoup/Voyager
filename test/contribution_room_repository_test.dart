// The writes behind Contribute / Withdraw / Transfer, the paired deletes, the
// sync mapping, and the schema-112 upgrade.

import 'dart:io';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/core/sync/firestore_document_mapper.dart';
import 'package:voyager/core/utils/ids.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/data/repositories/drift_repositories.dart';
import 'package:voyager/domain/models/contribution_room_models.dart';
import 'package:voyager/domain/models/enums.dart';
import 'package:voyager/domain/models/finance_models.dart';
import 'package:voyager/domain/services/contribution_room_writer.dart';

final _t0 = DateTime.utc(2026, 1, 1);

void main() {
  late AppDatabase db;
  late DriftFinanceRepository repo;

  setUpAll(() => driftRuntimeOptions.dontWarnAboutMultipleDatabases = true);

  setUp(() {
    db = AppDatabase.inMemory();
    repo = DriftFinanceRepository(db);
  });

  tearDown(() => db.close());

  Future<ContributionRoom> addRoom({String id = 'room'}) async {
    final room = ContributionRoom(
      id: id,
      createdAt: _t0,
      updatedAt: _t0,
      name: 'TFSA',
      baselineRemainingCents: 700000,
      baselineAsOf: DateTime(2026, 3, 1, 9),
      annualLimits: const [AnnualLimit(fromYear: 2026, cents: 700000)],
    );
    await repo.upsertContributionRoom(room);
    return room;
  }

  Future<Asset> addAsset(String id, {String? roomId, int? valueCents}) async {
    final asset = Asset(
      id: id,
      createdAt: _t0,
      updatedAt: _t0,
      name: 'Asset $id',
      contributionRoomId: roomId,
    );
    await repo.upsertAsset(asset);
    if (valueCents != null) {
      await upsertValuationOnDay(
        repo,
        assetId: id,
        day: DateTime(2026, 2, 1),
        valueCents: valueCents,
      );
    }
    return asset;
  }

  Future<AssetRoomEvent> contribute(
    Asset asset,
    int cents, {
    RoomEventKind kind = RoomEventKind.contribution,
    int? valuationCents,
  }) => saveRoomCashEvent(
    repo,
    asset: asset,
    kind: kind,
    amountCents: cents,
    occurredAt: DateTime(2026, 3, 5, 12),
    note: 'March',
    valuationCents: valuationCents,
    eventId: newId(),
    transactionId: newId(),
  );

  test('rooms, links and events round-trip through the tables', () async {
    await addRoom();
    await addAsset('a', roomId: 'room');
    final room = (await repo.listContributionRooms()).single;
    expect(room.annualLimits, const [
      AnnualLimit(fromYear: 2026, cents: 700000),
    ]);
    expect(room.baselineAsOf, DateTime(2026, 3, 1, 9));
    expect((await repo.listAssets()).single.contributionRoomId, 'room');
  });

  test('contribute writes a linked deposit, the event and a valuation', () async {
    await addRoom();
    final asset = await addAsset('a', roomId: 'room', valueCents: 100000);

    final event = await contribute(asset, 25000, valuationCents: 125000);

    final tx = (await repo.listTransactions()).single;
    expect(tx.type, TransactionType.deposit);
    expect(tx.amountCents, 25000);
    expect(tx.roomEventId, event.id);
    expect(tx.origin, 'Asset a');
    expect(tx.note, 'March');

    final stored = (await repo.getAssetRoomEvent(event.id))!;
    expect(stored.transactionId, tx.id);
    expect(stored.roomId, 'room');

    final valuations = await repo.listAssetValuations(assetId: 'a');
    expect(valuations.first.valueCents, 125000);
    expect(valuations.first.asOf, DateTime(2026, 3, 5));
    expect(stored.valuationId, valuations.first.id);
  });

  test('withdraw writes an expense', () async {
    await addRoom();
    final asset = await addAsset('a', roomId: 'room');
    await contribute(asset, 5000, kind: RoomEventKind.withdrawal);
    expect(
      (await repo.listTransactions()).single.type,
      TransactionType.expense,
    );
  });

  test('a retry with the same ids overwrites instead of duplicating', () async {
    await addRoom();
    final asset = await addAsset('a', roomId: 'room');
    for (var i = 0; i < 2; i++) {
      await saveRoomCashEvent(
        repo,
        asset: asset,
        kind: RoomEventKind.contribution,
        amountCents: 1000,
        occurredAt: DateTime(2026, 3, 5, 12),
        eventId: 'ev',
        transactionId: 'tx',
      );
    }
    expect(await repo.listAssetRoomEvents(), hasLength(1));
    expect(await repo.listTransactions(), hasLength(1));
    expect((await repo.getAssetRoomEvent('ev'))!.version, 1);
  });

  test('refuses an asset outside any room', () async {
    final asset = await addAsset('a');
    expect(() => contribute(asset, 1000), throwsStateError);
  });

  test('deleting the ledger row takes the event; restore brings both', () async {
    await addRoom();
    final asset = await addAsset('a', roomId: 'room');
    final event = await contribute(asset, 25000);
    final tx = (await repo.listTransactions()).single;

    await repo.softDeleteTransaction(tx.id);
    expect(await repo.listAssetRoomEvents(), isEmpty);
    expect(await repo.listTransactions(), isEmpty);

    await repo.restoreAssetRoomEvent(event.id);
    final restored = (await repo.getAssetRoomEvent(event.id))!;
    expect(restored.deletedAt, isNull);
    expect(restored.version, greaterThan(event.version + 1));
    expect((await repo.getTransaction(tx.id))!.deletedAt, isNull);
  });

  test('deleting the event takes the ledger row but not the valuation',
      () async {
    await addRoom();
    final asset = await addAsset('a', roomId: 'room');
    final event = await contribute(asset, 25000, valuationCents: 25000);

    await repo.softDeleteAssetRoomEvent(event.id);
    expect(await repo.listTransactions(), isEmpty);
    expect(await repo.listAssetValuations(assetId: 'a'), hasLength(1));
  });

  test('a transfer is two legs, no ledger rows, deleted together', () async {
    await addRoom();
    final a = await addAsset('a', roomId: 'room');
    final b = await addAsset('b', roomId: 'room');

    await saveRoomTransfer(
      repo,
      from: a,
      to: b,
      amountCents: 40000,
      occurredAt: DateTime(2026, 4, 1, 12),
      fromValuationCents: 60000,
      toValuationCents: 40000,
      transferGroupId: 'grp',
      outLegId: 'out',
      inLegId: 'in',
    );

    final legs = await repo.listAssetRoomEvents();
    expect(legs, hasLength(2));
    final out = legs.firstWhere((l) => l.id == 'out');
    final into = legs.firstWhere((l) => l.id == 'in');
    expect(out.kind, RoomEventKind.transferOut);
    expect(out.assetId, 'a');
    expect(out.counterAssetId, 'b');
    expect(into.kind, RoomEventKind.transferIn);
    expect(into.assetId, 'b');
    expect(await repo.listTransactions(), isEmpty);
    expect(
      roomYearSummary(
        (await repo.listContributionRooms()).single,
        legs,
        now: DateTime(2026, 5, 1),
      ).remainingCents,
      700000,
    );

    await repo.softDeleteAssetRoomEvent('in');
    expect(await repo.listAssetRoomEvents(), isEmpty);
    await repo.restoreAssetRoomEvent('out');
    expect(await repo.listAssetRoomEvents(), hasLength(2));
  });

  test('a transfer across rooms is refused', () async {
    await addRoom();
    await addRoom(id: 'fhsa');
    final a = await addAsset('a', roomId: 'room');
    final b = await addAsset('b', roomId: 'fhsa');
    expect(
      () => saveRoomTransfer(
        repo,
        from: a,
        to: b,
        amountCents: 1,
        occurredAt: DateTime(2026, 4, 1),
        transferGroupId: 'g',
        outLegId: 'o',
        inLegId: 'i',
      ),
      throwsArgumentError,
    );
  });

  test('deleting a room detaches its assets and keeps its events', () async {
    await addRoom();
    final asset = await addAsset('a', roomId: 'room');
    await contribute(asset, 1000);

    await repo.softDeleteContributionRoom('room');
    expect(await repo.listContributionRooms(), isEmpty);
    expect((await repo.listAssets()).single.contributionRoomId, isNull);
    expect(await repo.listAssetRoomEvents(), hasLength(1));
  });

  test('editing a linked ledger row updates its event', () async {
    await addRoom();
    final asset = await addAsset('a', roomId: 'room');
    final event = await contribute(asset, 1000);
    final tx = (await repo.listTransactions()).single;

    final edited = tx.copyWith(
      amountCents: 3000,
      occurredAt: DateTime(2026, 3, 9, 12),
      version: tx.version + 1,
    );
    await repo.upsertTransaction(edited);
    await syncRoomEventFromTransaction(repo, edited);

    final stored = (await repo.getAssetRoomEvent(event.id))!;
    expect(stored.amountCents, 3000);
    expect(stored.occurredAt, DateTime(2026, 3, 9, 12));
    expect(stored.version, event.version + 1);
  });

  group('sync mapping', () {
    test('room and event survive a round trip', () {
      final room = ContributionRoom(
        id: 'room',
        createdAt: _t0,
        updatedAt: _t0,
        version: 3,
        name: 'TFSA',
        baselineRemainingCents: -500,
        baselineAsOf: DateTime.utc(2026, 3, 1, 9),
        annualLimits: const [
          AnnualLimit(fromYear: 2026, cents: 700000),
          AnnualLimit(fromYear: 2027, cents: 750000),
        ],
      );
      final back = mergeContributionRoomFromRemote(
        contributionRoomToFirestore(room),
        'room',
      );
      expect(back.baselineRemainingCents, -500);
      expect(back.annualLimits, room.annualLimits);
      expect(back.baselineAsOf, room.baselineAsOf);

      final event = AssetRoomEvent(
        id: 'ev',
        createdAt: _t0,
        updatedAt: _t0,
        assetId: 'a',
        roomId: 'room',
        kind: RoomEventKind.transferIn,
        amountCents: 900,
        occurredAt: DateTime.utc(2026, 4, 1),
        counterAssetId: 'b',
        transferGroupId: 'g',
      );
      final eventBack = mergeAssetRoomEventFromRemote(
        assetRoomEventToFirestore(event),
        'ev',
      );
      expect(eventBack.kind, RoomEventKind.transferIn);
      expect(eventBack.counterAssetId, 'b');
      expect(eventBack.transferGroupId, 'g');
    });

    test('detaching an asset reaches the other device', () {
      final local = Asset(
        id: 'a',
        createdAt: _t0,
        updatedAt: _t0,
        name: 'TFSA',
        contributionRoomId: 'room',
      );
      final remote = assetToFirestore(
        local.copyWith(
          clearContributionRoomId: true,
          version: 1,
          updatedAt: _t0.add(const Duration(minutes: 1)),
        ),
      );
      expect(remote.containsKey('contributionRoomId'), isTrue);
      expect(
        mergeAssetFromRemote(remote, 'a', local: local).contributionRoomId,
        isNull,
      );
    });

    test('a document from before the fields keeps the local link', () {
      final local = FinancialTransaction(
        id: 't',
        createdAt: _t0,
        updatedAt: _t0,
        type: TransactionType.deposit,
        amountCents: 1,
        occurredAt: _t0,
        roomEventId: 'ev',
      );
      final old = transactionToFirestore(local.copyWith(version: 1))
        ..remove('roomEventId');
      expect(
        mergeTransactionFromRemote(old, 't', local: local).roomEventId,
        'ev',
      );
    });
  });

  test('a schema-111 database upgrades with its assets untracked', () async {
    final dir = Directory.systemTemp.createTempSync('voyager_room_migration');
    addTearDown(() => dir.deleteSync(recursive: true));
    final file = File('${dir.path}/voyager.sqlite');

    final seed = AppDatabase(NativeDatabase(file));
    await DriftFinanceRepository(seed).upsertAsset(
      Asset(id: 'a', createdAt: _t0, updatedAt: _t0, name: 'Old'),
    );
    await seed.customStatement('DROP TABLE contribution_rooms_table');
    await seed.customStatement('DROP TABLE asset_room_events_table');
    await seed.customStatement(
      'ALTER TABLE assets_table DROP COLUMN contribution_room_id',
    );
    await seed.customStatement(
      'ALTER TABLE transactions_table DROP COLUMN room_event_id',
    );
    await seed.customStatement('PRAGMA user_version = 111');
    await seed.close();

    final upgraded = AppDatabase(NativeDatabase(file));
    addTearDown(upgraded.close);
    final upgradedRepo = DriftFinanceRepository(upgraded);
    final asset = (await upgradedRepo.listAssets()).single;
    expect(asset.name, 'Old');
    expect(asset.contributionRoomId, isNull);
    expect(await upgradedRepo.listContributionRooms(), isEmpty);
    expect(await upgradedRepo.listAssetRoomEvents(), isEmpty);
  });
}

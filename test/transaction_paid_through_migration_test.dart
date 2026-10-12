// v145: a database that ran a development build of the v144 upgrade got
// `subscription_id` and `settles_due_date` but not `paid_through_before`, and
// stayed at user_version 144, so every transaction insert failed (including
// the startup pull). v145 adds whichever of the three columns is missing.

import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/core/utils/ids.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/data/repositories/drift_repositories.dart';
import 'package:voyager/domain/models/enums.dart';
import 'package:voyager/domain/models/finance_models.dart';

void main() {
  test('a schema-144 database missing paid_through_before gets it back', () async {
    final dir = Directory.systemTemp.createTempSync('voyager_paid_through_mig');
    addTearDown(() => dir.deleteSync(recursive: true));
    final file = File('${dir.path}/voyager.sqlite');

    final seed = AppDatabase(NativeDatabase(file));
    for (final statement in [
      'ALTER TABLE transactions_table DROP COLUMN paid_through_before',
      'PRAGMA user_version = 144',
    ]) {
      await seed.customStatement(statement);
    }
    await seed.close();

    final db = AppDatabase(NativeDatabase(file));
    addTearDown(db.close);
    final repository = DriftFinanceRepository(db);
    final now = utcNow();
    await repository.upsertTransaction(
      FinancialTransaction(
        id: 'pay',
        createdAt: now,
        updatedAt: now,
        type: TransactionType.expense,
        amountCents: 141500,
        occurredAt: DateTime(2026, 10, 3),
        subscriptionId: 'rent',
        settlesDueDate: DateTime(2026, 11, 1),
        paidThroughBefore: DateTime(2026, 10, 1),
      ),
    );
    final loaded = (await repository.getTransaction('pay'))!;
    expect(loaded.subscriptionId, 'rent');
    expect(loaded.settlesDueDate, DateTime(2026, 11, 1));
    expect(loaded.paidThroughBefore, DateTime(2026, 10, 1));
  });
}

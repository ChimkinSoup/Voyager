// Schema 92 gives a pipeline stage an optional colour. Existing databases
// carry stages written without one, and the upgrade has to leave them intact
// and un-coloured — a stage with no colour of its own is what keeps the
// position-derived hue the header already showed, so upgrading must not
// repaint a pipeline the user never asked to change.

import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/core/utils/ids.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/data/repositories/drift_repositories.dart';
import 'package:voyager/domain/models/job_models.dart';

/// Rewinds a schema-92 database to look like a schema-91 one: drops the column
/// the upgrade adds and resets user_version, so reopening it runs the real
/// onUpgrade path rather than a hand-written approximation of it.
Future<void> _rewindToSchema91(File file) async {
  final db = AppDatabase(NativeDatabase(file));
  await db.customStatement(
    'ALTER TABLE job_stages_table DROP COLUMN color_value',
  );
  await db.customStatement('PRAGMA user_version = 91');
  await db.close();
}

void main() {
  late Directory dir;
  late File file;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('voyager_stage_color_test');
    file = File('${dir.path}/voyager.sqlite');
  });

  tearDown(() => dir.deleteSync(recursive: true));

  test('the upgrade adds color_value and leaves the stages it finds', () async {
    final now = utcNow();
    var db = AppDatabase(NativeDatabase(file));
    var repo = DriftJobRepository(db);
    await repo.upsertStage(
      JobStage(
        id: 'applied',
        name: 'Applied',
        sortOrder: 0,
        createdAt: now,
        updatedAt: now,
      ),
    );
    await repo.upsertStage(
      JobStage(
        id: 'interview',
        name: 'Interview',
        sortOrder: 1,
        createdAt: now,
        updatedAt: now,
      ),
    );
    await db.close();

    await _rewindToSchema91(file);

    db = AppDatabase(NativeDatabase(file));
    repo = DriftJobRepository(db);
    final stages = await repo.listStages();

    expect(stages.map((stage) => stage.name), ['Applied', 'Interview']);
    expect(
      stages.map((stage) => stage.colorValue),
      everyElement(isNull),
      reason: 'an upgraded stage keeps the position-derived colour',
    );

    // And the new column is writable on the migrated table.
    await repo.upsertStage(stages.first.copyWith(colorValue: 0xFF2E7D32));
    expect((await repo.listStages()).first.colorValue, 0xFF2E7D32);
    await db.close();
  });
}

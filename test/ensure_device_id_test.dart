import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/data/repositories/drift_repositories.dart';

void main() {
  test(
    'callers at once on a fresh install all get the id that is saved',
    () async {
      final db = AppDatabase.inMemory();
      addTearDown(db.close);
      final settings = DriftSettingsRepository(db);

      // The bootstrap and Gaia's attach both ask during the first launch.
      final ids = await Future.wait([
        ensureDeviceId(settings),
        ensureDeviceId(settings),
      ]);

      final saved = (await settings.getSettings()).deviceId;
      expect(saved, isNotNull);
      expect(ids, [saved, saved]);
      expect(await ensureDeviceId(settings), saved);
    },
  );
}

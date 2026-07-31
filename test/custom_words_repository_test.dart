import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/data/repositories/drift_repositories.dart';

void main() {
  late AppDatabase db;
  late DriftSettingsRepository settingsRepo;

  setUp(() {
    db = AppDatabase.inMemory();
    settingsRepo = DriftSettingsRepository(db);
  });

  tearDown(() async {
    await db.close();
  });

  test('addCustomWord persists and getCustomWords returns it', () async {
    await settingsRepo.addCustomWord('voyager');
    expect(await settingsRepo.getCustomWords(), {'voyager'});
  });

  test('addCustomWord normalizes case', () async {
    await settingsRepo.addCustomWord('Voyager');
    expect(await settingsRepo.getCustomWords(), {'voyager'});
  });

  test('addCustomWord is idempotent', () async {
    await settingsRepo.addCustomWord('voyager');
    await settingsRepo.addCustomWord('voyager');
    expect(await settingsRepo.getCustomWords(), {'voyager'});
  });

  test('removeCustomWord deletes the word', () async {
    await settingsRepo.addCustomWord('voyager');
    await settingsRepo.removeCustomWord('voyager');
    expect(await settingsRepo.getCustomWords(), isEmpty);
  });

  test('getCustomWords returns empty set when nothing added', () async {
    expect(await settingsRepo.getCustomWords(), isEmpty);
  });
}

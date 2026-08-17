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

  group('renameCustomWord', () {
    test('the new spelling replaces the old one', () async {
      await settingsRepo.addCustomWord('voyagr');
      await settingsRepo.renameCustomWord('voyagr', 'voyager');
      expect(await settingsRepo.getCustomWords(), {'voyager'});
    });

    test('the old spelling stays as a tombstone so the rename syncs', () async {
      // Dropping the row instead would leave the other devices with a live
      // 'voyagr' document and nothing telling them it is gone.
      await settingsRepo.addCustomWord('voyagr');
      await settingsRepo.renameCustomWord('voyagr', 'voyager');
      final old = await settingsRepo.getCustomWordRecord('voyagr');
      expect(old, isNotNull);
      expect(old!.deletedAt, isNotNull);
      expect(old.version, greaterThan(0));
    });

    test('normalizes both spellings', () async {
      await settingsRepo.addCustomWord('Voyagr');
      await settingsRepo.renameCustomWord('  VOYAGR ', ' Voyager ');
      expect(await settingsRepo.getCustomWords(), {'voyager'});
    });

    test('renaming onto a word already added is refused', () async {
      await settingsRepo.addCustomWord('voyagr');
      await settingsRepo.addCustomWord('voyager');
      await settingsRepo.renameCustomWord('voyagr', 'voyager');
      // Neither side applied: the rename would have silently swallowed one of
      // the two words.
      expect(await settingsRepo.getCustomWords(), {'voyagr', 'voyager'});
    });

    test('renaming onto a word removed earlier clears its tombstone', () async {
      await settingsRepo.addCustomWord('voyager');
      await settingsRepo.removeCustomWord('voyager');
      await settingsRepo.addCustomWord('voyagr');
      await settingsRepo.renameCustomWord('voyagr', 'voyager');
      expect(await settingsRepo.getCustomWords(), {'voyager'});
    });

    test('renaming a word that was never added does nothing', () async {
      await settingsRepo.renameCustomWord('voyagr', 'voyager');
      expect(await settingsRepo.getCustomWords(), isEmpty);
    });

    test('a rename to the same word is a no-op, not a delete', () async {
      await settingsRepo.addCustomWord('voyager');
      await settingsRepo.renameCustomWord('voyager', 'Voyager');
      expect(await settingsRepo.getCustomWords(), {'voyager'});
      expect(
        (await settingsRepo.getCustomWordRecord('voyager'))!.deletedAt,
        isNull,
      );
    });

    test('a spelling the tokenizer could never produce is refused', () async {
      // Anything the checker will not look up would sit in the dictionary
      // doing nothing, with no way for the user to tell.
      await settingsRepo.addCustomWord('voyagr');
      await settingsRepo.renameCustomWord('voyagr', 'well-known');
      await settingsRepo.renameCustomWord('voyagr', 'two words');
      await settingsRepo.renameCustomWord('voyagr', '');
      expect(await settingsRepo.getCustomWords(), {'voyagr'});
    });
  });
}

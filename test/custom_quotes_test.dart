import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/core/sync/firestore_document_mapper.dart';
import 'package:voyager/core/utils/ids.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/data/repositories/drift_repositories.dart';
import 'package:voyager/domain/models/settings_models.dart';

void main() {
  group('sameQuoteText', () {
    test('ignores case, surrounding space and repeated whitespace', () {
      // What the settings editor rejects a second copy on: a quote retyped
      // slightly differently is still the same quote in the pool.
      expect(sameQuoteText('Carpe diem', '  carpe   DIEM '), isTrue);
    });

    test('different quotes are not the same', () {
      expect(sameQuoteText('Carpe diem', 'Carpe noctem'), isFalse);
    });
  });

  group('custom quote repository', () {
    late AppDatabase db;
    late DriftSettingsRepository repo;

    CustomQuote quote(String id, String text) {
      final now = utcNow();
      return CustomQuote(id: id, text: text, createdAt: now, updatedAt: now);
    }

    setUp(() {
      db = AppDatabase.inMemory();
      repo = DriftSettingsRepository(db);
    });

    tearDown(() async {
      await db.close();
    });

    test('upsert then read back', () async {
      await repo.upsertCustomQuote(quote('q1', 'Carpe diem'));
      final all = await repo.getCustomQuotes();
      expect(all.map((q) => q.text), ['Carpe diem']);
      expect((await repo.getCustomQuote('q1'))?.text, 'Carpe diem');
    });

    test('upsert on the same id edits rather than duplicates', () async {
      await repo.upsertCustomQuote(quote('q1', 'Carpe diem'));
      await repo.upsertCustomQuote(quote('q1', 'Carpe noctem'));
      final all = await repo.getCustomQuotes();
      expect(all.map((q) => q.text), ['Carpe noctem']);
    });

    test('a soft-deleted quote leaves the pool but not the table', () async {
      // The tombstone has to survive locally so the delete can propagate to
      // the other devices; only the pool query hides it.
      await repo.upsertCustomQuote(quote('q1', 'Carpe diem'));
      await repo.softDeleteCustomQuote('q1');
      expect(await repo.getCustomQuotes(), isEmpty);
      final withDeleted = await repo.getCustomQuotes(includeDeleted: true);
      expect(withDeleted.single.deletedAt, isNotNull);
    });

    test('getCustomQuote returns null for an unknown id', () async {
      expect(await repo.getCustomQuote('nope'), isNull);
    });
  });

  group('custom quote sync mapping', () {
    final createdAt = DateTime.utc(2026, 1, 1);

    test('round trips through firestore', () {
      final original = CustomQuote(
        id: 'q1',
        text: 'Carpe diem',
        createdAt: createdAt,
        updatedAt: DateTime.utc(2026, 2, 1),
        version: 3,
      );
      final merged = mergeCustomQuoteFromRemote(
        customQuoteToFirestore(original),
        'q1',
      );
      expect(merged.text, 'Carpe diem');
      expect(merged.createdAt, createdAt);
      expect(merged.updatedAt, DateTime.utc(2026, 2, 1));
      expect(merged.version, 3);
      expect(merged.deletedAt, isNull);
    });

    test('a newer local edit wins over an older remote one', () {
      final local = CustomQuote(
        id: 'q1',
        text: 'Local wording',
        createdAt: createdAt,
        updatedAt: DateTime.utc(2026, 3, 1),
        version: 5,
      );
      final remote = customQuoteToFirestore(
        CustomQuote(
          id: 'q1',
          text: 'Remote wording',
          createdAt: createdAt,
          updatedAt: DateTime.utc(2026, 2, 1),
          version: 2,
        ),
      );
      expect(
        mergeCustomQuoteFromRemote(remote, 'q1', local: local).text,
        'Local wording',
      );
    });

    test('a remote delete applies', () {
      final deletedAt = DateTime.utc(2026, 4, 1);
      final remote = customQuoteToFirestore(
        CustomQuote(
          id: 'q1',
          text: 'Carpe diem',
          createdAt: createdAt,
          updatedAt: deletedAt,
          version: 9,
          deletedAt: deletedAt,
        ),
      );
      expect(
        mergeCustomQuoteFromRemote(remote, 'q1').deletedAt,
        deletedAt,
      );
    });
  });
}

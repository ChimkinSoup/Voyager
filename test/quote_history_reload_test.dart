import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/domain/models/journal_models.dart';
import 'package:voyager/domain/models/settings_models.dart';

void main() {
  test('reloading the history lets the bank see a synced draw', () async {
    final db = AppDatabase(NativeDatabase.memory());
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        quotePoolProvider.overrideWith(
          (ref) => const [
            Quote(id: 'a', text: 'A'),
            Quote(id: 'b', text: 'B'),
          ],
        ),
      ],
    );
    addTearDown(() async {
      container.dispose();
      await db.close();
    });

    await container.read(quotesLoadedProvider.future);

    // As a pull from another device would land them: straight into the
    // table, 'a' drawn today in each of twenty journals.
    final now = DateTime.now().toUtc();
    final journals = [for (var i = 0; i < 20; i++) 'j$i'];
    for (final journalId in journals) {
      await container
          .read(journalRepositoryProvider)
          .upsertEntry(
            JournalEntry(
              id: 'e-$journalId',
              createdAt: now,
              updatedAt: now,
              journalId: journalId,
              title: '',
              body: '',
              entryDate: now,
              quoteId: 'a',
            ),
            recordLocalActivity: false,
          );
    }
    container.invalidate(quoteHistoryProvider);
    await container.read(quotesLoadedProvider.future);

    // Blind to those draws, the bank would pick 'b' in all twenty only one
    // time in about a million.
    final bank = container.read(quoteBankProvider);
    for (final journalId in journals) {
      expect(bank.nextQuote(journalId).id, 'b', reason: journalId);
    }
  });
}

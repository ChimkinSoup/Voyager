import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/core/soft_delete/soft_delete_toast.dart';

void main() {
  group('restoreVersionFrom', () {
    test('outranks the tombstone a bumping soft delete left on disk', () {
      // The delete wrote version + 1 and that is what a re-read finds; the
      // restore has to beat it, not tie it.
      expect(
        restoreVersionFrom(preDeleteVersion: 7, currentVersion: 8),
        greaterThan(8),
      );
    });

    test('outranks a tombstone written without a version bump', () {
      // A couple of tables stamp `deletedAt` straight onto the row.
      expect(
        restoreVersionFrom(preDeleteVersion: 7, currentVersion: 7),
        greaterThan(7),
      );
    });

    test('outranks a revision a pull landed during the undo window', () {
      // The whole point: another device edited the row three times while the
      // offer stood. A restore at the snapshot's own +2 would lose the next
      // pull and take the row away again.
      expect(
        restoreVersionFrom(preDeleteVersion: 7, currentVersion: 11),
        greaterThan(11),
      );
    });

    test('still clears the tombstone when the row is gone from disk', () {
      // Nothing local to read, but Firestore may still hold the tombstone the
      // delete pushed at preDeleteVersion + 1.
      expect(
        restoreVersionFrom(preDeleteVersion: 7, currentVersion: null),
        greaterThan(7 + 1),
      );
    });

    test('never goes backwards on a disk copy that lags the snapshot', () {
      expect(
        restoreVersionFrom(preDeleteVersion: 7, currentVersion: 2),
        greaterThan(7),
      );
    });

    test('is monotonic across repeated delete/restore cycles', () {
      var version = 0;
      for (var i = 0; i < 5; i++) {
        final tombstone = version + 1;
        version = restoreVersionFrom(
          preDeleteVersion: version,
          currentVersion: tombstone,
        );
        expect(version, greaterThan(tombstone));
      }
    });
  });

  group('abortIfAlreadyRestored', () {
    test('aborts once the row is live on disk again', () {
      // A pull brought it back during the undo window. Writing the older
      // snapshot over it is data loss, not an undo.
      expect(
        () => abortIfAlreadyRestored(found: true, deletedAt: null),
        throwsA(isA<RestoreSuperseded>()),
      );
    });

    test('lets a still-tombstoned row through', () {
      expect(
        () => abortIfAlreadyRestored(found: true, deletedAt: DateTime.now()),
        returnsNormally,
      );
    });

    test('lets a row that is not on disk at all through', () {
      // Purged locally rather than restored — there is still an undo to do.
      expect(
        () => abortIfAlreadyRestored(found: false, deletedAt: null),
        returnsNormally,
      );
    });
  });

  group('deletedMessage', () {
    test('quotes a name it was given', () {
      expect(deletedMessage('Groceries', fallback: 'transaction'),
          'Deleted "Groceries"');
    });

    test('trims before quoting', () {
      expect(deletedMessage('  Groceries \n', fallback: 'transaction'),
          'Deleted "Groceries"');
    });

    test('falls back rather than showing empty quotes', () {
      expect(deletedMessage(null, fallback: 'entry'), 'Deleted entry');
      expect(deletedMessage('', fallback: 'entry'), 'Deleted entry');
      expect(deletedMessage('   ', fallback: 'entry'), 'Deleted entry');
    });

    test('leaves a name that already fits alone', () {
      final name = 'x' * 48;
      expect(deletedMessage(name, fallback: 'task'), 'Deleted "$name"');
    });

    test('cuts a long name down and keeps the closing quote', () {
      final message = deletedMessage('y' * 200, fallback: 'task');
      expect(message, 'Deleted "${'y' * 48}…"');
    });

    test('takes the whitespace at the cut with it', () {
      // Otherwise a name that happens to break on a space reads as "… …".
      final name = '${'z' * 47} tail that runs on';
      expect(deletedMessage(name, fallback: 'task'), 'Deleted "${'z' * 47}…"');
    });

    test('never cuts inside a grapheme cluster', () {
      // 50 flags: each is a pair of regional indicators, so a code-unit cut
      // would leave half a flag — a lone letter — at the end.
      final message = deletedMessage('🇦🇺' * 50, fallback: 'card');
      expect(message, 'Deleted "${'🇦🇺' * 48}…"');
    });
  });
}

// The shared "where does a new item go?" rule behind the Todo page's
// "All tasks" view and the Journal page's "All journals" view. Both pages call
// resolveNewItemTarget, so these cases pin the behaviour for both at once.

import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/core/utils/all_view_destination.dart';

void main() {
  group('resolveNewItemTarget', () {
    test('prefers the list currently being viewed', () {
      expect(
        resolveNewItemTarget(
          currentId: 'work',
          lastViewedId: 'personal',
          legacyId: 'legacy',
          availableIds: const ['legacy', 'work', 'personal'],
        ),
        'work',
      );
    });

    test('falls back to the persisted id when there is no current one', () {
      // The all-view restored from settings: nothing is selected in-page yet,
      // but the id recorded last session still names the real destination.
      expect(
        resolveNewItemTarget(
          currentId: null,
          lastViewedId: 'personal',
          legacyId: 'legacy',
          availableIds: const ['legacy', 'work', 'personal'],
        ),
        'personal',
      );
    });

    test('skips ids that no longer exist', () {
      expect(
        resolveNewItemTarget(
          currentId: 'deleted',
          lastViewedId: 'also-deleted',
          legacyId: 'legacy',
          availableIds: const ['legacy', 'work'],
        ),
        'legacy',
      );
    });

    test('falls back to the first id when even the default is gone', () {
      expect(
        resolveNewItemTarget(
          currentId: null,
          lastViewedId: null,
          legacyId: 'legacy',
          availableIds: const ['work', 'personal'],
        ),
        'work',
      );
    });

    test('returns null only when there is nothing to file into', () {
      expect(
        resolveNewItemTarget(
          currentId: 'work',
          lastViewedId: 'personal',
          legacyId: 'legacy',
          availableIds: const [],
        ),
        isNull,
      );
    });
  });

  group('shortDestinationName', () {
    test('leaves names that already fit alone', () {
      expect(shortDestinationName('Work'), 'Work');
      expect(shortDestinationName('  Work  '), 'Work');
    });

    test('truncates long names to the budget, ellipsis included', () {
      final short = shortDestinationName('Personal Reflections');
      expect(short.length, 14);
      expect(short, endsWith('…'));
      expect(short, startsWith('Personal'));
    });

    test('does not leave a space stranded before the ellipsis', () {
      // The 13-character cut lands on a space, which would otherwise read as
      // "Reading list …".
      expect(shortDestinationName('Reading list here'), 'Reading list…');
    });
  });
}

import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/core/spellcheck/flagged_word_rules.dart';
import 'package:voyager/core/spellcheck/voyager_spell_check_service.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/data/repositories/drift_repositories.dart';

/// The data and set-arithmetic halves of `FLAGGED_WORDS.md`. The typing half —
/// pairs applied at a boundary, the flash, the revert — lives in
/// `autocorrect_session_test.dart`, where the real widget path is.
void main() {
  group('known-set subtraction', () {
    late VoyagerSpellCheckService service;

    setUp(() {
      service = VoyagerSpellCheckService()
        ..updateDictionary({'neve', 'never', 'nerve', 'form', 'from'});
    });

    test('a flagged word leaves the known set', () {
      expect(service.knownWords, contains('neve'));
      service.updateFlaggedWords({'neve': null});
      expect(service.knownWords, isNot(contains('neve')));
      expect(service.knownWords, contains('never'));
    });

    test('a flagged word is checked as a misspelling', () {
      expect(service.checkTextSync('neve from'), isEmpty);
      service.updateFlaggedWords({'neve': null});
      final spans = service.checkTextSync('neve from');
      expect(spans, hasLength(1));
      expect(spans.single.range.start, 0);
      expect(spans.single.range.end, 4);
    });

    test('flagging bumps the generation so open fields repaint', () {
      final before = service.generation;
      service.updateFlaggedWords({'neve': null});
      expect(service.generation, greaterThan(before));
    });

    test('a flagged word is not a suggestion target', () {
      service.updateFlaggedWords({'neve': null});
      final spans = service.checkTextSync('nvee', includeSuggestions: true);
      expect(spans.single.suggestions, isNot(contains('neve')));
    });

    test('a custom word can be flagged out of the set too', () {
      service.updateCustomWords({'voyagr'});
      expect(service.knownWords, contains('voyagr'));
      service.updateFlaggedWords({'voyagr': null});
      expect(service.knownWords, isNot(contains('voyagr')));
    });

    test('replacementFor reads the stored pair, case-insensitively', () {
      service.updateFlaggedWords({'neve': 'never', 'form': null});
      expect(service.replacementFor('Neve'), 'never');
      expect(service.replacementFor('form'), isNull);
      expect(service.isFlagged('FORM'), isTrue);
      expect(service.isFlagged('never'), isFalse);
    });
  });

  group('rules', () {
    const known = {'never', 'nerve', 'from', 'than'};

    test('a flag has to be one word token', () {
      expect(validateFlagWord('neve', const {}), isNull);
      expect(validateFlagWord('well-known', const {}), isNotNull);
      expect(validateFlagWord('two words', const {}), isNotNull);
    });

    test('flagging the target of an existing pair is refused by name', () {
      final error = validateFlagWord('never', {'neve': 'never'});
      expect(error, isNotNull);
      // Naming the rule is the point: silently clearing it would hide
      // something the user wrote (§10).
      expect(error, contains('neve'));
    });

    test('an unrelated pair does not block a flag', () {
      expect(validateFlagWord('form', {'neve': 'never'}), isNull);
    });

    test('an empty replacement is a flag with no pair', () {
      expect(
        validateFlagReplacement(
          word: 'neve',
          replacement: '',
          known: known,
          flagged: const {},
        ),
        isNull,
      );
    });

    test('a replacement equal to the flagged word is refused', () {
      expect(
        validateFlagReplacement(
          word: 'neve',
          replacement: 'neve',
          known: known,
          flagged: const {},
        ),
        isNotNull,
      );
    });

    test('a replacement the checker does not know is refused', () {
      expect(
        validateFlagReplacement(
          word: 'neve',
          replacement: 'nevar',
          known: known,
          flagged: const {},
        ),
        isNotNull,
      );
    });

    test('a replacement that is itself flagged is refused', () {
      final error = validateFlagReplacement(
        word: 'neve',
        replacement: 'nerve',
        known: known,
        flagged: const {'nerve': null},
      );
      expect(error, isNotNull);
      expect(error, contains('flagged'));
    });

    test('a legal replacement passes', () {
      expect(
        validateFlagReplacement(
          word: 'neve',
          replacement: 'never',
          known: known,
          flagged: const {},
        ),
        isNull,
      );
    });
  });

  group('repository', () {
    late AppDatabase db;
    late DriftSettingsRepository repo;

    setUp(() {
      db = AppDatabase.inMemory();
      repo = DriftSettingsRepository(db);
    });

    tearDown(() async {
      await db.close();
    });

    test('flagWord persists the word and its replacement', () async {
      await repo.flagWord('Neve', replacement: 'Never');
      expect(await repo.getFlaggedWords(), {'neve': 'never'});
    });

    test('a flag with no replacement maps to null', () async {
      await repo.flagWord('neve');
      expect(await repo.getFlaggedWords(), {'neve': null});
    });

    test('flagWord refuses a replacement equal to the word', () async {
      await repo.flagWord('neve', replacement: 'neve');
      expect(await repo.getFlaggedWords(), isEmpty);
    });

    test('flagWord refuses a word the tokenizer cannot produce', () async {
      await repo.flagWord('well-known');
      expect(await repo.getFlaggedWords(), isEmpty);
    });

    test('flagging a word that is also custom tombstones the custom row',
        () async {
      // §10: otherwise "remove the custom word" would look like it worked
      // while the bundled spelling kept the word known.
      await repo.addCustomWord('neve');
      await repo.flagWord('neve');
      expect(await repo.getCustomWords(), isEmpty);
      expect(await repo.getFlaggedWords(), {'neve': null});
      final custom = await repo.getCustomWordRecord('neve');
      expect(custom!.deletedAt, isNotNull);
    });

    test('setFlaggedReplacement edits in place and can clear', () async {
      await repo.flagWord('neve', replacement: 'never');
      await repo.setFlaggedReplacement('neve', 'nerve');
      expect(await repo.getFlaggedWords(), {'neve': 'nerve'});
      await repo.setFlaggedReplacement('neve', null);
      // Clearing the replacement keeps the flag (§7).
      expect(await repo.getFlaggedWords(), {'neve': null});
    });

    test('setFlaggedReplacement does nothing for an unflagged word', () async {
      await repo.setFlaggedReplacement('neve', 'never');
      expect(await repo.getFlaggedWords(), isEmpty);
    });

    test('unflagWord tombstones rather than dropping the row', () async {
      await repo.flagWord('neve', replacement: 'never');
      await repo.unflagWord('neve');
      expect(await repo.getFlaggedWords(), isEmpty);
      final row = await repo.getFlaggedWordRecord('neve');
      expect(row, isNotNull);
      expect(row!.deletedAt, isNotNull);
      // The replacement goes with the flag: stopping is not a state that keeps
      // a rewrite rule the user can no longer see.
      expect(row.replacement, isNull);
      expect(row.version, greaterThan(0));
    });

    test('re-flagging a lifted flag clears its tombstone', () async {
      await repo.flagWord('neve');
      await repo.unflagWord('neve');
      await repo.flagWord('neve', replacement: 'never');
      expect(await repo.getFlaggedWords(), {'neve': 'never'});
    });

    test('purgeExpiredDeleted drops old flag tombstones', () async {
      await repo.flagWord('neve');
      await repo.unflagWord('neve');
      await repo.purgeExpiredDeleted(
        DateTime.now().add(const Duration(days: 3650)),
      );
      expect(await repo.getFlaggedWordRecord('neve'), isNull);
    });
  });
}

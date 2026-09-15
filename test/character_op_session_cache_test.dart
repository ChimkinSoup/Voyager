import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/domain/services/character_op_session.dart';

/// [CharacterOpSession] caches its live ops in document order instead of
/// sorting every op on every keystroke. The cache is only right if it matches
/// what a fresh sort of the same ops produces, which is what every test here
/// checks by rebuilding a session from [CharacterOpSession.allOps].
void main() {
  String rebuilt(CharacterOpSession session) =>
      CharacterOpSession(clientId: 'x', initialOperations: session.allOps).text;

  test('random edits keep the cached order equal to a fresh sort', () {
    const alphabet = 'abcdefgh \n';
    for (var seed = 0; seed < 8; seed++) {
      final random = Random(seed);
      var text = 'The quick brown fox jumps over the lazy dog.';
      final session = CharacterOpSession(clientId: 'c', initialText: text);

      for (var step = 0; step < 300; step++) {
        final start = random.nextInt(text.length + 1);
        final end = min(text.length, start + random.nextInt(4));
        final insert = String.fromCharCodes(
          List.generate(
            random.nextInt(4),
            (_) => alphabet.codeUnitAt(random.nextInt(alphabet.length)),
          ),
        );
        final next = text.replaceRange(start, end, insert);
        session.recordTextChange(text, next);
        text = next;

        expect(session.text, text, reason: 'seed $seed step $step');
        expect(rebuilt(session), text, reason: 'seed $seed step $step');
      }
    }
  });

  test('a before that disagrees with the session still lands on after', () {
    final session = CharacterOpSession(clientId: 'c', initialText: 'hello');
    session.recordTextChange('goodbye', 'goodbye!');

    expect(session.text, 'goodbye!');
    expect(rebuilt(session), 'goodbye!');
  });

  test('typing at the end of a long entry does not re-sort it', () {
    // Was ~150ms a keystroke at this size, 15s for the loop below. The bound
    // is far above the fixed cost so wall-clock noise can't trip it.
    final base = List.generate(20000, (i) => i % 7 == 6 ? ' ' : 'x').join();
    final session = CharacterOpSession(clientId: 'c', initialText: base);
    var text = base;

    final stopwatch = Stopwatch()..start();
    for (var k = 0; k < 100; k++) {
      final next = '${text}a';
      session.recordTextChange(text, next);
      text = next;
    }
    stopwatch.stop();

    expect(session.text, text);
    expect(stopwatch.elapsed, lessThan(const Duration(seconds: 2)));
  });
}

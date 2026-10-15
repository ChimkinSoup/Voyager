// Two devices typing at the same place before each other's characters
// arrived minted the same positions, character for character, so the words
// merged letter by letter ("ablepthaawwoorrdd"), and each device then held a
// different order of them from its resolver and the cloud (BUG-235).

import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/domain/services/character_op_session.dart';
import 'package:voyager/domain/services/character_operation.dart';
import 'package:voyager/domain/services/character_sequence_crdt_merger.dart';

/// Types [word] into [session] one character at a time after [at].
void _typeAt(CharacterOpSession session, int at, String word) {
  for (var k = 0; k < word.length; k++) {
    final before = session.text;
    session.recordTextChange(
      before,
      before.replaceRange(at + k, at + k, word[k]),
    );
  }
}

void main() {
  final merger = CharacterSequenceCrdtMerger();

  ({String a, String b, String resolved}) typeTogether(String start, int at) {
    final seed = CharacterOpSession(clientId: 'seed', initialText: start);
    final a = CharacterOpSession(
      clientId: 'device-a',
      initialOperations: seed.allOps,
    );
    final b = CharacterOpSession(
      clientId: 'device-b',
      initialOperations: seed.allOps,
    );
    _typeAt(a, at, 'alphaword');
    _typeAt(b, at, 'betaword');
    final fromA = a.takePendingOps();
    final fromB = b.takePendingOps();
    a.absorbRemote(fromB);
    b.absorbRemote(fromA);
    return (
      a: a.text,
      b: b.text,
      resolved: merger.applyMergedText([...seed.allOps, ...fromA, ...fromB]),
    );
  }

  for (final (name, start, at) in [
    ('in the middle', 'START END', 6),
    ('at the end', 'START ', 6),
    ('at the start', 'END', 0),
  ]) {
    test('words typed at the same place $name stay whole', () {
      final result = typeTogether(start, at);
      final head = start.substring(0, at);
      final tail = start.substring(at);

      expect(
        result.resolved,
        anyOf(
          '${head}alphawordbetaword$tail',
          '${head}betawordalphaword$tail',
        ),
      );
      expect(result.a, result.resolved);
      expect(result.b, result.resolved);
    });
  }

  test('the session orders shared positions the way the resolver does', () {
    // Two devices' characters at one position, held in the order they
    // arrived; the resolver tells them apart by clock, then client.
    const fromB = CharacterOperation(
      id: 'b_0_V',
      clientId: 'device-b',
      logicalClock: 0,
      position: 'V',
      character: 'B',
    );
    const fromA = CharacterOperation(
      id: 'a_0_V',
      clientId: 'device-a',
      logicalClock: 0,
      position: 'V',
      character: 'A',
    );
    final session = CharacterOpSession(
      clientId: 'x',
      initialOperations: const [fromB, fromA],
    );
    expect(merger.applyMergedText(const [fromB, fromA]), 'AB');
    expect(session.text, 'AB');
  });
}

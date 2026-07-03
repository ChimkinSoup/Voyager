import 'lib/domain/services/character_sequence_crdt_merger.dart';
import 'lib/domain/services/character_operation.dart';

void main() {
  var s = 'there is no version control?';
  var ops = <CharacterOperation>[];
  var pos = 'a0';
  for (int i = 0; i < s.length; i++) {
    ops.add(CharacterOperation(
      id: 'clientB_${i}_$pos',
      clientId: 'clientB',
      logicalClock: i,
      position: pos,
      character: s[i],
    ));
    // Simulate what happens if pos generation is bugged and stays same?
    // No, let's just generate normally.
  }
}

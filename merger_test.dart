import 'package:voyager/domain/services/character_op_session.dart';
import 'package:voyager/domain/services/character_sequence_crdt_merger.dart';
import 'package:voyager/domain/services/character_operation.dart';

void main() {
  final sessionLocal = CharacterOpSession(clientId: 'clientA', initialText: 'Version control?');
  sessionLocal.recordTextChange('Version control?', '===');
  
  final sessionRemote = CharacterOpSession(clientId: 'clientB', initialText: 'Version control?');
  sessionRemote.recordTextChange('Version control?', 'there is no version control?'); // wait, the previous test was checking this!
  
  // Now merge!
  final opsA = sessionLocal.allOps; // includes tombstones
  final opsB = sessionRemote.allOps; // includes tombstones
  
  final merger = CharacterSequenceCrdtMerger();
  // Merge opsA and opsB
  final byId = <String, CharacterOperation>{};
  for (final op in [...opsA, ...opsB]) {
    final existing = byId[op.id];
    // Simple _wins logic from CharacterSequenceCrdtMerger
    if (existing == null) {
      byId[op.id] = op;
    } else {
      if (op.deleted != existing.deleted) {
        if (op.logicalClock >= existing.logicalClock) byId[op.id] = op;
      } else if (op.logicalClock != existing.logicalClock) {
        if (op.logicalClock > existing.logicalClock) byId[op.id] = op;
      } else if (op.clientId.compareTo(existing.clientId) > 0) {
        byId[op.id] = op;
      }
    }
  }
  
  print('Merged text:');
  print(merger.applyMergedText(byId.values.toList()));
}

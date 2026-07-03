import 'package:voyager/domain/services/character_op_session.dart';
import 'package:voyager/domain/services/character_sequence_crdt_merger.dart';
import 'package:voyager/domain/services/character_operation.dart';

void main() {
  final session = CharacterOpSession(clientId: 'clientA', initialText: 'Version control?');
  session.recordTextChange('Version control?', 'there is no Version control?');
  
  // Now replace all with ===
  final sessionB = CharacterOpSession(clientId: 'clientB', initialText: 'Version control?');
  sessionB.recordTextChange('Version control?', 'there is no Version control?');
  sessionB.recordTextChange('there is no Version control?', '===');
  
  final merger = CharacterSequenceCrdtMerger();
  final byId = <String, CharacterOperation>{};
  for (final op in [...session.allOps, ...sessionB.allOps]) {
    final existing = byId[op.id];
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

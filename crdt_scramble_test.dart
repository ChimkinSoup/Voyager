import 'lib/domain/services/character_op_session.dart';
import 'lib/domain/services/character_sequence_crdt_merger.dart';
import 'lib/domain/services/character_operation.dart';

void main() {
  final session1 = CharacterOpSession(clientId: 'clientA', initialText: 'Version control?');
  
  // Client A types 'there is no v' replacing 'V'
  session1.recordTextChange('Version control?', 'there is no version control?');
  
  // Save ops from client A
  var opsA = session1.allOps.where((o) => !o.deleted).map((o) => o.copyWith()).toList();
  
  // Client A deletes all and types '==='
  session1.recordTextChange('there is no version control?', '===');
  
  // Wait, let's say the tombstones were LOST, but the inserts were kept!
  // This simulates the CRDT merging 'there is no version control?' with '===' 
  // WITHOUT the tombstones for 'there is no version control?'.
  final opsA2 = session1.allOps.where((o) => !o.deleted).map((o) => o.copyWith()).toList();
  
  final merger = CharacterSequenceCrdtMerger();
  
  // Merge opsA and opsA2!
  final allOps = [...opsA, ...opsA2];
  
  print('Merged without tombstones:');
  print(merger.applyMergedText(allOps));
}

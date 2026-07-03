import 'lib/domain/services/character_op_session.dart';
import 'lib/domain/services/character_operation.dart';
import 'lib/domain/services/fractional_index.dart';

void main() {
  final session = CharacterOpSession(clientId: 'client1', initialText: 'Version control?');
  session.recordTextChange('Version control?', '===');
  print('Text: ${session.text}');
  
  final ops = session.takePendingOps();
  for (final op in ops) {
    print('${op.character} at ${op.position} (deleted: ${op.deleted})');
  }
}

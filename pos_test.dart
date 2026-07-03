import 'lib/domain/services/character_op_session.dart';

void main() {
  final session = CharacterOpSession(clientId: 'clientA', initialText: 'Version control?');
  
  session.recordTextChange('Version control?', 'there is no version control?');
  
  for (final op in session.allOps.where((o) => !o.deleted)) {
    print('${op.character} -> ${op.position}');
  }
}

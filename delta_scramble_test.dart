import 'lib/core/sync/text_delta_injector.dart';

void main() {
  // Scenario: 
  // User had "there is no version control?" remotely.
  // User had "===" locally.
  // We merge them using TextDeltaInjector.
  
  final local = '===';
  final oldRemote = 'there is no version control?';
  final newRemote = 'there is no version control?'; // No change remotely?
  
  // Wait, if oldRemote and newRemote are different?
  final oldRemote2 = 'Version control?';
  final newRemote2 = 'there is no version control?';
  
  print('Merge 1:');
  print(TextDeltaInjector.injectRemoteDelta(
    localText: local,
    oldRemoteText: oldRemote2,
    newRemoteText: newRemote2,
  ));
}

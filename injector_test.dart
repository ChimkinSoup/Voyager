import 'lib/core/sync/text_delta_injector.dart';

void main() {
  print(TextDeltaInjector.injectRemoteDelta(
    localText: '===',
    oldRemoteText: 'Version control?',
    newRemoteText: 'heerys iio nc hcaonngterdol?',
  ));
}

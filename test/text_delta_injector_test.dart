import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/core/sync/text_delta_injector.dart';

void main() {
  group('TextDeltaInjector', () {
    test('returns new remote text when local matches old remote', () {
      expect(
        TextDeltaInjector.injectRemoteDelta(
          localText: 'hello world',
          oldRemoteText: 'hello world',
          newRemoteText: 'hello brave world',
        ),
        'hello brave world',
      );
    });

    test('injects remote insertion while preserving local suffix edits', () {
      expect(
        TextDeltaInjector.injectRemoteDelta(
          localText: 'hello world!!!',
          oldRemoteText: 'hello world',
          newRemoteText: 'hello brave world',
        ),
        'hello brave world!!!',
      );
    });

    test('injects remote replacement in the middle of local text', () {
      expect(
        TextDeltaInjector.injectRemoteDelta(
          localText: 'start old middle end',
          oldRemoteText: 'start old end',
          newRemoteText: 'start new end',
        ),
        'start new middle end',
      );
    });

    test('no-ops when remote text is unchanged', () {
      expect(
        TextDeltaInjector.injectRemoteDelta(
          localText: 'local only',
          oldRemoteText: 'remote',
          newRemoteText: 'remote',
        ),
        'local only',
      );
    });
  });
}

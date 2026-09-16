// TextDeltaInjector merges a remote text change into what a focused editor
// holds. When it cannot line the two up it falls back — and the fallback must
// never hand back a document containing the remote text twice over.

import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/core/sync/text_delta_injector.dart';

void main() {
  test('an unalignable merge does not append a second copy of the document',
      () {
    const oldRemote = 'The quick brown fox jumps over the lazy dog.';
    // The remote device rewrote a word in the middle.
    const newRemote = 'The quick brown cat jumps over the lazy dog.';
    // This device edited both ends while the change was in flight.
    const local = 'A quick brown fox jumps over the lazy dog!';

    final merged = TextDeltaInjector.injectRemoteDelta(
      localText: local,
      oldRemoteText: oldRemote,
      newRemoteText: newRemote,
    );

    expect(
      'jumps over'.allMatches(merged).length,
      1,
      reason: 'merged: $merged',
    );
  });
}

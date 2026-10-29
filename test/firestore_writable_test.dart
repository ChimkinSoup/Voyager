import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/core/sync/firestore_writable.dart';
import 'package:voyager/core/sync/sync_error_classification.dart';

/// Documents Firestore refuses for their shape, caught before the Windows
/// SDK throws the refusal where nothing catches it.
void main() {
  test('arrays of maps and maps of arrays are fine', () {
    checkFirestoreWritable({
      'tags': ['a', 'b'],
      'marks': [
        {
          'points': [
            {'x': 1, 'y': 2},
          ],
        },
      ],
    });
  });

  test('an array in an array is refused where it is, as permanent', () {
    Object? caught;
    try {
      checkFirestoreWritable({
        'images': [
          {
            'edits': {
              'points': [
                [1, 2],
              ],
            },
          },
        ],
      });
    } catch (error) {
      caught = error;
    }
    expect(caught, isA<SyncPayloadUnwritableException>());
    expect(
      (caught! as SyncPayloadUnwritableException).field,
      'images.0.edits.points.0',
    );
    expect(classifySyncFailure(caught), SyncFailureKind.permanent);
    expect(describeSyncFailure(caught), contains('images.0.edits.points.0'));
  });
}

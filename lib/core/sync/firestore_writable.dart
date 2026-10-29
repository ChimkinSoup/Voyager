/// A document Firestore refuses for its shape, caught before it's handed
/// over: the Windows SDK throws that refusal in native code, where nothing
/// catches it, and the app ends.
class SyncPayloadUnwritableException implements Exception {
  const SyncPayloadUnwritableException(this.field, this.reason);

  /// Where in the document, as `images.0.edits.marks.0.points.0`.
  final String field;
  final String reason;

  @override
  String toString() => 'SyncPayloadUnwritableException: $field $reason';
}

/// Throws [SyncPayloadUnwritableException] if [data] holds an array directly
/// in an array, which Firestore doesn't store.
void checkFirestoreWritable(Map<String, dynamic> data) {
  void visit(Object? value, String path, {required bool inArray}) {
    switch (value) {
      case List() when inArray:
        throw SyncPayloadUnwritableException(
          path,
          'is an array in an array, which Firestore refuses',
        );
      case List():
        for (var i = 0; i < value.length; i++) {
          visit(value[i], '$path.$i', inArray: true);
        }
      case Map():
        for (final entry in value.entries) {
          final key = '${entry.key}';
          visit(entry.value, path.isEmpty ? key : '$path.$key', inArray: false);
        }
    }
  }

  visit(data, '', inArray: false);
}

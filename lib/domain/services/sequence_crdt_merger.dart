import 'package:voyager/domain/models/settings_models.dart';

class SequenceCrdtMerger {
  List<SyncOperation> merge(List<SyncOperation> local, List<SyncOperation> remote) {
    final all = [...local, ...remote];
    all.sort((a, b) {
      final seq = a.sequence.compareTo(b.sequence);
      if (seq != 0) return seq;
      return a.timestamp.compareTo(b.timestamp);
    });

    final seen = <String>{};
    return all.where((op) => seen.add(op.id)).toList();
  }

  String applyMergedPayload(List<SyncOperation> merged) {
    if (merged.isEmpty) return '';
    return merged.last.payload;
  }
}

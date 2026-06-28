import 'package:voyager/domain/services/character_operation.dart';
import 'package:voyager/domain/services/fractional_index.dart';

/// Tracks in-memory character ops for an actively edited text field.
class CharacterOpSession {
  CharacterOpSession({
    required this.clientId,
    required String initialText,
  }) : _logicalClock = 0 {
    _seedFromText(initialText);
  }

  final String clientId;
  int _logicalClock;
  final Map<String, CharacterOperation> _opsById = {};
  final List<String> _pendingOpIds = [];

  List<CharacterOperation> get allOps =>
      _opsById.values.toList(growable: false);

  String get text => _reconstructText();

  void resetFromText(String text) {
    _opsById.clear();
    _pendingOpIds.clear();
    _logicalClock = 0;
    _seedFromText(text);
  }

  void recordTextChange(String before, String after) {
    if (before == after) return;

    final oldIds = _liveOrderedOps().map((op) => op.id).toList();
    final oldText = before;

    // Simple diff: walk both strings.
    var i = 0;
    var j = 0;
    while (i < oldText.length && j < after.length && oldText[i] == after[j]) {
      i++;
      j++;
    }

    var oldEnd = oldText.length;
    var newEnd = after.length;
    while (oldEnd > i &&
        newEnd > j &&
        oldText[oldEnd - 1] == after[newEnd - 1]) {
      oldEnd--;
      newEnd--;
    }

    final deleteCount = oldEnd - i;
    final insertSegment = after.substring(j, newEnd);

    if (deleteCount > 0) {
      final live = _liveOrderedOps();
      final toDelete = live.skip(i).take(deleteCount).toList();
      for (final op in toDelete) {
        _tombstone(op.id);
      }
    }

    if (insertSegment.isNotEmpty) {
      final live = _liveOrderedOps();
      String? posBefore;
      String? posAfter;
      if (i > 0 && i - 1 < live.length) {
        posBefore = live[i - 1].position;
      }
      if (i < live.length) {
        posAfter = live[i].position;
      }

      var cursorBefore = posBefore;
      for (var k = 0; k < insertSegment.length; k++) {
        final char = insertSegment[k];
        final pos = FractionalIndex.between(
          before: cursorBefore,
          after: posAfter,
        );
        _insertOp(char: char, position: pos);
        cursorBefore = pos;
      }
    }

    // If diff produced no ops but text changed structurally, re-seed.
    if (_reconstructText() != after) {
      resetFromText(after);
    }

    // Preserve unrelated op ids ordering sanity.
    assert(oldIds.length >= 0);
  }

  List<CharacterOperation> takePendingOps() {
    final pending = _pendingOpIds
        .map((id) => _opsById[id])
        .whereType<CharacterOperation>()
        .toList();
    _pendingOpIds.clear();
    return pending;
  }

  void _seedFromText(String text) {
    var prevPos = '';
    for (var i = 0; i < text.length; i++) {
      final char = text[i];
      final pos = i == 0
          ? FractionalIndex.first()
          : FractionalIndex.after(prevPos);
      prevPos = pos;
      final id = '${clientId}_${_logicalClock}_$pos';
      _opsById[id] = CharacterOperation(
        id: id,
        clientId: clientId,
        logicalClock: _logicalClock++,
        position: pos,
        character: char,
      );
    }
  }

  void _insertOp({required String char, required String position}) {
    final id = '${clientId}_${_logicalClock}_$position';
    final op = CharacterOperation(
      id: id,
      clientId: clientId,
      logicalClock: _logicalClock++,
      position: position,
      character: char,
    );
    _opsById[id] = op;
    _pendingOpIds.add(id);
  }

  void _tombstone(String id) {
    final existing = _opsById[id];
    if (existing == null || existing.deleted) return;
    final tombstoned = existing.copyWith(deleted: true);
    _opsById[id] = tombstoned;
    _pendingOpIds.add(id);
  }

  List<CharacterOperation> _liveOrderedOps() {
    return _opsById.values.where((op) => !op.deleted).toList()
      ..sort((a, b) => a.position.compareTo(b.position));
  }

  String _reconstructText() {
    return _liveOrderedOps().map((op) => op.character).join();
  }
}

/// Registry of active character-op editing sessions keyed by document.
class CharacterOpRegistry {
  final Map<String, CharacterOpSession> _sessions = {};

  String key(String collection, String documentId) =>
      '${collection}_$documentId';

  CharacterOpSession ensureSession({
    required String collection,
    required String documentId,
    required String clientId,
    required String initialText,
  }) {
    final k = key(collection, documentId);
    return _sessions.putIfAbsent(
      k,
      () => CharacterOpSession(clientId: clientId, initialText: initialText),
    );
  }

  CharacterOpSession? session(String collection, String documentId) {
    return _sessions[key(collection, documentId)];
  }

  void recordTextChange({
    required String collection,
    required String documentId,
    required String clientId,
    required String before,
    required String after,
  }) {
    final session = ensureSession(
      collection: collection,
      documentId: documentId,
      clientId: clientId,
      initialText: before,
    );
    session.recordTextChange(before, after);
  }

  List<CharacterOperation> takePendingOps(String collection, String documentId) {
    return _sessions[key(collection, documentId)]?.takePendingOps() ??
        const [];
  }

  void resetSession({
    required String collection,
    required String documentId,
    required String clientId,
    required String text,
  }) {
    final k = key(collection, documentId);
    _sessions[k] = CharacterOpSession(clientId: clientId, initialText: text);
  }

  void removeSession(String collection, String documentId) {
    _sessions.remove(key(collection, documentId));
  }

  void clear() => _sessions.clear();
}

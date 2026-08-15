// The char-op payload encode is handed to a background isolate once a write is
// big enough (a full-document reseed, or operation-log compaction). Everything
// crossing that boundary has to be sendable and has to come back byte-identical
// to what the inline path produces — both of which only fail at runtime, so
// they are pinned here.

import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/core/sync/char_ops_encoder.dart';
import 'package:voyager/core/sync/sync_engine.dart';
import 'package:voyager/domain/services/character_op_session.dart';
import 'package:voyager/domain/services/character_operation.dart';

List<CharacterOperation> _opsForText(String text) {
  final session = CharacterOpSession(
    clientId: 'device-a',
    initialText: text,
    seedAsPending: true,
  );
  return session.takePendingOps();
}

const _snapshot = <String, dynamic>{
  'id': 'entry-1',
  'title': 'Seeded',
  'body': 'hello world',
  'tags': ['alpha', 'beta'],
  'mood': 4,
  'version': 2,
  'deletedAt': null,
};

void main() {
  test('the isolate path encodes identically to the inline path', () async {
    // One op per character, so this clears the threshold comfortably.
    final ops = _opsForText('a' * (charOpEncodeIsolateThreshold + 40));
    expect(ops.length, greaterThanOrEqualTo(charOpEncodeIsolateThreshold));

    final request = CharOpsEncodeRequest(
      charOps: ops,
      snapshot: _snapshot,
      groupId: 'device-a_entry-1_1',
      maxPayloadBytes: maxOperationPayloadBytes,
    );

    final viaIsolate = await encodeCharOpPayloads(
      charOps: ops,
      snapshot: _snapshot,
      groupId: 'device-a_entry-1_1',
      maxPayloadBytes: maxOperationPayloadBytes,
    );

    expect(viaIsolate, encodeCharOpPayloadsSync(request));
  });

  test('a small write stays inline and still encodes correctly', () async {
    final ops = _opsForText('short');
    expect(ops.length, lessThan(charOpEncodeIsolateThreshold));

    final encoded = await encodeCharOpPayloads(
      charOps: ops,
      snapshot: _snapshot,
      groupId: 'device-a_entry-1_1',
      maxPayloadBytes: maxOperationPayloadBytes,
    );

    expect(
      encoded,
      encodeCharOpPayloadsSync(
        CharOpsEncodeRequest(
          charOps: ops,
          snapshot: _snapshot,
          groupId: 'device-a_entry-1_1',
          maxPayloadBytes: maxOperationPayloadBytes,
        ),
      ),
    );
  });

  test('an oversized payload still throws through the isolate', () async {
    final ops = _opsForText('a' * (charOpEncodeIsolateThreshold + 40));
    await expectLater(
      encodeCharOpPayloads(
        charOps: ops,
        snapshot: _snapshot,
        // Small enough that the snapshot alone cannot fit.
        maxPayloadBytes: 300,
        groupId: 'device-a_entry-1_1',
      ),
      throwsA(isA<SyncPayloadTooLargeException>()),
    );
  });
}

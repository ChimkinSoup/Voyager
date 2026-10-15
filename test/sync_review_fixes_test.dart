// Regressions found reviewing the BUG-233..239 changes: an unsent-text
// recovery that brought back another device's deletion, a dream tie-break
// that swapped tags and dates between devices, and an undo step that drifted
// from the merged text the field showed.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/core/sync/firestore_document_mapper.dart';
import 'package:voyager/core/sync/unsent_text.dart';
import 'package:voyager/core/text/merge_aware_undo.dart';
import 'package:voyager/domain/models/dream_models.dart';
import 'package:voyager/domain/models/settings_models.dart';
import 'package:voyager/domain/services/character_operation.dart';

SyncOperation _op(int sequence, DateTime at, List<CharacterOperation> ops) =>
    SyncOperation(
      id: 'op-$sequence',
      documentId: 'doc',
      sequence: sequence,
      payload: CharOpsPayload(charOps: ops).encode(),
      deviceId: ops.first.clientId,
      timestamp: at,
    );

void main() {
  test('another device\'s deletion this device never pulled is not owed '
      'back as unsent typing', () async {
    final t0 = DateTime.utc(2026, 10, 1, 9);
    // "xfooy", typed on A and sent.
    final chars = [
      for (final (i, c) in 'xfooy'.split('').indexed)
        CharacterOperation(
          id: 'a-$i',
          clientId: 'a',
          logicalClock: i,
          position: String.fromCharCode(0x62 + i),
          character: c,
        ),
    ];
    final sent = _op(1, t0, chars);
    // B deletes "foo" and sends it; A, offline, never sees it.
    final deleted = _op(2, t0.add(const Duration(minutes: 1)), [
      for (final op in chars.sublist(1, 4)) op.copyWith(deleted: true),
    ]);
    // A types "bar" on the end, saves, and is killed before uploading.
    final result = await textWithUnsentEdits(
      localText: 'xfooybar',
      logText: 'xy',
      operations: [sent, deleted],
      savedAt: t0.add(const Duration(minutes: 2)),
    );
    expect(result, 'xybar');
  });

  test('dreams tied on stamps and note but not tags settle on one copy', () {
    final at = DateTime.utc(2026, 10, 1, 9);
    DreamEntry dream(List<String> tags, DateTime date) => DreamEntry(
      id: 'dream',
      createdAt: at,
      updatedAt: at,
      version: 3,
      title: 'Same',
      body: 'Same body',
      notes: 'same note',
      entryDate: date,
      tags: tags,
    );
    final a = dream(['flying'], at);
    final b = dream(['falling'], at);
    // Exactly one side takes the other's copy.
    expect(
      dreamRemoteWinsTie(dreamEntryToFirestore(b), a),
      isNot(dreamRemoteWinsTie(dreamEntryToFirestore(a), b)),
    );

    final c = dream(['flying'], at.add(const Duration(days: 1)));
    expect(
      dreamRemoteWinsTie(dreamEntryToFirestore(c), a),
      isNot(dreamRemoteWinsTie(dreamEntryToFirestore(a), c)),
    );
  });

  testWidgets('the step the field shows is the merged text, so undo comes '
      'back to it', (tester) async {
    final text = TextEditingController(text: 'abc');
    final undo = MergeAwareUndoController(text);
    addTearDown(() {
      undo.dispose();
      text.dispose();
    });

    // Merged text the step can't be derived to by diffing the remote change.
    undo.applyRemote(
      const TextEditingValue(
        text: 'aXYc',
        selection: TextSelection.collapsed(offset: 4),
      ),
      previousRemoteText: 'abc',
      remoteText: 'aXc',
    );
    text.value = const TextEditingValue(
      text: 'aXYcd',
      selection: TextSelection.collapsed(offset: 5),
    );
    await tester.pump(const Duration(milliseconds: 600));

    undo.undo();
    expect(text.text, 'aXYc');
  });
}

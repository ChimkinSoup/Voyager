import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/core/text/list_text_editing.dart';
import 'package:voyager/domain/services/character_op_session.dart';
import 'package:voyager/domain/services/character_operation.dart';
import 'package:voyager/domain/services/fractional_index.dart';

/// Builds the operations a real, previously-synced "1. a\n2. b" would have —
/// alternating authorship between two devices, the way a genuinely
/// collaborative document looks — rather than everything freshly seeded by
/// one client (which [FractionalIndex] generates deterministically, so a
/// same-length reseed by the same client can coincidentally produce
/// identical ids and mask the bug).
List<CharacterOperation> _mixedAuthorshipOps(String text) {
  final ops = <CharacterOperation>[];
  String? prevPos;
  for (var i = 0; i < text.length; i++) {
    final pos = prevPos == null
        ? FractionalIndex.first()
        : FractionalIndex.after(prevPos);
    prevPos = pos;
    final clientId = i.isEven ? 'device-a' : 'device-b';
    ops.add(
      CharacterOperation(
        id: '${clientId}_${i}_$pos',
        clientId: clientId,
        logicalClock: i,
        position: pos,
        character: text[i],
      ),
    );
  }
  return ops;
}

/// Regression coverage for a real bug: Tab-indent and smart-Backspace mutate
/// the controller directly (via FocusNode.onKeyEvent), bypassing
/// TextField.onChanged. The character-op CRDT session assumes every
/// recordTextChange's `before` argument exactly matches its own internal
/// reconstructed text — if a controller mutation happens without a
/// corresponding recordTextChange call, the session silently desyncs, and
/// the next recordTextChange call (with a `before` the session doesn't
/// actually match) computes deletes/inserts against the wrong character
/// positions, corrupting the operation log. This showed up in production as
/// doubled letters in the "Remote" side of a journal sync conflict.
void main() {
  test(
    'skipping recordTextChange after a Tab-indent silently re-seeds the '
    'session, discarding remote devices\' character authorship',
    () {
      final ops = _mixedAuthorshipOps('1. a\n2. b');
      final session = CharacterOpSession(clientId: 'device-a', initialOperations: ops);
      expect(session.text, '1. a\n2. b');
      // A real synced entry: authorship split across two devices.
      expect(session.allOps.map((op) => op.clientId).toSet(), {'device-a', 'device-b'});

      // Tab-indent "2. b" the way handleListTab does, but — reproducing the
      // bug — WITHOUT telling the session about it.
      final controller = TextEditingController(text: '1. a\n2. b')
        ..selection = const TextSelection.collapsed(offset: 9);
      handleListTab(controller: controller, outdent: false);
      expect(controller.text, '1. a\n  2. b'); // real text now has the indent

      // A later, ordinary keystroke diffs against the *real* current text
      // (what the field's own `_lastText` bookkeeping correctly observed)
      // — but the session's internal character-op list was never updated
      // for the indent, so this `before` doesn't match what the session
      // actually holds.
      final before = controller.text; // '1. a\n  2. b', but the session still thinks '1. a\n2. b'
      controller.text = '1. a\n  2. bx';
      session.recordTextChange(before, controller.text);

      // The text itself happens to reconstruct correctly locally (the
      // session's self-repair kicks in), but the repair re-seeds every
      // character as freshly authored by *this* client — device-b's
      // authorship of "2. b" is silently erased. Once this session's ops
      // are pushed and merged against a remote copy that still has
      // device-b's *original* operations for those same characters, the
      // remote ends up with two distinct operation sets for the same
      // text, reconstructing as doubled characters — exactly like the
      // reported merge conflict.
      expect(session.text, controller.text); // text looks fine locally...
      expect(
        session.allOps.map((op) => op.clientId).toSet(),
        {'device-a'}, // ...but device-b's authorship is gone.
      );
    },
  );

  test(
    'recordTextChange after every mutation (the fix) keeps the session in sync',
    () {
      final ops = _mixedAuthorshipOps('1. a\n2. b');
      final session = CharacterOpSession(clientId: 'device-a', initialOperations: ops);
      final controller = TextEditingController(text: '1. a\n2. b')
        ..selection = const TextSelection.collapsed(offset: 9);

      var before = controller.text;
      handleListTab(controller: controller, outdent: false);
      session.recordTextChange(before, controller.text);
      expect(controller.text, '1. a\n  2. b');
      expect(session.text, controller.text);
      // No spurious re-seed: device-b's authorship of its characters
      // survives (only the two new indent-space ops are device-a's).
      expect(
        session.allOps.map((op) => op.clientId).toSet(),
        {'device-a', 'device-b'},
      );

      before = controller.text;
      controller.text = '1. a\n  2. bx';
      session.recordTextChange(before, controller.text);
      expect(session.text, controller.text);

      // Backspace the marker off "  2. bx" too, staying in sync. Cursor
      // sits right after "  2. " (indent + marker + spacing = 5 chars into
      // that line, which starts at index 5), i.e. offset 10.
      before = controller.text;
      controller.selection = const TextSelection.collapsed(offset: 10);
      handleListBackspace(controller: controller);
      session.recordTextChange(before, controller.text);
      expect(session.text, controller.text);
    },
  );
}

import 'dart:isolate';
import 'dart:typed_data';

import 'package:voyager/domain/models/settings_models.dart';
import 'package:voyager/domain/services/character_op_session.dart';
import 'package:voyager/domain/services/character_operation.dart';
import 'package:voyager/domain/services/character_sequence_crdt_merger.dart';

/// [localText] with the characters typed into it here but never sent, put
/// into the text the log spells now — or null when it owes nothing.
///
/// For a row saved here but never uploaded — the app was killed inside the
/// upload debounce — whose document another device has moved on since. After
/// a restart nothing in memory remembers the unsent characters, and the pull,
/// finding the cloud's revision newer, used to take its text over the row and
/// drop them (BUG-238).
///
/// [savedAt] is when the row was last saved here. Every character the log had
/// inserted up to that moment — deleted since or not — is one the row may have
/// been typed against, so a run only the row has, compared with those, was
/// typed here and never sent. Deleted characters count: this device may not
/// have pulled another device's deletion before saving, and a row still
/// holding them hasn't typed them anew. Each run goes back after the character
/// it followed, wherever that character sits now, even deleted since.
/// Characters deleted here and not sent can't be told from the other device's
/// inserts and aren't owed back.
Future<String?> textWithUnsentEdits({
  required String localText,
  required String? logText,
  required List<SyncOperation> operations,
  required DateTime savedAt,
}) async {
  final merger = CharacterSequenceCrdtMerger();
  final now = _ordered(merger.mergeOperations(const [], operations));
  final live = [
    for (final op in now)
      if (!op.deleted) op,
  ];
  // Only where the log's characters are the text the pull resolved to: a
  // snapshot chosen over them says nothing about which of them the row lacks.
  // Null [logText] skips that check — an open editor's own characters are in
  // the resolved text too, and the result is laid over the log's alone.
  final liveText = live.map((op) => op.character).join();
  if (live.isEmpty || (logText != null && liveText != logText)) return null;
  // Cheap first: a row whose every character the log has held, in order,
  // has nothing new in it. The usual case — a device that is only behind.
  if (_isSubsequence(localText, now.map((op) => op.character).join())) {
    return null;
  }

  // Assumes the devices' clocks agree: each operation is stamped by the clock
  // of the device that sent it, [savedAt] by this one's. Another device's
  // running ahead by more than the time from its upload to this save puts
  // characters the row already held after the save, and they are put in a
  // second time. A margin on other devices' stamps doesn't help — their
  // edits in the same place soon after the save then scramble the unsent
  // run. Free of clocks would be the newest operation the saved text was
  // built from, by server write time, kept with the row.
  final before = [
    for (final operation in operations)
      if (!operation.timestamp.isAfter(savedAt)) operation,
  ];
  // None: the log was compacted since, which rewrites all of it, and the text
  // the row was typed against can't be told any more.
  if (before.isEmpty) return null;
  final then = _ordered(merger.mergeOperations(const [], before));
  final thenText = then.map((op) => op.character).join();
  // The alignment can be millions of steps on a long text: off the UI isolate.
  final runs = await Isolate.run(() => _localOnlyRuns(localText, thenText));
  if (runs == null || runs.isEmpty) return null;

  // Each run's place in the text now: after every live character that sorts
  // at or before the one it followed.
  final inserts = <int, String>{};
  for (final (at, run) in runs) {
    final after = at == 0 ? null : then[at - 1];
    final index = after == null
        ? 0
        : live
              .where((op) => CharacterOpSession.compareOps(op, after) <= 0)
              .length;
    inserts[index] = (inserts[index] ?? '') + run;
  }
  final merged = StringBuffer();
  for (var i = 0; i <= liveText.length; i++) {
    final insert = inserts[i];
    if (insert != null) merged.write(insert);
    if (i < liveText.length) merged.write(liveText[i]);
  }
  return merged.toString();
}

List<CharacterOperation> _ordered(List<CharacterOperation> ops) =>
    ops..sort(CharacterOpSession.compareOps);

/// The runs of [local] that [log] doesn't have, each with the index in [log]
/// it sits before. Null when the texts differ over too long a stretch to
/// align here.
List<(int, String)>? _localOnlyRuns(String local, String log) {
  var prefix = 0;
  final shorter = local.length < log.length ? local.length : log.length;
  while (prefix < shorter &&
      local.codeUnitAt(prefix) == log.codeUnitAt(prefix)) {
    prefix++;
  }
  var suffix = 0;
  while (suffix < shorter - prefix &&
      local.codeUnitAt(local.length - 1 - suffix) ==
          log.codeUnitAt(log.length - 1 - suffix)) {
    suffix++;
  }
  final a = local.substring(prefix, local.length - suffix);
  final b = log.substring(prefix, log.length - suffix);
  if (a.isEmpty) return const [];
  if (b.isEmpty) return [(prefix, a)];
  // A longest-common-subsequence table over the stretch that differs, kept to
  // a size that is cheap on a pull; anything bigger is left as it was.
  if (a.length * b.length > 9000000 || a.length > 65535 || b.length > 65535) {
    return null;
  }
  final width = b.length + 1;
  final table = Uint16List((a.length + 1) * width);
  for (var i = a.length - 1; i >= 0; i--) {
    for (var j = b.length - 1; j >= 0; j--) {
      final down = table[(i + 1) * width + j];
      final right = table[i * width + j + 1];
      table[i * width + j] = a.codeUnitAt(i) == b.codeUnitAt(j)
          ? table[(i + 1) * width + j + 1] + 1
          : (down > right ? down : right);
    }
  }
  final runs = <(int, String)>[];
  final run = StringBuffer();
  var runAt = 0;
  void close() {
    if (run.isEmpty) return;
    runs.add((prefix + runAt, run.toString()));
    run.clear();
  }

  var i = 0;
  var j = 0;
  while (i < a.length) {
    if (j < b.length && a.codeUnitAt(i) == b.codeUnitAt(j)) {
      close();
      i++;
      j++;
    } else if (j < b.length &&
        table[i * width + j + 1] >= table[(i + 1) * width + j]) {
      close();
      j++;
    } else {
      if (run.isEmpty) runAt = j;
      run.writeCharCode(a.codeUnitAt(i));
      i++;
    }
  }
  close();
  return runs;
}

bool _isSubsequence(String part, String whole) {
  var i = 0;
  for (var j = 0; j < whole.length && i < part.length; j++) {
    if (whole.codeUnitAt(j) == part.codeUnitAt(i)) i++;
  }
  return i == part.length;
}

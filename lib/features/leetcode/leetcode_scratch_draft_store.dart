import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:voyager/features/leetcode/leetcode_scratch_draft.dart';

/// The one live Study/Cram scratch session, kept on this device only.
///
/// A single slot, the same contract [LeetCodeTrackDraftStore] keeps: scratch
/// work belongs to the run that is happening now, so there is never a second
/// session to keep alongside it. Nothing here syncs.
abstract class LeetCodeScratchDraftStore {
  /// The stored session, or null when there is none. A blob that can't be read
  /// is discarded and reported as none.
  Future<LeetCodeScratchSession?> load();

  Future<void> save(LeetCodeScratchSession session);

  Future<void> clear();
}

const _scratchFileName = 'leetcode_scratch_session.json';

class FileLeetCodeScratchDraftStore implements LeetCodeScratchDraftStore {
  /// [directory] defaults to the app's documents directory — the same place
  /// the database lives. Tests point it somewhere temporary.
  FileLeetCodeScratchDraftStore({Future<Directory> Function()? directory})
    : _directory = directory ?? getApplicationDocumentsDirectory;

  final Future<Directory> Function() _directory;

  /// Writes are chained rather than fired in parallel: a dispose flush and a
  /// still-pending debounce can both land on the same slot, and the later one
  /// has to win. Reads join the same chain so a load never sees a half file.
  Future<void> _chain = Future<void>.value();

  Future<File> _file() async {
    final dir = await _directory();
    return File(p.join(dir.path, _scratchFileName));
  }

  Future<T> _enqueue<T>(Future<T> Function() op) {
    final result = _chain.then((_) => op());
    _chain = result.then((_) {}, onError: (_) {});
    return result;
  }

  @override
  Future<LeetCodeScratchSession?> load() => _enqueue(() async {
    try {
      final file = await _file();
      if (!await file.exists()) return null;
      final raw = await file.readAsString();
      if (raw.trim().isEmpty) return null;
      return LeetCodeScratchSession.fromJson(
        Map<String, dynamic>.from(jsonDecode(raw) as Map),
      );
    } catch (error) {
      // Unreadable or from another schema — drop it and open a clean session.
      debugPrint('LeetCode scratch session could not be read: $error');
      await _deleteQuietly();
      return null;
    }
  });

  @override
  Future<void> save(LeetCodeScratchSession session) => _enqueue(() async {
    try {
      final file = await _file();
      await file.writeAsString(jsonEncode(session.toJson()), flush: true);
    } catch (error) {
      // Scratch that can't be written is a crash-recovery convenience lost,
      // never an error worth interrupting a review session for.
      debugPrint('LeetCode scratch session could not be saved: $error');
    }
  });

  @override
  Future<void> clear() => _enqueue(_deleteQuietly);

  Future<void> _deleteQuietly() async {
    try {
      final file = await _file();
      if (await file.exists()) await file.delete();
    } catch (error) {
      debugPrint('LeetCode scratch session could not be cleared: $error');
    }
  }
}

/// In-memory slot, for tests and for any build where the platform has no
/// documents directory to write to.
class MemoryLeetCodeScratchDraftStore implements LeetCodeScratchDraftStore {
  LeetCodeScratchSession? session;

  @override
  Future<LeetCodeScratchSession?> load() async => session;

  @override
  Future<void> save(LeetCodeScratchSession value) async => session = value;

  @override
  Future<void> clear() async => session = null;
}

final leetCodeScratchDraftStoreProvider = Provider<LeetCodeScratchDraftStore>(
  (ref) => FileLeetCodeScratchDraftStore(),
);

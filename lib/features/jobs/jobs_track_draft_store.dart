import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:voyager/features/jobs/jobs_track_draft.dart';

/// The one unsaved track-application form, kept on this device only.
///
/// Deliberately not a repository and not a Drift table: a draft never syncs,
/// never appears in a list, and is overwritten wholesale — a single slot is the
/// entire contract. Same shape as the LeetCode track draft store, which this
/// mirrors.
abstract class JobsTrackDraftStore {
  /// The stored draft, or null when there is none. A blob that can't be read
  /// is discarded and reported as none.
  Future<JobsTrackDraft?> load();

  Future<void> save(JobsTrackDraft draft);

  Future<void> clear();
}

const _draftFileName = 'jobs_track_draft.json';

class FileJobsTrackDraftStore implements JobsTrackDraftStore {
  /// [directory] defaults to the app's documents directory — the same place
  /// the database lives. Tests point it somewhere temporary.
  FileJobsTrackDraftStore({Future<Directory> Function()? directory})
    : _directory = directory ?? getApplicationDocumentsDirectory;

  final Future<Directory> Function() _directory;

  /// Writes are chained rather than fired in parallel: the close flush and a
  /// still-pending debounce can both land on the same slot, and the later one
  /// has to win. Reads join the same chain so a load never sees a half file.
  Future<void> _chain = Future<void>.value();

  Future<File> _file() async {
    final dir = await _directory();
    return File(p.join(dir.path, _draftFileName));
  }

  Future<T> _enqueue<T>(Future<T> Function() op) {
    final result = _chain.then((_) => op());
    _chain = result.then((_) {}, onError: (_) {});
    return result;
  }

  @override
  Future<JobsTrackDraft?> load() => _enqueue(() async {
    try {
      final file = await _file();
      if (!await file.exists()) return null;
      final raw = await file.readAsString();
      if (raw.trim().isEmpty) return null;
      final draft = JobsTrackDraft.fromJson(
        Map<String, dynamic>.from(jsonDecode(raw) as Map),
      );
      // A blob from another schema version reads as null; drop it so the next
      // save isn't fighting a file it can't parse.
      if (draft == null) await _deleteQuietly();
      return draft;
    } catch (error) {
      // Unreadable or from another schema — drop it and open the normal flow.
      debugPrint('Jobs draft could not be read: $error');
      await _deleteQuietly();
      return null;
    }
  });

  @override
  Future<void> save(JobsTrackDraft draft) => _enqueue(() async {
    try {
      final file = await _file();
      await file.writeAsString(jsonEncode(draft.toJson()), flush: true);
    } catch (error) {
      // A draft that can't be written is a convenience lost, never an error
      // worth interrupting the form for.
      debugPrint('Jobs draft could not be saved: $error');
    }
  });

  @override
  Future<void> clear() => _enqueue(_deleteQuietly);

  Future<void> _deleteQuietly() async {
    try {
      final file = await _file();
      if (await file.exists()) await file.delete();
    } catch (error) {
      debugPrint('Jobs draft could not be cleared: $error');
    }
  }
}

/// In-memory slot, for tests and for any build where the platform has no
/// documents directory to write to.
class MemoryJobsTrackDraftStore implements JobsTrackDraftStore {
  JobsTrackDraft? draft;

  @override
  Future<JobsTrackDraft?> load() async => draft;

  @override
  Future<void> save(JobsTrackDraft value) async => draft = value;

  @override
  Future<void> clear() async => draft = null;
}

final jobsTrackDraftStoreProvider = Provider<JobsTrackDraftStore>(
  (ref) => FileJobsTrackDraftStore(),
);

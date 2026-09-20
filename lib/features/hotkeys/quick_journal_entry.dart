import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/constants/journal_constants.dart';
import 'package:voyager/core/utils/all_view_destination.dart';
import 'package:voyager/core/utils/ids.dart';
import 'package:voyager/domain/models/journal_models.dart';
import 'package:voyager/domain/models/settings_models.dart';

/// Which entry is today's Quick Journal Entry — the one the journal hotkey
/// opens, from the notepad floater or in the app.
///
/// Device-local on purpose: the entry itself syncs like any other, but the
/// pointer does not, so two devices never race to claim one day.
abstract class QuickJournalPointerStore {
  Future<({String day, String entryId})?> load();

  Future<void> save(String day, String entryId);
}

class FileQuickJournalPointerStore implements QuickJournalPointerStore {
  FileQuickJournalPointerStore({Future<Directory> Function()? directory})
    : _directory = directory ?? getApplicationDocumentsDirectory;

  final Future<Directory> Function() _directory;

  Future<File> _file() async =>
      File(p.join((await _directory()).path, 'quick_journal_entry.json'));

  @override
  Future<({String day, String entryId})?> load() async {
    try {
      final file = await _file();
      if (!await file.exists()) return null;
      final json = jsonDecode(await file.readAsString()) as Map;
      final day = json['day'];
      final entryId = json['entryId'];
      if (day is! String || entryId is! String) return null;
      return (day: day, entryId: entryId);
    } catch (error) {
      debugPrint('Quick journal pointer could not be read: $error');
      return null;
    }
  }

  @override
  Future<void> save(String day, String entryId) async {
    try {
      final file = await _file();
      await file.writeAsString(
        jsonEncode({'day': day, 'entryId': entryId}),
        flush: true,
      );
    } catch (error) {
      debugPrint('Quick journal pointer could not be saved: $error');
    }
  }
}

final quickJournalPointerStoreProvider = Provider<QuickJournalPointerStore>(
  (_) => FileQuickJournalPointerStore(),
);

/// The entry the journal notepad floater is bound to, until its last flush
/// has landed.
///
/// The journal page skips its own body writes for this entry meanwhile: its
/// editor still holds the text from before the notepad, and a lifecycle flush
/// would write that back over what was typed in the notepad. The page picks
/// the new body up through its provider listener once the notepad refreshes
/// the entry caches.
final quickJournalNotepadEntryId = ValueNotifier<String?>(null);

String _localDayKey(DateTime now) =>
    '${now.year.toString().padLeft(4, '0')}-'
    '${now.month.toString().padLeft(2, '0')}-'
    '${now.day.toString().padLeft(2, '0')}';

Future<JournalEntry>? _resolving;

/// Today's Quick Journal Entry, created on the spot when there is none — or
/// when the one there was has since been deleted, from anywhere.
///
/// Serialized, so the notepad and the in-app hotkey can never both create one.
Future<JournalEntry> resolveQuickJournalEntry(ProviderContainer container) {
  return _resolving ??= _resolve(container).whenComplete(
    () => _resolving = null,
  );
}

Future<JournalEntry> _resolve(ProviderContainer container) async {
  final store = container.read(quickJournalPointerStoreProvider);
  final repo = container.read(journalRepositoryProvider);
  final today = _localDayKey(DateTime.now());

  final pointer = await store.load();
  if (pointer != null && pointer.day == today) {
    final existing = await repo.getEntry(pointer.entryId);
    if (existing != null && existing.deletedAt == null) return existing;
  }

  final settingsRepo = container.read(settingsRepositoryProvider);
  final settings = await settingsRepo.getSettings();
  var journals = await repo.listJournals();
  if (journals.isEmpty) {
    final now = utcNow();
    final defaultJournal = Journal(
      id: legacyJournalId,
      name: 'Journal',
      colorValue: settings.accentColor,
      createdAt: now,
      updatedAt: now,
    );
    await repo.upsertJournal(defaultJournal);
    container.read(remoteSyncServiceProvider).pushJournal(defaultJournal);
    journals = [defaultJournal];
  }
  final journalId =
      resolveNewItemTarget(
        currentId: null,
        lastViewedId: settings.lastViewedJournalId,
        legacyId: legacyJournalId,
        availableIds: [for (final journal in journals) journal.id],
      ) ??
      legacyJournalId;

  // The same fields the journal page stamps on a new entry.
  final weather = container
      .read(weatherServiceProvider)
      .readCachedSnapshot(settings);
  // Awaited, rather than read for whatever the bank already holds: the hotkey
  // can fire before the startup warm-up has loaded it — or instead of it, with
  // the cache disabled — and reading the loading state left that day's entry
  // with no quote for good, since nothing revisits it afterwards. The pool is
  // a few hundred bytes beside the reads above, and a pool that fails to load
  // must not take the notepad down with it.
  Quote? quote;
  try {
    await container.read(quotesLoadedProvider.future);
    quote = container.read(quoteBankProvider).nextQuote();
  } catch (error) {
    debugPrint('Quick journal quote could not be drawn: $error');
  }
  final now = utcNow();
  final entry = JournalEntry(
    id: newId(),
    journalId: journalId,
    title: '',
    body: '',
    entryDate: now,
    weatherIcon: weather?.icon ?? 'sunny',
    mood: kDefaultMood,
    quoteId: quote?.id,
    customQuote: quote?.text,
    timestamp: now,
    createdAt: now,
    updatedAt: now,
  );
  await repo.upsertEntry(entry);
  // A no-op delta, for what the journal page's create gets from its
  // finalize pass: the upload is scheduled and the entry lists refreshed.
  await container
      .read(journalWriteCoordinatorProvider)
      .saveEntry(entryId: entry.id, applyDelta: (base) => base);
  await store.save(today, entry.id);
  return entry;
}

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/constants/journal_constants.dart';
import 'package:voyager/core/platform/app_data_directory.dart';
import 'package:voyager/core/utils/all_view_destination.dart';
import 'package:voyager/core/utils/calendar_days.dart';
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
    : _directory = directory ?? appDataDirectory;

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

typedef _Target = ({
  AppSettings settings,
  DateTime todayStart,
  String today,
  String? journalId,
});

/// Today, and the journal the hotkey files into — null only when there are no
/// journals at all.
Future<_Target> _target(ProviderContainer container) async {
  final settings = await container
      .read(settingsRepositoryProvider)
      .getSettings();
  final todayStart = journalDay(DateTime.now(), settings.dayStartHour);
  final journals = await container
      .read(journalRepositoryProvider)
      .listJournals();
  return (
    settings: settings,
    todayStart: todayStart,
    today: _localDayKey(todayStart),
    journalId: resolveNewItemTarget(
      currentId: null,
      lastViewedId: settings.lastViewedJournalId,
      legacyId: legacyJournalId,
      availableIds: [for (final journal in journals) journal.id],
    ),
  );
}

/// Today's Quick Journal Entry if there is one, without creating it — for the
/// notepad, which only creates it once something is written.
///
/// The hotkey's own entry while it lives: not once deleted, from anywhere, or
/// re-dated to another day (one started after midnight and moved back to the
/// day it is about). Otherwise an entry already written today in the journal
/// the hotkey targets — say one added by hand on the journal page — is adopted
/// as today's, the latest when there are several.
Future<JournalEntry?> findQuickJournalEntry(
  ProviderContainer container,
) async => _find(container, await _target(container));

Future<JournalEntry?> _find(ProviderContainer container, _Target target) async {
  final store = container.read(quickJournalPointerStoreProvider);
  final repo = container.read(journalRepositoryProvider);
  final pointer = await store.load();
  final today = target.today;
  bool isToday(JournalEntry entry) =>
      _localDayKey(journalDay(entry.entryDate, target.settings.dayStartHour)) ==
      today;
  if (pointer != null && pointer.day == today) {
    final existing = await repo.getEntry(pointer.entryId);
    if (existing != null && existing.deletedAt == null && isToday(existing)) {
      return existing;
    }
  }

  final journalId = target.journalId;
  if (journalId == null) return null;
  // Bounded loosely and filtered by [journalDay], which owns the day-start
  // rule; the latest comes first.
  final candidates = await repo.listEntries(
    journalId: journalId,
    from: target.todayStart.subtract(const Duration(days: 1)).toUtc(),
    to: target.todayStart.add(const Duration(days: 2)).toUtc(),
  );
  for (final entry in candidates) {
    if (isToday(entry)) {
      await store.save(today, entry.id);
      return entry;
    }
  }
  return null;
}

/// Today's Quick Journal Entry, created on the spot when
/// [findQuickJournalEntry] has none — as [id] when given, so the notepad can
/// hand its image targets an id before the entry exists.
///
/// Serialized, so the notepad and the in-app hotkey can never both create one.
Future<JournalEntry> resolveQuickJournalEntry(
  ProviderContainer container, {
  String? id,
}) {
  return _resolving ??= _resolve(
    container,
    id,
  ).whenComplete(() => _resolving = null);
}

Future<JournalEntry> _resolve(ProviderContainer container, String? id) async {
  final target = await _target(container);
  final existing = await _find(container, target);
  if (existing != null) return existing;

  final store = container.read(quickJournalPointerStoreProvider);
  final repo = container.read(journalRepositoryProvider);
  final settings = target.settings;
  final today = target.today;
  var journalId = target.journalId;
  if (journalId == null) {
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
    journalId = defaultJournal.id;
  }

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
    quote = container.read(quoteBankProvider).nextQuote(journalId);
  } catch (error) {
    debugPrint('Quick journal quote could not be drawn: $error');
  }
  final now = utcNow();
  final entry = JournalEntry(
    id: id ?? newId(),
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

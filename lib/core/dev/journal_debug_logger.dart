import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:voyager/domain/models/journal_models.dart';
import 'package:voyager/domain/models/settings_models.dart';
import 'package:voyager/domain/repositories/repositories.dart';

const _logFileName = 'journal_debug.log';
const _maxLogBytes = 2 * 1024 * 1024;

/// UI state captured from [JournalPage] at the time of a debug event.
class JournalPageDebugSnapshot {
  const JournalPageDebugSnapshot({
    this.selectedEntryId,
    this.titleText = '',
    this.bodyText = '',
    this.metadataDirty = false,
    this.bodyFocused = false,
    this.titleFocused = false,
    this.journalFilter,
    this.viewAllJournals = false,
    this.bodyDraftEntryIds = const [],
  });

  final String? selectedEntryId;
  final String titleText;
  final String bodyText;
  final bool metadataDirty;
  final bool bodyFocused;
  final bool titleFocused;
  final String? journalFilter;
  final bool viewAllJournals;
  final List<String> bodyDraftEntryIds;

  String format() {
    final buffer = StringBuffer()
      ..writeln('UI STATE:')
      ..writeln('  selectedEntryId=$selectedEntryId')
      ..writeln('  journalFilter=$journalFilter viewAllJournals=$viewAllJournals')
      ..writeln('  metadataDirty=$metadataDirty')
      ..writeln('  titleFocused=$titleFocused bodyFocused=$bodyFocused')
      ..writeln('  title="${_preview(titleText, 120)}"')
      ..writeln('  body="${_preview(bodyText, 200)}"')
      ..writeln('  bodyDraftEntryIds=${bodyDraftEntryIds.join(", ")}');
    return buffer.toString();
  }

  static String _preview(String value, int max) {
    final normalized = value.replaceAll('\n', '\\n');
    if (normalized.length <= max) return normalized;
    return '${normalized.substring(0, max)}…';
  }
}

/// Persists a rolling text log of journal page UI state and save actions.
class JournalDebugLogger extends ChangeNotifier {
  JournalDebugLogger({
    SettingsRepository? settingsRepository,
    JournalRepository? journalRepository,
  })  : _settingsRepository = settingsRepository,
        _journalRepository = journalRepository;

  final SettingsRepository? _settingsRepository;
  final JournalRepository? _journalRepository;

  bool enabled = false;
  Future<void>? _writeChain = Future<void>.value();

  Future<void> loadFromSettings() async {
    final repo = _settingsRepository;
    if (repo == null) return;
    final settings = await repo.getSettings();
    applySettings(settings);
  }

  void applySettings(AppSettings settings) {
    if (enabled == settings.devJournalDebugLog) return;
    enabled = settings.devJournalDebugLog;
    notifyListeners();
  }

  Future<void> setEnabled(bool value) async {
    if (enabled == value) return;
    enabled = value;
    notifyListeners();

    final repo = _settingsRepository;
    if (repo != null) {
      final settings = await repo.getSettings();
      await repo.saveSettings(settings.copyWith(devJournalDebugLog: value));
    }

    if (value) {
      await _enqueue(() async {
        await _append(
          'LOG_ENABLED',
          details: 'Journal page debug logging started.',
        );
      });
    } else {
      await _enqueue(() async {
        await _append(
          'LOG_DISABLED',
          details: 'Journal page debug logging stopped.',
        );
      });
    }
  }

  Future<String> logFilePath() async {
    final dir = await getApplicationDocumentsDirectory();
    return p.join(dir.path, _logFileName);
  }

  Future<String> readLog() async {
    final file = File(await logFilePath());
    if (!await file.exists()) return '';
    return file.readAsString();
  }

  Future<void> clearLog() async {
    final file = File(await logFilePath());
    if (await file.exists()) {
      await file.writeAsString('');
    }
    if (enabled) {
      await _enqueue(() async {
        await _append('LOG_CLEARED', details: 'Log file cleared.');
      });
    }
  }

  Future<void> recordEvent(
    String event, {
    JournalPageDebugSnapshot? page,
    JournalEntry? entry,
    String? details,
  }) async {
    if (!enabled) return;
    await _enqueue(() async {
      await _append(event, page: page, entry: entry, details: details);
    });
  }

  Future<void> _append(
    String event, {
    JournalPageDebugSnapshot? page,
    JournalEntry? entry,
    String? details,
  }) async {
    final repo = _journalRepository;
    if (repo == null) return;

    final timestamp = DateTime.now().toUtc().toIso8601String();
    final buffer = StringBuffer()
      ..writeln('=' * 80)
      ..writeln('$timestamp | $event');

    if (entry != null) {
      buffer.writeln(_formatEntryHeader(entry));
    }
    if (details != null && details.isNotEmpty) {
      buffer.writeln(details);
    }
    if (page != null) {
      buffer.write(page.format());
    }

    buffer.writeln('-' * 80);
    buffer.write(await _formatDbSnapshot(repo, page: page, entry: entry));
    buffer.writeln('=' * 80);
    buffer.writeln();

    final text = buffer.toString();

    final file = File(await logFilePath());
    await _trimIfNeeded(file);
    await file.writeAsString(text, mode: FileMode.append, flush: true);
  }

  Future<void> _trimIfNeeded(File file) async {
    if (!await file.exists()) return;
    final length = await file.length();
    if (length <= _maxLogBytes) return;

    final content = await file.readAsString();
    final trimmed = content.substring(content.length - (_maxLogBytes ~/ 2));
    final nextIndex = trimmed.indexOf('=' * 80);
    final kept = nextIndex >= 0 ? trimmed.substring(nextIndex) : trimmed;
    await file.writeAsString(
      '... log truncated ...\n$kept',
      flush: true,
    );
  }

  Future<String> _formatDbSnapshot(
    JournalRepository repo, {
    JournalPageDebugSnapshot? page,
    JournalEntry? entry,
  }) async {
    final buffer = StringBuffer()..writeln('DB SNAPSHOT:');

    final focusId = page?.selectedEntryId ?? entry?.id;
    if (focusId != null) {
      final stored = await repo.getEntry(focusId);
      buffer.writeln(
        stored == null
            ? '  selected entry $focusId: (not in DB)'
            : '  selected: ${_formatEntryLine(stored)}',
      );
    }

    final scopeJournalId =
        page?.viewAllJournals == true ? null : page?.journalFilter;
    final entries = await repo.listEntries(
      journalId: scopeJournalId,
      limit: 40,
    );
    buffer.writeln(
      '  scope=${scopeJournalId ?? "ALL"} listed=${entries.length} entries',
    );
    for (var i = 0; i < entries.length; i++) {
      buffer.writeln('    [${i}] ${_formatEntryLine(entries[i])}');
    }

    return buffer.toString();
  }

  String _formatEntryHeader(JournalEntry entry) {
    return 'Entry id=${entry.id} journalId=${entry.journalId} '
        'title="${entry.title}"';
  }

  String _formatEntryLine(JournalEntry entry) {
    final bodyPreview = JournalPageDebugSnapshot._preview(entry.body, 80);
    final deleted = entry.deletedAt != null ? ' deleted' : '';
    return 'id=${entry.id} v=${entry.version} '
        'updated=${entry.updatedAt.toUtc().toIso8601String()}$deleted '
        'title="${entry.title}" body="$bodyPreview"';
  }

  Future<void> _enqueue(Future<void> Function() action) {
    _writeChain = _writeChain!.then((_) => action());
    return _writeChain!;
  }
}

void logJournalDebug(
  JournalDebugLogger? logger,
  String event, {
  JournalPageDebugSnapshot? page,
  JournalEntry? entry,
  String? details,
}) {
  if (logger == null || !logger.enabled) return;
  unawaited(
    logger.recordEvent(event, page: page, entry: entry, details: details),
  );
}

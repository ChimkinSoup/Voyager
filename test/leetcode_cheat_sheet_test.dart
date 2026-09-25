// The LeetCode cheat sheet's data layer: sync across devices, the cascade
// deletes and their undo, the device-local settings columns, export shaping,
// search, and the text parsing Viewing mode leans on.
//
// Two devices share one InMemorySyncRepository (the server) while writing to
// their own databases, which is what makes "device B sees it" a real
// assertion rather than a round trip through a single local table — the same
// harness `secondary_collections_sync_test.dart` uses.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/core/soft_delete/restore_contract.dart';
import 'package:voyager/core/sync/debouncer.dart';
import 'package:voyager/core/sync/firestore_collections.dart';
import 'package:voyager/core/sync/firestore_document_mapper.dart';
import 'package:voyager/core/sync/remote_sync_service.dart';
import 'package:voyager/core/sync/sync_engine.dart';
import 'package:voyager/core/sync/synced_write_notifier.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/data/remote/in_memory_sync.dart';
import 'package:voyager/data/repositories/drift_repositories.dart';
import 'package:voyager/domain/models/leetcode_cheat_models.dart';
import 'package:voyager/domain/models/settings_models.dart';
import 'package:voyager/features/leetcode/leetcode_cheat_entry.dart';
import 'package:voyager/features/leetcode/leetcode_cheat_export.dart';
import 'package:voyager/features/leetcode/leetcode_cheat_providers.dart';
import 'package:voyager/features/leetcode/leetcode_cheat_search.dart';
import 'package:voyager/features/leetcode/leetcode_cheat_text.dart';

final _now = DateTime.utc(2026, 9, 20, 12);

/// One device: its own database and repositories, wired to the shared server.
class _Device {
  _Device(this.syncRepo, String deviceId) {
    db = AppDatabase.inMemory();
    syncedWrites = SyncedWriteNotifier();
    settings = DriftSettingsRepository(db, syncedWrites: syncedWrites);
    leetCode = DriftLeetCodeRepository(db);

    sync = RemoteSyncService(
      syncRepository: syncRepo,
      journalRepository: DriftJournalRepository(db),
      dreamRepository: DriftDreamRepository(db),
      todoRepository: DriftTodoRepository(db),
      leetCodeRepository: leetCode,
      studyRepository: DriftStudyRepository(db),
      workoutRepository: DriftWorkoutRepository(db),
      jobRepository: DriftJobRepository(db),
      rankingRepository: DriftRankingRepository(db),
      calendarRepository: DriftCalendarRepository(db),
      trackerRepository: DriftTrackerRepository(db),
      financeRepository: DriftFinanceRepository(db),
      notificationRepository: DriftNotificationRepository(db),
      reminderRepository: DriftReminderRepository(db),
      bucketListRepository: DriftBucketListRepository(db),
      mediaRepository: DriftMediaRepository(db),
      settingsRepository: settings,
      syncEngine: SyncEngine(
        syncRepository: syncRepo,
        deviceId: deviceId,
        debouncer: Debouncer(delay: Duration.zero),
      ),
      deviceId: deviceId,
      uploadDebounceDelay: Duration.zero,
    );
  }

  final InMemorySyncRepository syncRepo;
  late final AppDatabase db;
  late final SyncedWriteNotifier syncedWrites;
  late final DriftSettingsRepository settings;
  late final DriftLeetCodeRepository leetCode;
  late final RemoteSyncService sync;

  Future<void> pullCheat() async {
    await sync.pullLeetCodeCheatTabs();
    await sync.pullLeetCodeCheatSections();
    await sync.pullLeetCodeCheatEntries();
  }

  Future<void> close() => db.close();
}

LeetCodeCheatTab _tab({
  String id = 'tab-1',
  String name = 'Java',
  String? languageKey = 'java',
  double position = kCheatPositionStep,
  int version = 0,
  DateTime? updatedAt,
}) => LeetCodeCheatTab(
  id: id,
  name: name,
  languageKey: languageKey,
  position: position,
  createdAt: _now,
  updatedAt: updatedAt ?? _now,
  version: version,
);

LeetCodeCheatSection _section({
  String id = 'section-1',
  String tabId = 'tab-1',
  String name = 'ArrayList',
  double position = kCheatPositionStep,
}) => LeetCodeCheatSection(
  id: id,
  tabId: tabId,
  name: name,
  position: position,
  createdAt: _now,
  updatedAt: _now,
);

LeetCodeCheatEntry _entry({
  String id = 'entry-1',
  String sectionId = 'section-1',
  String command = '.add(e)',
  String? label,
  String description = 'Appends to the back.',
  String? complexity = 'O(1) amortized',
  double position = kCheatPositionStep,
}) => LeetCodeCheatEntry(
  id: id,
  sectionId: sectionId,
  command: command,
  label: label,
  description: description,
  complexity: complexity,
  position: position,
  createdAt: _now,
  updatedAt: _now,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('sync', () {
    late InMemorySyncRepository server;
    late _Device deviceA;
    late _Device deviceB;

    setUp(() {
      server = InMemorySyncRepository();
      deviceA = _Device(server, 'device-a');
      deviceB = _Device(server, 'device-b');
    });

    tearDown(() async {
      await deviceA.close();
      await deviceB.close();
    });

    test('an entry created on A appears on B, parents and all', () async {
      await deviceA.leetCode.upsertCheatTab(_tab());
      await deviceA.leetCode.upsertCheatSection(_section());
      await deviceA.leetCode.upsertCheatEntry(_entry());
      deviceA.sync.pushLeetCodeCheatTab(_tab());
      deviceA.sync.pushLeetCodeCheatSection(_section());
      deviceA.sync.pushLeetCodeCheatEntry(_entry());
      await Future<void>.delayed(Duration.zero);

      await deviceB.pullCheat();

      expect(await deviceB.leetCode.listCheatTabs(), hasLength(1));
      expect(await deviceB.leetCode.listCheatSections(), hasLength(1));
      final entries = await deviceB.leetCode.listCheatEntries();
      expect(entries, hasLength(1));
      expect(entries.single.command, '.add(e)');
      expect(entries.single.description, 'Appends to the back.');
      expect(entries.single.complexity, 'O(1) amortized');
    });

    test('the same entry edited on both resolves by version, and leaves the '
        'other two collections alone', () async {
      await deviceA.leetCode.upsertCheatTab(_tab());
      await deviceA.leetCode.upsertCheatSection(_section());
      await deviceA.leetCode.upsertCheatEntry(_entry());
      deviceA.sync.pushLeetCodeCheatTab(_tab());
      deviceA.sync.pushLeetCodeCheatSection(_section());
      deviceA.sync.pushLeetCodeCheatEntry(_entry());
      await Future<void>.delayed(Duration.zero);
      await deviceB.pullCheat();

      // B's edit is the later revision by version, so it wins on A.
      final onA = _entry().copyWith(command: 'A wins?');
      final onB = _entry()
          .copyWith(command: 'B wins')
          .copyWith(command: 'B wins');
      await deviceA.leetCode.upsertCheatEntry(onA);
      await deviceB.leetCode.upsertCheatEntry(onB);
      deviceB.sync.pushLeetCodeCheatEntry(onB);
      await Future<void>.delayed(Duration.zero);

      await deviceA.pullCheat();

      final entries = await deviceA.leetCode.listCheatEntries();
      expect(entries.single.command, 'B wins');
      expect(onB.version, greaterThan(onA.version));
      // The tab and section were never touched by any of it.
      expect((await deviceA.leetCode.listCheatTabs()).single.version, 0);
      expect((await deviceA.leetCode.listCheatSections()).single.version, 0);
    });

    test('a tombstone pushed from A deletes the row on B', () async {
      await deviceA.leetCode.upsertCheatTab(_tab());
      await deviceA.leetCode.upsertCheatSection(_section());
      await deviceA.leetCode.upsertCheatEntry(_entry());
      deviceA.sync.pushLeetCodeCheatTab(_tab());
      deviceA.sync.pushLeetCodeCheatSection(_section());
      deviceA.sync.pushLeetCodeCheatEntry(_entry());
      await Future<void>.delayed(Duration.zero);
      await deviceB.pullCheat();

      final deleted = await deviceA.leetCode.softDeleteCheatEntry('entry-1');
      deviceA.sync.pushLeetCodeCheatEntry(deleted);
      await Future<void>.delayed(Duration.zero);

      await deviceB.pullCheat();
      expect(await deviceB.leetCode.listCheatEntries(), isEmpty);
    });
  });

  group('reads join through live parents', () {
    late AppDatabase db;
    late DriftLeetCodeRepository repo;

    setUp(() async {
      db = AppDatabase.inMemory();
      repo = DriftLeetCodeRepository(db);
      await repo.upsertCheatTab(_tab());
      await repo.upsertCheatSection(_section());
      await repo.upsertCheatEntry(_entry());
    });

    tearDown(() => db.close());

    test(
      'an orphaned section and entry are filtered out, not chased',
      () async {
        // The tab is tombstoned directly, without the cascade, which is what a
        // pull of another device's tab delete looks like.
        await repo.upsertCheatTab(_tab().copyWith(deletedAt: _now));

        expect(await repo.listCheatSections(), isEmpty);
        expect(await repo.listCheatEntries(), isEmpty);
        // The rows are still on disk, untouched.
        expect(await repo.getAllCheatSections(), hasLength(1));
        expect((await repo.getAllCheatEntries()).single.deletedAt, isNull);
      },
    );
  });

  group('cascade delete and undo', () {
    late AppDatabase db;
    late DriftLeetCodeRepository repo;

    setUp(() async {
      db = AppDatabase.inMemory();
      repo = DriftLeetCodeRepository(db);
      await repo.upsertCheatTab(_tab());
      await repo.upsertCheatSection(_section());
      for (var i = 1; i <= 3; i++) {
        await repo.upsertCheatEntry(
          _entry(id: 'entry-$i', position: kCheatPositionStep * i),
        );
      }
    });

    tearDown(() => db.close());

    test('deleting a section with three entries takes all four', () async {
      final result = await repo.softDeleteCheatSection('section-1');
      expect(result.entries, hasLength(3));
      expect(await repo.listCheatSections(), isEmpty);
      expect(await repo.listCheatEntries(), isEmpty);
    });

    test('undo brings the section and all three back', () async {
      await repo.softDeleteCheatSection('section-1');
      final restored = await repo.restoreCheatSection('section-1');

      expect(restored.entries, hasLength(3));
      expect(await repo.listCheatSections(), hasLength(1));
      expect(await repo.listCheatEntries(), hasLength(3));
    });

    test('an entry deleted on its own does not ride back in on the section '
        'restore', () async {
      // Its own instant, so the cascade's exact-match restore skips it.
      await repo.softDeleteCheatEntry('entry-2');
      // The two deletes are told apart by their `deletedAt` instant alone,
      // as Rankings' cascades are. Timestamps are stored to sub-second
      // precision, so a user cannot land both in one instant — but two
      // back-to-back calls in a test can.
      await Future<void>.delayed(const Duration(milliseconds: 2));
      await repo.softDeleteCheatSection('section-1');
      await repo.restoreCheatSection('section-1');

      final live = await repo.listCheatEntries();
      expect(live.map((e) => e.id), unorderedEquals(['entry-1', 'entry-3']));
    });

    test('deleting a tab takes its sections and their entries', () async {
      await repo.upsertCheatSection(
        _section(id: 'section-2', position: kCheatPositionStep * 2),
      );
      await repo.upsertCheatEntry(
        _entry(id: 'entry-4', sectionId: 'section-2'),
      );

      final result = await repo.softDeleteCheatTab('tab-1');
      expect(result.sections, hasLength(2));
      expect(result.entries, hasLength(4));
      expect(await repo.listCheatTabs(), isEmpty);

      final restored = await repo.restoreCheatTab('tab-1');
      expect(restored.sections, hasLength(2));
      expect(restored.entries, hasLength(4));
      expect(await repo.listCheatEntries(), hasLength(4));
    });

    test(
      'a pull that already brought the row back surfaces as RestoreSuperseded '
      'rather than overwriting it',
      () async {
        await repo.softDeleteCheatEntry('entry-1');
        // Another device's restore lands inside the undo window.
        final live = (await repo.listCheatEntries(
          includeDeleted: true,
        )).firstWhere((e) => e.id == 'entry-1');
        await repo.upsertCheatEntry(
          live.copyWith(clearDeletedAt: true, command: 'edited elsewhere'),
        );

        await expectLater(
          repo.restoreCheatEntry('entry-1'),
          throwsA(isA<RestoreSuperseded>()),
        );
        // The newer remote edit is still there, not the pre-delete snapshot.
        final entry = await repo.getCheatEntry('entry-1');
        expect(entry!.command, 'edited elsewhere');
      },
    );

    test('a restore outranks the tombstone it undoes', () async {
      final tombstone = await repo.softDeleteCheatEntry('entry-1');
      final restored = await repo.restoreCheatEntry('entry-1');
      expect(restored.version, greaterThan(tombstone.version));
    });
  });

  group('device-local settings', () {
    late AppDatabase db;
    late DriftSettingsRepository settings;

    setUp(() {
      db = AppDatabase.inMemory();
      settings = DriftSettingsRepository(db);
    });

    tearDown(() => db.close());

    test('remembering a tab does not move AppSettings.updatedAt', () async {
      final before = await settings.getSettings();
      await settings.saveSettings(
        before.copyWith(leetCodeCheatLastTabId: 'tab-7'),
      );

      final after = await settings.getSettings();
      expect(after.leetCodeCheatLastTabId, 'tab-7');
      // The whole mechanism: the column is absent from settingsSyncPayload,
      // so the last-write-wins clock stays where it was and merely opening
      // the sheet cannot overwrite another device's newer preference.
      expect(after.updatedAt, before.updatedAt);
    });

    test('collapsing a section does not move it either', () async {
      final before = await settings.getSettings();
      await settings.saveSettings(
        before.copyWith(leetCodeCheatCollapsedSections: const ['s1', 's2']),
      );

      final after = await settings.getSettings();
      expect(after.leetCodeCheatCollapsedSections, ['s1', 's2']);
      expect(after.updatedAt, before.updatedAt);
    });

    test('neither column reaches the sync payload', () {
      const a = AppSettingsProbe.withCheatState;
      const b = AppSettingsProbe.withoutCheatState;
      expect(settingsSyncPayload(a), settingsSyncPayload(b));
    });

    test('a tab this device has never seen still opens on one', () async {
      final data = LeetCodeCheatSheetData(
        tabs: [
          _tab(id: 'tab-a'),
          _tab(id: 'tab-b'),
        ],
        sectionsByTab: const {},
        entriesBySection: const {},
      );
      // Deleted on another device, or not pulled to this one yet.
      expect(data.resolveTab('tab-gone')!.id, 'tab-a');
      expect(data.resolveTab(null)!.id, 'tab-a');
      expect(data.resolveTab('tab-b')!.id, 'tab-b');
    });

    test('with no tabs at all there is nothing to resolve to', () {
      const data = LeetCodeCheatSheetData.empty();
      expect(data.resolveTab('tab-gone'), isNull);
    });
  });

  group('complexity per line', () {
    test('each line of the command gets the line of the field beside it', () {
      final entry = _entry(
        command: 'for (int i…)\n  for (int j…)\n  sum += a[i]',
        complexity: 'O(n)\nO(n²)\nO(1)',
      );
      expect(entry.complexityByLine, ['O(n)', 'O(n²)', 'O(1)']);
    });

    test('a blank line is a line with no badge, wherever it falls', () {
      // The leading blank is the case that matters: it means "the opening
      // line costs nothing to say", and it must not slide the rest up.
      expect(
        _entry(
          command: 'while (lo < hi)\n  mid = (lo + hi) / 2',
          complexity: '\nO(1)',
        ).complexityByLine,
        ['', 'O(1)'],
      );
    });

    test('a short or absent field leaves the rest of the lines bare', () {
      expect(_entry(command: 'a\nb\nc', complexity: 'O(1)').complexityByLine, [
        'O(1)',
        '',
        '',
      ]);
      expect(_entry(command: 'a\nb', complexity: null).complexityByLine, [
        '',
        '',
      ]);
    });

    test('a field longer than the command drops its surplus', () {
      expect(_entry(command: 'a', complexity: 'O(1)\nO(n)').complexityByLine, [
        'O(1)',
      ]);
    });

    test('a single-line entry still reads as one command and one cost', () {
      final entry = _entry();
      expect(entry.commandLines, ['.add(e)']);
      expect(entry.complexityByLine, ['O(1) amortized']);
    });
  });

  group('export', () {
    LeetCodeCheatSheetData sheet({
      List<LeetCodeCheatTab>? tabs,
      Map<String, List<LeetCodeCheatSection>>? sections,
      Map<String, List<LeetCodeCheatEntry>>? entries,
    }) => LeetCodeCheatSheetData(
      tabs: tabs ?? [_tab()],
      sectionsByTab: sections ?? {},
      entriesBySection: entries ?? {},
    );

    test('an empty section is skipped and a populated one is kept', () {
      final markdown = leetCodeCheatSheetMarkdown(
        sheet(
          sections: {
            'tab-1': [
              _section(id: 'empty', name: 'Empty'),
              _section(
                id: 'full',
                name: 'ArrayList',
                position: kCheatPositionStep * 2,
              ),
            ],
          },
          entries: {
            'full': [_entry()],
          },
        ),
      );

      expect(markdown, contains('## ArrayList'));
      expect(markdown, isNot(contains('Empty')));
      expect(markdown, contains('### `.add(e)` — O(1) amortized'));
      expect(markdown, contains('Appends to the back.'));
    });

    test(
      'a label leads the heading, and an entry without one is unchanged',
      () {
        String markdownFor(LeetCodeCheatEntry entry) =>
            leetCodeCheatSheetMarkdown(
              sheet(
                tabs: [_tab()],
                sections: {
                  'tab-1': [_section(id: 'full', name: 'ArrayList')],
                },
                entries: {
                  'full': [entry],
                },
              ),
            );

        expect(
          markdownFor(_entry(sectionId: 'full', label: 'Append')),
          contains('### Append — `.add(e)` — O(1) amortized'),
        );
        expect(
          markdownFor(_entry(sectionId: 'full')),
          contains('### `.add(e)` — O(1) amortized'),
        );
      },
    );

    test('a block exports one line at a time, each with its own cost', () {
      final markdown = leetCodeCheatSheetMarkdown(
        sheet(
          tabs: [_tab()],
          sections: {
            'tab-1': [_section(id: 'full', name: 'ArrayList')],
          },
          entries: {
            'full': [
              _entry(
                sectionId: 'full',
                label: 'Nested scan',
                command: 'for (a : list)\n  for (b : list)',
                complexity: 'O(n)\nO(n²)',
                description: '',
              ),
            ],
          },
        ),
      );

      expect(
        markdown,
        contains(
          '### Nested scan — `for (a : list)` — O(n)\n'
          '`  for (b : list)` — O(n²)\n',
        ),
      );
    });

    test('a tab with no surviving section is skipped with it', () {
      final markdown = leetCodeCheatSheetMarkdown(
        sheet(
          tabs: [
            _tab(id: 'tab-1'),
            _tab(id: 'tab-2', name: 'Python'),
          ],
          sections: {
            'tab-1': [_section(id: 'empty')],
            'tab-2': [_section(id: 'full', tabId: 'tab-2', name: 'dict')],
          },
          entries: {
            'full': [_entry(sectionId: 'full', command: '.get(k, v)')],
          },
        ),
      );

      expect(markdown, isNot(contains('# Java')));
      expect(markdown, contains('# Python'));
    });

    test('an unset complexity leaves no em dash behind', () {
      final markdown = leetCodeCheatSheetMarkdown(
        sheet(
          sections: {
            'tab-1': [_section()],
          },
          entries: {
            'section-1': [_entry(complexity: null)],
          },
        ),
      );
      expect(markdown, contains('### `.add(e)`\n'));
      expect(markdown, isNot(contains('—')));
    });

    test('an empty sheet exports nothing at all, so the caller can say so', () {
      expect(
        leetCodeCheatSheetMarkdown(const LeetCodeCheatSheetData.empty()),
        isEmpty,
      );
      expect(
        leetCodeCheatSheetMarkdown(
          sheet(
            sections: {
              'tab-1': [_section()],
            },
          ),
        ),
        isEmpty,
      );
    });

    test('one tab can be exported on its own', () {
      final data = sheet(
        tabs: [
          _tab(id: 'tab-1'),
          _tab(id: 'tab-2', name: 'Python'),
        ],
        sections: {
          'tab-1': [_section(id: 's1')],
          'tab-2': [_section(id: 's2', tabId: 'tab-2', name: 'dict')],
        },
        entries: {
          's1': [_entry(sectionId: 's1')],
          's2': [_entry(id: 'e2', sectionId: 's2')],
        },
      );
      final markdown = leetCodeCheatSheetMarkdown(data, tabId: 'tab-2');
      expect(markdown, contains('# Python'));
      expect(markdown, isNot(contains('# Java')));
    });
  });

  group('search', () {
    final data = LeetCodeCheatSheetData(
      tabs: [
        _tab(id: 'java'),
        _tab(id: 'python', name: 'Python'),
      ],
      sectionsByTab: {
        'java': [_section(id: 'jl', tabId: 'java', name: 'ArrayList')],
        'python': [_section(id: 'pd', tabId: 'python', name: 'dict')],
      },
      entriesBySection: {
        'jl': [
          _entry(id: 'j1', sectionId: 'jl', command: '.add(e)'),
          _entry(
            id: 'j2',
            sectionId: 'jl',
            command: '.size()',
            description: 'How many elements.',
            complexity: 'O(1)',
          ),
        ],
        'pd': [
          _entry(
            id: 'p1',
            sectionId: 'pd',
            command: '.get(k, v)',
            description: 'Returns v when k is absent.',
            complexity: null,
          ),
        ],
      },
    );

    test('matches across every tab, in tab then section order', () {
      final hits = searchLeetCodeCheatSheet(data, 'e');
      expect(hits.map((h) => h.entry.id), ['j1', 'j2', 'p1']);
    });

    test('matches command, description and complexity alike', () {
      expect(searchLeetCodeCheatSheet(data, '.size').single.entry.id, 'j2');
      expect(searchLeetCodeCheatSheet(data, 'absent').single.entry.id, 'p1');
      // Only j1 carries "amortized"; j2's complexity is the bare O(1), which
      // both of them would match.
      expect(searchLeetCodeCheatSheet(data, 'amortized').single.entry.id, 'j1');
    });

    test('a label is part of the haystack too', () {
      final labelled = LeetCodeCheatSheetData(
        tabs: [_tab(id: 'java')],
        sectionsByTab: {
          'java': [_section(id: 'jl', tabId: 'java', name: 'ArrayList')],
        },
        entriesBySection: {
          'jl': [_entry(id: 'j1', sectionId: 'jl', label: 'Append')],
        },
      );
      expect(
        searchLeetCodeCheatSheet(labelled, 'append').single.entry.id,
        'j1',
      );
    });

    test('is case-insensitive', () {
      expect(searchLeetCodeCheatSheet(data, 'RETURNS').single.entry.id, 'p1');
      expect(
        searchLeetCodeCheatSheet(data, '.SIZE').map((h) => h.entry.id),
        searchLeetCodeCheatSheet(data, '.size').map((h) => h.entry.id),
      );
    });

    test('section and tab names are not part of the haystack', () {
      // "ArrayList" is a section heading here, not entry text — search is
      // about finding the command, and the heading is how the result is
      // labelled rather than something to match against.
      expect(searchLeetCodeCheatSheet(data, 'ArrayList'), isEmpty);
    });

    test('a blank query matches nothing rather than everything', () {
      expect(searchLeetCodeCheatSheet(data, '   '), isEmpty);
    });

    test(
      'the tab strip gets a count per tab, and none for a tab with no hits',
      () {
        final counts = leetCodeCheatMatchCounts(
          searchLeetCodeCheatSheet(data, '.add'),
        );
        expect(counts, {'java': 1});
      },
    );
  });

  group('description parsing', () {
    test('a fenced block is split out of the prose around it', () {
      final parts = parseCheatDescription(
        'Before.\n```java\nint x = 1;\n```\nAfter.',
      );
      expect(parts, hasLength(3));
      expect(parts[0].isCode, isFalse);
      expect(parts[1].isCode, isTrue);
      expect(parts[1].text, 'int x = 1;');
      expect(parts[1].fenceLanguage, 'java');
      expect(parts[2].text.trim(), 'After.');
    });

    test('an unclosed fence stays literal to the end of that description', () {
      final parts = parseCheatDescription('Before.\n```\nint x = 1;');
      expect(parts.every((p) => !p.isCode), isTrue);
      // The fence line itself comes back, so nothing is silently eaten.
      expect(parts.map((p) => p.text).join('\n'), contains('```'));
      expect(parts.map((p) => p.text).join('\n'), contains('int x = 1;'));
    });

    test('a description with no fence is one prose part', () {
      final parts = parseCheatDescription('Just prose with `code` in it.');
      expect(parts, hasLength(1));
      expect(parts.single.isCode, isFalse);
    });
  });

  group('highlighting', () {
    const base = TextStyle(fontSize: 12);

    test('a tab with no languageKey renders its command without throwing', () {
      final spans = cheatCommandSpans(
        'new ArrayList<>()',
        languageKey: null,
        base: base,
        syntax: const {},
      );
      expect(spans.map((s) => s.text).join(), 'new ArrayList<>()');
    });

    test('a language the build no longer offers reads as no language', () {
      expect(cheatLanguageKey('brainfuck'), isNull);
      expect(cheatLanguageKey(null), isNull);
      expect(cheatLanguageKey('java'), 'java');

      final spans = cheatCommandSpans(
        'new ArrayList<>()',
        languageKey: 'brainfuck',
        base: base,
        syntax: const {},
      );
      expect(spans.map((s) => s.text).join(), 'new ArrayList<>()');
    });

    test('a known language tokenizes and still covers the command exactly', () {
      final spans = cheatCommandSpans(
        'new ArrayList<>()',
        languageKey: 'java',
        base: base,
        syntax: const {'keyword': TextStyle(color: Color(0xFFFF0000))},
      );
      expect(spans.map((s) => s.text).join(), 'new ArrayList<>()');
      expect(spans.length, greaterThan(1));
    });

    test('a needle straddling a token boundary is still marked whole', () {
      final spans = cheatCommandSpans(
        'new ArrayList<>()',
        languageKey: 'java',
        base: base,
        syntax: const {},
        keywords: const ['new Array'],
        highlightColor: const Color(0xFF00FF00),
      );
      expect(spans.map((s) => s.text).join(), 'new ArrayList<>()');
      final marked = spans
          .where((s) => s.style?.backgroundColor == const Color(0xFF00FF00))
          .map((s) => s.text)
          .join();
      expect(marked, 'new Array');
    });

    test('an empty command produces nothing to mark', () {
      final spans = cheatCommandSpans(
        '',
        languageKey: 'java',
        base: base,
        syntax: const {},
      );
      expect(spans.map((s) => s.text).join(), isEmpty);
    });
  });

  group('positions', () {
    test('a drop between two neighbours takes their midpoint', () {
      expect(cheatPositionBetween(100, 200), 150);
    });

    test('a drop at either end steps past the row it lands beside', () {
      expect(cheatPositionBetween(null, 100), 100 - kCheatPositionStep);
      expect(cheatPositionBetween(100, null), 100 + kCheatPositionStep);
      expect(cheatPositionBetween(null, null), kCheatPositionStep);
    });

    test('a healthy list needs no renormalizing', () {
      expect(cheatPositionsNeedRenormalize([1024, 2048, 3072]), isFalse);
    });

    test('a seam dropped on until it closes does', () {
      var lo = 1024.0;
      const hi = 2048.0;
      for (var i = 0; i < 60; i++) {
        lo = cheatPositionBetween(lo, hi);
      }
      expect(cheatPositionsNeedRenormalize([1024, lo, hi]), isTrue);
    });

    test('renormalizing spreads a closed-up section back out', () async {
      final db = AppDatabase.inMemory();
      addTearDown(db.close);
      final repo = DriftLeetCodeRepository(db);
      await repo.upsertCheatTab(_tab());
      await repo.upsertCheatSection(_section());
      final crowded = [
        _entry(id: 'e1', position: 1),
        _entry(id: 'e2', position: 1.0000001),
        _entry(id: 'e3', position: 1.0000002),
      ];
      for (final entry in crowded) {
        await repo.upsertCheatEntry(entry);
      }

      final written = await repo.renormalizeCheatEntries(crowded);
      expect(written, hasLength(3));

      final positions = [
        for (final e in await repo.listCheatEntries(sectionId: 'section-1'))
          e.position,
      ];
      expect(positions, [
        kCheatPositionStep,
        kCheatPositionStep * 2,
        kCheatPositionStep * 3,
      ]);
      expect(cheatPositionsNeedRenormalize(positions), isFalse);
    });
  });

  group('the chord is LeetCode-only', () {
    test('it fires under /leetcode and nowhere else', () {
      expect(leetCodeCheatChordAllowed('/leetcode'), isTrue);
      expect(leetCodeCheatChordAllowed('/leetcode/session'), isTrue);

      // Including the flashcard section, which shares the session widgets but
      // not this feature.
      expect(leetCodeCheatChordAllowed('/study'), isFalse);
      expect(leetCodeCheatChordAllowed('/journal'), isFalse);
      expect(leetCodeCheatChordAllowed('/'), isFalse);
      // Not a prefix match on the bare string: another section could start
      // with the same letters.
      expect(leetCodeCheatChordAllowed('/leetcoder'), isFalse);
    });
  });

  group('the mapper', () {
    test('a tab round-trips, language key and all', () {
      final tab = _tab();
      final back = mergeLeetCodeCheatTabFromRemote(
        leetCodeCheatTabToFirestore(tab),
        tab.id,
      );
      expect(back.name, tab.name);
      expect(back.languageKey, 'java');
      expect(back.position, tab.position);
    });

    test('a cleared language is kept, an absent key is not', () {
      final local = _tab();
      final cleared = leetCodeCheatTabToFirestore(
        _tab(
          languageKey: null,
          version: 1,
          updatedAt: _now.add(const Duration(minutes: 1)),
        ),
      );
      expect(
        mergeLeetCodeCheatTabFromRemote(
          cleared,
          'tab-1',
          local: local,
        ).languageKey,
        isNull,
      );

      // A document written before the field existed carries no key at all.
      final legacy = Map<String, dynamic>.from(cleared)..remove('languageKey');
      expect(
        mergeLeetCodeCheatTabFromRemote(
          legacy,
          'tab-1',
          local: local,
        ).languageKey,
        'java',
      );
    });

    test('an entry round-trips, and a null complexity stays null', () {
      final entry = _entry(complexity: null);
      final back = mergeLeetCodeCheatEntryFromRemote(
        leetCodeCheatEntryToFirestore(entry),
        entry.id,
      );
      expect(back.command, '.add(e)');
      expect(back.description, 'Appends to the back.');
      expect(back.complexity, isNull);
      expect(back.sectionId, 'section-1');
    });

    test('a label round-trips, and null and absent still differ', () {
      final labelled = _entry(label: 'Append');
      expect(
        mergeLeetCodeCheatEntryFromRemote(
          leetCodeCheatEntryToFirestore(labelled),
          labelled.id,
        ).label,
        'Append',
      );

      // A label the user cleared has to survive the merge as cleared...
      final cleared = leetCodeCheatEntryToFirestore(_entry().copyWith());
      expect(
        mergeLeetCodeCheatEntryFromRemote(
          cleared,
          'entry-1',
          local: labelled,
        ).label,
        isNull,
      );

      // ...while a document written before the field existed keeps the local
      // one, exactly as an absent complexity does.
      final legacy = Map<String, dynamic>.from(cleared)..remove('label');
      expect(
        mergeLeetCodeCheatEntryFromRemote(
          legacy,
          'entry-1',
          local: labelled,
        ).label,
        'Append',
      );
    });

    test('an older remote loses to the local row', () {
      final local = _entry().copyWith(command: 'local', version: 5);
      final older = leetCodeCheatEntryToFirestore(_entry(command: 'remote'));
      expect(
        mergeLeetCodeCheatEntryFromRemote(
          older,
          'entry-1',
          local: local,
        ).command,
        'local',
      );
    });
  });

  group('the three collections are registered', () {
    test('as records, and as snapshot-only rather than CRDT-backed', () {
      for (final name in [
        FirestoreCollections.leetcodeCheatTabs,
        FirestoreCollections.leetcodeCheatSections,
        FirestoreCollections.leetcodeCheatEntries,
      ]) {
        expect(FirestoreCollections.records, contains(name));
        expect(FirestoreCollections.snapshotOnly, contains(name));
        expect(FirestoreCollections.crdtBacked, isNot(contains(name)));
      }
    });
  });
}

/// Two settings rows differing only in the cheat sheet's device-local columns.
abstract final class AppSettingsProbe {
  static const withCheatState = AppSettings(
    leetCodeCheatLastTabId: 'tab-1',
    leetCodeCheatCollapsedSections: ['s1'],
  );
  static const withoutCheatState = AppSettings();
}

import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/core/sync/firestore_collections.dart';
import 'package:voyager/core/sync/firestore_document_mapper.dart';
import 'package:voyager/core/sync/synced_write_notifier.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/data/repositories/drift_repositories.dart';
import 'package:voyager/domain/models/gaia_models.dart';
import 'package:voyager/features/gaia/host/gaia_chat_store.dart';
import 'package:voyager/features/settings/services/backup_collections.dart';
import 'package:voyager/features/trash/trash_service.dart';

/// Projects, Phase 1 (GAIA_PROJECTS_HLD.md §10, §12): how chats group by
/// project, deleting and restoring one, and its chats' sync.

final _at = DateTime.utc(2026, 11, 10, 12);

GaiaChat _chat(
  String id, {
  String? projectId,
  bool pinned = false,
  String? forkOf,
  int minutes = 0,
}) => GaiaChat(
  id: id,
  title: id,
  createdAt: _at,
  updatedAt: _at,
  lastMessageAt: _at.add(Duration(minutes: minutes)),
  projectId: projectId,
  pinned: pinned,
  forkOf: forkOf,
);

GaiaProject _project(String id, {int minutes = 0}) => GaiaProject(
  id: id,
  name: id,
  createdAt: _at.add(Duration(minutes: minutes)),
  updatedAt: _at,
  version: 1,
);

/// As the repository lists them: pinned first, then the most recent.
List<GaiaChat> _listed(List<GaiaChat> chats) => [...chats]
  ..sort((a, b) {
    if (a.pinned != b.pinned) return a.pinned ? -1 : 1;
    return b.lastMessageAt.compareTo(a.lastMessageAt);
  });

List<String> _ids(List<GaiaForkGroup> groups) => [
  for (final group in groups) ...[
    group.chat.id,
    for (final fork in group.forks) '${fork.id} (under ${group.chat.id})',
  ],
];

void main() {
  group('sections (§2, §7.1)', () {
    test('a chat whose project is missing or gone is in none', () {
      final sections = gaiaChatSections(
        _listed([
          _chat('in', projectId: 'p1', minutes: 3),
          _chat('nowhere', projectId: 'gone', minutes: 2),
          _chat('loose', minutes: 1),
        ]),
        [_project('p1')],
      );
      expect(sections.projects.single.project.id, 'p1');
      expect(_ids(sections.projects.single.groups), ['in']);
      expect(sections.projects.single.count, 1);
      expect(_ids(sections.chats), ['nowhere', 'loose']);
    });

    test('a pinned chat sits at the top of its project, or in Pinned with '
        'none', () {
      List<GaiaChat> chats(String? projectId) => _listed([
        _chat('recent', projectId: 'p1', minutes: 5),
        _chat('pinned', projectId: projectId, pinned: true),
      ]);

      final inProject = gaiaChatSections(chats('p1'), [_project('p1')]);
      expect(inProject.pinned, isEmpty);
      expect(_ids(inProject.projects.single.groups), ['pinned', 'recent']);

      final out = gaiaChatSections(chats(null), [_project('p1')]);
      expect(_ids(out.pinned), ['pinned']);
      expect(_ids(out.projects.single.groups), ['recent']);
      expect(out.chats, isEmpty);
    });

    test('projects go by their most recent chat, an empty one by when it '
        'was made, and forks sit under their chat within one', () {
      final sections = gaiaChatSections(
        _listed([
          _chat('a', projectId: 'old', minutes: 30),
          _chat('a fork', projectId: 'old', forkOf: 'a', minutes: 40),
          _chat('b', projectId: 'new', minutes: 10),
          // Moved out: on its own, not under its original.
          _chat('b fork', forkOf: 'b', minutes: 50),
        ]),
        [
          _project('old'),
          _project('new', minutes: 20),
          _project('empty', minutes: 25),
        ],
      );
      expect(sections.projects.map((s) => s.project.id), [
        'old',
        'empty',
        'new',
      ]);
      expect(_ids(sections.projects.first.groups), ['a', 'a fork (under a)']);
      expect(_ids(sections.chats), ['b fork']);
    });
  });

  group('deleting and restoring (§3.3)', () {
    late AppDatabase db;
    late DriftGaiaRepository repository;
    late TrashService trash;

    setUp(() async {
      db = AppDatabase.inMemory();
      repository = DriftGaiaRepository(db);
      trash = TrashService(
        db: db,
        collections: buildBackupCollections(
          journalRepository: DriftJournalRepository(db),
          dreamRepository: DriftDreamRepository(db),
          todoRepository: DriftTodoRepository(db),
          leetCodeRepository: DriftLeetCodeRepository(db),
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
          photoSeriesRepository: DriftPhotoSeriesRepository(db),
          gaiaRepository: repository,
          settingsRepository: DriftSettingsRepository(db),
        ),
        push: (_, _) async {},
      );
      await repository.upsertProject(_project('p1'));
      await repository.upsertChat(_chat('one', projectId: 'p1'));
      await repository.upsertChat(_chat('two', projectId: 'p1'));
      await repository.upsertChat(_chat('other'));
      // Deleted on its own before the project was.
      await repository.upsertChat(
        _chat('earlier', projectId: 'p1').copyWith(deletedAt: _at),
      );
      await repository.upsertMemory(
        GaiaMemory(
          id: 'm1',
          text: 'Flights booked',
          projectId: 'p1',
          status: GaiaMemoryStatus.active,
          createdAt: _at,
          updatedAt: _at,
          version: 1,
        ),
      );
      await repository.upsertMemory(
        GaiaMemory(
          id: 'g1',
          text: 'Likes tea',
          status: GaiaMemoryStatus.active,
          createdAt: _at,
          updatedAt: _at,
          version: 1,
        ),
      );
    });

    tearDown(() => db.close());

    Future<Map<String, String?>> live() async => {
      for (final chat in await repository.listChats()) chat.id: chat.projectId,
    };

    Future<Map<String, String?>> liveMemories() async => {
      for (final memory in await repository.listMemories())
        memory.id: memory.projectId,
    };

    test('unchecked, its chats stay in no project, and a restore brings it '
        'back empty', () async {
      final deleted = await gaiaDeleteProject(
        repository,
        'p1',
        withChats: false,
      );
      expect(deleted, isEmpty);
      expect(await repository.listProjects(), isEmpty);
      expect(await live(), {'one': null, 'two': null, 'other': null});
      // Its memories become global (§3.3).
      expect(await liveMemories(), {'m1': null, 'g1': null});

      final item = (await trash.list()).firstWhere((i) => i.id == 'p1');
      expect(item.title, 'p1');
      expect(item.summary, isNull);
      await trash.restore(item);
      expect((await repository.listProjects()).single.id, 'p1');
      expect(await live(), {'one': null, 'two': null, 'other': null});
      expect(await liveMemories(), {'m1': null, 'g1': null});
    });

    test('checked, its chats go to the trash with it and come back with it, '
        'still in it', () async {
      final deleted = await gaiaDeleteProject(
        repository,
        'p1',
        withChats: true,
      );
      expect(deleted.map((c) => c.id), unorderedEquals(['one', 'two']));
      expect(await live(), {'other': null});
      // Its memories go to the trash with it (§3.3).
      expect(await liveMemories(), {'g1': null});

      final items = await trash.list();
      final item = items.firstWhere((i) => i.id == 'p1');
      expect(item.summary, '2 chats');
      // Listed as part of the project, not on their own.
      expect(items.map((i) => i.id), isNot(contains('one')));

      await trash.restore(item);
      expect((await repository.listProjects()).single.id, 'p1');
      expect(await live(), {'one': 'p1', 'two': 'p1', 'other': null});
      expect(await liveMemories(), {'m1': 'p1', 'g1': null});
      // The one deleted before it stays deleted.
      expect((await repository.getChat('earlier'))!.isDeleted, isTrue);
    });

    test(
      'its chats, memories and the project reach sync once, after one write',
      () async {
        final writes = <String>[];
        final notifier = SyncedWriteNotifier()
          ..onWrite = (collection, records) => writes.add(
            '$collection: ${records.map((r) => (r as dynamic).id).join(' ')}',
          );
        final changes = <void>[];
        final watching = repository.watchChanges().listen(changes.add);
        await gaiaDeleteProject(
          DriftGaiaRepository(db, syncedWrites: notifier),
          'p1',
          withChats: true,
        );
        await pumpEventQueue();
        await watching.cancel();
        expect(writes, [
          '${FirestoreCollections.gaiaChats}: one two',
          '${FirestoreCollections.gaiaMemories}: m1',
          '${FirestoreCollections.gaiaProjects}: p1',
        ]);
        expect(changes, hasLength(1));
      },
    );

    test('a chat moves into a project and out of it', () async {
      await gaiaMoveChat(repository, 'other', 'p1');
      expect((await repository.getChat('other'))!.projectId, 'p1');
      await gaiaMoveChat(repository, 'one', null);
      expect((await repository.getChat('one'))!.projectId, isNull);
    });
  });

  group('sync (§2)', () {
    test("a chat taken out of its project on another device is taken out "
        'here too', () {
      final local = _chat('c', projectId: 'p1');
      final remote = gaiaChatToFirestore(
        local.copyWith(clearProjectId: true, version: 5),
      );
      expect(remote.containsKey('projectId'), isTrue);
      expect(
        mergeGaiaChatFromRemote(remote, 'c', local: local).projectId,
        isNull,
      );
    });

    test("a copy from before projects keeps the chat's project", () {
      final local = _chat('c', projectId: 'p1');
      final remote = gaiaChatToFirestore(local.copyWith(version: 5))
        ..remove('projectId');
      expect(
        mergeGaiaChatFromRemote(remote, 'c', local: local).projectId,
        'p1',
      );
    });

    test('a project round-trips', () {
      final project = _project('p1').copyWith(name: 'Trip');
      final merged = mergeGaiaProjectFromRemote(
        gaiaProjectToFirestore(project),
        'p1',
      );
      expect(merged.name, 'Trip');
      expect(merged.version, project.version);
    });

    test("a project's folders round-trip, and a stale copy doesn't take this "
        "device's away (§4)", () {
      final local = _project(
        'p1',
      ).copyWith(folders: {'desk': 'D:/Japan', 'laptop': 'C:/Japan'});
      expect(
        mergeGaiaProjectFromRemote(gaiaProjectToFirestore(local), 'p1').folders,
        {'desk': 'D:/Japan', 'laptop': 'C:/Japan'},
      );
      final stale = gaiaProjectToFirestore(
        _project(
          'p1',
        ).copyWith(name: 'Trip', folders: {'laptop': 'E:/Japan'}, version: 9),
      );
      final merged = mergeGaiaProjectFromRemote(stale, 'p1', local: local);
      expect(merged.name, 'Trip');
      expect(merged.folders, {'desk': 'D:/Japan', 'laptop': 'E:/Japan'});
    });

    test("a stale copy doesn't undo this device's own folder (§4)", () {
      final local = _project('p1').copyWith(folders: {'desk': ''});
      final stale = gaiaProjectToFirestore(
        _project('p1').copyWith(
          name: 'Trip',
          folders: {'desk': 'D:/Old', 'laptop': 'C:/Japan'},
          version: 9,
        ),
      );
      final merged = mergeGaiaProjectFromRemote(
        stale,
        'p1',
        local: local,
        deviceId: 'desk',
      );
      expect(merged.name, 'Trip');
      expect(merged.folders, {'desk': '', 'laptop': 'C:/Japan'});
    });
  });

  group('folders (§4)', () {
    test("setting one on a device keeps the other devices'", () async {
      final db = AppDatabase.inMemory();
      addTearDown(db.close);
      final repository = DriftGaiaRepository(db);
      await repository.upsertProject(
        _project('p1').copyWith(folders: {'laptop': 'C:/Japan'}),
      );
      final store = GaiaChatStore(repository, deviceId: 'desk');
      await store.setProjectFolder('p1', 'D:/Japan');
      expect((await repository.getProject('p1'))!.folders, {
        'laptop': 'C:/Japan',
        'desk': 'D:/Japan',
      });
      await store.setProjectFolder('p1', 'D:/Trip');
      expect((await repository.getProject('p1'))!.folders['desk'], 'D:/Trip');
    });

    test('removing one keeps it as an empty path, so the removal syncs, and '
        'no reader sees it', () async {
      final db = AppDatabase.inMemory();
      addTearDown(db.close);
      final repository = DriftGaiaRepository(db);
      await repository.upsertProject(
        _project('p1').copyWith(folders: {'desk': 'D:/Japan'}),
      );
      await GaiaChatStore(
        repository,
        deviceId: 'desk',
      ).setProjectFolder('p1', null);
      final removed = (await repository.getProject('p1'))!;
      expect(removed.folders, {'desk': ''});
      expect(removed.folderPaths, isEmpty);
      expect(gaiaProjectFolder(removed, 'desk'), isNull);

      // Another device still holding the path takes the removal.
      final elsewhere = _project('p1').copyWith(
        folders: {'desk': 'D:/Japan', 'laptop': 'C:/Japan'},
        version: 1,
      );
      expect(
        mergeGaiaProjectFromRemote(
          gaiaProjectToFirestore(removed),
          'p1',
          local: elsewhere,
        ).folderPaths,
        {'laptop': 'C:/Japan'},
      );
    });
  });
}

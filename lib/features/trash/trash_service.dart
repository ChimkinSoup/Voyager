import 'package:voyager/core/dev/error_logger.dart';
import 'package:voyager/core/soft_delete/erasure.dart';
import 'package:voyager/core/soft_delete/restore_contract.dart';
import 'package:voyager/core/sync/firestore_document_mapper.dart';
import 'package:voyager/core/sync/soft_delete_policy.dart';
import 'package:voyager/core/utils/ids.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/features/settings/services/backup_collections.dart';
import 'package:voyager/features/settings/services/data_import_service.dart'
    show BackupRecordUploader;
import 'package:voyager/features/trash/trash_kinds.dart';

/// Re-attaches the images a delete took off a restored row —
/// `MediaService.restoreReferencesDetachedSince` in the app.
typedef TrashMediaRestorer =
    Future<void> Function(
      String ownerCollection,
      String documentId,
      DateTime parentDeletedAt,
    );

/// One row of one collection, in its Firestore payload shape.
class TrashRow {
  const TrashRow(this.kind, this.id, this.data);

  final TrashKind kind;
  final String id;
  final Map<String, dynamic> data;

  DateTime? get deletedAt => parseFirestoreDate(data['deletedAt']);
}

/// Something the trash lists: one deleted row, and the rows its delete took
/// with it.
class TrashItem {
  const TrashItem({
    required this.row,
    required this.deletedAt,
    required this.members,
  });

  final TrashRow row;
  final DateTime deletedAt;

  /// Deleted with [row], by the same cascade. Not including [row] itself.
  final List<TrashRow> members;

  TrashKind get kind => row.kind;
  String get id => row.id;

  /// Null for a row never given one.
  String? get title {
    final title = kind.title(row.data)?.trim();
    return title == null || title.isEmpty ? null : title;
  }

  /// "14 tasks", "2 decks · 40 cards", or null for a row that took nothing
  /// countable with it.
  String? get summary {
    final parts = <String>[];
    for (final child in _countedChildren(kind)) {
      final count = members.where((m) => m.kind.collection == child.$1).length;
      if (count == 0) continue;
      parts.add('$count ${count == 1 ? child.$2.$1 : child.$2.$2}');
    }
    return parts.isEmpty ? null : parts.join(' · ');
  }
}

/// A restore that could not go ahead because the row's container is itself
/// gone and its feature has no default container to put it in instead.
class TrashRestoreBlocked implements Exception {
  const TrashRestoreBlocked({required this.parentNoun, this.parentTitle});

  final String parentNoun;
  final String? parentTitle;

  @override
  String toString() => 'TrashRestoreBlocked: $parentNoun "$parentTitle"';
}

/// Lists, restores and erases deleted rows across every feature
/// (`TRASH_HLD.md`).
///
/// Built on the backup registry: every synced collection there can already
/// be read out as payloads, tombstones included, and written back from one.
/// A restore is a payload with its tombstone lifted and an erase one with its
/// content emptied, each at a version that outranks the row on disk, so both
/// go out through the same serializers the sync layer and backups use.
class TrashService {
  TrashService({
    required this._db,
    required this._collections,
    required this._push,
    this._restoreMedia,
    this._policy = const SoftDeletePolicy(),
  });

  final AppDatabase _db;
  final List<BackupCollection> _collections;
  final BackupRecordUploader _push;
  final TrashMediaRestorer? _restoreMedia;
  final SoftDeletePolicy _policy;

  /// Everything restorable, newest deletion first.
  Future<List<TrashItem>> list({DateTime? now}) async {
    final rows = await _readAll();
    final cutoff = _policy.purgeCutoff(now ?? utcNow());
    final candidates = <TrashRow>[
      for (final byId in rows.values)
        for (final row in byId.values)
          if (row.kind.listed && _inTrash(row, cutoff)) row,
    ];
    final items = [
      for (final row in candidates)
        TrashItem(
          row: row,
          deletedAt: row.deletedAt!,
          members: _membersOf(row, rows),
        ),
    ];
    // A row taken by another row's delete is shown as part of that one.
    final taken = {
      for (final item in items)
        for (final member in item.members) _key(member),
    };
    return [
      for (final item in items)
        if (!taken.contains(_key(item.row))) item,
    ]..sort((a, b) => b.deletedAt.compareTo(a.deletedAt));
  }

  /// Brings [item] and the rows deleted with it back.
  ///
  /// Returns the name of the default container it was put in when its own is
  /// in the trash too, or null when it went back where it was. Throws
  /// [RestoreSuperseded] if it is no longer in the trash, and
  /// [TrashRestoreBlocked] if its container is gone and it has nowhere else to
  /// go.
  Future<String?> restore(TrashItem item) async {
    final rows = await _readAll();
    final root = rows[item.kind.collection]?[item.id];
    final rootDeletedAt = root?.deletedAt;
    if (root == null || rootDeletedAt == null || isErasedAt(rootDeletedAt)) {
      throw const RestoreSuperseded();
    }
    final members = _membersOf(root, rows);
    final now = utcNow();
    final rewrites = <String, Map<String, dynamic>>{};
    String? fallbackName;

    for (final parent in root.kind.parents) {
      final storedId = root.data[parent.key] as String?;
      if (storedId == null) continue;
      final parentId = parent.localId(storedId);
      if (parentId == parent.fallbackId) continue;
      final parentRow = rows[parent.collection]?[parentId];
      if (parentRow != null && parentRow.deletedAt == null) continue;
      if (!parent.hasFallback) {
        throw TrashRestoreBlocked(
          parentNoun: trashKinds[parent.collection]!.noun,
          parentTitle: parentRow == null
              ? null
              : trashKinds[parent.collection]!.title(parentRow.data),
        );
      }
      fallbackName = parent.fallbackName;
      // The rows that went with it sat in the same container, and follow it.
      for (final row in [root, ...members]) {
        if (row.kind.collection == root.kind.collection &&
            row.data[parent.key] == storedId) {
          (rewrites[_key(row)] ??= {})[parent.key] = parent.fallbackId;
        }
      }
    }

    // A row the delete took that also hangs off something deleted on its own
    // — a deck link whose other deck is still in the trash — stays deleted
    // rather than coming back pointing at nothing.
    final restoring = {_key(root), for (final member in members) _key(member)};
    final restored = [
      root,
      for (final member in members)
        if (member.kind.parents.every(
          (parent) =>
              parent.hasFallback ||
              _parentStays(member, parent, rows, restoring),
        ))
          member,
    ];

    await _write([
      for (final row in restored)
        (
          row,
          {
            ...row.data,
            ...?rewrites[_key(row)],
            'deletedAt': null,
            'updatedAt': now.toIso8601String(),
            'version': parseVersion(row.data) + 1,
          },
        ),
    ]);

    final restoreMedia = _restoreMedia;
    if (restoreMedia != null) {
      for (final row in restored) {
        final owner = row.kind.mediaOwner;
        if (owner != null) {
          await restoreMedia(owner, row.id, row.deletedAt!);
        }
      }
    }
    return fallbackName;
  }

  /// Empties [items] and the rows deleted with them, for good.
  ///
  /// The rows stay as tombstones — a removed row can't reach the other devices
  /// — but with their content gone, marked [kErasedAt] so no trash lists them
  /// again, and at a version no concurrent edit elsewhere can outrank.
  Future<void> erase(List<TrashItem> items) async {
    final rows = await _readAll();
    final now = utcNow().toIso8601String();
    final seen = <String>{};
    final writes = <(TrashRow, Map<String, dynamic>)>[];
    for (final item in items) {
      final root = rows[item.kind.collection]?[item.id];
      if (root == null || root.deletedAt == null) continue;
      if (isErasedAt(root.deletedAt)) continue;
      final members = [root, ..._membersOf(root, rows)];
      for (final row in [
        ...members,
        for (final member in members) ..._erasedWith(member, rows),
      ]) {
        if (!seen.add(_key(row))) continue;
        writes.add((
          row,
          {
            ...row.data,
            for (final field in row.kind.wipe)
              if (row.data.containsKey(field)) field: _blank(row.data[field]),
            'deletedAt': kErasedAt.toIso8601String(),
            'updatedAt': now,
            'version': parseVersion(row.data) + kEraseVersionStep,
          },
        ));
      }
    }
    await _write(writes);
  }

  /// Whether [row]'s [parent] is live, or among the rows [restoring].
  bool _parentStays(
    TrashRow row,
    TrashParent parent,
    Map<String, Map<String, TrashRow>> rows,
    Set<String> restoring,
  ) {
    final storedId = row.data[parent.key] as String?;
    if (storedId == null) return true;
    final parentRow = rows[parent.collection]?[parent.localId(storedId)];
    if (parentRow == null) return false;
    return parentRow.deletedAt == null || restoring.contains(_key(parentRow));
  }

  bool _inTrash(TrashRow row, DateTime cutoff) {
    final deletedAt = row.deletedAt;
    return deletedAt != null &&
        !isErasedAt(deletedAt) &&
        deletedAt.isAfter(cutoff);
  }

  /// Every row [root]'s delete took with it: children, their children, and so
  /// on, each carrying [root]'s exact `deletedAt`.
  List<TrashRow> _membersOf(
    TrashRow root,
    Map<String, Map<String, TrashRow>> rows,
  ) {
    final stamp = root.deletedAt!;
    final found = <String, TrashRow>{};
    final queue = [root];
    while (queue.isNotEmpty) {
      final owner = queue.removeLast();
      for (final child in owner.kind.children) {
        for (final row
            in rows[child.collection]?.values ?? const <TrashRow>[]) {
          final deletedAt = row.deletedAt;
          if (deletedAt == null || !deletedAt.isAtSameMomentAs(stamp)) continue;
          if (!child.keys.any((key) => row.data[key] == owner.id)) continue;
          if (row.id == root.id && row.kind == root.kind) continue;
          if (found.containsKey(_key(row))) continue;
          found[_key(row)] = row;
          queue.add(row);
        }
      }
    }
    return found.values.toList();
  }

  /// The rows [TrashKind.erasedWith] names for [owner], not erased already.
  Iterable<TrashRow> _erasedWith(
    TrashRow owner,
    Map<String, Map<String, TrashRow>> rows,
  ) sync* {
    for (final dependent in owner.kind.erasedWith) {
      for (final row
          in rows[dependent.collection]?.values ?? const <TrashRow>[]) {
        if (isErasedAt(row.deletedAt)) continue;
        if (dependent.keys.any((key) => row.data[key] == owner.id)) yield row;
      }
    }
  }

  Future<Map<String, Map<String, TrashRow>>> _readAll() async {
    final rows = <String, Map<String, TrashRow>>{};
    for (final collection in _collections) {
      final kind = trashKinds[collection.name];
      if (kind == null) continue;
      rows[collection.name] = {
        for (final record in await collection.read())
          record.id: TrashRow(kind, record.id, record.data),
      };
    }
    return rows;
  }

  /// Uploads of earlier restores and erases that may still be running, in the
  /// order those were made. Never completes with an error.
  Future<void> get uploads => _uploads;
  Future<void> _uploads = Future.value();

  /// Writes [writes] in one transaction, in the registry's order so a
  /// container always lands before what it holds, then starts uploading them.
  ///
  /// Returns once the rows are committed. The upload runs behind it: every
  /// push path hands a failed upload to the outbox, so waiting on the network
  /// here would only hold up the caller. The uploads are chained, so a later
  /// restore or erase of the same rows can't reach the server first.
  Future<void> _write(List<(TrashRow, Map<String, dynamic>)> writes) async {
    if (writes.isEmpty) return;
    final byCollection = <String, List<(TrashRow, Map<String, dynamic>)>>{};
    for (final write in writes) {
      (byCollection[write.$1.kind.collection] ??= []).add(write);
    }
    final written = <String, List<Object>>{};
    await _db.transaction(() async {
      for (final collection in _collections) {
        final pending = byCollection[collection.name];
        if (pending == null) continue;
        // The same hooks an import runs, so a collection that checks a
        // record against its siblings — a calendar's overlays, a deck link's
        // cycles — sees the rows as they stand rather than a backup's.
        collection.prepare?.call(await collection.read());
        for (final (row, data) in pending) {
          (written[collection.name] ??= []).add(
            await collection.restore(row.id, data),
          );
        }
        final extra = await collection.afterRestore?.call() ?? const [];
        written[collection.name]!.addAll(extra);
      }
    });
    _uploads = _uploads.then((_) => _upload(written));
  }

  Future<void> _upload(Map<String, List<Object>> written) async {
    try {
      for (final entry in written.entries) {
        await _push(entry.key, entry.value);
      }
    } catch (error, stackTrace) {
      ErrorLogger.instance.record(
        error,
        stackTrace,
        context: 'trash: uploading restored or erased rows',
      );
    }
  }
}

String _key(TrashRow row) => '${row.kind.collection}/${row.id}';

/// The collections counted in a row's summary, reached through its children
/// and theirs — a folder counts the decks and cards under it.
List<(String, (String, String))> _countedChildren(TrashKind kind) {
  final counted = <(String, (String, String))>[];
  final seen = <String>{};
  final queue = [kind];
  while (queue.isNotEmpty) {
    for (final child in queue.removeAt(0).children) {
      if (!seen.add(child.collection)) continue;
      final label = child.counted;
      if (label != null) counted.add((child.collection, label));
      final next = trashKinds[child.collection];
      if (next != null) queue.add(next);
    }
  }
  return counted;
}

/// An empty value of [value]'s own type, so an erased row still decodes.
Object? _blank(Object? value) => switch (value) {
  String() => '',
  List() => const <Object?>[],
  Map() => const <String, Object?>{},
  num() => 0,
  _ => value,
};

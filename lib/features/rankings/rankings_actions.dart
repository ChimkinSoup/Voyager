import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/sync/firestore_collections.dart';
import 'package:voyager/core/soft_delete/soft_delete_toast.dart';
import 'package:voyager/core/sync/remote_sync_service.dart';
import 'package:voyager/core/utils/ids.dart';
import 'package:voyager/core/widgets/confirm_dialog.dart';
import 'package:voyager/domain/models/ranking_models.dart';
import 'package:voyager/domain/rankings/ranking_queries.dart';
import 'package:voyager/domain/repositories/repositories.dart';

/// Every write the Rankings page makes, in one place.
///
/// Same three beats as the rest of the app: write through the repository,
/// invalidate what reads it, hand the record to the sync layer. Nothing here
/// builds widgets, so the list, the editor panel and the manage sheet all call
/// the same code.
///
/// Two rules every action keeps:
///
/// * **The network is never awaited.** Firestore holds an offline write until
///   the server acknowledges it, so an action that awaited its upload before
///   refreshing left the page frozen on the old data for as long as the device
///   was offline — and an edit made to that stale row wrote it back.
/// * **Entries and units are patched by id, never written from a snapshot.**
///   A widget's copy of a row lags the disk by a reload at best, and a whole
///   row written from it put back whatever anyone had changed since — a note
///   the panel had just saved, a score another device set, a delete.
class RankingsActions {
  /// Resolves the container now, while [ref]'s widget is certainly mounted, so
  /// nothing after the first `await` depends on it staying so.
  RankingsActions(WidgetRef ref)
    : this.detached(ProviderScope.containerOf(ref.context, listen: false));

  /// Actions that outlive the widget that asked for them.
  ///
  /// A soft delete unmounts the row it deleted, and a [WidgetRef] throws once
  /// its widget is gone — so the undo the toast offers, pressed seconds later,
  /// has to run off the container instead. So does anything flushed from a
  /// `dispose`, where the ref is already dead: resolve the container in
  /// `initState` and build these from it.
  const RankingsActions.detached(ProviderContainer container)
    : _container = container;

  final ProviderContainer _container;

  RankingRepository get _repository => _container.read(rankingRepositoryProvider);
  RemoteSyncService get _sync => _container.read(remoteSyncServiceProvider);

  void _refresh() => invalidateRankingProvidersIn(_container);

  /// [_refresh] for a write that changed entries in [categoryId] and nothing
  /// else — no category, no child. Re-reading those as well rebuilt the whole
  /// page two or three times over for what shows as a one-row change.
  void _refreshParents(String categoryId) {
    _container.invalidate(rankingParentsProvider(categoryId));
    _container.invalidate(rankingParentCountsProvider);
  }

  /// [_refreshParents] for units: a unit edit changes no entry.
  void _refreshChildren(String categoryId) =>
      _container.invalidate(rankingChildrenByParentProvider(categoryId));

  // ---------------------------------------------------------------- categories

  Future<RankingCategory> createCategory({
    required String name,
    required int colorValue,
    required String iconKey,
    required int sortOrder,
  }) async {
    final now = utcNow();
    final category = RankingCategory(
      id: newId(),
      name: name.trim(),
      colorValue: colorValue,
      iconKey: iconKey,
      sortOrder: sortOrder,
      createdAt: now,
      updatedAt: now,
    );
    await _repository.upsertCategory(category);
    _sync.pushRankingCategory(category);
    _refresh();
    return category;
  }

  Future<void> saveCategory(RankingCategory category) async {
    await _repository.upsertCategory(category);
    _sync.pushRankingCategory(category);
    _refresh();
  }

  Future<void> reorderCategories(List<String> orderedIds) async {
    final sync = _sync;
    final written = await _repository.reorderCategories(orderedIds);
    _refresh();
    unawaited(sync.pushRankingCategoriesBatch(written));
  }

  Future<void> setCategoryArchived(
    RankingCategory category, {
    required bool archived,
  }) {
    return saveCategory(
      archived
          ? category.copyWith(archivedAt: utcNow())
          : category.copyWith(clearArchivedAt: true),
    );
  }

  /// Tombstones the category and everything in it, detaching the images on the
  /// way so the blobs start the same 30-day clock the rows are on.
  ///
  /// Returns the detach stamps [restoreCategory] needs — see [_detachMedia].
  Future<MediaDetachStamps> deleteCategory(RankingCategory category) async {
    final sync = _sync;
    final result = await _repository.softDeleteCategory(category.id);
    _refresh();
    final stamps = await _detachMedia([
      for (final parent in result.parents) parent.id,
      for (final child in result.children) child.id,
    ]);
    sync.pushRankingCategory(result.category);
    unawaited(sync.pushRankingParentsBatch(result.parents));
    unawaited(sync.pushRankingChildrenBatch(result.children));
    return stamps;
  }

  Future<void> restoreCategory(
    RankingCategory tombstone,
    MediaDetachStamps mediaStamps,
  ) async {
    final sync = _sync;
    final result = await _repository.restoreCategory(tombstone.id);
    _refresh();
    await _restoreMedia(mediaStamps);
    sync.pushRankingCategory(result.category);
    unawaited(sync.pushRankingParentsBatch(result.parents));
    unawaited(sync.pushRankingChildrenBatch(result.children));
  }

  /// Moves a template field between the 5 and 10 scales, carrying every value
  /// already stored against it (§7.3).
  ///
  /// The rewrite is the whole point: leaving an 8 behind on a field that now
  /// tops out at 5 would render as a full strip and sort as an outlier. Values
  /// are rounded to the destination's steps, which is lossy going down — the
  /// editor warns before calling this.
  ///
  /// One repository transaction that reads the category fresh and does nothing
  /// if the field is already on [scoreMax], so a second confirm cannot halve
  /// the values twice, and a crash cannot leave half of them rescaled.
  Future<void> rescaleTemplateField(
    String categoryId,
    String fieldId, {
    required int scoreMax,
    required bool isParentTemplate,
  }) async {
    final sync = _sync;
    final result = await _repository.rescaleTemplateField(
      categoryId,
      fieldId,
      scoreMax: scoreMax,
      isParentTemplate: isParentTemplate,
    );
    if (result == null) return;
    _refresh();
    _pushRewrite(sync, result);
  }

  /// [rescaleTemplateField] for the entry ([isParent]) or unit overall score.
  ///
  /// Without it an 8.5 overall stayed 8.5 on a 5-point scale: a full strip, an
  /// average above every true 5, and a silent clamp the next time it was
  /// touched.
  Future<void> rescaleOverall(
    String categoryId, {
    required int scoreMax,
    required bool isParent,
  }) async {
    final sync = _sync;
    final result = await _repository.rescaleOverall(
      categoryId,
      scoreMax: scoreMax,
      isParent: isParent,
    );
    if (result == null) return;
    _refresh();
    _pushRewrite(sync, result);
  }

  void _pushRewrite(RemoteSyncService sync, RankingCategoryRewrite rewrite) {
    sync.pushRankingCategory(rewrite.category);
    unawaited(sync.pushRankingParentsBatch(rewrite.parents));
    unawaited(sync.pushRankingChildrenBatch(rewrite.children));
  }

  /// Moves a surface onto a new step and re-rounds everything already stored
  /// against it (§8.1).
  ///
  /// "Everything" is the overall score itself plus every template field still
  /// inheriting from it: a field that follows the overall has to follow it
  /// here too, or the next thing to read it would find a value off its own
  /// grid. Fields that have opted out are left alone.
  ///
  /// Returns how many scores actually moved, which is what the caller warns
  /// about before calling.
  Future<int> setOverallPrecision(
    RankingCategory category, {
    required bool isParent,
    required RankingScorePrecision precision,
  }) async {
    final current = isParent
        ? category.parentScorePrecision
        : category.childScorePrecision;
    if (current == precision) return 0;

    final next = isParent
        ? category.copyWith(parentScorePrecision: precision)
        : category.copyWith(childScorePrecision: precision);
    final moved = await _reroundForCategory(next, previous: category);
    await saveCategory(next);
    return moved;
  }

  /// Takes one template field off — or back onto — the overall's step, and
  /// re-rounds the values already stored against it.
  Future<int> setFieldPrecision(
    RankingCategory category,
    RankingTemplateField field, {
    required bool isParentTemplate,
    required bool inherit,
    RankingScorePrecision? precision,
  }) async {
    final updated = field.copyWith(
      inheritPrecision: inherit,
      scorePrecision: precision,
      clearScorePrecision: inherit,
    );
    final next = _withTemplate(
      category,
      isParentTemplate: isParentTemplate,
      fields: [
        for (final existing in _templateOf(category, isParentTemplate))
          if (existing.id == field.id) updated else existing,
      ],
    );
    final moved = await _reroundForCategory(next, previous: category);
    await saveCategory(next);
    return moved;
  }

  /// How many stored scores [next]'s precisions would move, without writing
  /// anything. The warning dialogs ask this before they ask the user.
  Future<int> countScoresOffStep(
    RankingCategory next, {
    required RankingCategory previous,
  }) => _reroundForCategory(next, previous: previous, dryRun: true);

  /// Rewrites every parent and child score that [next]'s precisions no longer
  /// allow, and answers how many there were.
  ///
  /// Reads through the repository rather than off the page's providers: a
  /// precision change touches entries the list may be filtering out, and every
  /// one of them has to land on the new grid — deleted ones included, or a
  /// restore would bring back a score off the grid.
  Future<int> _reroundForCategory(
    RankingCategory next, {
    required RankingCategory previous,
    bool dryRun = false,
  }) async {
    final repository = _repository;
    final sync = _sync;
    var moved = 0;
    final parentFields = {
      for (final field in next.parentTemplate)
        field.id: rankingFieldPrecision(
          field,
          overallPrecision: next.parentScorePrecision,
        ),
    };
    final childFields = {
      for (final field in next.childTemplate)
        field.id: rankingFieldPrecision(
          field,
          overallPrecision: next.childScorePrecision,
        ),
    };
    final fieldScoreMax = {
      for (final field in [...next.parentTemplate, ...next.childTemplate])
        field.id: field.scoreMax,
    };

    (Map<String, RankingFieldValue>, int) reroundValues(
      Map<String, RankingFieldValue> values,
      Map<String, RankingScorePrecision> precisions,
    ) {
      var changed = 0;
      final result = <String, RankingFieldValue>{};
      for (final entry in values.entries) {
        final score = entry.value.score;
        final precision = precisions[entry.key];
        if (score == null || precision == null) {
          result[entry.key] = entry.value;
          continue;
        }
        final rounded = roundRankingScore(
          score,
          scoreMax: fieldScoreMax[entry.key] ?? 5,
          precision: precision,
        );
        if (rounded == score) {
          result[entry.key] = entry.value;
          continue;
        }
        changed++;
        result[entry.key] = entry.value.copyWith(score: rounded);
      }
      return (result, changed);
    }

    final writtenParents = <RankingParent>[];
    final writtenChildren = <RankingChild>[];

    for (final parent in await repository.listParents(
      previous.id,
      includeDeleted: true,
    )) {
      var changed = 0;
      var updated = parent;

      final overall = parent.overallScore;
      if (overall != null) {
        final rounded = roundRankingScore(
          overall,
          scoreMax: next.parentScoreMax,
          precision: next.parentScorePrecision,
        );
        if (rounded != overall) {
          changed++;
          updated = updated.copyWith(overallScore: rounded, touch: false);
        }
      }

      final (values, valueChanges) = reroundValues(
        parent.fieldValues,
        parentFields,
      );
      if (valueChanges > 0) {
        changed += valueChanges;
        updated = updated.copyWith(fieldValues: values, touch: false);
      }
      if (changed > 0) {
        moved += changed;
        if (!dryRun) {
          await repository.upsertParent(updated, recordLocalActivity: false);
          writtenParents.add(updated);
        }
      }

      for (final child in await repository.listChildren(
        parent.id,
        includeDeleted: true,
      )) {
        var childChanged = 0;
        var updatedChild = child;

        final childOverall = child.overallScore;
        if (childOverall != null) {
          final rounded = roundRankingScore(
            childOverall,
            scoreMax: next.childScoreMax,
            precision: next.childScorePrecision,
          );
          if (rounded != childOverall) {
            childChanged++;
            updatedChild = updatedChild.copyWith(
              overallScore: rounded,
              touch: false,
            );
          }
        }

        final (childValues, childValueChanges) = reroundValues(
          child.fieldValues,
          childFields,
        );
        if (childValueChanges > 0) {
          childChanged += childValueChanges;
          updatedChild = updatedChild.copyWith(
            fieldValues: childValues,
            touch: false,
          );
        }
        if (childChanged > 0) {
          moved += childChanged;
          if (!dryRun) {
            await repository.upsertChild(
              updatedChild,
              recordLocalActivity: false,
            );
            writtenChildren.add(updatedChild);
          }
        }
      }
    }

    if (!dryRun) {
      unawaited(sync.pushRankingParentsBatch(writtenParents));
      unawaited(sync.pushRankingChildrenBatch(writtenChildren));
    }
    return moved;
  }

  /// Writes a whole template back onto its category — the one path add,
  /// rename, reorder, remove and restore all take, so none of them can forget
  /// to renumber `sortOrder`.
  Future<void> saveTemplate(
    RankingCategory category, {
    required bool isParentTemplate,
    required List<RankingTemplateField> fields,
  }) {
    return saveCategory(
      _withTemplate(
        category,
        isParentTemplate: isParentTemplate,
        fields: fields,
      ),
    );
  }

  List<RankingTemplateField> _templateOf(
    RankingCategory category,
    bool isParentTemplate,
  ) => isParentTemplate ? category.parentTemplate : category.childTemplate;

  RankingCategory _withTemplate(
    RankingCategory category, {
    required bool isParentTemplate,
    required List<RankingTemplateField> fields,
  }) {
    // Renumbered here so the display order is whatever the list says, and a
    // removed field cannot leave a gap that reorders the ones around it.
    final renumbered = [
      for (var i = 0; i < fields.length; i++) fields[i].copyWith(sortOrder: i),
    ];
    return isParentTemplate
        ? category.copyWith(parentTemplate: renumbered)
        : category.copyWith(childTemplate: renumbered);
  }

  // ------------------------------------------------------------------- parents

  /// Title is the only thing a new entry needs (§3.4). It starts queued, at the
  /// end of the queue, so creating one never displaces something already in it.
  Future<RankingParent> createParent({
    required String categoryId,
    required String title,
    required int queueSortOrder,
  }) async {
    final now = utcNow();
    final parent = RankingParent(
      id: newId(),
      categoryId: categoryId,
      title: title.trim(),
      queueSortOrder: queueSortOrder,
      createdAt: now,
      updatedAt: now,
    );
    await _repository.upsertParent(parent);
    _sync.pushRankingParent(parent);
    _refreshParents(categoryId);
    return parent;
  }

  /// Reads entry [id] fresh, applies [change] and the edit rules to it, and
  /// writes the result — one entry's writes at a time.
  ///
  /// Returns null, writing nothing, for an entry that is gone or deleted: a
  /// late edit to a deleted row used to bring it back live without its
  /// children or its images.
  Future<RankingParent?> _patchParent(
    String id,
    RankingParent Function(RankingParent fresh) change,
  ) {
    final repository = _repository;
    final sync = _sync;
    return _serialized('parent:$id', () async {
      final fresh = await repository.getParent(id);
      if (fresh == null || fresh.isDeleted) return null;
      final changed = change(fresh);
      // A change with nothing left to do once it sees the fresh row — a status
      // already set, a tag list already full — is not a revision.
      if (identical(changed, fresh)) return fresh;
      final next = applyRankingEditRules(fresh, changed);
      await repository.upsertParent(next);
      _refreshParents(next.categoryId);
      sync.pushRankingParent(next);
      return next;
    });
  }

  /// Saves an edited entry: the fields that differ between [previous] and
  /// [next] are laid over the row as it is on disk now, and then
  /// [applyRankingEditRules] has its say about the star and the in-progress
  /// promotion.
  ///
  /// Returns what was written, or null when the entry has been deleted.
  Future<RankingParent?> saveParent(
    RankingParent next, {
    required RankingParent previous,
  }) => _patchParent(
    next.id,
    (fresh) => rankingParentEditOnto(fresh, previous: previous, next: next),
  );

  /// Puts back a tag the editor took off [parentId], at the [index] it held.
  ///
  /// Reads the entry fresh rather than restoring a snapshot: it may have been
  /// edited while the offer stood, and the undo is for the one tag, not a
  /// rollback of everything since. A tag already back on the entry — re-added
  /// by hand, or by another device — throws [RestoreSuperseded] so the toast
  /// says so instead of doing nothing.
  Future<void> restoreTag(String parentId, String tag, int index) async {
    await _patchParent(parentId, (parent) {
      if (parent.tags.contains(tag)) throw const RestoreSuperseded();
      if (parent.tags.length >= maxRankingParentTags) return parent;
      final tags = [...parent.tags]
        ..insert(index.clamp(0, parent.tags.length), tag);
      return parent.copyWith(tags: tags);
    });
  }

  /// Marks an entry started because something was added to it that is not one
  /// of its own fields — a child, an image.
  Future<void> markInProgress(String parentId) async {
    final repository = _repository;
    final fresh = await repository.getParent(parentId);
    // Checked before queueing a write, so a unit save on an entry already
    // started costs no entry write and no entry reload.
    if (fresh == null ||
        fresh.isRanked ||
        fresh.status == RankingStatus.inProgress) {
      return;
    }
    await _patchParent(
      parentId,
      (parent) => parent.isRanked || parent.status == RankingStatus.inProgress
          ? parent
          : parent.copyWith(status: RankingStatus.inProgress),
    );
  }

  Future<RankingParent?> setOverallScore(String parentId, double? score) =>
      _patchParent(
        parentId,
        (parent) => score == null
            ? parent.copyWith(clearOverallScore: true)
            : parent.copyWith(overallScore: score),
      );

  Future<void> setStatus(String parentId, RankingStatus status) =>
      _patchParent(
        parentId,
        (parent) => parent.isRanked || parent.status == status
            ? parent
            : parent.copyWith(status: status),
      );

  Future<void> toggleStar(String parentId) => _patchParent(
    parentId,
    (parent) => parent.copyWith(starred: !parent.starred),
  );

  Future<void> reorderQueue(List<String> orderedIds) async {
    final sync = _sync;
    final written = await _repository.reorderQueue(orderedIds);
    if (written.isEmpty) return;
    _refreshParents(written.first.categoryId);
    unawaited(sync.pushRankingParentsBatch(written));
  }

  /// Sets the overall score to the rounded mean of the children that have one
  /// (§3.4). Returns null — and writes nothing — when none of them do.
  Future<RankingParent?> averageFromChildren(
    String parentId,
    RankingCategory category,
    List<RankingChild> children,
  ) async {
    final average = rankingAverageFromChildren(
      children,
      scoreMax: category.parentScoreMax,
      precision: category.parentScorePrecision,
    );
    if (average == null) return null;
    return setOverallScore(parentId, average);
  }

  Future<MediaDetachStamps> deleteParent(String parentId) async {
    final sync = _sync;
    final result = await _repository.softDeleteParent(parentId);
    _refresh();
    final stamps = await _detachMedia([
      result.parent.id,
      for (final child in result.children) child.id,
    ]);
    sync.pushRankingParent(result.parent);
    unawaited(sync.pushRankingChildrenBatch(result.children));
    return stamps;
  }

  Future<void> restoreParent(String id, MediaDetachStamps mediaStamps) async {
    final sync = _sync;
    final result = await _repository.restoreParent(id);
    _refresh();
    await _restoreMedia(mediaStamps);
    sync.pushRankingParent(result.parent);
    unawaited(sync.pushRankingChildrenBatch(result.children));
  }

  // ------------------------------------------------------------------ children

  /// New children go to the bottom of the saved order (§3.5), and adding one
  /// counts as starting the entry.
  Future<RankingChild> createChild({
    required RankingParent parent,
    required String name,
    required int sortOrder,
  }) async {
    final sync = _sync;
    final now = utcNow();
    final child = RankingChild(
      id: newId(),
      parentId: parent.id,
      name: name.trim(),
      sortOrder: sortOrder,
      createdAt: now,
      updatedAt: now,
    );
    await _repository.upsertChild(child);
    sync.pushRankingChild(child);
    _refreshChildren(parent.categoryId);
    await markInProgress(parent.id);
    return child;
  }

  /// [_patchParent] for a unit. Returns null for a unit that is gone or
  /// deleted, and marks its entry started otherwise.
  Future<RankingChild?> _patchChild(
    String id,
    RankingChild Function(RankingChild fresh) change,
  ) async {
    final repository = _repository;
    final sync = _sync;
    final written = await _serialized('child:$id', () async {
      final fresh = await repository.getChild(id);
      if (fresh == null || fresh.isDeleted) return null;
      final next = change(fresh);
      if (identical(next, fresh)) return null;
      await repository.upsertChild(next);
      sync.pushRankingChild(next);
      return next;
    });
    if (written == null) return null;
    final parent = await repository.getParent(written.parentId);
    if (parent != null) _refreshChildren(parent.categoryId);
    await markInProgress(written.parentId);
    return written;
  }

  /// [saveParent] for a unit.
  Future<RankingChild?> saveChild(
    RankingChild next, {
    required RankingChild previous,
  }) => _patchChild(
    next.id,
    (fresh) => rankingChildEditOnto(fresh, previous: previous, next: next),
  );

  Future<RankingChild?> setChildOverallScore(String childId, double? score) =>
      _patchChild(
        childId,
        (child) => score == null
            ? child.copyWith(clearOverallScore: true)
            : child.copyWith(overallScore: score),
      );

  Future<void> reorderChildren(List<String> orderedIds) async {
    final repository = _repository;
    final sync = _sync;
    final written = await repository.reorderChildren(orderedIds);
    if (written.isEmpty) return;
    final parent = await repository.getParent(written.first.parentId);
    if (parent != null) _refreshChildren(parent.categoryId);
    unawaited(sync.pushRankingChildrenBatch(written));
  }

  Future<MediaDetachStamps> deleteChild(String childId) async {
    final sync = _sync;
    final tombstone = await _repository.softDeleteChild(childId);
    _refresh();
    final stamps = await _detachMedia([tombstone.id]);
    sync.pushRankingChild(tombstone);
    return stamps;
  }

  Future<void> restoreChild(String id, MediaDetachStamps mediaStamps) async {
    final sync = _sync;
    final child = await _repository.restoreChild(id);
    _refresh();
    await _restoreMedia(mediaStamps);
    sync.pushRankingChild(child);
  }

  // --------------------------------------------------------------------- media

  /// Detaches the images on every row a delete took, and reports the instant
  /// each detach stamped.
  ///
  /// Each row's detach calls `utcNow()` for itself, and
  /// [MediaService.restoreReferencesForOwner] matches that stamp exactly — so
  /// there is one instant per document to remember, not one per delete. This
  /// used to pass the *entity's* `deletedAt` instead, which is a different
  /// `utcNow()` a few hundred microseconds earlier: it matched no reference at
  /// all, and undoing a delete silently left every image detached.
  Future<MediaDetachStamps> _detachMedia(List<String> documentIds) =>
      _container
          .read(mediaServiceProvider)
          .removeReferencesForOwners(FirestoreCollections.rankings, documentIds);

  Future<void> _restoreMedia(MediaDetachStamps stamps) async {
    final media = _container.read(mediaServiceProvider);
    for (final entry in stamps.entries) {
      await media.restoreReferencesForOwner(
        FirestoreCollections.rankings,
        entry.key,
        entry.value,
      );
    }
  }
}

/// The tail of each row's write queue, by `kind:id`.
///
/// Module-level because [RankingsActions] is built afresh for every call: two
/// quick edits to one entry arrive on two different instances, and each has to
/// read the row only after the other has written it, or the second read hands
/// back the row without the first edit and writes it away again.
final _writeQueues = <String, Future<void>>{};

Future<T> _serialized<T>(String key, Future<T> Function() write) {
  final result = (_writeQueues[key] ?? Future<void>.value()).then(
    (_) => write(),
  );
  late final Future<void> tail;
  tail = result.then<void>((_) {}, onError: (Object _) {}).whenComplete(() {
    if (identical(_writeQueues[key], tail)) _writeQueues.remove(key);
  });
  _writeQueues[key] = tail;
  return result;
}

/// Confirms, deletes, and offers the undo — the shape every soft delete in the
/// app takes (see `SOFT_DELETE_TOAST.md`).
Future<bool> confirmDeleteRankingParent(
  BuildContext context,
  WidgetRef ref,
  RankingParent parent, {
  required int childCount,
  required String childUnitLabel,
}) async {
  // Captured while the caller is still mounted. Deleting a row unmounts the
  // widget that asked for the delete, so `ref` and `context` are both gone by
  // the time the undo runs — and the toast that offers it has to be raised in
  // an overlay that outlives them.
  final container = ProviderScope.containerOf(ref.context, listen: false);
  final overlay = Overlay.of(context, rootOverlay: true);

  final confirmed = await showConfirmDialog(
    context,
    title: 'Delete entry?',
    message: childCount == 0
        ? '"${parent.title}" will be deleted.'
        : '"${parent.title}" and its $childCount '
              '${_plural(childCount, childUnitLabel)} will be deleted.',
  );
  if (!confirmed) return false;

  final actions = RankingsActions.detached(container);
  late final MediaDetachStamps mediaStamps;
  await softDeleteWithUndo(
    overlay: overlay,
    message: deletedMessage(parent.title, fallback: 'entry'),
    delete: () async => mediaStamps = await actions.deleteParent(parent.id),
    restore: () => actions.restoreParent(parent.id, mediaStamps),
  );
  return true;
}

Future<bool> confirmDeleteRankingChild(
  BuildContext context,
  WidgetRef ref,
  RankingChild child,
) async {
  // See [confirmDeleteRankingParent] on why both are captured up front.
  final container = ProviderScope.containerOf(ref.context, listen: false);
  final overlay = Overlay.of(context, rootOverlay: true);

  final confirmed = await showConfirmDialog(
    context,
    title: 'Delete "${child.name}"?',
    message: 'It will be deleted.',
  );
  if (!confirmed) return false;

  final actions = RankingsActions.detached(container);
  late final MediaDetachStamps mediaStamps;
  await softDeleteWithUndo(
    overlay: overlay,
    message: deletedMessage(child.name, fallback: 'entry'),
    delete: () async => mediaStamps = await actions.deleteChild(child.id),
    restore: () => actions.restoreChild(child.id, mediaStamps),
  );
  return true;
}

Future<bool> confirmDeleteRankingCategory(
  BuildContext context,
  WidgetRef ref,
  RankingCategory category, {
  required int entryCount,
}) async {
  // See [confirmDeleteRankingParent] on why both are captured up front.
  final container = ProviderScope.containerOf(ref.context, listen: false);
  final overlay = Overlay.of(context, rootOverlay: true);

  final confirmed = await showConfirmDialog(
    context,
    title: 'Delete "${category.name}"?',
    message: entryCount == 0
        ? 'The category will be deleted.'
        : 'The category and its $entryCount '
              '${_plural(entryCount, 'entry', plural: 'entries')} will be '
              'deleted. Restoring it brings them all back.',
  );
  if (!confirmed) return false;

  final actions = RankingsActions.detached(container);
  late final MediaDetachStamps mediaStamps;
  await softDeleteWithUndo(
    overlay: overlay,
    message: deletedMessage(category.name, fallback: 'category'),
    delete: () async => mediaStamps = await actions.deleteCategory(category),
    restore: () => actions.restoreCategory(category, mediaStamps),
  );
  return true;
}

/// Offers back a tag a chip tap in the editor just took off [parentId].
///
/// No confirm first — the chip is a one-click remove on purpose — so this is
/// the way back from a stray one. Both are captured up front for the reason
/// [confirmDeleteRankingParent] gives: by the time Undo is pressed the panel
/// may be closed, or showing another entry.
void offerRankingTagUndo(
  BuildContext context,
  WidgetRef ref, {
  required String parentId,
  required String tag,
  required int index,
}) {
  final container = ProviderScope.containerOf(ref.context, listen: false);
  final overlay = Overlay.of(context, rootOverlay: true);
  showSoftDeleteUndoToast(
    overlay: overlay,
    message: deletedMessage(tag, fallback: 'tag'),
    restore: () =>
        RankingsActions.detached(container).restoreTag(parentId, tag, index),
  );
}

String _plural(int count, String singular, {String? plural}) => count == 1
    ? singular.toLowerCase()
    : (plural ?? '${singular.toLowerCase()}s');

/// Which instant each row's images were detached at, keyed by document id.
///
/// [MediaService.restoreReferencesForOwner] matches that stamp exactly, and
/// every row's detach calls `utcNow()` for itself — so a cascade delete has one
/// instant to remember per row, not one for the whole operation.
typedef MediaDetachStamps = Map<String, DateTime>;

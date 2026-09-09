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
/// Same three beats as the rest of the app: write through the repository, hand
/// the record to the sync layer, invalidate what reads it. Nothing here builds
/// widgets, so the list, the editor panel and the manage sheet all call the
/// same code.
class RankingsActions {
  const RankingsActions(WidgetRef ref) : _ref = ref, _container = null;

  /// Actions that outlive the widget that asked for them.
  ///
  /// A soft delete unmounts the row it deleted, and a [WidgetRef] throws once
  /// its widget is gone — so the undo the toast offers, pressed seconds later,
  /// has to run off the container instead.
  const RankingsActions.detached(ProviderContainer container)
    : _ref = null,
      _container = container;

  final WidgetRef? _ref;
  final ProviderContainer? _container;

  T _read<T>(ProviderListenable<T> provider) {
    final ref = _ref;
    return ref == null ? _container!.read(provider) : ref.read(provider);
  }

  RankingRepository get _repository => _read(rankingRepositoryProvider);
  RemoteSyncService get _sync => _read(remoteSyncServiceProvider);

  void _refresh() {
    final ref = _ref;
    if (ref == null) {
      invalidateRankingProvidersIn(_container!);
    } else {
      invalidateRankingProvidersFrom(ref);
    }
  }

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
    final written = await _repository.reorderCategories(orderedIds);
    await _sync.pushRankingCategoriesBatch(written);
    _refresh();
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
    final result = await _repository.softDeleteCategory(category.id);
    final stamps = await _detachMedia([
      for (final parent in result.parents) parent.id,
      for (final child in result.children) child.id,
    ]);
    _sync.pushRankingCategory(result.category);
    await _sync.pushRankingParentsBatch(result.parents);
    await _sync.pushRankingChildrenBatch(result.children);
    _refresh();
    return stamps;
  }

  Future<void> restoreCategory(
    RankingCategory tombstone,
    MediaDetachStamps mediaStamps,
  ) async {
    final result = await _repository.restoreCategory(tombstone.id);
    await _restoreMedia(mediaStamps);
    _sync.pushRankingCategory(result.category);
    await _sync.pushRankingParentsBatch(result.parents);
    await _sync.pushRankingChildrenBatch(result.children);
    _refresh();
  }

  /// Moves a template field between the 5 and 10 scales, carrying every value
  /// already stored against it (§7.3).
  ///
  /// The rewrite is the whole point: leaving an 8 behind on a field that now
  /// tops out at 5 would render as a full strip and sort as an outlier. Values
  /// are rounded to the destination's steps, which is lossy going down — the
  /// editor warns before calling this.
  Future<void> rescaleTemplateField(
    RankingCategory category,
    RankingTemplateField field, {
    required int scoreMax,
    required bool isParentTemplate,
  }) async {
    if (field.scoreMax == scoreMax) return;

    RankingFieldValue? rescaled(Map<String, RankingFieldValue> values) {
      final value = values[field.id];
      if (value?.score == null) return null;
      return value!.copyWith(
        score: rescaleRankingScore(
          value.score!,
          fromMax: field.scoreMax,
          toMax: scoreMax,
          precision: rankingFieldPrecision(
            field,
            overallPrecision: isParentTemplate
                ? category.parentScorePrecision
                : category.childScorePrecision,
          ),
        ),
      );
    }

    final parents = await _repository.listParents(category.id);
    if (isParentTemplate) {
      final written = <RankingParent>[];
      for (final parent in parents) {
        final value = rescaled(parent.fieldValues);
        if (value == null) continue;
        final next = parent.copyWith(
          fieldValues: {...parent.fieldValues, field.id: value},
        );
        await _repository.upsertParent(next, recordLocalActivity: false);
        written.add(next);
      }
      await _sync.pushRankingParentsBatch(written);
    } else {
      final written = <RankingChild>[];
      for (final parent in parents) {
        for (final child in await _repository.listChildren(parent.id)) {
          final value = rescaled(child.fieldValues);
          if (value == null) continue;
          final next = child.copyWith(
            fieldValues: {...child.fieldValues, field.id: value},
          );
          await _repository.upsertChild(next, recordLocalActivity: false);
          written.add(next);
        }
      }
      await _sync.pushRankingChildrenBatch(written);
    }

    await saveCategory(
      _withTemplate(
        category,
        isParentTemplate: isParentTemplate,
        fields: [
          for (final existing in _templateOf(category, isParentTemplate))
            if (existing.id == field.id)
              existing.copyWith(scoreMax: scoreMax)
            else
              existing,
        ],
      ),
    );
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
  /// one of them has to land on the new grid.
  Future<int> _reroundForCategory(
    RankingCategory next, {
    required RankingCategory previous,
    bool dryRun = false,
  }) async {
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

    for (final parent in await _repository.listParents(previous.id)) {
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
          updated = updated.copyWith(overallScore: rounded);
        }
      }

      final (values, valueChanges) = reroundValues(
        parent.fieldValues,
        parentFields,
      );
      if (valueChanges > 0) {
        changed += valueChanges;
        updated = updated.copyWith(fieldValues: values);
      }
      if (changed > 0) {
        moved += changed;
        if (!dryRun) {
          await _repository.upsertParent(updated, recordLocalActivity: false);
          writtenParents.add(updated);
        }
      }

      for (final child in await _repository.listChildren(parent.id)) {
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
            updatedChild = updatedChild.copyWith(overallScore: rounded);
          }
        }

        final (childValues, childValueChanges) = reroundValues(
          child.fieldValues,
          childFields,
        );
        if (childValueChanges > 0) {
          childChanged += childValueChanges;
          updatedChild = updatedChild.copyWith(fieldValues: childValues);
        }
        if (childChanged > 0) {
          moved += childChanged;
          if (!dryRun) {
            await _repository.upsertChild(
              updatedChild,
              recordLocalActivity: false,
            );
            writtenChildren.add(updatedChild);
          }
        }
      }
    }

    if (!dryRun) {
      await _sync.pushRankingParentsBatch(writtenParents);
      await _sync.pushRankingChildrenBatch(writtenChildren);
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
    _refresh();
    return parent;
  }

  /// Saves an edited entry, after [applyRankingEditRules] has had its say
  /// about the star and the in-progress promotion.
  Future<RankingParent> saveParent(
    RankingParent parent, {
    required RankingParent previous,
  }) async {
    final next = applyRankingEditRules(previous, parent);
    await _repository.upsertParent(next);
    _sync.pushRankingParent(next);
    _refresh();
    return next;
  }

  /// Marks an entry started because something was added to it that is not one
  /// of its own fields — a child, an image.
  Future<void> markInProgress(RankingParent parent) async {
    if (parent.isRanked || parent.status == RankingStatus.inProgress) return;
    final next = parent.copyWith(status: RankingStatus.inProgress);
    await _repository.upsertParent(next);
    _sync.pushRankingParent(next);
    _refresh();
  }

  Future<RankingParent> setOverallScore(RankingParent parent, double? score) =>
      saveParent(
        score == null
            ? parent.copyWith(clearOverallScore: true)
            : parent.copyWith(overallScore: score),
        previous: parent,
      );

  Future<void> setStatus(RankingParent parent, RankingStatus status) async {
    if (parent.isRanked || parent.status == status) return;
    final next = parent.copyWith(status: status);
    await _repository.upsertParent(next);
    _sync.pushRankingParent(next);
    _refresh();
  }

  Future<void> toggleStar(RankingParent parent) async {
    final next = parent.copyWith(starred: !parent.starred);
    await _repository.upsertParent(next);
    _sync.pushRankingParent(next);
    _refresh();
  }

  Future<void> reorderQueue(List<String> orderedIds) async {
    final written = await _repository.reorderQueue(orderedIds);
    await _sync.pushRankingParentsBatch(written);
    _refresh();
  }

  /// Sets the overall score to the rounded mean of the children that have one
  /// (§3.4). Returns null — and writes nothing — when none of them do.
  Future<RankingParent?> averageFromChildren(
    RankingParent parent,
    RankingCategory category,
    List<RankingChild> children,
  ) async {
    final average = rankingAverageFromChildren(
      children,
      scoreMax: category.parentScoreMax,
      precision: category.parentScorePrecision,
    );
    if (average == null) return null;
    return setOverallScore(parent, average);
  }

  Future<MediaDetachStamps> deleteParent(RankingParent parent) async {
    final result = await _repository.softDeleteParent(parent.id);
    final stamps = await _detachMedia([
      result.parent.id,
      for (final child in result.children) child.id,
    ]);
    _sync.pushRankingParent(result.parent);
    await _sync.pushRankingChildrenBatch(result.children);
    _refresh();
    return stamps;
  }

  Future<void> restoreParent(String id, MediaDetachStamps mediaStamps) async {
    final result = await _repository.restoreParent(id);
    await _restoreMedia(mediaStamps);
    _sync.pushRankingParent(result.parent);
    await _sync.pushRankingChildrenBatch(result.children);
    _refresh();
  }

  // ------------------------------------------------------------------ children

  /// New children go to the bottom of the saved order (§3.5), and adding one
  /// counts as starting the entry.
  Future<RankingChild> createChild({
    required RankingParent parent,
    required String name,
    required int sortOrder,
  }) async {
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
    _sync.pushRankingChild(child);
    await markInProgress(parent);
    _refresh();
    return child;
  }

  Future<void> saveChild(RankingChild child, {RankingParent? parent}) async {
    await _repository.upsertChild(child);
    _sync.pushRankingChild(child);
    if (parent != null) await markInProgress(parent);
    _refresh();
  }

  Future<void> reorderChildren(List<String> orderedIds) async {
    final written = await _repository.reorderChildren(orderedIds);
    await _sync.pushRankingChildrenBatch(written);
    _refresh();
  }

  Future<MediaDetachStamps> deleteChild(RankingChild child) async {
    final tombstone = await _repository.softDeleteChild(child.id);
    final stamps = await _detachMedia([tombstone.id]);
    _sync.pushRankingChild(tombstone);
    _refresh();
    return stamps;
  }

  Future<void> restoreChild(String id, MediaDetachStamps mediaStamps) async {
    final child = await _repository.restoreChild(id);
    await _restoreMedia(mediaStamps);
    _sync.pushRankingChild(child);
    _refresh();
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
  Future<MediaDetachStamps> _detachMedia(List<String> documentIds) async {
    final media = _read(mediaServiceProvider);
    final stamps = <String, DateTime>{};
    for (final documentId in documentIds) {
      final stamp = await media.removeReferencesForOwner(
        FirestoreCollections.rankings,
        documentId,
      );
      if (stamp != null) stamps[documentId] = stamp;
    }
    return stamps;
  }

  Future<void> _restoreMedia(MediaDetachStamps stamps) async {
    final media = _read(mediaServiceProvider);
    for (final entry in stamps.entries) {
      await media.restoreReferencesForOwner(
        FirestoreCollections.rankings,
        entry.key,
        entry.value,
      );
    }
  }
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
    delete: () async => mediaStamps = await actions.deleteParent(parent),
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
    delete: () async => mediaStamps = await actions.deleteChild(child),
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

String _plural(int count, String singular, {String? plural}) => count == 1
    ? singular.toLowerCase()
    : (plural ?? '${singular.toLowerCase()}s');

/// Which instant each row's images were detached at, keyed by document id.
///
/// [MediaService.restoreReferencesForOwner] matches that stamp exactly, and
/// every row's detach calls `utcNow()` for itself — so a cascade delete has one
/// instant to remember per row, not one for the whole operation.
typedef MediaDetachStamps = Map<String, DateTime>;

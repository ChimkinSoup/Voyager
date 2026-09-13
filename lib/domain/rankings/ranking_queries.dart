import 'package:voyager/domain/models/ranking_models.dart';

/// Where a new category goes: after the last one.
///
/// Not the count — a delete leaves a gap, so with 0, 1, 2 and the first
/// deleted, the count put a new category on 2 alongside the last, and the
/// strip order between the two was left to chance on every device.
int rankingNextCategorySortOrder(Iterable<RankingCategory> categories) {
  var next = 0;
  for (final category in categories) {
    if (category.sortOrder >= next) next = category.sortOrder + 1;
  }
  return next;
}

/// The smallest move a score can make under [precision].
double rankingScoreStep(RankingScorePrecision precision) => switch (precision) {
  RankingScorePrecision.integers => 1.0,
  RankingScorePrecision.half => 0.5,
  RankingScorePrecision.tenths => 0.1,
};

/// How many steps fit in one point of the scale — the integer the snap is done
/// in, so a tenth lands on 8.4 rather than on 8.400000000000001.
int _stepsPerPoint(RankingScorePrecision precision) => switch (precision) {
  RankingScorePrecision.integers => 1,
  RankingScorePrecision.half => 2,
  RankingScorePrecision.tenths => 10,
};

/// Snaps [value] onto the nearest allowed step and clamps it into the scale.
///
/// Every path that produces a score goes through this — the popover's commit,
/// the wheel nudge, the average-from-children button, a rescale, a precision
/// change — so a stored score is always one the UI can draw and print exactly.
double roundRankingScore(
  double value, {
  required int scoreMax,
  required RankingScorePrecision precision,
}) {
  // A pasted run of 400 digits parses to infinity, and `.round()` on that
  // throws rather than clamping.
  if (!value.isFinite) return value.isNaN || value < 0 ? 0 : scoreMax.toDouble();
  final steps = _stepsPerPoint(precision);
  // Multiply-round-divide rather than `(value / step).round() * step`: the
  // division is exact for these three denominators, so 84 / 10 is the double
  // nearest 8.4 and two scores that read the same compare equal (§12.14).
  final snapped = (value * steps).round() / steps;
  if (snapped <= 0) return 0;
  if (snapped >= scoreMax) return scoreMax.toDouble();
  return snapped;
}

/// Whether [value] already sits on [precision]'s grid, which is what decides
/// whether tightening the mode has to warn before re-rounding (§8.1).
bool rankingScoreIsOnStep(
  double value, {
  required int scoreMax,
  required RankingScorePrecision precision,
}) =>
    roundRankingScore(value, scoreMax: scoreMax, precision: precision) == value;

/// The step a template field actually moves on: the overall it sits under
/// while it inherits, its own once it stops.
///
/// A field that has opted out without choosing a mode falls back to the
/// overall rather than to a hardcoded default — there is no state in which a
/// field has no answer to this.
RankingScorePrecision rankingFieldPrecision(
  RankingTemplateField field, {
  required RankingScorePrecision overallPrecision,
}) => field.inheritPrecision
    ? overallPrecision
    : (field.scorePrecision ?? overallPrecision);

/// Where a field's number starts when the entry has never been scored.
///
/// Shown, never stored: an untouched field stays null so that a sort by it
/// can tell "unscored" from "scored exactly in the middle".
double rankingFieldMidpoint(
  int scoreMax, {
  required RankingScorePrecision precision,
}) => roundRankingScore(scoreMax / 2, scoreMax: scoreMax, precision: precision);

/// Mean of the children that have an overall score, rounded to the parent's
/// step. Null when no child has one.
///
/// Children without a score are excluded rather than counted as zero — a
/// half-watched season would otherwise drag the average toward the floor.
double? rankingAverageFromChildren(
  Iterable<RankingChild> children, {
  required int scoreMax,
  required RankingScorePrecision precision,
}) {
  final scores = [
    for (final child in children)
      if (child.overallScore != null) child.overallScore!,
  ];
  if (scores.isEmpty) return null;
  final mean = scores.reduce((a, b) => a + b) / scores.length;
  return roundRankingScore(mean, scoreMax: scoreMax, precision: precision);
}

/// Moves a score from one scale to another, keeping its position on the scale.
///
/// Used when a template field is rescaled between 5 and 10. Lossy in the
/// 10 → 5 direction, which is why the editor warns before it runs.
double rescaleRankingScore(
  double value, {
  required int fromMax,
  required int toMax,
  required RankingScorePrecision precision,
}) {
  if (fromMax == toMax) {
    return roundRankingScore(value, scoreMax: toMax, precision: precision);
  }
  return roundRankingScore(
    value * toMax / fromMax,
    scoreMax: toMax,
    precision: precision,
  );
}

/// A score as it reads in the UI: `9` rather than `9.0`, `9.5` as itself.
String formatRankingScore(double score) {
  final rounded = score.roundToDouble();
  return score == rounded
      ? rounded.toInt().toString()
      : score.toStringAsFixed(1);
}

/// How many of [children] carry an overall score, for the row's `8/12 scored`.
({int scored, int total}) rankingChildProgress(
  Iterable<RankingChild> children,
) {
  var scored = 0;
  var total = 0;
  for (final child in children) {
    total++;
    if (child.overallScore != null) scored++;
  }
  return (scored: scored, total: total);
}

/// The compact header's numbers. Ranked-only by design: an average that moved
/// when something was merely queued would not mean anything.
({int ranked, int inProgress, int queued, double? average})
rankingCategoryStats(Iterable<RankingParent> parents) {
  var ranked = 0;
  var inProgress = 0;
  var queued = 0;
  var total = 0.0;
  for (final parent in parents) {
    if (parent.isRanked) {
      ranked++;
      total += parent.overallScore!;
    } else if (parent.status == RankingStatus.inProgress) {
      inProgress++;
    } else {
      queued++;
    }
  }
  return (
    ranked: ranked,
    inProgress: inProgress,
    queued: queued,
    average: ranked == 0 ? null : total / ranked,
  );
}

/// Every structured tag carried by [parents], sorted for the filter menu.
///
/// Structured only, and deliberately: the filter list is the same vocabulary
/// the rows print, and a `#tag` written inside somebody's notes would sit here
/// as a filter with no chip anywhere to show which entries it would keep.
/// Notes tags stay findable through the search box.
///
/// Category-local on purpose: these never reach the Journal's pool or the
/// global Search page. Pass the category's live parents — a soft-deleted one
/// takes its tags out of the vocab until it is restored.
List<String> rankingTags(Iterable<RankingParent> parents) {
  final tags = <String>{};
  for (final parent in parents) {
    tags.addAll(parent.tags);
  }
  final sorted = tags.toList()..sort();
  return sorted;
}

/// The category's structured tags, most-used first, for the editor's
/// suggestions.
///
/// Ties break alphabetically so the list holds still between openings rather
/// than reshuffling every time two tags trade a use.
List<String> rankingTagSuggestions(Iterable<RankingParent> parents) {
  final counts = <String, int>{};
  for (final parent in parents) {
    for (final tag in parent.tags) {
      counts[tag] = (counts[tag] ?? 0) + 1;
    }
  }
  final sorted = counts.keys.toList()
    ..sort((a, b) {
      final byCount = counts[b]!.compareTo(counts[a]!);
      return byCount != 0 ? byCount : a.compareTo(b);
    });
  return sorted;
}

/// Case-insensitive substring match, every whitespace-separated term having to
/// hit somewhere in the entry (Jobs' idiom).
///
/// The haystack spans the parent and its children together, so searching an
/// episode name finds the show it belongs to — which is the only way a hit
/// inside a child can surface in a list of parents.
bool rankingMatchesQuery(
  RankingParent parent,
  List<RankingChild> children,
  String query,
) {
  final terms = query.toLowerCase().split(RegExp(r'\s+'))
    ..removeWhere((term) => term.isEmpty);
  if (terms.isEmpty) return true;
  final haystack = [
    parent.title,
    parent.notes,
    ...parent.tags,
    for (final child in children) ...[child.name, child.notes],
  ].join(' ').toLowerCase();
  return terms.every(haystack.contains);
}

/// The narrowing the toolbar applies, on top of the search box.
///
/// [statuses] only narrows the unranked section and [scoreMin]/[scoreMax] only
/// the ranked one: a queued entry has no overall score to fall in a range, and
/// a ranked one has no queued/in-progress state left to match.
class RankingFilters {
  const RankingFilters({
    this.scoreMin,
    this.scoreMax,
    this.statuses = const {},
    this.hasImages = false,
    this.tag,
  });

  static const none = RankingFilters();

  final double? scoreMin;
  final double? scoreMax;
  final Set<RankingStatus> statuses;
  final bool hasImages;
  final String? tag;

  bool get isEmpty =>
      scoreMin == null &&
      scoreMax == null &&
      statuses.isEmpty &&
      !hasImages &&
      tag == null;

  /// Whether the score range is narrower than the scale. The queue hides
  /// itself while it is (§5.1): an unranked entry has no overall score, so
  /// there is no honest answer to whether it falls in the range.
  bool get hasScoreRange => scoreMin != null || scoreMax != null;

  /// The narrowing the filter popover owns — everything but [statuses], which
  /// the stats-band chips control instead. This is what the popover's Clear
  /// action clears and what greys the Filter pill.
  bool get hasPopoverFilters => hasScoreRange || hasImages || tag != null;

  /// Drops the popover's own narrowing, leaving the chip selection alone.
  RankingFilters withoutPopoverFilters() =>
      RankingFilters(statuses: statuses);

  /// The same narrowing with the chips taken off, which is the scope the hero
  /// stats and the chip counts are measured against (§5.2).
  RankingFilters withoutStatuses() => RankingFilters(
    scoreMin: scoreMin,
    scoreMax: scoreMax,
    hasImages: hasImages,
    tag: tag,
  );

  RankingFilters copyWith({
    double? scoreMin,
    bool clearScoreMin = false,
    double? scoreMax,
    bool clearScoreMax = false,
    Set<RankingStatus>? statuses,
    bool? hasImages,
    String? tag,
    bool clearTag = false,
  }) => RankingFilters(
    scoreMin: clearScoreMin ? null : (scoreMin ?? this.scoreMin),
    scoreMax: clearScoreMax ? null : (scoreMax ?? this.scoreMax),
    statuses: statuses ?? this.statuses,
    hasImages: hasImages ?? this.hasImages,
    tag: clearTag ? null : (tag ?? this.tag),
  );
}

/// Applies the search box and the filters to one category's parents.
///
/// [documentIdsWithImages] holds parent *and* child ids, so a show whose
/// pictures all hang off its episodes still answers the "has images" filter.
List<RankingParent> filterRankingParents(
  List<RankingParent> parents, {
  required Map<String, List<RankingChild>> childrenByParent,
  required String query,
  required RankingFilters filters,
  Set<String> documentIdsWithImages = const {},
}) {
  bool hasImages(RankingParent parent) {
    if (documentIdsWithImages.contains(parent.id)) return true;
    for (final child in childrenByParent[parent.id] ?? const <RankingChild>[]) {
      if (documentIdsWithImages.contains(child.id)) return true;
    }
    return false;
  }

  // Structured tags only. A parent that only says `#thai` in its notes does
  // not pass a `thai` filter — the filter and the row chips are one vocabulary,
  // and a note tag has no chip.
  bool hasTag(RankingParent parent, String tag) => parent.tags.contains(tag);

  return [
    for (final parent in parents)
      if (_passesScoreRange(parent, filters) &&
          _passesStatus(parent, filters) &&
          (!filters.hasImages || hasImages(parent)) &&
          (filters.tag == null || hasTag(parent, filters.tag!)) &&
          rankingMatchesQuery(
            parent,
            childrenByParent[parent.id] ?? const [],
            query,
          ))
        parent,
  ];
}

bool _passesScoreRange(RankingParent parent, RankingFilters filters) {
  if (!parent.isRanked) return true;
  final score = parent.overallScore!;
  if (filters.scoreMin != null && score < filters.scoreMin!) return false;
  if (filters.scoreMax != null && score > filters.scoreMax!) return false;
  return true;
}

bool _passesStatus(RankingParent parent, RankingFilters filters) {
  if (parent.isRanked || filters.statuses.isEmpty) return true;
  return filters.statuses.contains(parent.status);
}

/// The unranked rows the stats-band status chips leave visible.
///
/// An empty chip set shows everything, which is Jobs' semantics: the chips are
/// a narrowing you switch on, not a selection you have to keep complete.
/// Ranked rows never pass through here — a scored entry has no queued or
/// in-progress state left to match (§3.2).
List<RankingParent> filterUnrankedByStatus(
  List<RankingParent> unranked,
  Set<RankingStatus> statuses,
) {
  if (statuses.isEmpty) return unranked;
  return [
    for (final parent in unranked)
      if (statuses.contains(parent.status)) parent,
  ];
}

/// The `#N` beside each ranked row, in the order the rows are drawn (§6.3).
///
/// Density ranking, not list position: every entry sharing a score shares its
/// rank, and the next score down skips past all of them — 10, 10, 10, 9, 8
/// ranks 1, 1, 1, 4, 5. Only the first row of a tier prints its number, so the
/// list reads as tiers rather than as a numbered run with repeats.
///
/// "First" is first *in list order*, which is what makes a starred row pinned
/// above its tier carry the number rather than leaving it stranded further
/// down. A tier therefore states its rank exactly once however the pinning
/// splits it.
List<int?> rankingDisplayRanks(List<RankingParent> rankedInListOrder) {
  // Counted once per distinct score and walked from the top, rather than
  // comparing every score with every other on each build: this runs on every
  // search keystroke.
  final counts = <double, int>{};
  for (final parent in rankedInListOrder) {
    counts.update(parent.overallScore!, (n) => n + 1, ifAbsent: () => 1);
  }
  final rankOf = <double, int>{};
  var better = 0;
  for (final score in counts.keys.toList()..sort((a, b) => b.compareTo(a))) {
    // 1-based by descending score: how many entries beat this one, plus one.
    rankOf[score] = better + 1;
    better += counts[score]!;
  }

  final ranks = <int?>[];
  final seen = <double>{};
  for (final parent in rankedInListOrder) {
    final score = parent.overallScore!;
    ranks.add(seen.add(score) ? rankOf[score] : null);
  }
  return ranks;
}

/// Applies the two rules an edit to an entry can trip, before it is written.
///
/// Both live here rather than at the controls that cause them so that the
/// editor panel, the list row's quick-rate and the row menu cannot disagree
/// about them:
///
/// * crossing between the ranked and unranked sections clears the star (§7.2),
///   and clearing a score lands in **in progress** rather than back in the
///   queue — the entry has been started, whatever its score says now;
/// * any non-title edit promotes a queued entry to in progress (§3.4). The
///   title is excluded by design: naming something you mean to watch is not
///   starting it. So is a status the user set by hand in the same save, which
///   would otherwise be overwritten by the very edit carrying it.
RankingParent applyRankingEditRules(
  RankingParent previous,
  RankingParent next,
) {
  var result = next;

  // Without a version bump: these ride along with the edit that tripped them,
  // and one save counting as three writes outranked a real edit made on
  // another device in the meantime.
  if (result.isRanked != previous.isRanked) {
    result = result.copyWith(starred: false, bumpVersion: false);
    if (!result.isRanked) {
      result = result.copyWith(
        status: RankingStatus.inProgress,
        bumpVersion: false,
      );
    }
  }

  if (_promotesToInProgress(previous, result)) {
    result = result.copyWith(
      status: RankingStatus.inProgress,
      bumpVersion: false,
    );
  }
  return result;
}

/// The fields an editor changed between [previous] and [next], laid over
/// [fresh] — the row as it stands on disk now.
///
/// An editor holds the row it last saw, and a save built wholly from that
/// copy would put back everything anyone else changed since: a note the panel
/// saved a moment ago, a score another device set. Only what this edit
/// touched is its to write.
RankingParent rankingParentEditOnto(
  RankingParent fresh, {
  required RankingParent previous,
  required RankingParent next,
}) {
  // Handed back as is when the edit changed nothing, so the caller can tell
  // there is nothing to write.
  if (_sameStampValues(
    rankingParentStampValues(previous),
    rankingParentStampValues(next),
  )) {
    return fresh;
  }
  final fieldValues = _fieldValuesEditOnto(
    fresh.fieldValues,
    previous: previous.fieldValues,
    next: next.fieldValues,
  );
  final overallChanged = next.overallScore != previous.overallScore;
  return fresh.copyWith(
    title: next.title != previous.title ? next.title : null,
    overallScore: overallChanged ? next.overallScore : null,
    clearOverallScore: overallChanged && next.overallScore == null,
    notes: next.notes != previous.notes ? next.notes : null,
    fieldValues: fieldValues,
    tags: _sameList(next.tags, previous.tags) ? null : next.tags,
    status: next.status != previous.status ? next.status : null,
    starred: next.starred != previous.starred ? next.starred : null,
    createdAt: next.createdAt != previous.createdAt ? next.createdAt : null,
  );
}

/// [rankingParentEditOnto] for a unit.
RankingChild rankingChildEditOnto(
  RankingChild fresh, {
  required RankingChild previous,
  required RankingChild next,
}) {
  if (_sameStampValues(
    rankingChildStampValues(previous),
    rankingChildStampValues(next),
  )) {
    return fresh;
  }
  final overallChanged = next.overallScore != previous.overallScore;
  return fresh.copyWith(
    name: next.name != previous.name ? next.name : null,
    overallScore: overallChanged ? next.overallScore : null,
    clearOverallScore: overallChanged && next.overallScore == null,
    notes: next.notes != previous.notes ? next.notes : null,
    fieldValues: _fieldValuesEditOnto(
      fresh.fieldValues,
      previous: previous.fieldValues,
      next: next.fieldValues,
    ),
    createdAt: next.createdAt != previous.createdAt ? next.createdAt : null,
  );
}

/// Null when the edit changed no field value, so the fresh map is kept as is.
Map<String, RankingFieldValue>? _fieldValuesEditOnto(
  Map<String, RankingFieldValue> fresh, {
  required Map<String, RankingFieldValue> previous,
  required Map<String, RankingFieldValue> next,
}) {
  Map<String, RankingFieldValue>? result;
  for (final id in {...previous.keys, ...next.keys}) {
    final before = previous[id] ?? const RankingFieldValue();
    final after = next[id] ?? const RankingFieldValue();
    final scoreChanged = before.score != after.score;
    final notesChanged = before.notes != after.notes;
    if (!scoreChanged && !notesChanged) continue;
    result ??= {...fresh};
    final current = result[id] ?? const RankingFieldValue();
    result[id] = RankingFieldValue(
      score: scoreChanged ? after.score : current.score,
      notes: notesChanged ? after.notes : current.notes,
    );
  }
  return result;
}

bool _sameStampValues(Map<String, Object?> a, Map<String, Object?> b) {
  for (final key in {...a.keys, ...b.keys}) {
    if (a[key] != b[key]) return false;
  }
  return true;
}

bool _sameList(List<String> a, List<String> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

bool _promotesToInProgress(RankingParent previous, RankingParent next) {
  if (next.isRanked) return false;
  if (previous.status != RankingStatus.queued) return false;
  if (next.status != RankingStatus.queued) return false;
  return next.notes != previous.notes ||
      !_sameFieldValues(next.fieldValues, previous.fieldValues) ||
      next.createdAt != previous.createdAt;
}

bool _sameFieldValues(
  Map<String, RankingFieldValue> a,
  Map<String, RankingFieldValue> b,
) {
  if (a.length != b.length) return false;
  for (final entry in a.entries) {
    final other = b[entry.key];
    if (other == null ||
        other.score != entry.value.score ||
        other.notes != entry.value.notes) {
      return false;
    }
  }
  return true;
}

/// The ranked section, sorted and — under a custom-field sort — narrowed.
///
/// A parent with no stored value for the sort field is dropped rather than
/// parked at one end: the list claims to be ordered by that field, and a row
/// the field says nothing about has no place in it. Stars still pin to the
/// top, ordered among themselves by the same key.
List<RankingParent> sortRankedParents(
  Iterable<RankingParent> parents, {
  required RankingSortMode sortMode,
  String? sortFieldId,
  bool ascending = false,
}) {
  final rows = [
    for (final parent in parents)
      if (parent.isRanked)
        if (sortMode != RankingSortMode.customField ||
            (sortFieldId != null &&
                parent.fieldValues[sortFieldId]?.score != null))
          parent,
  ];

  int byKey(RankingParent a, RankingParent b) {
    final result = switch (sortMode) {
      RankingSortMode.overallScore => a.overallScore!.compareTo(
        b.overallScore!,
      ),
      RankingSortMode.updatedAt => a.updatedAt.compareTo(b.updatedAt),
      RankingSortMode.createdAt => a.createdAt.compareTo(b.createdAt),
      RankingSortMode.customField =>
        a.fieldValues[sortFieldId]!.score!.compareTo(
          b.fieldValues[sortFieldId]!.score!,
        ),
    };
    if (result != 0) return ascending ? result : -result;
    // Ties break on recency in every mode, which is what §6.2 asks for under
    // the default sort and what reads least arbitrarily under the others.
    final recency = b.updatedAt.compareTo(a.updatedAt);
    return recency != 0 ? recency : a.title.compareTo(b.title);
  }

  rows.sort((a, b) {
    if (a.starred != b.starred) return a.starred ? -1 : 1;
    return byKey(a, b);
  });
  return rows;
}

/// The unranked section: stars first, then everything in progress, then the
/// queue in the order the user dragged it into.
///
/// In-progress rows are ordered by recency so that the row an edit just
/// promoted lands at the top of its group, which is what makes the auto-
/// promotion visible.
List<RankingParent> sortUnrankedParents(Iterable<RankingParent> parents) {
  final rows = [
    for (final parent in parents)
      if (!parent.isRanked) parent,
  ];
  rows.sort((a, b) {
    if (a.starred != b.starred) return a.starred ? -1 : 1;
    if (a.status != b.status) {
      return a.status == RankingStatus.inProgress ? -1 : 1;
    }
    if (a.status == RankingStatus.inProgress) {
      final recency = b.updatedAt.compareTo(a.updatedAt);
      return recency != 0 ? recency : a.title.compareTo(b.title);
    }
    final order = a.queueSortOrder.compareTo(b.queueSortOrder);
    return order != 0 ? order : a.title.compareTo(b.title);
  });
  return rows;
}

/// Whether a row in the unranked section is one the user can drag.
///
/// Only plain queued rows are: stars and in-progress rows are ordered by rules
/// of their own, so dropping one somewhere would move it to a position the
/// list is not keeping and it would spring back on the next rebuild.
bool rankingIsQueueDraggable(RankingParent parent) =>
    !parent.isRanked &&
    !parent.starred &&
    parent.status == RankingStatus.queued;

/// The new order of the queued ids after a row in the unranked section is
/// dragged from [oldIndex] to [newIndex].
///
/// The drag happens in the *whole* unranked list, but only the queued rows
/// have a stored order, so the drop position has to be translated between the
/// two. Counting the queued rows above the drop — in the list as it stands
/// with the dragged row already lifted out of it — is that translation, and it
/// lands a drop into the starred or in-progress block at the top of the queue
/// rather than refusing it.
///
/// [newIndex] is `ReorderableListView.onReorderItem`'s, which is already the
/// index in the post-removal list. Returns null when the dragged row is not
/// one the queue orders at all.
List<String>? rankingQueueOrderAfterDrag(
  List<RankingParent> unranked,
  int oldIndex,
  int newIndex,
) {
  if (oldIndex < 0 || oldIndex >= unranked.length) return null;
  final moved = unranked[oldIndex];
  if (!rankingIsQueueDraggable(moved)) return null;

  final remaining = [...unranked]..removeAt(oldIndex);
  var target = 0;
  for (var i = 0; i < newIndex && i < remaining.length; i++) {
    if (rankingIsQueueDraggable(remaining[i])) target++;
  }
  return [
    for (final parent in remaining)
      if (rankingIsQueueDraggable(parent)) parent.id,
  ]..insert(target, moved.id);
}

/// How the child list under one parent is being *looked at*.
///
/// [saved] is the manual order the user dragged; the rest are views that never
/// write [RankingChild.sortOrder] back.
enum RankingChildSort { saved, name, overallScore, customField }

List<RankingChild> sortRankingChildrenForView(
  Iterable<RankingChild> children, {
  RankingChildSort sort = RankingChildSort.saved,
  String? sortFieldId,
}) {
  final rows = children.toList();
  rows.sort((a, b) {
    switch (sort) {
      case RankingChildSort.saved:
        return a.sortOrder.compareTo(b.sortOrder);
      case RankingChildSort.name:
        return a.name.toLowerCase().compareTo(b.name.toLowerCase());
      case RankingChildSort.overallScore:
        return _compareNullableDesc(a.overallScore, b.overallScore, a, b);
      case RankingChildSort.customField:
        return _compareNullableDesc(
          sortFieldId == null ? null : a.fieldValues[sortFieldId]?.score,
          sortFieldId == null ? null : b.fieldValues[sortFieldId]?.score,
          a,
          b,
        );
    }
  });
  return rows;
}

/// Highest first, with unscored children after every scored one.
///
/// A child list is short and lives inside the entry the user is already
/// reading, so an unscored episode is parked at the bottom rather than hidden
/// the way an unscored parent is under a custom-field sort.
int _compareNullableDesc(
  double? a,
  double? b,
  RankingChild childA,
  RankingChild childB,
) {
  if (a == null && b == null)
    return childA.sortOrder.compareTo(childB.sortOrder);
  if (a == null) return 1;
  if (b == null) return -1;
  final result = b.compareTo(a);
  return result != 0 ? result : childA.sortOrder.compareTo(childB.sortOrder);
}

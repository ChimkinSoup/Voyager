import 'dart:convert';

import 'package:voyager/core/utils/ids.dart';
import 'package:voyager/domain/models/soft_deletable.dart';

/// Where a parent sits before it has an overall score.
///
/// `ranked` is deliberately absent: being ranked is derived from
/// [RankingParent.overallScore] rather than stored, so the two can never
/// disagree about which section a row belongs in.
enum RankingStatus {
  queued,
  inProgress;

  static RankingStatus fromName(String? name) => switch (name) {
    'inProgress' => RankingStatus.inProgress,
    _ => RankingStatus.queued,
  };
}

/// What the ranked section is ordered by.
///
/// [customField] pairs with [RankingCategory.sortFieldId]; the others ignore
/// it.
enum RankingSortMode {
  overallScore,
  updatedAt,
  createdAt,
  customField;

  static RankingSortMode fromName(String? name) => switch (name) {
    'updatedAt' => RankingSortMode.updatedAt,
    'createdAt' => RankingSortMode.createdAt,
    'customField' => RankingSortMode.customField,
    _ => RankingSortMode.overallScore,
  };
}

/// The grid a score is allowed to land on.
///
/// Replaces the half-step booleans the category used to carry: those could
/// only say "halves or wholes", and a tenth-precision score has no way to
/// spell itself in a boolean.
enum RankingScorePrecision {
  integers,
  half,
  tenths;

  static RankingScorePrecision fromName(String? name) => switch (name) {
    'integers' => RankingScorePrecision.integers,
    'tenths' => RankingScorePrecision.tenths,
    _ => RankingScorePrecision.half,
  };

  /// What the retired `*HalfStepsEnabled` boolean meant, for reading rows and
  /// payloads written before this enum existed.
  static RankingScorePrecision fromHalfSteps(bool halfSteps) =>
      halfSteps ? RankingScorePrecision.half : RankingScorePrecision.integers;

  /// The boolean an older build would have stored for this mode, so a device
  /// that has not updated yet still round-trips something sensible. Tenths has
  /// no honest answer, and the finer of the two is the safer lie.
  bool get halfStepsEquivalent => this != RankingScorePrecision.integers;

  String get label => switch (this) {
    RankingScorePrecision.integers => 'Whole',
    RankingScorePrecision.half => 'Half',
    RankingScorePrecision.tenths => 'Tenths',
  };
}

/// The two scales a score can be out of. Stored as the number itself so a
/// payload reads as `5`/`10` rather than as an enum index nothing else knows
/// how to interpret.
const rankingScoreMaxOptions = [5, 10];

/// One scored field on a category's parent or child template.
///
/// Fields are addressed by [id] for the life of the category: renaming one is
/// display-only, and removing one sets [removedAt] rather than dropping it, so
/// the values entries already hold stay attached to something the template
/// editor can offer to restore.
class RankingTemplateField {
  const RankingTemplateField({
    required this.id,
    required this.label,
    required this.sortOrder,
    this.scoreMax = 5,
    this.notesEnabled = true,
    this.inheritPrecision = true,
    this.scorePrecision,
    this.removedAt,
  });

  factory RankingTemplateField.fromJson(Map<String, dynamic> json) =>
      RankingTemplateField(
        id: json['id'] as String,
        label: json['label'] as String? ?? '',
        sortOrder: (json['sortOrder'] as num?)?.toInt() ?? 0,
        scoreMax: (json['scoreMax'] as num?)?.toInt() ?? 5,
        notesEnabled: json['notesEnabled'] as bool? ?? true,
        inheritPrecision: json['inheritPrecision'] as bool? ?? true,
        scorePrecision: json['scorePrecision'] == null
            ? null
            : RankingScorePrecision.fromName(json['scorePrecision'] as String?),
        removedAt: json['removedAt'] == null
            ? null
            : DateTime.parse(json['removedAt'] as String).toUtc(),
      );

  final String id;
  final String label;
  final int sortOrder;

  /// 5 or 10, independent of the category's overall scale.
  final int scoreMax;

  /// When false the notes box is hidden but whatever was typed in it stays on
  /// the entries, so switching it back on brings the writing back.
  final bool notesEnabled;

  /// Whether the field's step follows the overall score it sits under — the
  /// category's parent precision for a parent-template field, its child
  /// precision for a child-template one.
  ///
  /// One flag rather than the two the HLD names: a field never moves between
  /// the two templates, so only ever one of them could be live. What differs
  /// per template is the checkbox's wording, which the editor owns.
  final bool inheritPrecision;

  /// The field's own step, read only while [inheritPrecision] is false.
  final RankingScorePrecision? scorePrecision;

  /// Set when the field is taken off the template. The field and its values
  /// survive; only the editor stops showing it.
  final DateTime? removedAt;

  bool get isRemoved => removedAt != null;

  Map<String, dynamic> toJson() => {
    'id': id,
    'label': label,
    'sortOrder': sortOrder,
    'scoreMax': scoreMax,
    'notesEnabled': notesEnabled,
    'inheritPrecision': inheritPrecision,
    if (scorePrecision != null) 'scorePrecision': scorePrecision!.name,
    if (removedAt != null) 'removedAt': removedAt!.toIso8601String(),
  };

  RankingTemplateField copyWith({
    String? label,
    int? sortOrder,
    int? scoreMax,
    bool? notesEnabled,
    bool? inheritPrecision,
    RankingScorePrecision? scorePrecision,
    bool clearScorePrecision = false,
    DateTime? removedAt,
    bool clearRemovedAt = false,
  }) => RankingTemplateField(
    id: id,
    label: label ?? this.label,
    sortOrder: sortOrder ?? this.sortOrder,
    scoreMax: scoreMax ?? this.scoreMax,
    notesEnabled: notesEnabled ?? this.notesEnabled,
    inheritPrecision: inheritPrecision ?? this.inheritPrecision,
    scorePrecision: clearScorePrecision
        ? null
        : (scorePrecision ?? this.scorePrecision),
    removedAt: clearRemovedAt ? null : (removedAt ?? this.removedAt),
  );
}

/// Encodes a template for the one text column that holds it.
///
/// A template is only ever read together with its category, and its fields
/// have to survive being removed from it, so a JSON column beats a table of
/// rows whose only query would be "give me all of them for this category".
String encodeRankingTemplate(List<RankingTemplateField> fields) =>
    jsonEncode([for (final field in fields) field.toJson()]);

List<RankingTemplateField> decodeRankingTemplate(String? json) {
  if (json == null || json.isEmpty) return const [];
  final decoded = jsonDecode(json);
  if (decoded is! List) return const [];
  final fields = [
    for (final entry in decoded)
      if (entry is Map<String, dynamic>) RankingTemplateField.fromJson(entry),
  ];
  fields.sort((a, b) => a.sortOrder.compareTo(b.sortOrder));
  return fields;
}

/// One entry's answer to one template field.
///
/// A null [score] is what "never scored" means, and it is load-bearing: the
/// editor shows the scale's midpoint as a starting position without writing
/// it, so a field the user has not touched stays out of that field's sort
/// instead of piling every untouched entry onto the midpoint.
class RankingFieldValue {
  const RankingFieldValue({this.score, this.notes = ''});

  factory RankingFieldValue.fromJson(Map<String, dynamic> json) =>
      RankingFieldValue(
        score: (json['score'] as num?)?.toDouble(),
        notes: json['notes'] as String? ?? '',
      );

  final double? score;
  final String notes;

  bool get isEmpty => score == null && notes.isEmpty;

  Map<String, dynamic> toJson() => {
    if (score != null) 'score': score,
    if (notes.isNotEmpty) 'notes': notes,
  };

  RankingFieldValue copyWith({
    double? score,
    bool clearScore = false,
    String? notes,
  }) => RankingFieldValue(
    score: clearScore ? null : (score ?? this.score),
    notes: notes ?? this.notes,
  );
}

String encodeRankingFieldValues(Map<String, RankingFieldValue> values) =>
    jsonEncode({
      for (final entry in values.entries)
        if (!entry.value.isEmpty) entry.key: entry.value.toJson(),
    });

Map<String, RankingFieldValue> decodeRankingFieldValues(String? json) {
  if (json == null || json.isEmpty) return const {};
  final decoded = jsonDecode(json);
  if (decoded is! Map) return const {};
  return {
    for (final entry in decoded.entries)
      if (entry.value is Map)
        entry.key as String: RankingFieldValue.fromJson(
          Map<String, dynamic>.from(entry.value as Map),
        ),
  };
}

/// A ranking category — the whole shape of one kind of thing the user tracks.
///
/// Everything that makes shows different from restaurants lives here: whether
/// entries have child units and what they are called, which surfaces take
/// images, the scales, and the two templates. No categories are seeded; the
/// page opens empty until the user makes one.
class RankingCategory extends SoftDeletable {
  const RankingCategory({
    required super.id,
    required super.createdAt,
    required super.updatedAt,
    super.version,
    super.deletedAt,
    required this.name,
    required this.colorValue,
    this.iconKey = 'star',
    this.sortOrder = 0,
    this.childUnitsEnabled = false,
    this.childUnitLabel = 'Episode',
    this.imagesOnParent = true,
    this.imagesOnChild = false,
    this.parentScoreMax = 5,
    this.childScoreMax = 5,
    this.parentScorePrecision = RankingScorePrecision.half,
    this.childScorePrecision = RankingScorePrecision.half,
    this.parentTemplate = const [],
    this.childTemplate = const [],
    this.sortMode = RankingSortMode.overallScore,
    this.sortFieldId,
    this.sortAscending = false,
    this.archivedAt,
  });

  final String name;
  final int colorValue;

  /// Key into `rankingCategoryIcons`, not an icon code point: the icons come
  /// from a package whose code points are free to move between versions.
  final String iconKey;

  /// Position in the category strip. Syncs, so the order is the same on every
  /// device.
  final int sortOrder;

  final bool childUnitsEnabled;

  /// What one child is called — "Episode", "Dish". Shown wherever the child
  /// list names itself.
  final String childUnitLabel;

  final bool imagesOnParent;

  /// Only meaningful while [childUnitsEnabled]: a category with no children
  /// has nowhere to put a child gallery.
  final bool imagesOnChild;

  final int parentScoreMax;
  final int childScoreMax;

  /// The step the parent overall score moves on, inherited by every parent
  /// template field that has not opted out. The child setting is independent
  /// of it.
  final RankingScorePrecision parentScorePrecision;
  final RankingScorePrecision childScorePrecision;

  final List<RankingTemplateField> parentTemplate;
  final List<RankingTemplateField> childTemplate;

  /// The ranked section's sort, kept on the category rather than in a page
  /// prefs table so that it syncs with everything else about the category.
  final RankingSortMode sortMode;
  final String? sortFieldId;
  final bool sortAscending;

  /// Set = archived: hidden from the strip, and view-only until it is
  /// unarchived. Distinct from [deletedAt], which cascades to the entries.
  final DateTime? archivedAt;

  bool get isArchived => archivedAt != null;

  /// The template fields the editor shows, in display order. Removed fields
  /// are held back for the template editor's orphan list.
  List<RankingTemplateField> get activeParentTemplate => [
    for (final field in parentTemplate)
      if (!field.isRemoved) field,
  ];

  List<RankingTemplateField> get activeChildTemplate => [
    for (final field in childTemplate)
      if (!field.isRemoved) field,
  ];

  RankingCategory copyWith({
    String? name,
    int? colorValue,
    String? iconKey,
    int? sortOrder,
    bool? childUnitsEnabled,
    String? childUnitLabel,
    bool? imagesOnParent,
    bool? imagesOnChild,
    int? parentScoreMax,
    int? childScoreMax,
    RankingScorePrecision? parentScorePrecision,
    RankingScorePrecision? childScorePrecision,
    List<RankingTemplateField>? parentTemplate,
    List<RankingTemplateField>? childTemplate,
    RankingSortMode? sortMode,
    String? sortFieldId,
    bool clearSortFieldId = false,
    bool? sortAscending,
    DateTime? archivedAt,
    bool clearArchivedAt = false,
    DateTime? deletedAt,
    bool clearDeletedAt = false,
    int? version,
    bool bumpVersion = true,
  }) => RankingCategory(
    id: id,
    createdAt: createdAt,
    updatedAt: utcNow(),
    version: version ?? (bumpVersion ? this.version + 1 : this.version),
    deletedAt: clearDeletedAt ? null : (deletedAt ?? this.deletedAt),
    name: name ?? this.name,
    colorValue: colorValue ?? this.colorValue,
    iconKey: iconKey ?? this.iconKey,
    sortOrder: sortOrder ?? this.sortOrder,
    childUnitsEnabled: childUnitsEnabled ?? this.childUnitsEnabled,
    childUnitLabel: childUnitLabel ?? this.childUnitLabel,
    imagesOnParent: imagesOnParent ?? this.imagesOnParent,
    imagesOnChild: imagesOnChild ?? this.imagesOnChild,
    parentScoreMax: parentScoreMax ?? this.parentScoreMax,
    childScoreMax: childScoreMax ?? this.childScoreMax,
    parentScorePrecision: parentScorePrecision ?? this.parentScorePrecision,
    childScorePrecision: childScorePrecision ?? this.childScorePrecision,
    parentTemplate: parentTemplate ?? this.parentTemplate,
    childTemplate: childTemplate ?? this.childTemplate,
    sortMode: sortMode ?? this.sortMode,
    sortFieldId: clearSortFieldId ? null : (sortFieldId ?? this.sortFieldId),
    sortAscending: sortAscending ?? this.sortAscending,
    archivedAt: clearArchivedAt ? null : (archivedAt ?? this.archivedAt),
  );
}

/// The most structured tags one parent may carry.
///
/// A cap rather than an unbounded list because the row only ever shows two of
/// them: past ten the field has stopped being a classification and become a
/// second notes box.
const maxRankingParentTags = 10;

/// What a structured tag is allowed to look like: word characters, with inner
/// hyphens joining them into one token.
///
/// The same family as `journalTagPattern`, anchored — a note tag is *found*
/// inside prose, a structured tag *is* the whole string. The hyphen is what
/// lets `rom-com` be one tag; a space would be two, so it is refused rather
/// than joined on the user's behalf.
final rankingTagPattern = RegExp(r'^[A-Za-z0-9_]+(?:-[A-Za-z0-9_]+)*$');

/// Cleans a list of typed or imported tag tokens into what a parent stores.
///
/// Lowercases rather than keeping the typed casing: two devices that spell the
/// same genre `Thai` and `thai` would otherwise put two entries in the filter
/// vocab for one tag, and there is no later moment at which they could be
/// merged. Tokens that are not a legal tag are dropped, not repaired — a paste
/// of `rom com` becomes nothing rather than a `rom-com` the user never typed.
List<String> normalizeRankingTags(Iterable<String> raw) {
  final tags = <String>[];
  final seen = <String>{};
  for (final token in raw) {
    final stripped = token.trim().replaceFirst(RegExp(r'^#+'), '').trim();
    if (stripped.isEmpty) continue;
    if (!rankingTagPattern.hasMatch(stripped)) continue;
    final tag = stripped.toLowerCase();
    if (!seen.add(tag)) continue;
    tags.add(tag);
    if (tags.length == maxRankingParentTags) break;
  }
  return tags;
}

String encodeRankingTags(List<String> tags) => jsonEncode(tags);

List<String> decodeRankingTags(String? json) {
  if (json == null || json.isEmpty) return const [];
  final decoded = jsonDecode(json);
  if (decoded is! List) return const [];
  return normalizeRankingTags([
    for (final entry in decoded)
      if (entry is String) entry,
  ]);
}

/// One tracked thing: a show, a restaurant.
///
/// [overallScore] is the only thing that decides which of the page's two
/// sections this appears in, which is why [status] holds no `ranked` case.
class RankingParent extends SoftDeletable {
  const RankingParent({
    required super.id,
    required super.createdAt,
    required super.updatedAt,
    super.version,
    super.deletedAt,
    required this.categoryId,
    required this.title,
    this.overallScore,
    this.notes = '',
    this.fieldValues = const {},
    this.tags = const [],
    this.status = RankingStatus.queued,
    this.starred = false,
    this.queueSortOrder = 0,
  });

  /// Immutable after create: entries do not move between categories, and their
  /// field values would not survive it if they did.
  final String categoryId;

  final String title;

  /// Null = unranked. Set = ranked, whatever [status] says.
  final double? overallScore;

  final String notes;
  final Map<String, RankingFieldValue> fieldValues;

  /// Structured classification tags — genre, cuisine — in the order the user
  /// added them. Nothing to do with the `#tags` written inside [notes]: those
  /// stay freeform annotation, and only these reach the row and the filter.
  final List<String> tags;

  /// Only read while unranked.
  final RankingStatus status;

  /// Pins the row to the top of whichever section it is in. One flag rather
  /// than two because a star is cleared on every crossing between the
  /// sections, so the two could never hold different values at once.
  final bool starred;

  /// Manual position among queued rows. In-progress rows are ordered by their
  /// own rules and ignore it.
  final int queueSortOrder;

  bool get isRanked => overallScore != null;

  RankingParent copyWith({
    String? title,
    double? overallScore,
    bool clearOverallScore = false,
    String? notes,
    Map<String, RankingFieldValue>? fieldValues,
    List<String>? tags,
    RankingStatus? status,
    bool? starred,
    int? queueSortOrder,
    DateTime? createdAt,
    DateTime? deletedAt,
    bool clearDeletedAt = false,
    int? version,
    bool bumpVersion = true,
  }) => RankingParent(
    id: id,
    createdAt: createdAt ?? this.createdAt,
    updatedAt: utcNow(),
    version: version ?? (bumpVersion ? this.version + 1 : this.version),
    deletedAt: clearDeletedAt ? null : (deletedAt ?? this.deletedAt),
    categoryId: categoryId,
    title: title ?? this.title,
    overallScore: clearOverallScore
        ? null
        : (overallScore ?? this.overallScore),
    notes: notes ?? this.notes,
    fieldValues: fieldValues ?? this.fieldValues,
    tags: tags ?? this.tags,
    status: status ?? this.status,
    starred: starred ?? this.starred,
    queueSortOrder: queueSortOrder ?? this.queueSortOrder,
  );
}

/// One unit under a parent: an episode, a dish.
///
/// Flat — there are no seasons in v1 — and ordered by [sortOrder] alone, which
/// new children join the end of and only a drag rewrites.
class RankingChild extends SoftDeletable {
  const RankingChild({
    required super.id,
    required super.createdAt,
    required super.updatedAt,
    super.version,
    super.deletedAt,
    required this.parentId,
    required this.name,
    this.overallScore,
    this.notes = '',
    this.fieldValues = const {},
    this.sortOrder = 0,
  });

  final String parentId;
  final String name;

  /// Optional: a child can carry notes and field scores without one, and the
  /// parent's average-from-children button skips it while it is null.
  final double? overallScore;

  final String notes;
  final Map<String, RankingFieldValue> fieldValues;

  /// Saved manual order. A view sort never writes it.
  final int sortOrder;

  RankingChild copyWith({
    String? name,
    double? overallScore,
    bool clearOverallScore = false,
    String? notes,
    Map<String, RankingFieldValue>? fieldValues,
    int? sortOrder,
    DateTime? createdAt,
    DateTime? deletedAt,
    bool clearDeletedAt = false,
    int? version,
    bool bumpVersion = true,
  }) => RankingChild(
    id: id,
    createdAt: createdAt ?? this.createdAt,
    updatedAt: utcNow(),
    version: version ?? (bumpVersion ? this.version + 1 : this.version),
    deletedAt: clearDeletedAt ? null : (deletedAt ?? this.deletedAt),
    parentId: parentId,
    name: name ?? this.name,
    overallScore: clearOverallScore
        ? null
        : (overallScore ?? this.overallScore),
    notes: notes ?? this.notes,
    fieldValues: fieldValues ?? this.fieldValues,
    sortOrder: sortOrder ?? this.sortOrder,
  );
}

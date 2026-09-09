import 'package:voyager/core/utils/ids.dart';
import 'package:voyager/domain/models/soft_deletable.dart';

/// A job application.
///
/// [status] and [company] are stored as free strings rather than foreign keys
/// on purpose: a stage the user later deletes leaves the application readable
/// as an orphan, and removing a company from the suggestion list never
/// rewrites the applications that used it.
class JobApplication extends SoftDeletable {
  const JobApplication({
    required super.id,
    required super.createdAt,
    required super.updatedAt,
    super.version,
    super.deletedAt,
    required this.company,
    required this.title,
    required this.status,
    required this.dateApplied,
    this.applicationUrl,
    this.notes,
    this.seasonIds = const [],
  });

  final String company;
  final String title;

  /// The stage name as it stood when it was set. May no longer match any
  /// entry in the stage list — see [JobStage].
  final String status;

  /// The day the application went out. The sparkline buckets on this, not on
  /// [createdAt], so backdating an application moves its tally.
  final DateTime dateApplied;

  final String? applicationUrl;
  final String? notes;

  /// The seasons this application belongs to, empty when it is filed under
  /// none. An application may sit in more than one cycle at once — a role
  /// re-posted for a later term is the same application to the user.
  ///
  /// Not an archive flag: whether an application is archived is decided by its
  /// *seasons'* [JobSeason.archivedAt], and only once every one of them is
  /// retired. See [jobIsArchived].
  final List<String> seasonIds;

  JobApplication copyWith({
    String? company,
    String? title,
    String? status,
    DateTime? dateApplied,
    String? applicationUrl,
    bool clearApplicationUrl = false,
    String? notes,
    bool clearNotes = false,
    List<String>? seasonIds,
    DateTime? deletedAt,
    int? version,
    bool bumpVersion = true,
  }) {
    return JobApplication(
      id: id,
      createdAt: createdAt,
      updatedAt: utcNow(),
      version: version ?? (bumpVersion ? this.version + 1 : this.version),
      deletedAt: deletedAt ?? this.deletedAt,
      company: company ?? this.company,
      title: title ?? this.title,
      status: status ?? this.status,
      dateApplied: dateApplied ?? this.dateApplied,
      applicationUrl: clearApplicationUrl
          ? null
          : (applicationUrl ?? this.applicationUrl),
      notes: clearNotes ? null : (notes ?? this.notes),
      seasonIds: seasonIds ?? this.seasonIds,
    );
  }
}

/// One entry in an application's status timeline.
///
/// Append-only history: the strings are copied in as they read at the time, so
/// renaming a stage afterwards leaves past events describing what the pipeline
/// actually looked like when the move happened.
class JobStatusEvent extends SoftDeletable {
  const JobStatusEvent({
    required super.id,
    required super.createdAt,
    required super.updatedAt,
    super.version,
    super.deletedAt,
    required this.applicationId,
    this.fromStatus,
    required this.toStatus,
    required this.changedAt,
  });

  final String applicationId;

  /// Null on the event recorded when the application was created.
  final String? fromStatus;
  final String toStatus;
  final DateTime changedAt;

  JobStatusEvent copyWith({
    DateTime? deletedAt,
    int? version,
    bool bumpVersion = true,
  }) {
    return JobStatusEvent(
      id: id,
      createdAt: createdAt,
      updatedAt: utcNow(),
      version: version ?? (bumpVersion ? this.version + 1 : this.version),
      deletedAt: deletedAt ?? this.deletedAt,
      applicationId: applicationId,
      fromStatus: fromStatus,
      toStatus: toStatus,
      changedAt: changedAt,
    );
  }
}

/// A pipeline stage. [sortOrder] is display order only — any application may
/// move to any stage at any time, in either direction.
class JobStage extends SoftDeletable {
  const JobStage({
    required super.id,
    required super.createdAt,
    required super.updatedAt,
    super.version,
    super.deletedAt,
    required this.name,
    this.sortOrder = 0,
    this.colorValue,
  });

  final String name;
  final int sortOrder;

  /// The colour the user picked for this stage, or null while it has never
  /// been set. Nullable rather than defaulted: an unset stage keeps the
  /// position-derived colour the header has always given it, so adding the
  /// field changes nothing on screen until a colour is actually chosen.
  final int? colorValue;

  JobStage copyWith({
    String? name,
    int? sortOrder,
    int? colorValue,
    bool clearColorValue = false,
    DateTime? deletedAt,
    int? version,
    bool bumpVersion = true,
  }) {
    return JobStage(
      id: id,
      createdAt: createdAt,
      updatedAt: utcNow(),
      version: version ?? (bumpVersion ? this.version + 1 : this.version),
      deletedAt: deletedAt ?? this.deletedAt,
      name: name ?? this.name,
      sortOrder: sortOrder ?? this.sortOrder,
      colorValue: clearColorValue ? null : (colorValue ?? this.colorValue),
    );
  }
}

/// An entry in the company typeahead list. Not a foreign key for
/// [JobApplication.company] — deleting one leaves applications untouched.
class JobCompany extends SoftDeletable {
  const JobCompany({
    required super.id,
    required super.createdAt,
    required super.updatedAt,
    super.version,
    super.deletedAt,
    required this.name,
    this.categoryId,
  });

  final String name;

  /// At most one category per company (§4.5), so the assignment lives here
  /// rather than in a join table.
  final String? categoryId;

  JobCompany copyWith({
    String? name,
    String? categoryId,
    bool clearCategoryId = false,
    DateTime? deletedAt,
    int? version,
    bool bumpVersion = true,
  }) {
    return JobCompany(
      id: id,
      createdAt: createdAt,
      updatedAt: utcNow(),
      version: version ?? (bumpVersion ? this.version + 1 : this.version),
      deletedAt: deletedAt ?? this.deletedAt,
      name: name ?? this.name,
      categoryId: clearCategoryId ? null : (categoryId ?? this.categoryId),
    );
  }
}

/// A named colour group companies can be filed under.
class JobCategory extends SoftDeletable {
  const JobCategory({
    required super.id,
    required super.createdAt,
    required super.updatedAt,
    super.version,
    super.deletedAt,
    required this.name,
    required this.colorValue,
    this.sortOrder = 0,
  });

  final String name;
  final int colorValue;
  final int sortOrder;

  JobCategory copyWith({
    String? name,
    int? colorValue,
    int? sortOrder,
    DateTime? deletedAt,
    int? version,
    bool bumpVersion = true,
  }) {
    return JobCategory(
      id: id,
      createdAt: createdAt,
      updatedAt: utcNow(),
      version: version ?? (bumpVersion ? this.version + 1 : this.version),
      deletedAt: deletedAt ?? this.deletedAt,
      name: name ?? this.name,
      colorValue: colorValue ?? this.colorValue,
      sortOrder: sortOrder ?? this.sortOrder,
    );
  }
}

/// A named application cycle, e.g. `Fall 2025`.
///
/// A season is picked while tracking an application, not applied to it after
/// the fact — filing something under a season says when it went out, and says
/// nothing yet about whether that cycle is over.
///
/// Archiving is a property of the *season*: setting [archivedAt] retires the
/// whole cycle at once, which is what hides its applications from the default
/// list and what takes the season out of the picker for new ones. [sortOrder]
/// is the user's manual order, and it is the order the picker offers too.
class JobSeason extends SoftDeletable {
  const JobSeason({
    required super.id,
    required super.createdAt,
    required super.updatedAt,
    super.version,
    super.deletedAt,
    required this.name,
    this.sortOrder = 0,
    this.archivedAt,
  });

  final String name;
  final int sortOrder;

  /// When the season was retired, or null while it is still running. Kept as
  /// an instant rather than a bool so the archive carries its own date.
  final DateTime? archivedAt;

  bool get isArchived => archivedAt != null;

  JobSeason copyWith({
    String? name,
    int? sortOrder,
    DateTime? archivedAt,
    bool clearArchivedAt = false,
    DateTime? deletedAt,
    int? version,
    bool bumpVersion = true,
  }) {
    return JobSeason(
      id: id,
      createdAt: createdAt,
      updatedAt: utcNow(),
      version: version ?? (bumpVersion ? this.version + 1 : this.version),
      deletedAt: deletedAt ?? this.deletedAt,
      name: name ?? this.name,
      sortOrder: sortOrder ?? this.sortOrder,
      archivedAt: clearArchivedAt ? null : (archivedAt ?? this.archivedAt),
    );
  }
}

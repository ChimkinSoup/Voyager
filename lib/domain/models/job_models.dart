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
    this.seasonId,
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

  /// Null while the application is active; set once archived into a season.
  final String? seasonId;

  bool get isArchived => seasonId != null;

  JobApplication copyWith({
    String? company,
    String? title,
    String? status,
    DateTime? dateApplied,
    String? applicationUrl,
    bool clearApplicationUrl = false,
    String? notes,
    bool clearNotes = false,
    String? seasonId,
    bool clearSeasonId = false,
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
      seasonId: clearSeasonId ? null : (seasonId ?? this.seasonId),
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
  });

  final String name;
  final int sortOrder;

  JobStage copyWith({
    String? name,
    int? sortOrder,
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

/// A named archive bucket, e.g. `Fall 2025`.
class JobSeason extends SoftDeletable {
  const JobSeason({
    required super.id,
    required super.createdAt,
    required super.updatedAt,
    super.version,
    super.deletedAt,
    required this.name,
    this.sortOrder = 0,
  });

  final String name;
  final int sortOrder;

  JobSeason copyWith({
    String? name,
    int? sortOrder,
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
    );
  }
}

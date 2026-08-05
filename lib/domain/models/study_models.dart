import 'package:voyager/domain/models/soft_deletable.dart';

enum StudyGrade { fail, hard, good, easy }

class StudyFolder extends SoftDeletable {
  const StudyFolder({
    required super.id,
    required super.createdAt,
    required super.updatedAt,
    super.version,
    super.deletedAt,
    required this.name,
    this.parentFolderId,
  });

  final String name;
  final String? parentFolderId;

  StudyFolder copyWith({
    String? name,
    String? parentFolderId,
    bool clearParentFolderId = false,
    DateTime? deletedAt,
    int? version,
    bool bumpVersion = true,
  }) {
    return StudyFolder(
      id: id,
      createdAt: createdAt,
      updatedAt: DateTime.now().toUtc(),
      version: version ?? (bumpVersion ? this.version + 1 : this.version),
      deletedAt: deletedAt ?? this.deletedAt,
      name: name ?? this.name,
      parentFolderId: clearParentFolderId
          ? null
          : (parentFolderId ?? this.parentFolderId),
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'parentFolderId': parentFolderId,
    'createdAt': createdAt.toUtc().toIso8601String(),
    'updatedAt': updatedAt.toUtc().toIso8601String(),
    'version': version,
    'deletedAt': deletedAt?.toUtc().toIso8601String(),
  };

  factory StudyFolder.fromJson(Map<String, dynamic> json) {
    return StudyFolder(
      id: json['id'] as String,
      name: json['name'] as String,
      parentFolderId: json['parentFolderId'] as String?,
      createdAt: DateTime.parse(json['createdAt'] as String).toUtc(),
      updatedAt: DateTime.parse(json['updatedAt'] as String).toUtc(),
      version: json['version'] as int? ?? 0,
      deletedAt: json['deletedAt'] != null
          ? DateTime.parse(json['deletedAt'] as String).toUtc()
          : null,
    );
  }
}

class StudyDeck extends SoftDeletable {
  const StudyDeck({
    required super.id,
    required super.createdAt,
    required super.updatedAt,
    super.version,
    super.deletedAt,
    required this.name,
    this.parentFolderId,
  });

  final String name;
  final String? parentFolderId;

  StudyDeck copyWith({
    String? name,
    String? parentFolderId,
    bool clearParentFolderId = false,
    DateTime? deletedAt,
    int? version,
    bool bumpVersion = true,
  }) {
    return StudyDeck(
      id: id,
      createdAt: createdAt,
      updatedAt: DateTime.now().toUtc(),
      version: version ?? (bumpVersion ? this.version + 1 : this.version),
      deletedAt: deletedAt ?? this.deletedAt,
      name: name ?? this.name,
      parentFolderId: clearParentFolderId
          ? null
          : (parentFolderId ?? this.parentFolderId),
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'parentFolderId': parentFolderId,
    'createdAt': createdAt.toUtc().toIso8601String(),
    'updatedAt': updatedAt.toUtc().toIso8601String(),
    'version': version,
    'deletedAt': deletedAt?.toUtc().toIso8601String(),
  };

  factory StudyDeck.fromJson(Map<String, dynamic> json) {
    return StudyDeck(
      id: json['id'] as String,
      name: json['name'] as String,
      parentFolderId: json['parentFolderId'] as String?,
      createdAt: DateTime.parse(json['createdAt'] as String).toUtc(),
      updatedAt: DateTime.parse(json['updatedAt'] as String).toUtc(),
      version: json['version'] as int? ?? 0,
      deletedAt: json['deletedAt'] != null
          ? DateTime.parse(json['deletedAt'] as String).toUtc()
          : null,
    );
  }
}

/// A single flashcard with its permanent SM-2-style SRS state. [interval] is
/// in days; `interval <= 0` means the card has never had a successful review
/// (see `applyStudyGrade` in study_srs_engine.dart for why that base case
/// can't just fall out of the multiplicative formula).
class StudyCard extends SoftDeletable {
  const StudyCard({
    required super.id,
    required super.createdAt,
    required super.updatedAt,
    super.version,
    super.deletedAt,
    required this.deckId,
    required this.frontText,
    required this.backText,
    this.interval = 0,
    this.ease = 2.5,
    required this.dueAt,
    this.reviewCount = 0,
  });

  final String deckId;
  final String frontText;
  final String backText;
  final double interval;
  final double ease;
  final DateTime dueAt;
  final int reviewCount;

  bool get isNew => reviewCount == 0;
  bool get isLearning => reviewCount > 0 && interval < 1;

  StudyCard copyWith({
    String? deckId,
    String? frontText,
    String? backText,
    double? interval,
    double? ease,
    DateTime? dueAt,
    int? reviewCount,
    DateTime? deletedAt,
    int? version,
    bool bumpVersion = true,
  }) {
    return StudyCard(
      id: id,
      createdAt: createdAt,
      updatedAt: DateTime.now().toUtc(),
      version: version ?? (bumpVersion ? this.version + 1 : this.version),
      deletedAt: deletedAt ?? this.deletedAt,
      deckId: deckId ?? this.deckId,
      frontText: frontText ?? this.frontText,
      backText: backText ?? this.backText,
      interval: interval ?? this.interval,
      ease: ease ?? this.ease,
      dueAt: dueAt ?? this.dueAt,
      reviewCount: reviewCount ?? this.reviewCount,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'deckId': deckId,
    'frontText': frontText,
    'backText': backText,
    'interval': interval,
    'ease': ease,
    'dueAt': dueAt.toUtc().toIso8601String(),
    'reviewCount': reviewCount,
    'createdAt': createdAt.toUtc().toIso8601String(),
    'updatedAt': updatedAt.toUtc().toIso8601String(),
    'version': version,
    'deletedAt': deletedAt?.toUtc().toIso8601String(),
  };

  factory StudyCard.fromJson(Map<String, dynamic> json) {
    return StudyCard(
      id: json['id'] as String,
      deckId: json['deckId'] as String,
      frontText: json['frontText'] as String,
      backText: json['backText'] as String,
      interval: (json['interval'] as num?)?.toDouble() ?? 0,
      ease: (json['ease'] as num?)?.toDouble() ?? 2.5,
      dueAt: DateTime.parse(json['dueAt'] as String).toUtc(),
      reviewCount: json['reviewCount'] as int? ?? 0,
      createdAt: DateTime.parse(json['createdAt'] as String).toUtc(),
      updatedAt: DateTime.parse(json['updatedAt'] as String).toUtc(),
      version: json['version'] as int? ?? 0,
      deletedAt: json['deletedAt'] != null
          ? DateTime.parse(json['deletedAt'] as String).toUtc()
          : null,
    );
  }
}

/// One graded review of a card in real (non-cram) SRS mode. Append-only —
/// used to answer "cards reviewed today/total" without approximating from
/// card state. Cram-mode grades never create these (STUDY.md: cram must not
/// touch persisted SRS metadata).
class StudyReviewLog {
  const StudyReviewLog({
    required this.id,
    required this.cardId,
    required this.grade,
    required this.reviewedAt,
  });

  final String id;
  final String cardId;
  final StudyGrade grade;
  final DateTime reviewedAt;

  Map<String, dynamic> toJson() => {
    'id': id,
    'cardId': cardId,
    'grade': grade.name,
    'reviewedAt': reviewedAt.toUtc().toIso8601String(),
  };

  factory StudyReviewLog.fromJson(Map<String, dynamic> json) {
    return StudyReviewLog(
      id: json['id'] as String,
      cardId: json['cardId'] as String,
      grade: StudyGrade.values.byName(json['grade'] as String? ?? 'good'),
      reviewedAt: DateTime.parse(json['reviewedAt'] as String).toUtc(),
    );
  }
}

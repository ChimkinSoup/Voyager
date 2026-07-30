import 'package:voyager/domain/models/soft_deletable.dart';

class DreamEntry extends SoftDeletable {
  const DreamEntry({
    required super.id,
    required super.createdAt,
    required super.updatedAt,
    super.version,
    super.deletedAt,
    required this.title,
    required this.body,
    required this.entryDate,
    this.notes,
    this.tags = const [],
  });

  final String title;
  final String body;
  final String? notes;
  final DateTime entryDate;
  final List<String> tags;

  DreamEntry copyWith({
    String? title,
    String? body,
    String? notes,
    DateTime? entryDate,
    List<String>? tags,
    DateTime? deletedAt,
    int? version,
    bool bumpVersion = true,
  }) {
    return DreamEntry(
      id: id,
      createdAt: createdAt,
      updatedAt: DateTime.now().toUtc(),
      version: version ?? (bumpVersion ? this.version + 1 : this.version),
      deletedAt: deletedAt ?? this.deletedAt,
      title: title ?? this.title,
      body: body ?? this.body,
      notes: notes ?? this.notes,
      entryDate: entryDate ?? this.entryDate,
      tags: tags ?? this.tags,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'createdAt': createdAt.toUtc().toIso8601String(),
    'updatedAt': updatedAt.toUtc().toIso8601String(),
    'version': version,
    'deletedAt': deletedAt?.toUtc().toIso8601String(),
    'title': title,
    'body': body,
    'notes': notes,
    'entryDate': entryDate.toUtc().toIso8601String(),
    'tags': tags,
  };

  factory DreamEntry.fromJson(Map<String, dynamic> json) {
    return DreamEntry(
      id: json['id'] as String,
      createdAt: DateTime.parse(json['createdAt'] as String).toUtc(),
      updatedAt: DateTime.parse(json['updatedAt'] as String).toUtc(),
      version: json['version'] as int? ?? 0,
      deletedAt: json['deletedAt'] != null
          ? DateTime.parse(json['deletedAt'] as String).toUtc()
          : null,
      title: json['title'] as String,
      body: json['body'] as String,
      notes: json['notes'] as String?,
      entryDate: DateTime.parse(json['entryDate'] as String).toUtc(),
      tags: List<String>.from(json['tags'] as List? ?? const []),
    );
  }
}

int compareDreamEntriesNewestFirst(DreamEntry a, DreamEntry b) {
  final byDate = b.entryDate.compareTo(a.entryDate);
  if (byDate != 0) return byDate;
  final byCreated = b.createdAt.compareTo(a.createdAt);
  if (byCreated != 0) return byCreated;
  return b.id.compareTo(a.id);
}

List<DreamEntry> sortDreamEntriesNewestFirst(Iterable<DreamEntry> entries) {
  final sorted = entries.toList()..sort(compareDreamEntriesNewestFirst);
  return sorted;
}

/// One named role description the Jobs header copies to the clipboard
/// (`JOBS_EXPERIENCE_SNIPPETS_HLD.md`).
///
/// Only [description] is ever copied; [name] is the chip label. Order is the
/// position in `AppSettings.jobExperienceSnippets` — the first three are the
/// header's visible chips — so there is no sort field.
class JobExperienceSnippet {
  const JobExperienceSnippet({
    required this.id,
    required this.name,
    required this.description,
  });

  /// Stable identity for edits, reorders and deletes. Assigned on create and
  /// never changed, so renaming an entry keeps it the same row.
  final String id;

  /// Trimmed and non-empty. Enforced where snippets are written (the settings
  /// editor), not here, for the same reason `Snippet` leaves trigger rules to
  /// its dialog: a record arriving from sync must still parse.
  final String name;

  /// Stored exactly as last saved — leading/trailing whitespace included. May
  /// be empty; copying it then writes `""`.
  final String description;

  JobExperienceSnippet copyWith({String? name, String? description}) {
    return JobExperienceSnippet(
      id: id,
      name: name ?? this.name,
      description: description ?? this.description,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'description': description,
  };

  /// Null for anything that isn't a usable record — a non-map entry, or one
  /// with no id or no name. Sync and import both feed this untrusted data, and
  /// one bad row must not take the rest of the list with it.
  static JobExperienceSnippet? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['id'];
    final name = raw['name'];
    if (id is! String || id.isEmpty) return null;
    if (name is! String || name.trim().isEmpty) return null;
    final description = raw['description'];
    return JobExperienceSnippet(
      id: id,
      name: name,
      description: description is String ? description : '',
    );
  }

  static List<JobExperienceSnippet> listFromJson(Object? raw) {
    if (raw is! List) return const [];
    final out = <JobExperienceSnippet>[];
    for (final entry in raw) {
      final snippet = JobExperienceSnippet.fromJson(entry);
      if (snippet != null) out.add(snippet);
    }
    return out;
  }

  @override
  bool operator ==(Object other) =>
      other is JobExperienceSnippet &&
      other.id == id &&
      other.name == name &&
      other.description == description;

  @override
  int get hashCode => Object.hash(id, name, description);
}

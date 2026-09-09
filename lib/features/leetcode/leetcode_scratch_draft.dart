/// Bumped whenever the persisted shape changes in a way an older blob can't be
/// read as. A blob from a different version is discarded rather than migrated —
/// it is one abandoned session's scratch work, not user data worth carrying
/// forward.
const int kLeetCodeScratchSessionVersion = 1;

/// One problem's scratch pad, as it stood the last time the session flushed.
///
/// Deliberately not a [LeetCodeSolution]: nothing here is an answer the user
/// stands behind. It never reaches the problem row, the SRS schedule, or the
/// sync pipeline — it is a place to type while the card is up.
class LeetCodeScratchEntry {
  const LeetCodeScratchEntry({
    this.code = '',
    required this.language,
    this.expanded = false,
  });

  final String code;
  final String language;

  /// Whether this problem's pad was fullscreen. Kept per problem rather than
  /// per session so stepping back to a problem restores the surface the user
  /// left it in, not whatever the last card happened to be showing.
  final bool expanded;

  LeetCodeScratchEntry copyWith({
    String? code,
    String? language,
    bool? expanded,
  }) => LeetCodeScratchEntry(
    code: code ?? this.code,
    language: language ?? this.language,
    expanded: expanded ?? this.expanded,
  );

  Map<String, dynamic> toJson() => {
    'code': code,
    'language': language,
    'expanded': expanded,
  };

  factory LeetCodeScratchEntry.fromJson(Map<String, dynamic> json) =>
      LeetCodeScratchEntry(
        code: json['code'] as String? ?? '',
        language: json['language'] as String? ?? 'python',
        expanded: json['expanded'] as bool? ?? false,
      );
}

/// Every pad typed during one Study or Cram run, keyed by problem id.
///
/// This exists on disk for exactly one reason: a session that ends the normal
/// way deletes it, so a file still sitting there when a session opens means the
/// last one died mid-run. See [isOrphan].
class LeetCodeScratchSession {
  const LeetCodeScratchSession({
    required this.sessionId,
    required this.problemIds,
    required this.startedAt,
    this.endedNormally = false,
    this.lastLanguage,
    this.scratches = const {},
  });

  final String sessionId;

  /// The problems the session opened over. Only used to tell the user which
  /// run the recovery offer is about — restoring never replays queue position.
  final Set<String> problemIds;

  final DateTime startedAt;

  /// Written `false` for as long as the session is live. A clean exit deletes
  /// the file outright, so this is belt-and-braces: a blob that somehow
  /// survives a clean exit still must not be offered back.
  final bool endedNormally;

  /// The language last chosen in the pad, so the next problem opens in the one
  /// the user is actually working in rather than re-deriving from its
  /// solutions every card.
  final String? lastLanguage;

  final Map<String, LeetCodeScratchEntry> scratches;

  /// Whether this blob is worth offering back: it has to be from a run that
  /// never ended cleanly, and it has to hold something the user would miss.
  bool get isOrphan => !endedNormally && hasText;

  bool get hasText => scratches.values.any((e) => e.code.trim().isNotEmpty);

  LeetCodeScratchSession copyWith({
    bool? endedNormally,
    String? lastLanguage,
    Map<String, LeetCodeScratchEntry>? scratches,
  }) => LeetCodeScratchSession(
    sessionId: sessionId,
    problemIds: problemIds,
    startedAt: startedAt,
    endedNormally: endedNormally ?? this.endedNormally,
    lastLanguage: lastLanguage ?? this.lastLanguage,
    scratches: scratches ?? this.scratches,
  );

  Map<String, dynamic> toJson() => {
    'version': kLeetCodeScratchSessionVersion,
    'sessionId': sessionId,
    'problemIds': problemIds.toList(),
    'startedAt': startedAt.toUtc().toIso8601String(),
    'endedNormally': endedNormally,
    'lastLanguage': lastLanguage,
    'scratches': {
      for (final entry in scratches.entries) entry.key: entry.value.toJson(),
    },
  };

  /// Throws on anything it can't read, which the store turns into "no session".
  factory LeetCodeScratchSession.fromJson(Map<String, dynamic> json) {
    final version = json['version'] as int?;
    if (version != kLeetCodeScratchSessionVersion) {
      throw FormatException('Unsupported scratch session version: $version');
    }
    return LeetCodeScratchSession(
      sessionId: json['sessionId'] as String? ?? '',
      problemIds: {
        for (final id in (json['problemIds'] as List<dynamic>? ?? const []))
          id as String,
      },
      startedAt:
          DateTime.tryParse(json['startedAt'] as String? ?? '')?.toUtc() ??
          DateTime.now().toUtc(),
      endedNormally: json['endedNormally'] as bool? ?? false,
      lastLanguage: json['lastLanguage'] as String?,
      scratches: {
        for (final entry
            in (json['scratches'] as Map<dynamic, dynamic>? ?? const {})
                .entries)
          entry.key as String: LeetCodeScratchEntry.fromJson(
            Map<String, dynamic>.from(entry.value as Map),
          ),
      },
    );
  }
}

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
/// This rides inside the run's session checkpoint rather than in a file of its
/// own: scratch belongs to the session it was typed in, so it survives exactly
/// as long as that session does — through a Back to deck or a process death,
/// and no longer than a finish or a Start over. Which session it is, and when
/// it began, are the checkpoint's to say; this is only what was typed.
class LeetCodeScratchSession {
  const LeetCodeScratchSession({this.lastLanguage, this.scratches = const {}});

  /// The language last chosen in the pad, so the next problem opens in the one
  /// the user is actually working in rather than re-deriving from its
  /// solutions every card.
  final String? lastLanguage;

  final Map<String, LeetCodeScratchEntry> scratches;

  Map<String, dynamic> toJson() => {
    'lastLanguage': lastLanguage,
    'scratches': {
      for (final entry in scratches.entries) entry.key: entry.value.toJson(),
    },
  };

  factory LeetCodeScratchSession.fromJson(
    Map<String, dynamic> json,
  ) => LeetCodeScratchSession(
    lastLanguage: json['lastLanguage'] as String?,
    scratches: {
      for (final entry
          in (json['scratches'] as Map<dynamic, dynamic>? ?? const {}).entries)
        entry.key as String: LeetCodeScratchEntry.fromJson(
          Map<String, dynamic>.from(entry.value as Map),
        ),
    },
  );
}

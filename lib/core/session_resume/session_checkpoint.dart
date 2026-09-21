/// Bumped whenever the persisted shape changes in a way an older file cannot
/// be read as. A file from another version is discarded rather than migrated —
/// it is one unfinished session, not a record worth carrying forward.
const int kSessionCheckpointVersion = 1;

/// Which of the four session surfaces a checkpoint belongs to.
///
/// One file per kind and scope: opening Study must never pick up what Cram
/// left behind, and the Hub's library-wide run must never pick up a deck's.
enum SessionCheckpointKind {
  leetcodeStudy,
  leetcodeCram,
  studySession,
  studyCram,
}

/// One graded card or problem, as the session's undo stack holds it.
///
/// [before] and [after] are the whole row either side of the grade — the same
/// snapshots the in-memory step keeps, so an undo taken after a restart puts
/// back exactly the state the grade replaced rather than re-deriving one. The
/// grade itself is already on disk; this is only what it takes to reverse it.
///
/// The queues are id lists. The rows they name are resolved against live data
/// on the way back in, so a card edited while the session was away comes back
/// as it now stands.
class GradeStepDto {
  const GradeStepDto({
    required this.before,
    required this.after,
    required this.log,
    required this.queueBefore,
    required this.queueAfter,
  });

  /// `StudyCard` / `LeetCodeProblem` JSON, left opaque here: the checkpoint
  /// carries four surfaces' rows and has no business knowing either model.
  final Map<String, dynamic> before;
  final Map<String, dynamic> after;

  /// The review-log row the grade wrote, tombstoned on undo and revived on
  /// redo.
  final Map<String, dynamic> log;

  final List<String> queueBefore;
  final List<String> queueAfter;

  /// The row this step graded — what a prune checks for liveness.
  String get id => after['id'] as String;

  Map<String, dynamic> toJson() => {
    'before': before,
    'after': after,
    'log': log,
    'queueBefore': queueBefore,
    'queueAfter': queueAfter,
  };

  factory GradeStepDto.fromJson(Map<String, dynamic> json) => GradeStepDto(
    before: _map(json['before']),
    after: _map(json['after']),
    log: _map(json['log']),
    queueBefore: _ids(json['queueBefore']),
    queueAfter: _ids(json['queueAfter']),
  );
}

/// The three cram buckets as id lists — the whole of a cram session's state,
/// and also the whole of one undoable decision in it.
class CramBucketsDto {
  const CramBucketsDto({
    this.bucket0 = const [],
    this.bucket1 = const [],
    this.bucket2 = const [],
  });

  final List<String> bucket0;
  final List<String> bucket1;
  final List<String> bucket2;

  Map<String, dynamic> toJson() => {'0': bucket0, '1': bucket1, '2': bucket2};

  factory CramBucketsDto.fromJson(Map<String, dynamic> json) => CramBucketsDto(
    bucket0: _ids(json['0']),
    bucket1: _ids(json['1']),
    bucket2: _ids(json['2']),
  );
}

/// An unfinished Study or Cram run, as it stood the last time it was flushed.
///
/// Device-local and never synced: a half-finished session belongs to the
/// machine it was left on. The grades it made are already written to the
/// repository — what is kept here is the arrangement around them, which is the
/// part nothing else on disk records.
class SessionCheckpoint {
  const SessionCheckpoint({
    required this.kind,
    required this.scopeKey,
    required this.sessionId,
    required this.startedAt,
    required this.updatedAt,
    this.sourceIds = const {},
    this.remainingQueue = const [],
    this.buckets,
    this.graded = const [],
    this.undone = const [],
    this.decided = const [],
    this.undoneCram = const [],
    this.scratch,
  });

  final SessionCheckpointKind kind;

  /// What the checkpoint is *of*, within its kind: a deck id for a deck's
  /// session, `hub` for the library-wide one, empty where the kind is the
  /// whole scope.
  final String scopeKey;

  final String sessionId;
  final DateTime startedAt;
  final DateTime updatedAt;

  /// Everything the session had in scope when it last reconciled. Anything
  /// eligible now and not in here is a newcomer, and joins the tail rather
  /// than the middle of the round.
  final Set<String> sourceIds;

  /// Study only — head is the card the session was on.
  final List<String> remainingQueue;

  /// Cram only.
  final CramBucketsDto? buckets;

  final List<GradeStepDto> graded;
  final List<GradeStepDto> undone;
  final List<CramBucketsDto> decided;
  final List<CramBucketsDto> undoneCram;

  /// `LeetCodeScratchSession` JSON, kept opaque for the same reason the grade
  /// steps are. Null on the Study flashcard surfaces, which have no pads.
  final Map<String, dynamic>? scratch;

  Map<String, dynamic> toJson() => {
    'version': kSessionCheckpointVersion,
    'kind': kind.name,
    'scopeKey': scopeKey,
    'sessionId': sessionId,
    'startedAt': startedAt.toUtc().toIso8601String(),
    'updatedAt': updatedAt.toUtc().toIso8601String(),
    'sourceIds': sourceIds.toList(),
    'remainingQueue': remainingQueue,
    'buckets': buckets?.toJson(),
    'graded': [for (final step in graded) step.toJson()],
    'undone': [for (final step in undone) step.toJson()],
    'decided': [for (final step in decided) step.toJson()],
    'undoneCram': [for (final step in undoneCram) step.toJson()],
    'scratch': scratch,
  };

  /// Throws on anything it cannot read, which the store turns into "no
  /// checkpoint".
  factory SessionCheckpoint.fromJson(Map<String, dynamic> json) {
    final version = json['version'] as int?;
    if (version != kSessionCheckpointVersion) {
      throw FormatException('Unsupported session checkpoint version: $version');
    }
    final buckets = json['buckets'];
    return SessionCheckpoint(
      kind: SessionCheckpointKind.values.byName(json['kind'] as String),
      scopeKey: json['scopeKey'] as String? ?? '',
      sessionId: json['sessionId'] as String? ?? '',
      startedAt: DateTime.parse(json['startedAt'] as String).toUtc(),
      updatedAt: DateTime.parse(json['updatedAt'] as String).toUtc(),
      sourceIds: _ids(json['sourceIds']).toSet(),
      remainingQueue: _ids(json['remainingQueue']),
      buckets: buckets == null ? null : CramBucketsDto.fromJson(_map(buckets)),
      graded: _steps(json['graded']),
      undone: _steps(json['undone']),
      decided: _buckets(json['decided']),
      undoneCram: _buckets(json['undoneCram']),
      scratch: json['scratch'] == null ? null : _map(json['scratch']),
    );
  }
}

Map<String, dynamic> _map(Object? value) =>
    Map<String, dynamic>.from(value as Map);

List<String> _ids(Object? value) => [
  for (final id in (value as List<dynamic>? ?? const [])) id as String,
];

List<GradeStepDto> _steps(Object? value) => [
  for (final step in (value as List<dynamic>? ?? const []))
    GradeStepDto.fromJson(_map(step)),
];

List<CramBucketsDto> _buckets(Object? value) => [
  for (final step in (value as List<dynamic>? ?? const []))
    CramBucketsDto.fromJson(_map(step)),
];

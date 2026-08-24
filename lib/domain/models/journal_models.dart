import 'package:voyager/domain/models/soft_deletable.dart';

/// The mood every new entry starts at, and what the v85 migration wrote over
/// the entries that predated it. The scale is 0–10, so this is its midpoint:
/// an entry the user never touched reads as neutral rather than unrecorded.
const int kDefaultMood = 5;

class Journal extends SoftDeletable {
  const Journal({
    required super.id,
    required super.createdAt,
    required super.updatedAt,
    super.version,
    super.deletedAt,
    required this.name,
    this.colorValue,
    this.guidedJournaling = false,
    this.promptCycleDays = 7,
    this.showMood = true,
    this.showWeather = true,
    this.showQuotes = true,
    this.includeInAllView = true,
  });

  final String name;
  final int? colorValue;
  final bool guidedJournaling;
  final int promptCycleDays;

  /// Per-journal editor chrome. Each one hides its control on the journal page
  /// without touching what an entry stores, so toggling one back on shows the
  /// values that were being tracked all along.
  ///
  /// [showMood] additionally gates aggregation: the Life Tracker's lifetime
  /// mood average only counts journals with the bar on. Storage is unaffected,
  /// so the moods come back into the average when the bar returns.
  final bool showMood;
  final bool showWeather;

  /// Gated by the global [AppSettings.showQuotes] as well — the global switch
  /// is the master, this one narrows it per journal.
  final bool showQuotes;

  /// Whether this journal's entries appear in the combined "All journals"
  /// list. Excluding a journal hides it from that list only; its entries stay
  /// in search, analytics and the tag pool.
  final bool includeInAllView;

  Journal copyWith({
    String? name,
    int? colorValue,
    bool? guidedJournaling,
    int? promptCycleDays,
    bool? showMood,
    bool? showWeather,
    bool? showQuotes,
    bool? includeInAllView,
    DateTime? deletedAt,
    bool bumpVersion = true,
  }) {
    return Journal(
      id: id,
      createdAt: createdAt,
      updatedAt: DateTime.now().toUtc(),
      version: bumpVersion ? version + 1 : version,
      deletedAt: deletedAt ?? this.deletedAt,
      name: name ?? this.name,
      colorValue: colorValue ?? this.colorValue,
      guidedJournaling: guidedJournaling ?? this.guidedJournaling,
      promptCycleDays: promptCycleDays ?? this.promptCycleDays,
      showMood: showMood ?? this.showMood,
      showWeather: showWeather ?? this.showWeather,
      showQuotes: showQuotes ?? this.showQuotes,
      includeInAllView: includeInAllView ?? this.includeInAllView,
    );
  }
}

class JournalEntry extends SoftDeletable {
  const JournalEntry({
    required super.id,
    required super.createdAt,
    required super.updatedAt,
    super.version,
    super.deletedAt,
    required this.journalId,
    required this.title,
    required this.body,
    required this.entryDate,
    this.richBodyJson,
    this.timestamp,
    this.tags = const [],
    this.mood,
    this.quoteId,
    this.customQuote,
    this.weatherIcon,
    this.guidedPrompt,
  });

  final String journalId;
  final String title;
  final String body;
  final String? richBodyJson;
  final DateTime entryDate;
  final DateTime? timestamp;
  final List<String> tags;

  /// 0–10, defaulting to [kDefaultMood] on creation. Nullable only for rows
  /// that predate that default and never got the v85 backfill — a remote copy
  /// synced down from an older build, or an import. Everything that reads a
  /// mood still has to handle null; nothing new should write one.
  final int? mood;
  final String? quoteId;
  final String? customQuote;
  final String? weatherIcon;
  final String? guidedPrompt;

  JournalEntry copyWith({
    String? journalId,
    String? title,
    String? body,
    String? richBodyJson,
    DateTime? entryDate,
    DateTime? timestamp,
    List<String>? tags,
    int? mood,
    String? quoteId,
    String? customQuote,
    String? weatherIcon,
    String? guidedPrompt,
    DateTime? deletedAt,
    int? version,
    bool bumpVersion = true,
  }) {
    return JournalEntry(
      id: id,
      createdAt: createdAt,
      updatedAt: DateTime.now().toUtc(),
      version: version ?? (bumpVersion ? this.version + 1 : this.version),
      deletedAt: deletedAt ?? this.deletedAt,
      journalId: journalId ?? this.journalId,
      title: title ?? this.title,
      body: body ?? this.body,
      richBodyJson: richBodyJson ?? this.richBodyJson,
      entryDate: entryDate ?? this.entryDate,
      timestamp: timestamp ?? this.timestamp,
      tags: tags ?? this.tags,
      mood: mood ?? this.mood,
      quoteId: quoteId ?? this.quoteId,
      customQuote: customQuote ?? this.customQuote,
      weatherIcon: weatherIcon ?? this.weatherIcon,
      guidedPrompt: guidedPrompt ?? this.guidedPrompt,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'createdAt': createdAt.toUtc().toIso8601String(),
    'updatedAt': updatedAt.toUtc().toIso8601String(),
    'version': version,
    'deletedAt': deletedAt?.toUtc().toIso8601String(),
    'journalId': journalId,
    'title': title,
    'body': body,
    'richBodyJson': richBodyJson,
    'entryDate': entryDate.toUtc().toIso8601String(),
    'timestamp': timestamp?.toUtc().toIso8601String(),
    'tags': tags,
    'mood': mood,
    'quoteId': quoteId,
    'customQuote': customQuote,
    'weatherIcon': weatherIcon,
    'guidedPrompt': guidedPrompt,
  };

  factory JournalEntry.fromJson(Map<String, dynamic> json) {
    return JournalEntry(
      id: json['id'] as String,
      createdAt: DateTime.parse(json['createdAt'] as String).toUtc(),
      updatedAt: DateTime.parse(json['updatedAt'] as String).toUtc(),
      version: json['version'] as int? ?? 0,
      deletedAt: json['deletedAt'] != null ? DateTime.parse(json['deletedAt'] as String).toUtc() : null,
      journalId: json['journalId'] as String,
      title: json['title'] as String,
      body: json['body'] as String,
      entryDate: DateTime.parse(json['entryDate'] as String).toUtc(),
      richBodyJson: json['richBodyJson'] as String?,
      timestamp: json['timestamp'] != null ? DateTime.parse(json['timestamp'] as String).toUtc() : null,
      tags: List<String>.from(json['tags'] as List? ?? const []),
      mood: json['mood'] as int?,
      quoteId: json['quoteId'] as String?,
      customQuote: json['customQuote'] as String?,
      weatherIcon: json['weatherIcon'] as String?,
      guidedPrompt: json['guidedPrompt'] as String?,
    );
  }
}

class TagColor {
  const TagColor({required this.name, required this.colorValue});

  final String name;
  final int colorValue;
}

int compareJournalEntriesNewestFirst(JournalEntry a, JournalEntry b) {
  final byDate = b.entryDate.compareTo(a.entryDate);
  if (byDate != 0) return byDate;
  final byCreated = b.createdAt.compareTo(a.createdAt);
  if (byCreated != 0) return byCreated;
  return b.id.compareTo(a.id);
}

List<JournalEntry> sortJournalEntriesNewestFirst(Iterable<JournalEntry> entries) {
  final sorted = entries.toList()..sort(compareJournalEntriesNewestFirst);
  return sorted;
}

final _firstSentenceExp = RegExp(r'^(.+?[.!?])(?:\s|$)');

String firstSentencePreview(String body) {
  final trimmed = body.trim();
  if (trimmed.isEmpty) return '';

  // Capped on both paths, not just the fallback: a list row lays this out in
  // a `maxLines: 1` Text, so an entry whose first sentence runs for a whole
  // paragraph would pay the full text-layout cost per row, per rebuild, only
  // to draw an ellipsis.
  final match = _firstSentenceExp.firstMatch(trimmed);
  final raw = match != null
      ? match.group(1)!.trim()
      : trimmed.split('\n').first.trim();
  if (raw.length <= 120) return raw;
  return '${raw.substring(0, 117)}...';
}

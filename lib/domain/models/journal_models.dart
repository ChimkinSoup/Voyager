import 'package:voyager/domain/models/soft_deletable.dart';

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
  });

  final String name;
  final int? colorValue;
  final bool guidedJournaling;
  final int promptCycleDays;

  Journal copyWith({
    String? name,
    int? colorValue,
    bool? guidedJournaling,
    int? promptCycleDays,
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
    'createdAt': createdAt.toIso8601String(),
    'updatedAt': updatedAt.toIso8601String(),
    'version': version,
    'deletedAt': deletedAt?.toIso8601String(),
    'journalId': journalId,
    'title': title,
    'body': body,
    'richBodyJson': richBodyJson,
    'entryDate': entryDate.toIso8601String(),
    'timestamp': timestamp?.toIso8601String(),
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

String firstSentencePreview(String body) {
  final trimmed = body.trim();
  if (trimmed.isEmpty) return '';

  final match = RegExp(r'^(.+?[.!?])(?:\s|$)').firstMatch(trimmed);
  if (match != null) return match.group(1)!.trim();

  final line = trimmed.split('\n').first.trim();
  if (line.length <= 120) return line;
  return '${line.substring(0, 117)}...';
}

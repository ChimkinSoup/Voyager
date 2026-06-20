import 'package:voyager/domain/models/soft_deletable.dart';

class Journal extends SoftDeletable {
  const Journal({
    required super.id,
    required super.createdAt,
    required super.updatedAt,
    super.deletedAt,
    required this.name,
    this.guidedJournaling = false,
    this.promptCycleDays = 7,
  });

  final String name;
  final bool guidedJournaling;
  final int promptCycleDays;

  Journal copyWith({
    String? name,
    bool? guidedJournaling,
    int? promptCycleDays,
    DateTime? deletedAt,
  }) {
    return Journal(
      id: id,
      createdAt: createdAt,
      updatedAt: DateTime.now().toUtc(),
      deletedAt: deletedAt ?? this.deletedAt,
      name: name ?? this.name,
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
  }) {
    return JournalEntry(
      id: id,
      createdAt: createdAt,
      updatedAt: DateTime.now().toUtc(),
      deletedAt: deletedAt ?? this.deletedAt,
      journalId: journalId,
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
}

class TagColor {
  const TagColor({required this.name, required this.colorValue});

  final String name;
  final int colorValue;
}

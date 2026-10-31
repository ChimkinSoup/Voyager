import 'dart:convert';

import 'package:voyager/domain/models/snippet.dart';

/// What the composer's text needs of the user's Voyager settings (§9.5):
/// the Vim and autocorrect toggles, their snippets and their dictionary.
/// The companion has no database, so the main instance sends these in
/// `hello` and again as `text` whenever they change.
class GaiaTextSettings {
  const GaiaTextSettings({
    this.vim = false,
    this.autocorrect = false,
    this.snippetsEnabled = false,
    this.expandKey = SnippetExpandKey.tab,
    this.snippets = const [],
    this.customWords = const {},
    this.flaggedWords = const {},
  });

  /// Everything off, until the main instance says otherwise.
  static const off = GaiaTextSettings();

  final bool vim;
  final bool autocorrect;
  final bool snippetsEnabled;
  final SnippetExpandKey expandKey;
  final List<Snippet> snippets;

  /// Words the user added to the dictionary.
  final Set<String> customWords;

  /// Words the user flagged as wrong for them, each to its replacement.
  final Map<String, String?> flaggedWords;

  Map<String, Object?> toJson() => {
    'vim': vim,
    'autocorrect': autocorrect,
    'snippetsEnabled': snippetsEnabled,
    'expandKey': expandKey.name,
    'snippets': [for (final snippet in snippets) snippet.toJson()],
    'customWords': customWords.toList(),
    'flaggedWords': flaggedWords,
  };

  factory GaiaTextSettings.fromJson(Map<String, Object?> json) =>
      GaiaTextSettings(
        vim: json['vim'] == true,
        autocorrect: json['autocorrect'] == true,
        snippetsEnabled: json['snippetsEnabled'] == true,
        expandKey:
            SnippetExpandKey.values.asNameMap()[json['expandKey']] ??
            SnippetExpandKey.tab,
        snippets: Snippet.listFromJson(json['snippets']),
        customWords: {
          for (final word in json['customWords'] as List? ?? const [])
            word as String,
        },
        flaggedWords: {
          for (final MapEntry(:key, :value)
              in (json['flaggedWords'] as Map? ?? const {}).entries)
            key as String: value as String?,
        },
      );

  /// Whether [other] says the same, so an unchanged rebuild sends nothing.
  bool sameAs(GaiaTextSettings other) =>
      jsonEncode(toJson()) == jsonEncode(other.toJson());
}

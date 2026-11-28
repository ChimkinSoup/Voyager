/// Tokens a model used through Gaia: fresh input, output, and cache reads
/// and writes, which providers count apart.
class GaiaTokenCount {
  const GaiaTokenCount({
    this.input = 0,
    this.output = 0,
    this.cacheRead = 0,
    this.cacheWrite = 0,
  });

  factory GaiaTokenCount.fromJson(Map<Object?, Object?> json) {
    int count(String key) => (json[key] as num?)?.toInt() ?? 0;
    return GaiaTokenCount(
      input: count('input'),
      output: count('output'),
      cacheRead: count('cacheRead'),
      cacheWrite: count('cacheWrite'),
    );
  }

  final int input;
  final int output;
  final int cacheRead;
  final int cacheWrite;

  int get total => input + output + cacheRead + cacheWrite;

  GaiaTokenCount operator +(GaiaTokenCount other) => GaiaTokenCount(
    input: input + other.input,
    output: output + other.output,
    cacheRead: cacheRead + other.cacheRead,
    cacheWrite: cacheWrite + other.cacheWrite,
  );

  Map<String, int> toJson() => {
    'input': input,
    'output': output,
    'cacheRead': cacheRead,
    'cacheWrite': cacheWrite,
  };
}

/// What tokens not spent on a tier's turn are counted under: a utility job's
/// is `utility:<job>`.
const kGaiaTokensUtility = 'utility:';
const kGaiaTokensOther = 'other';

/// Who the tokens of a model call are counted for: an account by its
/// [GaiaAccount.key], and their source, a tier's name, a utility job
/// ([kGaiaTokensUtility]) or [kGaiaTokensOther]. [chatId] is the chat's turn
/// they were spent in, for a routine's token cap (GAIA_ROUTINES_HLD.md
/// §8.8.1); null outside one.
typedef GaiaTokensFor = ({String account, String source, String? chatId});

/// One line of the lifetime count: an account's tokens on a model, for a
/// source.
class GaiaTokenRow {
  const GaiaTokenRow({
    required this.account,
    required this.source,
    required this.model,
    required this.count,
  });

  factory GaiaTokenRow.fromJson(Map<Object?, Object?> json) => GaiaTokenRow(
    account: json['account']! as String,
    source: json['source']! as String,
    model: json['model']! as String,
    count: GaiaTokenCount.fromJson(json),
  );

  final String account;
  final String source;
  final String model;
  final GaiaTokenCount count;

  Map<String, Object?> toJson() => {
    'account': account,
    'source': source,
    'model': model,
    ...count.toJson(),
  };
}

/// Where the tokens of each model call go, by model: the companion sends
/// them to the main instance, which adds them to the lifetime count in
/// Firestore. Unset, as in tests, they go nowhere.
void Function(GaiaTokensFor tokensFor, Map<String, GaiaTokenCount> byModel)?
gaiaTokensUsed;

/// A count by model from its JSON; empty for anything else.
Map<String, GaiaTokenCount> gaiaTokensFromJson(Object? json) => {
  if (json is Map)
    for (final MapEntry(:key, :value) in json.entries)
      if (value is Map) '$key': GaiaTokenCount.fromJson(value),
};

Map<String, Object?> gaiaTokensToJson(Map<String, GaiaTokenCount> byModel) => {
  for (final MapEntry(:key, :value) in byModel.entries) key: value.toJson(),
};

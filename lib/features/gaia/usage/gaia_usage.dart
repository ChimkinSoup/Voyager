import 'package:collection/collection.dart';
import 'package:intl/intl.dart';
import 'package:voyager/domain/models/gaia_models.dart';

/// Which limit a window measures (GAIA_HLD.md §6.2). Gemini's `daily` comes
/// back with its adapter.
enum GaiaUsageKind { session, weekly, weeklyModel }

/// One usage window, whichever provider reported it.
class GaiaUsageWindow {
  const GaiaUsageWindow({
    required this.kind,
    required this.used,
    required this.observedAt,
    this.resetsAt,
    this.model,
  });

  factory GaiaUsageWindow.fromJson(Map<String, Object?> json) =>
      GaiaUsageWindow(
        kind: GaiaUsageKind.values.byName(json['kind']! as String),
        used: (json['used']! as num).toDouble(),
        observedAt: DateTime.fromMillisecondsSinceEpoch(
          json['observedAt']! as int,
        ),
        resetsAt: switch (json['resetsAt']) {
          final int ms => DateTime.fromMillisecondsSinceEpoch(ms),
          _ => null,
        },
        model: json['model'] as String?,
      );

  final GaiaUsageKind kind;

  /// The share of its limit used, 0 to 1.
  final double used;
  final DateTime observedAt;

  /// Null while the window hasn't started.
  final DateTime? resetsAt;

  /// The model a [GaiaUsageKind.weeklyModel] window is for.
  final String? model;

  /// [used], or 0 once the window has reset since it was read.
  double get usedNow {
    final resets = resetsAt;
    if (resets != null && !resets.isAfter(DateTime.now())) return 0;
    return used.clamp(0.0, 1.0);
  }

  Map<String, Object?> toJson() => {
    'kind': kind.name,
    'used': used,
    'observedAt': observedAt.millisecondsSinceEpoch,
    'resetsAt': resetsAt?.millisecondsSinceEpoch,
    'model': model,
  };
}

/// An account's usage, by window.
class GaiaUsage {
  const GaiaUsage(this.windows);

  final List<GaiaUsageWindow> windows;

  GaiaUsageWindow? get fiveHour =>
      windows.firstWhereOrNull((w) => w.kind == GaiaUsageKind.session);
  GaiaUsageWindow? get weekly =>
      windows.firstWhereOrNull((w) => w.kind == GaiaUsageKind.weekly);
  Iterable<GaiaUsageWindow> get weeklyModels =>
      windows.where((w) => w.kind == GaiaUsageKind.weeklyModel);

  /// [newer]'s windows, with this one's of the kinds it didn't report: a
  /// run's event says nothing of the per-model windows a poll read.
  GaiaUsage updatedBy(GaiaUsage newer) => GaiaUsage([
    ...newer.windows,
    ...windows.where(
      (window) => newer.windows.every((w) => w.kind != window.kind),
    ),
  ]);
}

/// How a usage read ended (§6.4).
enum GaiaUsageHealth { ok, endpointChanged, signedOut, stale, offline }

class GaiaUsageRead {
  const GaiaUsageRead(this.health, {this.usage});

  final GaiaUsageHealth health;

  /// Set when [health] is `ok`.
  final GaiaUsage? usage;
}

/// What the account's own agent runs say of its login, which is how a 401
/// from a usage source is told apart: a working login means the source
/// changed (§6.4).
enum GaiaRunAuth { unknown, working, failing }

/// One provider's usage reader. None costs tokens (§6.2).
abstract interface class GaiaUsageSource {
  /// [account] is whose usage to read (§6.1).
  Future<GaiaUsageRead> read({
    required GaiaRunAuth runs,
    required GaiaAccount account,
  });
}

/// What the Gaia page shows of an account's usage, sent over from the
/// companion by [GaiaAccount.key].
class GaiaAccountUsage {
  const GaiaAccountUsage({this.health, this.usage, this.checkedAt});

  factory GaiaAccountUsage.fromJson(Map<String, Object?> json) =>
      GaiaAccountUsage(
        health: switch (json['health']) {
          final String name => GaiaUsageHealth.values.byName(name),
          _ => null,
        },
        usage: switch (json['windows']) {
          final List windows => GaiaUsage([
            for (final window in windows)
              GaiaUsageWindow.fromJson((window as Map).cast()),
          ]),
          _ => null,
        },
        checkedAt: switch (json['checkedAt']) {
          final int ms => DateTime.fromMillisecondsSinceEpoch(ms),
          _ => null,
        },
      );

  /// Null until the first read ends, when only a run has reported.
  final GaiaUsageHealth? health;
  final GaiaUsage? usage;

  /// The last time its numbers were current.
  final DateTime? checkedAt;

  Map<String, Object?> toJson() => {
    'health': health?.name,
    'windows': usage?.windows.map((window) => window.toJson()).toList(),
    'checkedAt': checkedAt?.millisecondsSinceEpoch,
  };
}

/// What the user is told of an adapter's usage while it isn't `ok` (§6.4).
/// With [account], one of several, its login is told apart from the others.
String gaiaUsageMessage(
  String adapter,
  GaiaUsageHealth health,
  DateTime? checkedAt, {
  GaiaAccount? account,
}) {
  final (name, owner, login) = adapter == kGaiaCodexAdapter
      ? ('Codex', "OpenAI's", 'codex login')
      : ('Claude', "Anthropic's", 'claude auth login');
  return switch (health) {
    GaiaUsageHealth.ok => '',
    GaiaUsageHealth.endpointChanged =>
      "Gaia's $name usage reader no longer matches $owner endpoint. This is "
          'a Gaia issue, not your account: your account is working. $name '
          "usage isn't tracked until Gaia is updated.",
    GaiaUsageHealth.signedOut =>
      account == null
          ? 'Your $name account is signed out. Log in with `$login`.'
          : account.dir.isEmpty
          ? '${account.label} is signed out. Log in with `$login`.'
          : '${account.label} is signed out. Log in with `$login`, with '
                '${adapter == kGaiaCodexAdapter ? 'CODEX_HOME' : 'CLAUDE_CONFIG_DIR'} '
                'set to ${account.dir}.',
    GaiaUsageHealth.stale =>
      checkedAt == null
          ? 'Not checked yet. Refreshes next time this account runs.'
          : 'Not checked since ${DateFormat.jm().format(checkedAt)}. '
                'Refreshes next time this account runs.',
    GaiaUsageHealth.offline => "Offline: $name usage can't be read right now.",
  };
}

/// [json]'s keys and types, never its values: all of a response that goes
/// in the log when its shape isn't known (§6.4).
Object? gaiaJsonShape(Object? json) => switch (json) {
  final Map map => {
    for (final MapEntry(:key, :value) in map.entries)
      '$key': gaiaJsonShape(value),
  },
  final List list => [if (list.isNotEmpty) gaiaJsonShape(list.first)],
  null => 'null',
  _ => json.runtimeType.toString(),
};

// FRAGILE(usage): the words a CLI's failed turn uses for a bad login are not
// a stable API (observed: Claude Code "Not logged in · Please run /login",
// Codex's server "codex account authentication required to …").
// One no longer matched only makes a 401 read as `stale`.
final _authFailure = RegExp(
  r'not logged in|/login|codex login|failed to authenticate|'
  r'authentication_error|authentication required|invalid api key|'
  r'401 unauthorized',
  caseSensitive: false,
);

/// Whether a failed turn's [text] says the login is the problem.
bool gaiaRunAuthFailed(String text) => _authFailure.hasMatch(text);

// FRAGILE(usage): as above. Narrower than [_authFailure], as this replaces the
// error: a login another service wants, as an MCP server's, must keep its words.
// One no longer matched only shows Codex's own.
final _codexSignedOut = RegExp(
  r'unexpected status 401|codex account authentication required|codex login',
  caseSensitive: false,
);

/// What the user is told of a failed turn. Codex's own words for a bad login are
/// its API's raw 401, so they're replaced with what Setup says of it.
String gaiaRunErrorText(String text, GaiaAccount? account) =>
    account?.adapter == kGaiaCodexAdapter && _codexSignedOut.hasMatch(text)
    ? gaiaUsageMessage(
        kGaiaCodexAdapter,
        GaiaUsageHealth.signedOut,
        null,
        account: account,
      )
    : text;

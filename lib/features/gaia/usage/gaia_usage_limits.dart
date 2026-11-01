import 'package:flutter/material.dart' show DateUtils;
import 'package:intl/intl.dart';
import 'package:voyager/domain/models/gaia_models.dart';
import 'package:voyager/features/gaia/usage/gaia_usage.dart';

/// When an account counts as low (GAIA_HLD.md §6.5). Gemini's daily floor comes
/// back with its adapter.
const kGaiaWeeklyFloor = 0.05;
const kGaiaSessionFloor = 0.10;

/// A session window resetting sooner than this isn't worth warning about.
const kGaiaFloorMinWait = Duration(minutes: 45);

/// Whether [window] limits [model]: a per-model window only limits its own.
bool _limits(GaiaUsageWindow window, String model) =>
    window.kind != GaiaUsageKind.weeklyModel ||
    model.toLowerCase().contains((window.model ?? '').toLowerCase());

/// The windows of [usage] that [model] can't run on: all used up.
Iterable<GaiaUsageWindow> gaiaFullWindows(GaiaUsage usage, String model) =>
    usage.windows.where((w) => _limits(w, model) && w.usedNow >= 1);

/// The window of [usage] under its floor with the least left for [model]; null
/// when none is.
GaiaUsageWindow? gaiaLowWindow(GaiaUsage usage, String model) {
  GaiaUsageWindow? lowest;
  for (final window in usage.windows.where((w) => _limits(w, model))) {
    // As shares used: 1 - 0.9 comes out just under 0.1, so exactly at a floor
    // would count as past it.
    final used = window.usedNow;
    final low = switch (window.kind) {
      GaiaUsageKind.weekly ||
      GaiaUsageKind.weeklyModel => used > 1 - kGaiaWeeklyFloor,
      GaiaUsageKind.session =>
        used > 1 - kGaiaSessionFloor &&
            (window.resetsAt?.difference(DateTime.now()) ?? Duration.zero) >
                kGaiaFloorMinWait,
    };
    if (low && (lowest == null || used > lowest.usedNow)) {
      lowest = window;
    }
  }
  return lowest;
}

/// [window]'s name in a sentence: "the 5-hour limit".
String gaiaLimitName(GaiaUsageWindow window) => switch (window.kind) {
  GaiaUsageKind.session => '5-hour',
  GaiaUsageKind.weekly => 'weekly',
  GaiaUsageKind.weeklyModel => 'weekly ${window.model}',
};

/// A reset's time, with its day unless that's today.
String gaiaResetTime(DateTime at) => DateUtils.isSameDay(at, DateTime.now())
    ? DateFormat.jm().format(at)
    : DateFormat.E().add_jm().format(at);

// FRAGILE(usage): the words a CLI's failed turn uses for a used-up limit are
// not a stable API. Observed in the binaries: Claude Code 2.1.316 "You've hit
// your session limit · resets 4pm", "You've reached your …", "You're out of
// usage credits", "Your org is out of usage"; Codex 0.166.0 "You've hit your
// usage limit. Upgrade to Pro …" and "You've reached your usage limit.". A
// transient 429 ("Request rejected (429)") isn't one: it says nothing of the
// account's limits. One no longer matched is an ordinary error, and only the
// numbers can then mark the account exhausted.
final _limitFailure = RegExp(
  r"you['’]ve hit your|you['’]ve reached your|out of usage|usage limit",
  caseSensitive: false,
);

/// Whether a failed turn's [text] says a usage limit stopped it (§6.5).
bool gaiaRunLimited(String text) => _limitFailure.hasMatch(text);

/// The non-blocking warning over the composer (§6.5).
class GaiaLowUsage {
  const GaiaLowUsage({
    required this.text,
    required this.adapter,
    this.switchTo,
  });

  final String text;
  final String adapter;

  /// The agent's other account that isn't low, if it has one.
  final GaiaAccount? switchTo;
}

/// The decision card in place of the composer (§6.5), holding the first case
/// that applies: [accounts] with headroom, else other providers' [tiers], else
/// neither, and [resets] says when usage is back.
class GaiaLimitCard {
  const GaiaLimitCard({
    required this.agent,
    required this.account,
    required this.named,
    this.accounts = const [],
    this.tiers = const [],
    this.resets,
    this.resend = false,
  });

  final GaiaAgent agent;
  final GaiaAccount account;

  /// Whether the adapter has several accounts, which are then told apart.
  final bool named;
  final List<GaiaAccount> accounts;
  final List<GaiaTier> tiers;

  /// The soonest reset across this provider's accounts, if one is known.
  final ({GaiaAccount account, DateTime at})? resets;

  /// Whether this chat's last reply was the run a limit stopped, so there's a
  /// prompt to send again.
  final bool resend;
}

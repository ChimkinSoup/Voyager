import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:voyager/domain/services/finance_analytics.dart';

/// Which section of the finance page is showing: the day-to-day ledger
/// dashboard, the macro analytics suite, or the savings goals.
enum FinanceViewMode { ledger, analytics, goals }

/// What the spending breakdown groups expenses by.
enum FinanceBreakdownMode { category, tag, store }

/// Which chart the breakdown card's title dropdown is showing.
enum FinanceBreakdownChart { spending, income }

/// The finance page's chrome — which tab, which grouping, which cash-flow
/// bucket — as it was left last time.
///
/// Device-local on purpose. These are answers to "what am I looking at right
/// now on this screen", not preferences about the user's money: carrying a
/// desktop's Analytics tab over to a phone that was mid-ledger would be a
/// worse app, so none of this goes through AppSettings or Firestore.
@immutable
class FinanceUiPrefs {
  const FinanceUiPrefs({
    this.viewMode = FinanceViewMode.ledger,
    this.breakdownMode = FinanceBreakdownMode.category,
    this.breakdownChart = FinanceBreakdownChart.spending,
    this.cashFlowGranularity = CashFlowGranularity.monthly,
  });

  static const defaults = FinanceUiPrefs();

  final FinanceViewMode viewMode;
  final FinanceBreakdownMode breakdownMode;
  final FinanceBreakdownChart breakdownChart;
  final CashFlowGranularity cashFlowGranularity;

  FinanceUiPrefs copyWith({
    FinanceViewMode? viewMode,
    FinanceBreakdownMode? breakdownMode,
    FinanceBreakdownChart? breakdownChart,
    CashFlowGranularity? cashFlowGranularity,
  }) {
    return FinanceUiPrefs(
      viewMode: viewMode ?? this.viewMode,
      breakdownMode: breakdownMode ?? this.breakdownMode,
      breakdownChart: breakdownChart ?? this.breakdownChart,
      cashFlowGranularity: cashFlowGranularity ?? this.cashFlowGranularity,
    );
  }

  /// Anything unrecognised falls back to that field's default rather than
  /// failing the whole file — a key written by a later build shouldn't cost
  /// the user the two settings this build did understand.
  factory FinanceUiPrefs.fromJson(Map<String, dynamic> json) {
    return FinanceUiPrefs(
      viewMode: _byName(
        FinanceViewMode.values,
        json['financeViewMode'],
        defaults.viewMode,
      ),
      breakdownMode: _byName(
        FinanceBreakdownMode.values,
        json['financeBreakdownMode'],
        // Files from before Store existed carry the old Category/Tag flag.
        switch (json['financeBreakdownGroupByCategory']) {
          false => FinanceBreakdownMode.tag,
          _ => defaults.breakdownMode,
        },
      ),
      breakdownChart: _byName(
        FinanceBreakdownChart.values,
        json['financeBreakdownChart'],
        defaults.breakdownChart,
      ),
      cashFlowGranularity: _byName(
        CashFlowGranularity.values,
        json['financeCashFlowGranularity'],
        defaults.cashFlowGranularity,
      ),
    );
  }

  Map<String, dynamic> toJson() => {
    'financeViewMode': viewMode.name,
    'financeBreakdownMode': breakdownMode.name,
    'financeBreakdownChart': breakdownChart.name,
    'financeCashFlowGranularity': cashFlowGranularity.name,
  };

  static T _byName<T extends Enum>(List<T> values, Object? name, T fallback) {
    if (name is! String) return fallback;
    for (final value in values) {
      if (value.name == name) return value;
    }
    return fallback;
  }

  @override
  bool operator ==(Object other) =>
      other is FinanceUiPrefs &&
      other.viewMode == viewMode &&
      other.breakdownMode == breakdownMode &&
      other.breakdownChart == breakdownChart &&
      other.cashFlowGranularity == cashFlowGranularity;

  @override
  int get hashCode =>
      Object.hash(viewMode, breakdownMode, breakdownChart, cashFlowGranularity);
}

abstract class FinanceUiPrefsStore {
  /// The stored prefs, or [FinanceUiPrefs.defaults] when there are none. A
  /// blob that can't be read is discarded and reported as defaults.
  Future<FinanceUiPrefs> load();

  Future<void> save(FinanceUiPrefs prefs);
}

const _prefsFileName = 'finance_ui_prefs.json';

class FileFinanceUiPrefsStore implements FinanceUiPrefsStore {
  /// [directory] defaults to the app's documents directory — the same place
  /// the database lives. Tests point it somewhere temporary.
  FileFinanceUiPrefsStore({Future<Directory> Function()? directory})
    : _directory = directory ?? getApplicationDocumentsDirectory;

  final Future<Directory> Function() _directory;

  /// Writes are chained rather than fired in parallel: flipping a segmented
  /// button twice quickly starts two writes onto one file, and the later one
  /// has to win. Same contract as FileLeetCodeScratchDraftStore.
  Future<void> _chain = Future<void>.value();

  Future<T> _enqueue<T>(Future<T> Function() op) {
    final result = _chain.then((_) => op());
    _chain = result.then((_) {}, onError: (_) {});
    return result;
  }

  Future<File> _file() async {
    final dir = await _directory();
    return File(p.join(dir.path, _prefsFileName));
  }

  @override
  Future<FinanceUiPrefs> load() => _enqueue(() async {
    try {
      final file = await _file();
      if (!await file.exists()) return FinanceUiPrefs.defaults;
      final raw = await file.readAsString();
      if (raw.trim().isEmpty) return FinanceUiPrefs.defaults;
      return FinanceUiPrefs.fromJson(
        Map<String, dynamic>.from(jsonDecode(raw) as Map),
      );
    } catch (error) {
      debugPrint('Finance UI prefs could not be read: $error');
      return FinanceUiPrefs.defaults;
    }
  });

  @override
  Future<void> save(FinanceUiPrefs prefs) => _enqueue(() async {
    try {
      final file = await _file();
      await file.writeAsString(jsonEncode(prefs.toJson()), flush: true);
    } catch (error) {
      // A pref that can't be written is one tab position lost on the next
      // launch, never an error worth putting in front of the user.
      debugPrint('Finance UI prefs could not be saved: $error');
    }
  });
}

/// In-memory slot, for tests and for any build where the platform has no
/// documents directory to write to.
class MemoryFinanceUiPrefsStore implements FinanceUiPrefsStore {
  FinanceUiPrefs prefs = FinanceUiPrefs.defaults;

  @override
  Future<FinanceUiPrefs> load() async => prefs;

  @override
  Future<void> save(FinanceUiPrefs value) async => prefs = value;
}

final financeUiPrefsStoreProvider = Provider<FinanceUiPrefsStore>(
  (ref) => FileFinanceUiPrefsStore(),
);

class FinanceUiPrefsNotifier extends StateNotifier<FinanceUiPrefs> {
  FinanceUiPrefsNotifier(this._store) : super(FinanceUiPrefs.defaults) {
    unawaited(_hydrate());
  }

  final FinanceUiPrefsStore _store;

  /// Set as soon as the user touches anything, so a slow first read can't
  /// undo a choice they have already made. The finance page is reachable
  /// within a frame of launch; the file read is not.
  var _touched = false;

  Future<void> _hydrate() async {
    final loaded = await _store.load();
    if (_touched || !mounted) return;
    state = loaded;
  }

  void update(FinanceUiPrefs prefs) {
    _touched = true;
    if (prefs == state) return;
    state = prefs;
    // Written straight through rather than debounced: these change on a
    // deliberate button press, not on a keystroke, and the store serialises
    // overlapping writes for itself.
    unawaited(_store.save(prefs));
  }

  void setViewMode(FinanceViewMode mode) =>
      update(state.copyWith(viewMode: mode));

  void setBreakdownMode(FinanceBreakdownMode mode) =>
      update(state.copyWith(breakdownMode: mode));

  void setBreakdownChart(FinanceBreakdownChart chart) =>
      update(state.copyWith(breakdownChart: chart));

  void setCashFlowGranularity(CashFlowGranularity granularity) =>
      update(state.copyWith(cashFlowGranularity: granularity));
}

final financeUiPrefsProvider =
    StateNotifierProvider<FinanceUiPrefsNotifier, FinanceUiPrefs>(
      (ref) => FinanceUiPrefsNotifier(ref.watch(financeUiPrefsStoreProvider)),
    );

/// The tag the ledger is currently filtered to, or null for the whole ledger.
///
/// Session-only, and deliberately not in [FinanceUiPrefs]: it is set by a
/// budget's "View expenses" as a way of asking a question, and a question that
/// survived a restart would just be a ledger mysteriously missing rows.
final financeLedgerTagFilterProvider = StateProvider<String?>((_) => null);

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:voyager/domain/services/finance_analytics.dart';
import 'package:voyager/features/finance/finance_ui_prefs.dart';

void main() {
  late Directory dir;
  late FileFinanceUiPrefsStore store;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('voyager_finance_prefs');
    store = FileFinanceUiPrefsStore(directory: () async => dir);
  });

  tearDown(() async {
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  File prefsFile() => File(p.join(dir.path, 'finance_ui_prefs.json'));

  test('a fresh install reads the documented defaults', () async {
    final prefs = await store.load();

    expect(prefs.viewMode, FinanceViewMode.ledger);
    expect(prefs.breakdownGroupByCategory, isTrue);
    expect(prefs.cashFlowGranularity, CashFlowGranularity.monthly);
  });

  test('chrome survives a restart', () async {
    await store.save(
      const FinanceUiPrefs(
        viewMode: FinanceViewMode.analytics,
        breakdownGroupByCategory: false,
        cashFlowGranularity: CashFlowGranularity.yearly,
      ),
    );

    // A second store over the same directory is what the next launch sees.
    final reopened = await FileFinanceUiPrefsStore(
      directory: () async => dir,
    ).load();

    expect(reopened.viewMode, FinanceViewMode.analytics);
    expect(reopened.breakdownGroupByCategory, isFalse);
    expect(reopened.cashFlowGranularity, CashFlowGranularity.yearly);
  });

  test('an unreadable file falls back to defaults rather than throwing',
      () async {
    await prefsFile().writeAsString('{not json');

    expect(await store.load(), FinanceUiPrefs.defaults);
  });

  test('an unknown enum value falls back for that field only', () async {
    await prefsFile().writeAsString(
      jsonEncode({
        'financeViewMode': 'holograms',
        'financeBreakdownGroupByCategory': false,
      }),
    );

    final prefs = await store.load();

    expect(prefs.viewMode, FinanceViewMode.ledger);
    expect(prefs.breakdownGroupByCategory, isFalse);
    expect(prefs.cashFlowGranularity, CashFlowGranularity.monthly);
  });

  test('the file holds only finance chrome, so nothing here can reach sync',
      () async {
    await store.save(const FinanceUiPrefs(viewMode: FinanceViewMode.goals));

    final json =
        jsonDecode(await prefsFile().readAsString()) as Map<String, dynamic>;

    expect(json.keys.toSet(), {
      'financeViewMode',
      'financeBreakdownGroupByCategory',
      'financeCashFlowGranularity',
    });
  });

  test('the notifier keeps a choice made before the file has been read',
      () async {
    final slow = _SlowStore(
      const FinanceUiPrefs(viewMode: FinanceViewMode.analytics),
    );
    final notifier = FinanceUiPrefsNotifier(slow);

    // The user reaches the page and picks Goals while the read is in flight.
    notifier.setViewMode(FinanceViewMode.goals);
    slow.complete();
    await Future<void>.delayed(Duration.zero);

    expect(notifier.state.viewMode, FinanceViewMode.goals);
    notifier.dispose();
  });
}

/// A store whose load stays pending until [complete] is called.
class _SlowStore implements FinanceUiPrefsStore {
  _SlowStore(this._stored);

  final FinanceUiPrefs _stored;
  final _gate = Completer<FinanceUiPrefs>();

  void complete() => _gate.complete(_stored);

  @override
  Future<FinanceUiPrefs> load() => _gate.future;

  @override
  Future<void> save(FinanceUiPrefs prefs) async {}
}

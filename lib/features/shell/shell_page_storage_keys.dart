import 'package:flutter/material.dart';

/// PageStorage keys for shell tab scroll/state restoration.
abstract final class ShellPageStorageKeys {
  static const journalEntryList = PageStorageKey<String>(
    'shell.journal.entryList',
  );
  static const journalEntryListAll = PageStorageKey<String>(
    'shell.journal.entryList.all',
  );
  static const journalPreview = PageStorageKey<String>('shell.journal.preview');
  static const todoTaskList = PageStorageKey<String>('shell.todo.taskList');
  static const searchResults = PageStorageKey<String>('shell.search.results');
  static const settingsList = PageStorageKey<String>('shell.settings.list');
  static const analyticsList = PageStorageKey<String>('shell.analytics.list');
  static const devList = PageStorageKey<String>('shell.dev.list');
  static const financeLedgerWide = PageStorageKey<String>(
    'shell.finance.ledger.wide',
  );
  static const financeLedgerNarrow = PageStorageKey<String>(
    'shell.finance.ledger.narrow',
  );
  static const financeInsights = PageStorageKey<String>(
    'shell.finance.insights',
  );
}

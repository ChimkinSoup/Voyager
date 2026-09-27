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
  static const searchDreamResults = PageStorageKey<String>(
    'shell.search.dreamResults',
  );
  static const settingsAccountTab = PageStorageKey<String>(
    'shell.settings.account',
  );
  static const settingsAppearanceTab = PageStorageKey<String>(
    'shell.settings.appearance',
  );
  static const settingsEditingTab = PageStorageKey<String>(
    'shell.settings.editing',
  );
  static const settingsPagesTab = PageStorageKey<String>(
    'shell.settings.pages',
  );
  static const settingsDataTab = PageStorageKey<String>('shell.settings.data');
  static const settingsAboutTab = PageStorageKey<String>(
    'shell.settings.about',
  );
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

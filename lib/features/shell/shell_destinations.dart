import 'package:flutter/material.dart';
import 'package:voyager/features/analytics/analytics_page.dart';
import 'package:voyager/features/calendar/calendar_page.dart';
import 'package:voyager/features/dev/dev_page.dart';
import 'package:voyager/features/journal/journal_page.dart';
import 'package:voyager/features/search/search_page.dart';
import 'package:voyager/features/settings/settings_page.dart';
import 'package:voyager/features/todo/todo_page.dart';

/// Add a new main section by appending one entry here and its route in [app_router.dart].
class ShellDestination {
  const ShellDestination({
    required this.path,
    required this.icon,
    required this.label,
    required this.page,
  });

  final String path;
  final IconData icon;
  final String label;
  final Widget page;
}

const shellDestinations = <ShellDestination>[
  ShellDestination(path: '/journal', icon: Icons.book, label: 'Journal', page: JournalPage()),
  ShellDestination(path: '/todo', icon: Icons.check_box, label: 'To-Do', page: TodoPage()),
  ShellDestination(path: '/calendar', icon: Icons.calendar_month, label: 'Calendar', page: CalendarPage()),
  ShellDestination(path: '/search', icon: Icons.search, label: 'Search', page: SearchPage()),
  ShellDestination(path: '/analytics', icon: Icons.insights, label: 'Analytics', page: AnalyticsPage()),
  ShellDestination(path: '/dev', icon: Icons.bug_report_outlined, label: 'Dev', page: DevPage()),
  ShellDestination(path: '/settings', icon: Icons.settings, label: 'Settings', page: SettingsPage()),
];

int shellIndexForLocation(String location) {
  final index = shellDestinations.indexWhere((d) => location.startsWith(d.path));
  return index == -1 ? 0 : index;
}

String shellPathForIndex(int index) => shellDestinations[index].path;

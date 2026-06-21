import 'package:flutter/widgets.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:voyager/core/icons/voyager_icons.dart';
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
  ShellDestination(
    path: '/journal',
    icon: VoyagerIcons.journal,
    label: 'Journal',
    page: JournalPage(),
  ),
  ShellDestination(
    path: '/todo',
    icon: PhosphorIconsRegular.listChecks,
    label: 'To-Do',
    page: TodoPage(),
  ),
  ShellDestination(
    path: '/calendar',
    icon: VoyagerIcons.calendar,
    label: 'Calendar',
    page: CalendarPage(),
  ),
  ShellDestination(
    path: '/search',
    icon: VoyagerIcons.search,
    label: 'Search',
    page: SearchPage(),
  ),
  ShellDestination(
    path: '/analytics',
    icon: PhosphorIconsRegular.chartLine,
    label: 'Analytics',
    page: AnalyticsPage(),
  ),
  ShellDestination(
    path: '/dev',
    icon: VoyagerIcons.debug,
    label: 'Dev',
    page: DevPage(),
  ),
  ShellDestination(
    path: '/settings',
    icon: PhosphorIconsRegular.gear,
    label: 'Settings',
    page: SettingsPage(),
  ),
];

int shellIndexForLocation(String location) {
  final index = shellDestinations.indexWhere(
    (d) => location.startsWith(d.path),
  );
  return index == -1 ? 0 : index;
}

String shellPathForIndex(int index) => shellDestinations[index].path;

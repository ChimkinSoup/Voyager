import 'package:flutter/widgets.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:voyager/core/icons/voyager_icons.dart';
import 'package:voyager/features/analytics/analytics_page.dart';
import 'package:voyager/features/calendar/calendar_page.dart';
import 'package:voyager/features/demo/demo_page.dart';
import 'package:voyager/features/dev/dev_page.dart';
import 'package:voyager/features/dream_journal/dream_journal_page.dart';
import 'package:voyager/features/finance/finance_page.dart';
import 'package:voyager/features/journal/journal_page.dart';
import 'package:voyager/features/leetcode/leetcode_page.dart';
import 'package:voyager/features/life_tracker/life_tracker_page.dart';
import 'package:voyager/features/search/search_page.dart';
import 'package:voyager/features/settings/settings_page.dart';
import 'package:voyager/features/study/study_page.dart';
import 'package:voyager/features/todo/todo_page.dart';
import 'package:voyager/features/workout/workout_page.dart';
import 'package:voyager/domain/models/settings_models.dart';

/// A destination paired with its index in [shellDestinations], which is what
/// `goBranch` expects. The pair exists because the user can reorder the nav
/// without reordering the branches underneath it.
typedef OrderedDestination = ({ShellDestination dest, int originalIndex});

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
    path: '/dream-journal',
    icon: PhosphorIconsRegular.moonStars,
    label: 'Dreams',
    page: DreamJournalPage(),
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
    path: '/finance',
    icon: PhosphorIconsRegular.wallet,
    label: 'Finance',
    page: FinancePage(),
  ),
  ShellDestination(
    path: '/life-tracker',
    icon: PhosphorIconsRegular.tree,
    label: 'Life',
    page: LifeTrackerPage(),
  ),
  ShellDestination(
    path: '/leetcode',
    icon: PhosphorIconsRegular.code,
    label: 'LeetCode',
    page: LeetCodePage(),
  ),
  ShellDestination(
    path: '/study',
    icon: PhosphorIconsRegular.cardsThree,
    label: 'Study',
    page: StudyPage(),
  ),
  ShellDestination(
    path: '/workout',
    icon: PhosphorIconsRegular.barbell,
    label: 'Workout',
    page: WorkoutPage(),
  ),
  ShellDestination(
    path: '/demo',
    icon: PhosphorIconsRegular.flower,
    label: 'Demo',
    page: DemoPage(),
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

List<OrderedDestination> getOrderedDestinations(
  AppSettings settings,
  List<ShellDestination> original,
) {
  final order = settings.navPageOrder;
  if (order == null || order.isEmpty) {
    return [
      for (var i = 0; i < original.length; i++)
        (dest: original[i], originalIndex: i),
    ];
  }

  final result = <OrderedDestination>[];
  for (final path in order) {
    final index = original.indexWhere((d) => d.path == path);
    if (index != -1) {
      result.add((dest: original[index], originalIndex: index));
    }
  }

  // Add any missing destinations that were not in the saved order
  for (var i = 0; i < original.length; i++) {
    if (!result.any((r) => r.originalIndex == i)) {
      result.add((dest: original[i], originalIndex: i));
    }
  }

  return result;
}

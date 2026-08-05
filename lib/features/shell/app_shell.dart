import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:voyager/core/constants/app_constants.dart';
import 'package:voyager/core/layout/window_size_class.dart';
import 'package:voyager/core/sync/pending_flush_registry.dart';
import 'package:voyager/core/sync/sync_activity.dart';
import 'package:voyager/core/theme/voyager_spacing.dart';
import 'package:voyager/core/utils/time_format.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/widgets/weather_icon.dart';
import 'package:voyager/domain/models/settings_models.dart';
import 'package:voyager/features/calendar/calendar_page.dart';
import 'package:voyager/features/dev/dev_cache_status_tile.dart';
import 'package:voyager/features/dev/dev_fps_counter_tile.dart';
import 'package:voyager/features/notifications/notification_bell.dart';
import 'package:voyager/features/notifications/notification_inbox_popover.dart';
import 'package:voyager/features/journal/geometric_texture_warmup.dart';
import 'package:voyager/features/shell/shell_back_interceptor.dart';
import 'package:voyager/features/shell/shell_bottom_nav.dart';
import 'package:voyager/features/shell/shell_destinations.dart';
import 'package:voyager/features/shell/shell_keyboard_shortcuts.dart';
import 'package:voyager/features/shell/shell_nav_theme.dart';
import 'package:voyager/features/shell/weather_chart_transition_warmup.dart';
import 'package:voyager/features/shell/weather_forecast_sheet.dart';

class AppShell extends ConsumerWidget {
  const AppShell({super.key, required this.child});

  /// Branch container from [StatefulShellRoute] (a [StatefulNavigationShell]).
  final Widget child;

  StatefulNavigationShell get _navigationShell =>
      child as StatefulNavigationShell;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider).value ?? const AppSettings();
    final orderedDestinations = getOrderedDestinations(settings, shellDestinations);
    final navigationShell = _navigationShell;
    final index = navigationShell.currentIndex;
    final accent = Color(settings.accentColor);
    final content = _ShellBranchChangeFlusher(
      branchIndex: index,
      child: child,
    );

    return ShellKeyboardShortcuts(
      navigationShell: navigationShell,
      orderedDestinations: orderedDestinations,
      child: PopScope(
        // Always false: when a branch has something of its own to pop,
        // go_router routes the gesture to that branch's navigator and this
        // never fires. Reaching here means the section is at its root, and
        // Back should step back through sections before it leaves the app.
        canPop: false,
        onPopInvokedWithResult: (didPop, _) {
          if (didPop) return;
          _handleSystemBack(navigationShell, orderedDestinations);
        },
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            // Warm up calendar morph shaders immediately after login — before the
            // user navigates to the calendar — so the first transition is smooth.
            const CalendarMorphWarmup(),
            const GeometricTextureWarmup(),
            const WeatherChartTransitionWarmup(),
            const NotificationPopoverWarmup(),
            Scaffold(
              backgroundColor: Colors.transparent,
              body: context.isCompactWidth
                  ? _CompactShell(
                      selectedIndex: index,
                      accent: accent,
                      orderedDestinations: orderedDestinations,
                      onDestinationSelected: navigationShell.goBranch,
                      child: content,
                    )
                  : _ExpandedShell(
                      selectedIndex: index,
                      accent: accent,
                      orderedDestinations: orderedDestinations,
                      onDestinationSelected: navigationShell.goBranch,
                      child: content,
                    ),
            ),
            const CacheStatusOverlay(),
            const FpsCounterOverlay(),
          ],
        ),
      ),
    );
  }
}

/// Android Back at the root of a section.
///
/// Steps back to the user's first section rather than closing the app, which
/// is what a phone user expects from a bottom bar, and only exits once they
/// are already there.
void _handleSystemBack(
  StatefulNavigationShell navigationShell,
  List<OrderedDestination> orderedDestinations,
) {
  // A surface showing a sub-view in place gets to close it first.
  if (ShellBackInterceptors.instance.handle()) return;

  final homeIndex = orderedDestinations.isEmpty
      ? 0
      : orderedDestinations.first.originalIndex;
  if (navigationShell.currentIndex != homeIndex) {
    navigationShell.goBranch(homeIndex);
    return;
  }
  SystemNavigator.pop();
}

/// The desktop composition: persistent left rail, content beside it.
class _ExpandedShell extends StatelessWidget {
  const _ExpandedShell({
    required this.selectedIndex,
    required this.accent,
    required this.orderedDestinations,
    required this.onDestinationSelected,
    required this.child,
  });

  final int selectedIndex;
  final Color accent;
  final List<OrderedDestination> orderedDestinations;
  final ValueChanged<int> onDestinationSelected;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Row(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 8, 4, 8),
            child: _VoyagerNavigationRail(
              selectedIndex: selectedIndex,
              accent: accent,
              onDestinationSelected: onDestinationSelected,
              orderedDestinations: orderedDestinations,
            ),
          ),
          const VerticalDivider(width: 12),
          Expanded(child: child),
        ],
      ),
    );
  }
}

/// The phone composition: one pane, a status strip above it, navigation below.
///
/// The rail's shoulder items — clock, weather, sync activity, notifications —
/// move to the top strip rather than disappearing. They are shell-level
/// information on both shells; only their axis changes.
class _CompactShell extends StatelessWidget {
  const _CompactShell({
    required this.selectedIndex,
    required this.accent,
    required this.orderedDestinations,
    required this.onDestinationSelected,
    required this.child,
  });

  final int selectedIndex;
  final Color accent;
  final List<OrderedDestination> orderedDestinations;
  final ValueChanged<int> onDestinationSelected;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        SafeArea(bottom: false, child: _CompactStatusStrip(accent: accent)),
        Expanded(
          child: SafeArea(top: false, bottom: false, child: child),
        ),
        ShellBottomNav(
          selectedIndex: selectedIndex,
          accent: accent,
          onDestinationSelected: onDestinationSelected,
          orderedDestinations: orderedDestinations,
        ),
      ],
    );
  }
}

class _CompactStatusStrip extends StatelessWidget {
  const _CompactStatusStrip({required this.accent});

  final Color accent;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 48,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: VoyagerSpacing.sm),
        child: Row(
          children: [
            const _ClockText(),
            const SizedBox(width: VoyagerSpacing.md),
            _WeatherButton(axis: Axis.horizontal),
            const Spacer(),
            const _SyncActivityIndicator(axis: Axis.horizontal),
            const SizedBox(width: VoyagerSpacing.xs),
            NotificationBell(accent: accent),
          ],
        ),
      ),
    );
  }
}

/// Flushes in-memory edits when the user switches main sections.
class _ShellBranchChangeFlusher extends ConsumerStatefulWidget {
  const _ShellBranchChangeFlusher({
    required this.branchIndex,
    required this.child,
  });

  final int branchIndex;
  final Widget child;

  @override
  ConsumerState<_ShellBranchChangeFlusher> createState() =>
      _ShellBranchChangeFlusherState();
}

class _ShellBranchChangeFlusherState extends ConsumerState<_ShellBranchChangeFlusher> {
  @override
  void didUpdateWidget(covariant _ShellBranchChangeFlusher oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.branchIndex != widget.branchIndex) {
      FocusManager.instance.primaryFocus?.unfocus();
      unawaited(PendingFlushRegistry.instance.flushAll());

      final currentPath = shellPathForIndex(widget.branchIndex);
      final repo = ref.read(settingsRepositoryProvider);
      repo.getSettings().then((s) {
        repo.saveSettings(s.copyWith(lastSeenNavPage: currentPath));
      });
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

class _VoyagerNavigationRail extends StatelessWidget {
  const _VoyagerNavigationRail({
    required this.selectedIndex,
    required this.accent,
    required this.onDestinationSelected,
    required this.orderedDestinations,
  });

  final int selectedIndex;
  final Color accent;
  final ValueChanged<int> onDestinationSelected;
  final List<OrderedDestination> orderedDestinations;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 72,
      child: LayoutBuilder(
        builder: (context, constraints) {
          return SingleChildScrollView(
            primary: false,
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: constraints.maxHeight),
              child: IntrinsicHeight(
                child: Column(
                  children: [
                    _RailClockWeather(accent: accent),
                    const SizedBox(height: 8),
                    for (final item in orderedDestinations)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 2),
                        child: ExcludeFocus(
                          child: _RailDestinationButton(
                            icon: item.dest.icon,
                            label: item.dest.label,
                            selected: item.originalIndex == selectedIndex,
                            accent: accent,
                            onTap: () => onDestinationSelected(item.originalIndex),
                          ),
                        ),
                      ),
                    const Spacer(),
                    const _SyncActivityIndicator(axis: Axis.vertical),
                    const SizedBox(height: 4),
                    NotificationBell(accent: accent),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _SyncActivityIndicator extends ConsumerWidget {
  const _SyncActivityIndicator({required this.axis});

  final Axis axis;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final activity = ref.watch(syncActivityProvider);

    // NOTE: these three colors fail contrast on the light theme (audit P1).
    // Left as-is here on purpose — retheming them is `/impeccable colorize`'s
    // scope, and this pass only changes the axis they lay out on.
    final slots = <Widget>[
      _SyncActivitySlotIcon(
        slotKey: 'local',
        event: activity.eventFor(SyncActivityDirection.localSave),
        tooltipPrefix: 'Saved locally',
        icon: PhosphorIconsRegular.floppyDisk,
        color: Colors.lightGreenAccent,
      ),
      _SyncActivitySlotIcon(
        slotKey: 'upload',
        event: activity.eventFor(SyncActivityDirection.upload),
        tooltipPrefix: 'Uploaded',
        icon: PhosphorIconsRegular.cloudArrowUp,
        color: Colors.lightBlueAccent,
      ),
      _SyncActivitySlotIcon(
        slotKey: 'download',
        event: activity.eventFor(SyncActivityDirection.download),
        tooltipPrefix: 'Checked',
        icon: PhosphorIconsRegular.cloudArrowDown,
        color: Colors.redAccent,
      ),
    ];

    if (axis == Axis.horizontal) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < slots.length; i++) ...[
            if (i > 0) const SizedBox(width: 4),
            slots[i],
          ],
        ],
      );
    }

    return SizedBox(
      width: 28,
      height: 72,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          for (var i = 0; i < slots.length; i++) ...[
            if (i > 0) const SizedBox(height: 4),
            slots[i],
          ],
        ],
      ),
    );
  }
}

class _SyncActivitySlotIcon extends StatelessWidget {
  const _SyncActivitySlotIcon({
    required this.slotKey,
    required this.event,
    required this.tooltipPrefix,
    required this.icon,
    required this.color,
  });

  final String slotKey;
  final SyncActivityEvent? event;
  final String tooltipPrefix;
  final IconData icon;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final visible = event != null;
    return SizedBox(
      height: 20,
      width: 20,
      child: IgnorePointer(
        ignoring: !visible,
        child: AnimatedOpacity(
          key: visible ? ValueKey('$slotKey-${event!.sequence}') : null,
          opacity: visible ? 1 : 0,
          duration: const Duration(milliseconds: 120),
          child: Tooltip(
            message: visible ? '$tooltipPrefix ${event!.collection}' : '',
            child: Icon(icon, color: color, size: 20),
          ),
        ),
      ),
    );
  }
}

class _RailDestinationButton extends StatefulWidget {
  const _RailDestinationButton({
    required this.icon,
    required this.label,
    required this.selected,
    required this.accent,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final bool selected;
  final Color accent;
  final VoidCallback onTap;

  @override
  State<_RailDestinationButton> createState() => _RailDestinationButtonState();
}

class _RailDestinationButtonState extends State<_RailDestinationButton> {
  var _hovered = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final foreground = widget.selected
        ? widget.accent
        : theme.colorScheme.onSurface;
    final backgroundColor = widget.selected
        ? shellNavSelectedFill(theme)
        : _hovered
        ? shellNavHoverFill(theme)
        : Colors.transparent;

    return Semantics(
      button: true,
      selected: widget.selected,
      label: widget.label,
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(18),
        child: InkWell(
          onTap: widget.onTap,
          onHover: (hovered) {
            if (_hovered != hovered) {
              setState(() => _hovered = hovered);
            }
          },
          borderRadius: BorderRadius.circular(18),
          hoverColor: Colors.transparent,
          splashColor: Colors.transparent,
          highlightColor: Colors.transparent,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 100),
            curve: Curves.easeOut,
            width: shellNavItemWidth,
            height: shellNavItemHeight,
            decoration: BoxDecoration(
              color: backgroundColor,
              borderRadius: BorderRadius.circular(18),
              border: widget.selected
                  ? Border.all(
                      color: widget.accent.withValues(
                        alpha: accentBorderAlpha,
                      ),
                      width: 1.0,
                    )
                  : null,
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(widget.icon, size: 24, color: foreground),
                const SizedBox(height: 3),
                AnimatedDefaultTextStyle(
                  duration: const Duration(milliseconds: 150),
                  curve: Curves.easeOut,
                  style:
                      theme.textTheme.labelSmall?.copyWith(
                        color: foreground,
                        fontSize: 10,
                      ) ??
                      const TextStyle(),
                  child: Text(
                    widget.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _RailClockWeather extends StatelessWidget {
  const _RailClockWeather({required this.accent});

  final Color accent;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 8, bottom: 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const _ClockText(),
          const SizedBox(height: 8),
          _WeatherButton(axis: Axis.vertical),
        ],
      ),
    );
  }
}

/// Owns the once-a-minute clock tick. Kept separate from the weather button so
/// the tick repaints four characters rather than the whole shoulder of the
/// rail.
class _ClockText extends StatefulWidget {
  const _ClockText();

  @override
  State<_ClockText> createState() => _ClockTextState();
}

class _ClockTextState extends State<_ClockText> {
  late String _time;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _time = formatTime12Hour(DateTime.now());
    _timer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted) {
        setState(() => _time = formatTime12Hour(DateTime.now()));
      }
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 300),
      child: Text(
        _time,
        key: ValueKey(_time),
        style: theme.textTheme.titleMedium?.copyWith(
          color: theme.colorScheme.onSurface,
        ),
      ),
    );
  }
}

class _WeatherButton extends ConsumerStatefulWidget {
  const _WeatherButton({required this.axis});

  final Axis axis;

  @override
  ConsumerState<_WeatherButton> createState() => _WeatherButtonState();
}

class _WeatherButtonState extends ConsumerState<_WeatherButton> {
  var _hovered = false;

  @override
  Widget build(BuildContext context) {
    final weatherAsync = ref.watch(currentWeatherProvider);
    final cachedWeather = ref.watch(cachedCurrentWeatherProvider);
    final weather = weatherAsync.valueOrNull ?? cachedWeather;
    final icon = weather?.icon;
    final theme = Theme.of(context);
    final onSurface = theme.colorScheme.onSurface;
    final horizontal = widget.axis == Axis.horizontal;

    final iconWidget = Icon(
      weatherIconData(icon),
      size: 22,
      color: onSurface,
    );
    final tempWidget = weather?.tempC == null
        ? null
        : Text(
            '${weather!.tempC!.round()}°',
            style: theme.textTheme.labelSmall?.copyWith(
              color: onSurface,
              fontSize: 10,
            ),
          );

    return Semantics(
      button: true,
      label: 'Weather forecast',
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(18),
        child: InkWell(
          onTap: () => showWeatherForecastSheet(context),
          onHover: (hovered) {
            if (_hovered != hovered) {
              setState(() => _hovered = hovered);
            }
          },
          borderRadius: BorderRadius.circular(18),
          hoverColor: Colors.transparent,
          splashColor: Colors.transparent,
          highlightColor: Colors.transparent,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 90),
            constraints: horizontal
                ? const BoxConstraints(minWidth: 48, minHeight: 40)
                : const BoxConstraints.tightFor(
                    width: shellNavItemWidth,
                    height: shellNavItemHeight,
                  ),
            padding: horizontal
                ? const EdgeInsets.symmetric(horizontal: VoyagerSpacing.sm)
                : EdgeInsets.zero,
            decoration: BoxDecoration(
              color: _hovered ? shellNavHoverFill(theme) : Colors.transparent,
              borderRadius: BorderRadius.circular(18),
            ),
            child: horizontal
                ? Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      iconWidget,
                      if (tempWidget != null) ...[
                        const SizedBox(width: VoyagerSpacing.xs),
                        tempWidget,
                      ],
                    ],
                  )
                : Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      iconWidget,
                      if (tempWidget != null) ...[
                        const SizedBox(height: VoyagerSpacing.xs),
                        tempWidget,
                      ],
                    ],
                  ),
          ),
        ),
      ),
    );
  }
}

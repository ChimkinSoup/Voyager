import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:voyager/core/sync/sync_activity.dart';
import 'package:voyager/core/utils/time_format.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/widgets/weather_icon.dart';
import 'package:voyager/domain/models/settings_models.dart';
import 'package:voyager/features/dev/dev_calendar_zoom_prewarm_tile.dart';
import 'package:voyager/features/dev/dev_cache_status_tile.dart';
import 'package:voyager/features/shell/shell_destinations.dart';
import 'package:voyager/features/shell/shell_keyboard_shortcuts.dart';
import 'package:voyager/features/shell/weather_forecast_sheet.dart';

const _railItemWidth = 68.0;
const _railItemHeight = 56.0;

class AppShell extends ConsumerWidget {
  const AppShell({super.key, required this.child});

  /// Branch container from [StatefulShellRoute] (a [StatefulNavigationShell]).
  final Widget child;

  StatefulNavigationShell get _navigationShell =>
      child as StatefulNavigationShell;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider).value ?? const AppSettings();
    final navigationShell = _navigationShell;
    final index = navigationShell.currentIndex;
    final accent = Color(settings.accentColor);

    return ShellKeyboardShortcuts(
      navigationShell: navigationShell,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Scaffold(
            body: Row(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(8, 8, 4, 8),
                  child: _VoyagerNavigationRail(
                    selectedIndex: index,
                    accent: accent,
                    onDestinationSelected: navigationShell.goBranch,
                  ),
                ),
                const VerticalDivider(width: 12),
                Expanded(child: child),
              ],
            ),
          ),
          const CacheStatusOverlay(),
          const CalendarZoomPrewarmOverlay(),
        ],
      ),
    );
  }
}

class _VoyagerNavigationRail extends StatelessWidget {
  const _VoyagerNavigationRail({
    required this.selectedIndex,
    required this.accent,
    required this.onDestinationSelected,
  });

  final int selectedIndex;
  final Color accent;
  final ValueChanged<int> onDestinationSelected;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 72,
      child: Column(
        children: [
          _RailClockWeather(accent: accent),
          const SizedBox(height: 8),
          for (var i = 0; i < shellDestinations.length; i++)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: ExcludeFocus(
                child: _RailDestinationButton(
                  icon: shellDestinations[i].icon,
                  label: shellDestinations[i].label,
                  selected: i == selectedIndex,
                  accent: accent,
                  onTap: () => onDestinationSelected(i),
                ),
              ),
            ),
          const Spacer(),
          const _SyncActivityIndicator(),
        ],
      ),
    );
  }
}

class _SyncActivityIndicator extends ConsumerWidget {
  const _SyncActivityIndicator();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final activity = ref.watch(syncActivityProvider);

    return SizedBox(
      width: 28,
      height: 72,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          _SyncActivitySlotIcon(
            slotKey: 'local',
            event: activity.eventFor(SyncActivityDirection.localSave),
            tooltipPrefix: 'Saved locally',
            icon: PhosphorIconsRegular.floppyDisk,
            color: Colors.lightGreenAccent,
          ),
          const SizedBox(height: 4),
          _SyncActivitySlotIcon(
            slotKey: 'upload',
            event: activity.eventFor(SyncActivityDirection.upload),
            tooltipPrefix: 'Uploaded',
            icon: PhosphorIconsRegular.cloudArrowUp,
            color: Colors.lightBlueAccent,
          ),
          const SizedBox(height: 4),
          _SyncActivitySlotIcon(
            slotKey: 'download',
            event: activity.eventFor(SyncActivityDirection.download),
            tooltipPrefix: 'Checked',
            icon: PhosphorIconsRegular.cloudArrowDown,
            color: Colors.redAccent,
          ),
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
    final colorScheme = Theme.of(context).colorScheme;
    final active = widget.selected || _hovered;
    final foreground = widget.selected ? widget.accent : colorScheme.onSurface;

    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      cursor: SystemMouseCursors.click,
      child: Semantics(
        button: true,
        selected: widget.selected,
        label: widget.label,
        child: Material(
          color: Colors.transparent,
          borderRadius: BorderRadius.circular(18),
          child: InkWell(
            onTap: widget.onTap,
            borderRadius: BorderRadius.circular(18),
            hoverColor: Colors.transparent,
            splashColor: Colors.transparent,
            highlightColor: Colors.transparent,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 90),
              width: _railItemWidth,
              height: _railItemHeight,
              decoration: BoxDecoration(
                color: active
                    ? colorScheme.onSurface.withValues(alpha: 0.10)
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(18),
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(widget.icon, size: 24, color: foreground),
                  const SizedBox(height: 3),
                  Text(
                    widget.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: foreground,
                      fontSize: 10,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _RailClockWeather extends ConsumerStatefulWidget {
  const _RailClockWeather({required this.accent});

  final Color accent;

  @override
  ConsumerState<_RailClockWeather> createState() => _RailClockWeatherState();
}

class _RailClockWeatherState extends ConsumerState<_RailClockWeather> {
  late String _time;
  Timer? _timer;
  var _weatherHovered = false;

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
    final weatherAsync = ref.watch(currentWeatherProvider);
    final icon = weatherAsync.value?.icon;
    final colorScheme = Theme.of(context).colorScheme;

    return Padding(
      padding: const EdgeInsets.only(top: 8, bottom: 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 300),
            child: Text(
              _time,
              key: ValueKey(_time),
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(color: widget.accent),
            ),
          ),
          const SizedBox(height: 8),
          MouseRegion(
            onEnter: (_) => setState(() => _weatherHovered = true),
            onExit: (_) => setState(() => _weatherHovered = false),
            cursor: SystemMouseCursors.click,
            child: Semantics(
              button: true,
              label: 'Weather forecast',
              child: Material(
                color: Colors.transparent,
                borderRadius: BorderRadius.circular(18),
                child: InkWell(
                  onTap: () => showWeatherForecastSheet(context),
                  borderRadius: BorderRadius.circular(18),
                  hoverColor: Colors.transparent,
                  splashColor: Colors.transparent,
                  highlightColor: Colors.transparent,
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 90),
                    width: _railItemWidth,
                    height: _railItemHeight,
                    decoration: BoxDecoration(
                      color: _weatherHovered
                          ? colorScheme.onSurface.withValues(alpha: 0.10)
                          : Colors.transparent,
                      borderRadius: BorderRadius.circular(18),
                    ),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          weatherIconData(icon),
                          color: widget.accent,
                          size: 22,
                        ),
                        if (weatherAsync.value?.tempC != null) ...[
                          const SizedBox(height: 4),
                          Text(
                            '${weatherAsync.value!.tempC!.round()}°',
                            style: Theme.of(context).textTheme.labelSmall
                                ?.copyWith(
                                  color: widget.accent,
                                  fontSize: 10,
                                ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

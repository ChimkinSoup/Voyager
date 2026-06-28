import 'dart:async';
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:voyager/core/sync/pending_flush_registry.dart';
import 'package:voyager/core/sync/sync_activity.dart';
import 'package:voyager/core/utils/time_format.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/widgets/weather_icon.dart';
import 'package:voyager/domain/models/settings_models.dart';
import 'package:voyager/features/calendar/calendar_page.dart';
import 'package:voyager/features/dev/dev_cache_status_tile.dart';
import 'package:voyager/features/journal/geometric_texture_warmup.dart';
import 'package:voyager/features/shell/shell_destinations.dart';
import 'package:voyager/features/shell/shell_keyboard_shortcuts.dart';
import 'package:voyager/features/shell/weather_chart_transition_warmup.dart';
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
          // Warm up calendar morph shaders immediately after login — before the
          // user navigates to the calendar — so the first transition is smooth.
          const CalendarMorphWarmup(),
          const GeometricTextureWarmup(),
          const WeatherChartTransitionWarmup(),
          Scaffold(
            backgroundColor: Colors.transparent,
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
                Expanded(
                  child: _ShellBranchChangeFlusher(
                    branchIndex: index,
                    child: child,
                  ),
                ),
              ],
            ),
          ),
          const CacheStatusOverlay(),
        ],
      ),
    );
  }
}

/// Flushes in-memory edits when the user switches main sections.
class _ShellBranchChangeFlusher extends StatefulWidget {
  const _ShellBranchChangeFlusher({
    required this.branchIndex,
    required this.child,
  });

  final int branchIndex;
  final Widget child;

  @override
  State<_ShellBranchChangeFlusher> createState() =>
      _ShellBranchChangeFlusherState();
}

class _ShellBranchChangeFlusherState extends State<_ShellBranchChangeFlusher> {
  @override
  void didUpdateWidget(covariant _ShellBranchChangeFlusher oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.branchIndex != widget.branchIndex) {
      unawaited(PendingFlushRegistry.instance.flushAll());
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
    final foreground = widget.selected ? widget.accent : colorScheme.onSurface;
    final backgroundColor = widget.selected
        ? Color.lerp(
            colorScheme.surface,
            Theme.of(context).scaffoldBackgroundColor,
            0.35,
          )!.withValues(alpha: 0.92)
        : _hovered
        ? colorScheme.onSurface.withValues(alpha: 0.10)
        : Colors.transparent;

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
              duration: const Duration(milliseconds: 100),
              curve: Curves.easeOut,
              width: _railItemWidth,
              height: _railItemHeight,
              decoration: BoxDecoration(
                color: backgroundColor,
                borderRadius: BorderRadius.circular(18),
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  _RailGlowingIcon(
                    icon: widget.icon,
                    color: foreground,
                    glowColor: widget.accent,
                    glow: widget.selected,
                  ),
                  const SizedBox(height: 3),
                  AnimatedDefaultTextStyle(
                    duration: const Duration(milliseconds: 150),
                    curve: Curves.easeOut,
                    style:
                        Theme.of(context).textTheme.labelSmall?.copyWith(
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
      ),
    );
  }
}

class _RailGlowingIcon extends StatelessWidget {
  const _RailGlowingIcon({
    required this.icon,
    required this.color,
    required this.glowColor,
    required this.glow,
    this.size = 24,
    this.glowAlpha = 0.65,
    this.glowBlur = 10,
    this.intenseGlow = false,
  });

  final IconData icon;
  final Color color;
  final Color glowColor;
  final bool glow;
  final double size;
  final double glowAlpha;
  final double glowBlur;
  final bool intenseGlow;

  @override
  Widget build(BuildContext context) {
    final iconWidget = Icon(this.icon, size: size, color: color);
    final glowTint = intenseGlow
        ? Color.lerp(glowColor, Colors.white, 0.4)!
        : glowColor;
    final glowOpacity = glowAlpha.clamp(0.0, 1.0);

    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        clipBehavior: Clip.none,
        alignment: Alignment.center,
        children: [
          if (glow && intenseGlow) ...[
            ImageFiltered(
              imageFilter: ImageFilter.blur(
                sigmaX: glowBlur * 1.8,
                sigmaY: glowBlur * 1.8,
              ),
              child: Icon(
                this.icon,
                size: size,
                color: glowTint.withValues(alpha: glowOpacity * 0.75),
              ),
            ),
            ImageFiltered(
              imageFilter: ImageFilter.blur(
                sigmaX: glowBlur * 0.55,
                sigmaY: glowBlur * 0.55,
              ),
              child: Icon(
                this.icon,
                size: size,
                color: glowTint.withValues(alpha: glowOpacity),
              ),
            ),
          ] else
            AnimatedOpacity(
              opacity: glow ? 1 : 0,
              duration: const Duration(milliseconds: 150),
              curve: Curves.easeOut,
              child: ImageFiltered(
                imageFilter: ImageFilter.blur(
                  sigmaX: glowBlur,
                  sigmaY: glowBlur,
                ),
                child: Icon(
                  this.icon,
                  size: size,
                  color: glowColor.withValues(alpha: glowOpacity),
                ),
              ),
            ),
          iconWidget,
        ],
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
    final cachedWeather = ref.watch(cachedCurrentWeatherProvider);
    final weather = weatherAsync.value ?? cachedWeather;
    final icon = weather?.icon;
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
              ).textTheme.titleMedium?.copyWith(color: Colors.white),
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
                        _RailGlowingIcon(
                          icon: weatherIconData(icon),
                          color: Colors.white,
                          glowColor: widget.accent,
                          glow: true,
                          size: 22,
                          glowAlpha: 1,
                          glowBlur: 12,
                          intenseGlow: true,
                        ),
                        if (weather?.tempC != null) ...[
                          const SizedBox(height: 4),
                          Text(
                            '${weather!.tempC!.round()}°',
                            style: Theme.of(context).textTheme.labelSmall
                                ?.copyWith(
                                  color: Colors.white,
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

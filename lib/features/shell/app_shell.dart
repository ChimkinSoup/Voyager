import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:voyager/core/constants/app_constants.dart';
import 'package:voyager/core/layout/window_size_class.dart';
import 'package:voyager/core/motion/motion.dart';
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
import 'package:voyager/core/widgets/voyager_scroll_view.dart';
import 'package:voyager/features/workout/workout_overlay.dart';

class AppShell extends ConsumerWidget {
  const AppShell({super.key, required this.child});

  /// Branch container from [StatefulShellRoute] (a [StatefulNavigationShell]).
  final Widget child;

  StatefulNavigationShell get _navigationShell =>
      child as StatefulNavigationShell;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider).value ?? const AppSettings();
    final orderedDestinations = getOrderedDestinations(
      settings,
      shellDestinations,
    );
    final navigationShell = _navigationShell;
    final index = navigationShell.currentIndex;
    final accent = Color(settings.accentColor);
    final content = _ShellBranchChangeFlusher(branchIndex: index, child: child);

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
            // Above the page content and outside the branch containers, so a
            // live workout's island stays put no matter which section is on
            // screen — that persistence is the whole point of the island.
            const WorkoutOverlay(),
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
        Expanded(child: SafeArea(top: false, bottom: false, child: child)),
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
            const _ConnectivityIndicator(),
            const SizedBox(width: VoyagerSpacing.xs),
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

class _ShellBranchChangeFlusherState
    extends ConsumerState<_ShellBranchChangeFlusher> {
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
    // Clock, weather, sync and the inbox bell sit outside the scroll view so a
    // rail with more destinations than fit still shows them: only the
    // destination list itself scrolls, between two fixed shoulders.
    return SizedBox(
      width: 72,
      child: Column(
        children: [
          _RailClockWeather(accent: accent),
          const SizedBox(height: 18),
          Expanded(
            child: _RailDestinationList(
              child: Column(
                children: [
                  for (final item in orderedDestinations)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 2),
                      child: ExcludeFocus(
                        child: _RailDestinationButton(
                          icon: item.dest.icon,
                          label: item.dest.label,
                          selected: item.originalIndex == selectedIndex,
                          accent: accent,
                          onTap: () =>
                              onDestinationSelected(item.originalIndex),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 18),
          const _ConnectivityIndicator(),
          const SizedBox(height: 4),
          const _SyncActivityIndicator(axis: Axis.vertical),
          NotificationBell(accent: accent),
          const SizedBox(height: 20),
        ],
      ),
    );
  }
}

/// The rail's scrolling destination list, softened at whichever end is holding
/// content back.
///
/// The list is squeezed between two fixed shoulders, so with more destinations
/// than fit it has to cut one off — and a hard clip against the clock or the
/// inbox bell reads as a rendering fault rather than as "there is more here".
/// A gradient over the last [_fade] logical pixels says the same thing the way
/// a scroll view should.
///
/// Each end's fade ramps in over its own first [_fade] pixels of travel rather
/// than switching on, so an end that is already at rest stays perfectly sharp:
/// a rail short enough to fit every destination never fades at all, and one
/// scrolled to its bottom fades only its top.
class _RailDestinationList extends StatefulWidget {
  const _RailDestinationList({required this.child});

  final Widget child;

  @override
  State<_RailDestinationList> createState() => _RailDestinationListState();
}

class _RailDestinationListState extends State<_RailDestinationList> {
  /// Depth of the gradient, and the travel over which it reaches full strength.
  static const double _fade = 14;

  final ScrollController _controller = ScrollController();

  double _topFade = 0;
  double _bottomFade = 0;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _syncFades() {
    if (!mounted) return;
    final position = _controller.hasClients ? _controller.position : null;
    final top = position == null
        ? 0.0
        : ((position.pixels - position.minScrollExtent) / _fade).clamp(
            0.0,
            1.0,
          );
    final bottom = position == null
        ? 0.0
        : ((position.maxScrollExtent - position.pixels) / _fade).clamp(
            0.0,
            1.0,
          );
    if (top == _topFade && bottom == _bottomFade) return;
    setState(() {
      _topFade = top;
      _bottomFade = bottom;
    });
  }

  @override
  Widget build(BuildContext context) {
    // Scroll notifications cover the pointer moving the list; this covers the
    // dimensions changing under it — the first layout, and the destination set
    // being reordered or trimmed in settings. It settles after one pass,
    // because a sync that changes nothing doesn't rebuild.
    WidgetsBinding.instance.addPostFrameCallback((_) => _syncFades());

    final list = NotificationListener<ScrollNotification>(
      onNotification: (_) {
        _syncFades();
        return false;
      },
      child: VoyagerScrollView(controller: _controller, child: widget.child),
    );

    if (_topFade == 0 && _bottomFade == 0) return list;

    return ShaderMask(
      blendMode: BlendMode.dstIn,
      shaderCallback: (rect) {
        // Both ramps have to fit inside the rail with room to spare, or the
        // stops stop ascending and the gradient throws.
        final depth = math.min(_fade, rect.height / 3);
        final ratio = rect.height == 0 ? 0.0 : depth / rect.height;
        return LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            const Color(0xFFFFFFFF).withValues(alpha: 1 - _topFade),
            const Color(0xFFFFFFFF),
            const Color(0xFFFFFFFF),
            const Color(0xFFFFFFFF).withValues(alpha: 1 - _bottomFade),
          ],
          stops: [0, ratio, 1 - ratio, 1],
        ).createShader(rect);
      },
      child: list,
    );
  }
}

/// The shell's offline badge — nothing at all while the backend is reachable.
///
/// Only the degraded state is worth chrome. A dot that is green all day trains
/// the eye to stop reading it, and by the time it matters it has become part
/// of the furniture; an icon that appears only when something is wrong is
/// noticed the once it needs to be. It sits in the same shoulder as the sync
/// activity slots because it answers the same question they do — is my work
/// leaving this machine — just over a longer horizon.
class _ConnectivityIndicator extends ConsumerWidget {
  const _ConnectivityIndicator();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final online = ref.watch(connectivityStatusProvider).isOnline;

    return AnimatedSwitcher(
      duration: VoyagerMotion.reduced(context)
          ? VoyagerMotion.crossfade
          : const Duration(milliseconds: 220),
      child: online
          ? const SizedBox.shrink()
          : Tooltip(
              message:
                  'Offline — changes are saved on this device and sync when '
                  'the connection returns.',
              child: PhosphorIcon(
                PhosphorIconsDuotone.wifiSlash,
                size: 20,
                // The one themed role that reads as "attention" against the
                // rail in both light and dark, unlike the fixed accent colors
                // the sync slots below still use.
                color: theme.colorScheme.error,
              ),
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
    final hasActivity =
        activity.eventFor(SyncActivityDirection.localSave) != null ||
        activity.eventFor(SyncActivityDirection.upload) != null ||
        activity.eventFor(SyncActivityDirection.download) != null;
    if (!hasActivity) return const SizedBox.shrink();

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
      child: Column(
        mainAxisSize: MainAxisSize.min,
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

  /// One [AnimatedContainer] carries both fills, but they want different
  /// clocks — selection settles with the page it summons, hover has to answer
  /// the pointer immediately. Whichever changed last sets the duration.
  Duration _fillDuration = shellNavHoverDuration;

  @override
  void didUpdateWidget(covariant _RailDestinationButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.selected != widget.selected) {
      _fillDuration = shellNavSelectionDuration(context);
    }
  }

  void _setHovered(bool hovered) {
    if (_hovered == hovered) return;
    setState(() {
      _hovered = hovered;
      _fillDuration = shellNavHoverDuration;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final selectionDuration = shellNavSelectionDuration(context);
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
          onHover: _setHovered,
          borderRadius: BorderRadius.circular(18),
          hoverColor: Colors.transparent,
          splashColor: Colors.transparent,
          highlightColor: Colors.transparent,
          child: AnimatedContainer(
            duration: _fillDuration,
            curve: Curves.easeOut,
            width: shellNavItemWidth,
            height: shellNavItemHeight,
            decoration: BoxDecoration(
              color: backgroundColor,
              borderRadius: BorderRadius.circular(18),
              border: widget.selected
                  ? Border.all(
                      color: widget.accent.withValues(alpha: accentBorderAlpha),
                      width: 1.0,
                    )
                  : null,
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                // Icon and label carry the accent, so they are as much the
                // selection indicator as the fill is and settle on its clock.
                TweenAnimationBuilder<Color?>(
                  tween: ColorTween(end: foreground),
                  duration: selectionDuration,
                  curve: Curves.easeOut,
                  builder: (context, color, _) =>
                      Icon(widget.icon, size: 24, color: color),
                ),
                const SizedBox(height: 3),
                AnimatedDefaultTextStyle(
                  duration: selectionDuration,
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
      padding: const EdgeInsets.only(top: 8, bottom: 0),
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

    final iconWidget = WeatherIcon(icon, size: 22);
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

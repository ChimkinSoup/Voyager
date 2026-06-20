import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/domain/models/settings_models.dart';
import 'package:voyager/features/shell/shell_destinations.dart';

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

    return Scaffold(
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
          for (var i = 0; i < shellDestinations.length; i++)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: _RailDestinationButton(
                icon: shellDestinations[i].icon,
                label: shellDestinations[i].label,
                selected: i == selectedIndex,
                accent: accent,
                onTap: () => onDestinationSelected(i),
              ),
            ),
          const Spacer(),
          _RailClockWeather(accent: accent),
        ],
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
              width: 68,
              height: 56,
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

class _RailClockWeather extends StatefulWidget {
  const _RailClockWeather({required this.accent});

  final Color accent;

  @override
  State<_RailClockWeather> createState() => _RailClockWeatherState();
}

class _RailClockWeatherState extends State<_RailClockWeather> {
  late String _time;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _time = DateFormat('HH:mm').format(DateTime.now());
    _timer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted) {
        setState(() => _time = DateFormat('HH:mm').format(DateTime.now()));
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
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
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
          Icon(Icons.wb_sunny_outlined, color: widget.accent, size: 22),
        ],
      ),
    );
  }
}

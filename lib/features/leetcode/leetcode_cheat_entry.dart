import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:voyager/core/widgets/glass_button.dart';
import 'package:go_router/go_router.dart';
import 'package:voyager/routing/app_router.dart';
import 'package:voyager/features/leetcode/leetcode_cheat_providers.dart';
import 'package:voyager/features/leetcode/leetcode_cheat_sheet.dart';

const String _kCheatTooltip = 'Cheat sheet  (Ctrl+Shift+C)';

/// The cheat sheet's entry point as a labelled [GlassButton] — the Dashboard
/// header row and the scratch editor's toolbar.
///
/// There is deliberately no floating action button anywhere: the Track FAB
/// already owns the bottom-right corner, and a second one would fight it.
class LeetCodeCheatSheetButton extends ConsumerWidget {
  const LeetCodeCheatSheetButton({super.key, this.dense = false});

  /// Matches the shape of its neighbours in the scratch editor's toolbar.
  final bool dense;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    // Faintly accented, so the reference sheet reads as its own kind of thing
    // in a row of controls that act on the problem in front of you. A tint,
    // not the solid accent an active toggle like Compare wears: light mode
    // thickens the wafer the button already tints with `primary`, dark mode
    // washes that same `primary` over the matte plate.
    final plate =
        theme.inputDecorationTheme.fillColor ?? theme.colorScheme.surface;
    return GlassButton(
      dense: dense,
      height: dense ? 32 : null,
      color: isDark
          ? Color.alphaBlend(
              theme.colorScheme.primary.withValues(alpha: 0.22),
              plate,
            )
          : null,
      glassOpacity: isDark ? null : 0.16,
      icon: const Icon(PhosphorIconsRegular.listChecks),
      label: 'Cheat sheet',
      tooltip: _kCheatTooltip,
      onPressed: () => toggleLeetCodeCheatSheet(context, ref),
    );
  }
}

/// The same entry point as a bare icon, for rows that are already full — the
/// session and cram top rows, and the Track modal's close corner.
class LeetCodeCheatSheetIconButton extends ConsumerWidget {
  const LeetCodeCheatSheetIconButton({super.key, this.size = 20});

  final double size;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return IconButton(
      icon: Icon(PhosphorIconsRegular.listChecks, size: size),
      // The accent the labelled form carries as a tint, on strokes thin enough
      // that it stays a hint rather than a highlight.
      color: Theme.of(context).colorScheme.primary,
      tooltip: _kCheatTooltip,
      onPressed: () => toggleLeetCodeCheatSheet(context, ref),
    );
  }
}

/// Mounts `Ctrl+Shift+C` for the LeetCode branch.
///
/// The handler is registered for as long as the branch is alive, but it
/// **re-checks the router's location at key time**. The shell keeps every
/// branch alive and preloads several, so a handler that only gated at mount
/// time would claim the chord while the user is on Journal.
/// `shellTabShortcutsEnabled` is the existing precedent for a gate of this
/// shape.
///
/// The chord fires regardless of what has focus — a text field in the Track
/// form, the scratch editor, the description field in the sheet itself — so
/// there is no `isTextInputFocused` bail here. While the sheet is up it
/// handles the chord itself, which is what lets Editing drop to Viewing before
/// a second press closes.
class LeetCodeCheatSheetScope extends ConsumerStatefulWidget {
  const LeetCodeCheatSheetScope({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<LeetCodeCheatSheetScope> createState() =>
      _LeetCodeCheatSheetScopeState();
}

class _LeetCodeCheatSheetScopeState
    extends ConsumerState<LeetCodeCheatSheetScope> {
  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_handleKeyEvent);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_handleKeyEvent);
    super.dispose();
  }

  bool _handleKeyEvent(KeyEvent event) {
    if (!mounted || !isLeetCodeCheatChord(event)) return false;
    if (!_onLeetCodeRoute()) return false;
    // Already open: its own handler has the chord, and answering here too
    // would close it on the same press that was meant to drop it to Viewing.
    if (ref.read(leetCodeCheatSheetOpenProvider)) return false;
    unawaited(openLeetCodeCheatSheet(context, ref));
    return true;
  }

  bool _onLeetCodeRoute() =>
      leetCodeCheatChordAllowed(_currentLocation(ref.read(routerProvider)));

  @override
  Widget build(BuildContext context) => widget.child;
}

/// Whether [event] is `Ctrl+Shift+C`.
///
/// Free today: `study_keyboard_shortcuts.dart` explicitly bails out of its
/// bare-`C` scratch shortcut whenever Control is held, and nothing else in the
/// app binds it.
@visibleForTesting
bool isLeetCodeCheatChord(KeyEvent event) {
  if (event is! KeyDownEvent) return false;
  if (event.logicalKey != LogicalKeyboardKey.keyC) return false;
  if (!HardwareKeyboard.instance.isControlPressed) return false;
  return HardwareKeyboard.instance.isShiftPressed;
}

/// Whether the chord may fire at [location].
///
/// LeetCode only. Inert everywhere else in the app, `/study` included — the
/// flashcard section shares the session widgets but not this feature.
@visibleForTesting
bool leetCodeCheatChordAllowed(String location) =>
    location == '/leetcode' || location.startsWith('/leetcode/');

/// The router's current location, as `voyager_app.dart` reads it.
String _currentLocation(GoRouter router) =>
    router.routerDelegate.currentConfiguration.uri.path;

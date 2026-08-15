import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/utils/key_binding.dart';
import 'package:voyager/core/utils/keyboard_focus_utils.dart';
import 'package:voyager/domain/models/study_models.dart';

/// Keyboard shortcuts for an active Study/Cram session: Space always flips
/// the card (hardcoded — STUDY.md: "in ANY mode they should still be able
/// to press space to flip the card"), plus the 4 user-configurable grading
/// keys, active only once the back is showing, and U/R to step back and
/// forward through the session's own history. Uses a [HardwareKeyboard]
/// handler so it works with no widget in the tree holding focus, same
/// approach as [CalendarKeyboardShortcuts].
class StudyKeyboardShortcuts extends ConsumerStatefulWidget {
  const StudyKeyboardShortcuts({
    super.key,
    required this.child,
    required this.onSpace,
    required this.showingBack,
    this.onGrade,
    this.onUndo,
    this.onRedo,
    this.arrowsNavigateHistory = false,
  });

  final Widget child;
  final VoidCallback onSpace;

  /// Whether the card is currently showing its back — grading keys only
  /// fire once the answer has been revealed.
  final bool showingBack;
  final ValueChanged<StudyGrade>? onGrade;

  /// Step back to the previous card, and forward again into a step that was
  /// taken back. Null when there is nothing left in that direction, which is
  /// also what greys out the header buttons.
  final VoidCallback? onUndo;
  final VoidCallback? onRedo;

  /// Whether ←/→ step through the history alongside U/R. On for the review
  /// sessions, where nothing else claims the arrows; off for cram, where they
  /// already mean fail/pass and mirror the swipe.
  final bool arrowsNavigateHistory;

  @override
  ConsumerState<StudyKeyboardShortcuts> createState() =>
      _StudyKeyboardShortcutsState();
}

class _StudyKeyboardShortcutsState
    extends ConsumerState<StudyKeyboardShortcuts> {
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

  bool _enabled() {
    if (!mounted) return false;
    final route = ModalRoute.of(context);
    if (route?.isCurrent != true) return false;
    if (isTextInputFocused()) return false;
    if (!subtreeIsVisible(context)) return false;
    return true;
  }

  bool _handleKeyEvent(KeyEvent event) {
    if (!_enabled()) return false;
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) return false;

    if (event.logicalKey == LogicalKeyboardKey.space) {
      widget.onSpace();
      return true;
    }

    if (_handleGradeKey(event)) return true;
    return _handleHistoryKey(event);
  }

  /// The grading keys are checked before the history keys, so a user who has
  /// bound a grade to U or R still grades with it while the answer is showing.
  bool _handleGradeKey(KeyEvent event) {
    if (widget.onGrade == null || !widget.showingBack) return false;
    final settings = ref.read(settingsProvider).valueOrNull;
    if (settings == null) return false;

    if (matchesKeyBinding(event, settings.srsFailKey)) {
      widget.onGrade!(StudyGrade.fail);
      return true;
    }
    if (matchesKeyBinding(event, settings.srsHardKey)) {
      widget.onGrade!(StudyGrade.hard);
      return true;
    }
    if (matchesKeyBinding(event, settings.srsGoodKey)) {
      widget.onGrade!(StudyGrade.good);
      return true;
    }
    if (matchesKeyBinding(event, settings.srsEasyKey)) {
      widget.onGrade!(StudyGrade.easy);
      return true;
    }
    return false;
  }

  bool _handleHistoryKey(KeyEvent event) {
    // Bare keys only: Ctrl+R and friends belong to the platform, not here.
    if (HardwareKeyboard.instance.isControlPressed ||
        HardwareKeyboard.instance.isAltPressed ||
        HardwareKeyboard.instance.isMetaPressed) {
      return false;
    }

    final key = event.logicalKey;
    final isUndo =
        key == LogicalKeyboardKey.keyU ||
        (widget.arrowsNavigateHistory && key == LogicalKeyboardKey.arrowLeft);
    final isRedo =
        key == LogicalKeyboardKey.keyR ||
        (widget.arrowsNavigateHistory && key == LogicalKeyboardKey.arrowRight);

    if (isUndo) {
      widget.onUndo?.call();
      // Swallowed either way: with nothing to undo the key does nothing, but
      // it is still this session's key.
      return true;
    }
    if (isRedo) {
      widget.onRedo?.call();
      return true;
    }
    return false;
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:voyager/features/hotkeys/floaters/finance_floater.dart';
import 'package:voyager/features/hotkeys/floaters/floater_controller.dart';
import 'package:voyager/features/hotkeys/floaters/journal_floater.dart';
import 'package:voyager/features/hotkeys/floaters/todo_floater.dart';
import 'package:voyager/features/hotkeys/quick_capture.dart';

/// Shows the open floater in place of the app while the window is lent to it.
///
/// The app is never unmounted — its pages keep their state, drafts and
/// editing sessions — only hidden, kept out of focus and its tickers, and
/// laid out at the size it had before, so a 68px-tall window can't reflow
/// it into the phone layout.
class FloaterHost extends ConsumerStatefulWidget {
  const FloaterHost({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<FloaterHost> createState() => _FloaterHostState();
}

class _FloaterHostState extends ConsumerState<FloaterHost> {
  Size? _mainSize;

  @override
  Widget build(BuildContext context) {
    final controller = ref.watch(floaterControllerProvider);
    final kind = controller.active;
    final media = MediaQuery.of(context);
    // Still frozen after the floater closes, until the window is back at the
    // main placement: the frames in between are floater-sized, and one hidden
    // to the tray stays that size until it is next shown.
    final atMainSize = kind == null && controller.windowAtMainPlacement;
    if (atMainSize && !media.size.isEmpty) _mainSize = media.size;
    final frozen = atMainSize ? null : _mainSize;

    return Stack(
      fit: StackFit.expand,
      children: [
        Offstage(
          offstage: kind != null,
          child: TickerMode(
            enabled: kind == null,
            child: ExcludeFocus(
              excluding: kind != null,
              child: MediaQuery(
                data: frozen == null ? media : media.copyWith(size: frozen),
                child: OverflowBox(
                  alignment: Alignment.topLeft,
                  minWidth: frozen?.width,
                  maxWidth: frozen?.width,
                  minHeight: frozen?.height,
                  maxHeight: frozen?.height,
                  child: widget.child,
                ),
              ),
            ),
          ),
        ),
        if (kind != null)
          _FloaterSurface(kind: kind, confirmation: controller.confirmation),
      ],
    );
  }
}

class _FloaterSurface extends StatelessWidget {
  const _FloaterSurface({required this.kind, required this.confirmation});

  final QuickCaptureKind kind;
  final String? confirmation;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final confirmation = this.confirmation;
    return Material(
      color: theme.scaffoldBackgroundColor,
      child: DecoratedBox(
        position: DecorationPosition.foreground,
        decoration: BoxDecoration(
          border: Border.all(color: theme.colorScheme.outlineVariant),
        ),
        child: Stack(
          fit: StackFit.expand,
          children: [
            // Its own navigator, for the overlays the fields open (popovers,
            // tag suggestions, selection toolbars): the app's navigator is
            // offstage. Keyed so a replacement starts a fresh route. Without a
            // hero controller: the app's one would pass from the replaced
            // navigator to its successor, and the ownership check that runs
            // after that frame null-checks a navigator already gone.
            HeroControllerScope.none(
              child: Navigator(
                key: ValueKey(kind),
                onGenerateRoute: (_) => PageRouteBuilder<void>(
                  transitionDuration: Duration.zero,
                  pageBuilder: (_, _, _) => Material(
                    type: MaterialType.transparency,
                    child: switch (kind) {
                      QuickCaptureKind.todo => const TodoFloater(),
                      QuickCaptureKind.journal => const JournalFloater(),
                      QuickCaptureKind.finance => const FinanceFloater(),
                    },
                  ),
                ),
              ),
            ),
            if (confirmation != null)
              ColoredBox(
                color: theme.scaffoldBackgroundColor,
                child: Center(
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        PhosphorIconsRegular.checkCircle,
                        color: theme.colorScheme.primary,
                      ),
                      const SizedBox(width: 8),
                      Text(confirmation, style: theme.textTheme.titleSmall),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

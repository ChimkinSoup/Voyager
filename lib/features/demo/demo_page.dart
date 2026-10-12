import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/features/demo/weeping_cherry_canvas.dart';
import 'package:voyager/features/life_tracker/life_tracker_stats.dart';

/// Demo page showcasing a watercolour weeping cherry in a night sky, its
/// petals one per week of a life and the weeks lived fallen to the ground.
class DemoPage extends ConsumerStatefulWidget {
  const DemoPage({super.key});

  @override
  ConsumerState<DemoPage> createState() => _DemoPageState();
}

class _DemoPageState extends ConsumerState<DemoPage> {
  static const _inkColor = Color(0xFFE8E2D8);

  int _replayCount = 0;

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsProvider.settled);
    // Null until settings load, so the tree doesn't fall for zero weeks and
    // then again for the real count.
    final weeks = settings.hasValue
        ? weeksLivedFor(settings.value!.birthDate, DateTime.now()) ?? 0
        : null;

    final chrome = BoxDecoration(
      color: weepingNightColor.withValues(alpha: 0.85),
      borderRadius: BorderRadius.circular(8),
      border: Border.all(color: _inkColor.withValues(alpha: 0.15)),
    );

    return SizedBox.expand(
      child: Stack(
        children: [
          Positioned.fill(
            child: WeepingCherryCanvas(
              weeksLived: weeks,
              replayCount: _replayCount,
            ),
          ),
          Positioned(
            left: 24,
            top: 24,
            child: Row(
              children: [
                DecoratedBox(
                  decoration: chrome,
                  child: const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                    child: Text(
                      'Demo — Watercolour Weeping Cherry',
                      style: TextStyle(
                        color: _inkColor,
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 0.5,
                      ),
                    ),
                  ),
                ),
                if ((weeks ?? 0) > 0) ...[
                  const SizedBox(width: 8),
                  Tooltip(
                    message: 'Replay the weeks falling',
                    child: Material(
                      type: MaterialType.transparency,
                      child: InkWell(
                        borderRadius: BorderRadius.circular(8),
                        onTap: () => setState(() => _replayCount++),
                        child: Ink(
                          decoration: chrome,
                          padding: const EdgeInsets.all(9),
                          child: Icon(
                            PhosphorIconsRegular.arrowCounterClockwise,
                            size: 16,
                            color: _inkColor.withValues(alpha: 0.85),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

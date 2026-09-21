import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:voyager/core/layout/window_size_class.dart';
import 'package:voyager/core/motion/motion.dart';
import 'package:voyager/core/reminders/reminder_engine.dart';
import 'package:voyager/core/reminders/reminder_labels.dart';
import 'package:voyager/core/theme/voyager_theme.dart';
import 'package:voyager/core/widgets/glass_button.dart';
import 'package:voyager/domain/models/reminder_models.dart';
import 'package:voyager/features/shell/reveal_request.dart';
import 'package:voyager/routing/app_router.dart';

/// How many stickies are shown at once. The rest wait their turn behind a
/// count, so a morning of missed reminders cannot wall off the window.
const int _kMaxVisibleStickies = 3;

const double _kStickyWidth = 360;

/// Due reminders as sticky cards over the app (`SCHEDULED_REMINDERS_HLD.md`
/// §5.3). They stay until acknowledged or snoozed, and only the cards
/// themselves take the pointer: the gaps between and around them fall through
/// to the page.
///
/// Bottom of the window, away from [VoyagerToast]'s slot at the top, so a
/// transient toast never lands on a sticky's buttons.
class ReminderStickyStack extends ConsumerWidget {
  const ReminderStickyStack({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final engine = ref.watch(reminderEngineProvider);
    final due = engine.due;
    if (due.isEmpty) return const SizedBox.shrink();

    final compact = context.isCompactWidth;
    final padding = MediaQuery.paddingOf(context);
    final focused = engine.focusedSourceKey;
    // The focused card is always among the visible ones.
    final ordered = [
      ...due.where((v) => v.sourceKey == focused),
      ...due.where((v) => v.sourceKey != focused),
    ];
    final visible = ordered.take(_kMaxVisibleStickies).toList();
    final hidden = due.length - visible.length;

    final stack = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final view in visible)
          Padding(
            key: ValueKey(view.sourceKey),
            padding: const EdgeInsets.only(top: 8),
            child: _StickyReminderCard(
              view: view,
              focusGeneration: view.sourceKey == focused
                  ? engine.focusGeneration
                  : null,
            ),
          ),
        if (hidden > 0)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Align(
              alignment: Alignment.centerRight,
              child: _MoreBadge(count: hidden),
            ),
          ),
      ],
    );

    return Positioned(
      left: compact ? 16 : null,
      right: 16,
      // Above the phone shell's bottom navigation.
      bottom: padding.bottom + (compact ? 80 : 16),
      child: compact ? stack : SizedBox(width: _kStickyWidth, child: stack),
    );
  }
}

class _MoreBadge extends StatelessWidget {
  const _MoreBadge({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.surfaceContainerHighest,
      elevation: 2,
      borderRadius: BorderRadius.circular(VoyagerTheme.fieldRadius),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        child: Text(
          '+$count more',
          style: theme.textTheme.labelSmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}

class _StickyReminderCard extends ConsumerStatefulWidget {
  const _StickyReminderCard({required this.view, this.focusGeneration});

  final ReminderSourceView view;

  /// Non-null while an OS notification tap is pointing at this card; a new
  /// value replays the highlight.
  final int? focusGeneration;

  @override
  ConsumerState<_StickyReminderCard> createState() =>
      _StickyReminderCardState();
}

class _StickyReminderCardState extends ConsumerState<_StickyReminderCard>
    with SingleTickerProviderStateMixin {
  late final AnimationController _entrance;
  Timer? _highlightTimer;
  var _highlighted = false;
  var _busy = false;

  @override
  void initState() {
    super.initState();
    _entrance = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 220),
    )..forward();
    if (widget.focusGeneration != null) _highlight();
  }

  @override
  void didUpdateWidget(_StickyReminderCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.focusGeneration != null &&
        widget.focusGeneration != oldWidget.focusGeneration) {
      _highlight();
    }
  }

  void _highlight() {
    _highlightTimer?.cancel();
    setState(() => _highlighted = true);
    _highlightTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) setState(() => _highlighted = false);
    });
  }

  @override
  void dispose() {
    _highlightTimer?.cancel();
    _entrance.dispose();
    super.dispose();
  }

  Future<void> _run(Future<void> Function(ReminderEngine engine) action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action(ref.read(reminderEngineProvider));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _open() {
    final view = widget.view;
    final router = ref.read(routerProvider);
    final task = view.task;
    final event = view.event;
    if (task != null) {
      ref.read(revealRequestProvider.notifier).state = RevealRequest.task(task);
      router.go('/todo');
    } else if (event != null) {
      final key = view.evaluation?.occurrence?.key;
      final day = key == null ? null : DateTime.tryParse(key);
      ref.read(revealRequestProvider.notifier).state = RevealRequest.event(
        event,
        day: day == null ? null : DateTime(day.year, day.month, day.day),
      );
      router.go('/calendar');
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final view = widget.view;
    final isRule = view.sourceKind == ReminderSourceKind.scheduledRule;
    final dueSince = view.evaluation?.dueSince;
    final reduced = VoyagerMotion.reduced(context);
    final accent = theme.colorScheme.primary;

    final icon = switch (view.sourceKind) {
      ReminderSourceKind.scheduledRule => PhosphorIconsRegular.bellRinging,
      ReminderSourceKind.todo => PhosphorIconsRegular.checkSquare,
      ReminderSourceKind.calendarEvent => PhosphorIconsRegular.calendarDot,
    };
    final meta = [
      if (view.subtitle case final subtitle? when subtitle.isNotEmpty) subtitle,
      if (isRule && dueSince != null)
        'Due ${reminderWhenLabel(dueSince, DateTime.now())}',
    ];

    final text = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          view.title,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.bodyMedium?.copyWith(
            fontWeight: FontWeight.w600,
            decoration: isRule ? null : TextDecoration.underline,
            decorationColor: theme.colorScheme.onSurfaceVariant.withValues(
              alpha: 0.4,
            ),
          ),
        ),
        for (final line in meta)
          Text(
            line,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
      ],
    );

    final card = Material(
      color: theme.colorScheme.surfaceContainerHighest,
      // Bells ride lighter than the reminders the user wrote on purpose.
      elevation: isRule ? 6 : 3,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: _highlighted
            ? BorderSide(color: accent, width: 1.5)
            : BorderSide.none,
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 10, 10, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Icon(icon, size: 16, color: accent),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: isRule
                      ? text
                      : Semantics(
                          button: true,
                          label: 'Open ${view.title}',
                          child: MouseRegion(
                            cursor: SystemMouseCursors.click,
                            child: GestureDetector(onTap: _open, child: text),
                          ),
                        ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Wrap(
              alignment: WrapAlignment.end,
              spacing: 6,
              runSpacing: 6,
              children: [
                GlassButton(
                  dense: true,
                  label: 'Snooze 10 min',
                  enabled: !_busy,
                  onPressed: () => _run(
                    (engine) => engine.snooze(
                      view.sourceKey,
                      ReminderSnooze.tenMinutes,
                    ),
                  ),
                ),
                GlassButton(
                  dense: true,
                  label: 'Tomorrow',
                  enabled: !_busy,
                  onPressed: () => _run(
                    (engine) =>
                        engine.snooze(view.sourceKey, ReminderSnooze.tomorrow),
                  ),
                ),
                GlassButton(
                  dense: true,
                  label: 'Acknowledge',
                  color: accent,
                  enabled: !_busy,
                  onPressed: () =>
                      _run((engine) => engine.acknowledge(view.sourceKey)),
                ),
              ],
            ),
          ],
        ),
      ),
    );

    return FadeTransition(
      opacity: _entrance,
      child: SlideTransition(
        position:
            Tween<Offset>(
              begin: reduced ? Offset.zero : const Offset(0, 0.2),
              end: Offset.zero,
            ).animate(
              CurvedAnimation(
                parent: _entrance,
                curve: reduced ? Curves.easeOut : VoyagerSpring.moveCurve,
              ),
            ),
        child: card,
      ),
    );
  }
}

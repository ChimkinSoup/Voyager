import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/motion/motion.dart';
import 'package:voyager/core/theme/voyager_theme.dart';
import 'package:voyager/core/utils/calendar_days.dart';
import 'package:voyager/core/widgets/context_menu.dart';
import 'package:voyager/domain/models/finance_models.dart';
import 'package:voyager/domain/services/finance_analytics.dart';
import 'package:voyager/features/finance/finance_net_flow_calendar.dart';
import 'package:voyager/features/finance/finance_net_flow_chart.dart';
import 'package:voyager/features/finance/finance_ui_prefs.dart';
import 'package:voyager/features/leetcode/leetcode_detail_view.dart';

/// Fraction of the open over which the expanded card fades in — the same
/// gesture as LeetCode's activity card, so the same number.
const double _kCardFadeInFraction = 0.3;

/// Height of the expanded chart, dated axis included. It has to clear the
/// hover bubble, which is laid out inside the chart's own box and is ~90 tall.
const double _kExpandedChartHeight = 180;

/// First day, at local midnight, of [range] ending on [today].
DateTime financeHeroRangeStart(FinanceHeroRange range, DateTime today) {
  final day = DateTime(today.year, today.month, today.day);
  return switch (range) {
    FinanceHeroRange.month => DateTime(day.year, day.month, 1),
    FinanceHeroRange.d7 => addCalendarDays(day, -6),
    FinanceHeroRange.d30 => addCalendarDays(day, -29),
    FinanceHeroRange.d90 => addCalendarDays(day, -89),
    FinanceHeroRange.ytd => DateTime(day.year, 1, 1),
  };
}

String _rangeLabel(FinanceHeroRange range) => switch (range) {
  FinanceHeroRange.month => 'Month',
  FinanceHeroRange.d7 => '7D',
  FinanceHeroRange.d30 => '30D',
  FinanceHeroRange.d90 => '90D',
  FinanceHeroRange.ytd => 'YTD',
};

/// The finance page's hero: this month's net so far, how that compares with
/// the same stretch of last month, and each day of the month as a signed line.
///
/// A glance surface. The plot takes no pointer at all; the whole card is one
/// tap target that grows into [openFinanceNetFlowView].
///
/// Always reads the full ledger. A tag filter on the ledger below narrows the
/// rows, never this.
class FinanceNetFlowHero extends StatefulWidget {
  const FinanceNetFlowHero({super.key, required this.transactions});

  final List<FinancialTransaction> transactions;

  @override
  State<FinanceNetFlowHero> createState() => _FinanceNetFlowHeroState();
}

class _FinanceNetFlowHeroState extends State<FinanceNetFlowHero> {
  final _key = GlobalKey();
  bool _hovered = false;

  void _open() {
    final box = _key.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return;
    openFinanceNetFlowView(context, box.localToGlobal(Offset.zero) & box.size);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent = theme.colorScheme.primary;
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final transactions = widget.transactions;

    // Month start through today: the number, the line and the delta all
    // cover the same days, so post-dated rows count in none of them.
    final monthNet = monthToDateNet(transactions, today);
    final delta = monthNet - priorMonthToDateNet(transactions, today);
    final flows = dailyNetSeries(
      transactions,
      from: DateTime(today.year, today.month, 1),
      to: today,
    );

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: _open,
        behavior: HitTestBehavior.opaque,
        child: Container(
          key: _key,
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHighest.withValues(
              alpha: _hovered ? 0.5 : 0.35,
            ),
            borderRadius: BorderRadius.circular(18),
            border: Border.all(
              color: accent.withValues(alpha: _hovered ? 0.35 : 0.12),
            ),
          ),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final chartWidth = (constraints.maxWidth * 0.45).clamp(
                120.0,
                360.0,
              );
              return Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          'Net flow · ${DateFormat.MMMM().format(now)}',
                          style: theme.textTheme.labelMedium?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                            letterSpacing: 0.5,
                          ),
                        ),
                        const SizedBox(height: 6),
                        FittedBox(
                          fit: BoxFit.scaleDown,
                          alignment: Alignment.centerLeft,
                          child: Text(
                            formatCents(monthNet, signed: true),
                            style: theme.textTheme.displaySmall?.copyWith(
                              color: netFlowSignColor(monthNet, theme),
                              fontWeight: FontWeight.w700,
                              letterSpacing: -0.5,
                            ),
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '${formatCents(delta, signed: true)} vs last month',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.labelMedium?.copyWith(
                            color: netFlowSignColor(delta, theme),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 16),
                  SizedBox(
                    width: chartWidth,
                    height: 64,
                    // fl_chart hit-tests its plot even with touches off; the
                    // card's tap has to win everywhere on it.
                    child: IgnorePointer(
                      child: FinanceNetFlowChart(flows: flows, compact: true),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Align(
                    alignment: Alignment.topCenter,
                    child: Icon(
                      PhosphorIconsRegular.arrowsOut,
                      size: 14,
                      color: theme.colorScheme.onSurfaceVariant.withValues(
                        alpha: _hovered ? 0.8 : 0.4,
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

/// Grows the net-flow view out of [anchorRect] into a card inset from the
/// window edge — LeetCode's activity zoom (openLeetCodeActivityView is the
/// source of truth for the choreography). Escape, back, the close button or a
/// tap on the darkened margin shrinks it back.
Future<void> openFinanceNetFlowView(BuildContext context, Rect anchorRect) {
  return Navigator.of(context, rootNavigator: true).push(
    PageRouteBuilder<void>(
      opaque: false,
      barrierColor: Colors.transparent,
      barrierDismissible: false,
      transitionDuration: Duration.zero,
      reverseTransitionDuration: Duration.zero,
      pageBuilder: (context, animation, secondaryAnimation) =>
          _NetFlowOverlay(anchorRect: anchorRect),
    ),
  );
}

class _NetFlowOverlay extends StatefulWidget {
  const _NetFlowOverlay({required this.anchorRect});

  final Rect anchorRect;

  @override
  State<_NetFlowOverlay> createState() => _NetFlowOverlayState();
}

class _NetFlowOverlayState extends State<_NetFlowOverlay>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 300),
  );
  bool _closing = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _controller.forward();
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _close() async {
    if (_closing) return;
    _closing = true;
    await _controller.reverse();
    if (mounted) Navigator.of(context).pop();
  }

  /// Shrinks back, then takes the ledger to [day].
  ///
  /// The container is captured before closing: once the route pops, this
  /// overlay's context is gone. The filter and the jump go out as the close
  /// starts, so an empty day's placeholder header is laid out under the
  /// shrinking view instead of popping in after it; the tab switch and the
  /// scroll wait for the close so they happen on a page the user can see.
  Future<void> _jumpTo(DateTime day) async {
    if (_closing) return;
    final container = ProviderScope.containerOf(context, listen: false);
    final closed = _close();
    container.read(financeLedgerTagFilterProvider.notifier).state = null;
    container.read(financeLedgerJumpProvider.notifier).state =
        FinanceLedgerJump(day, ready: closed);
    await closed;
    container
        .read(financeUiPrefsProvider.notifier)
        .setViewMode(FinanceViewMode.ledger);
  }

  @override
  Widget build(BuildContext context) {
    final targetRect = leetCodeZoomRect(
      Offset.zero & MediaQuery.sizeOf(context),
    );
    final reducedMotion = VoyagerMotion.reduced(context);

    return CallbackShortcuts(
      bindings: {const SingleActivator(LogicalKeyboardKey.escape): _close},
      child: Focus(
        autofocus: true,
        child: PopScope(
          canPop: false,
          onPopInvokedWithResult: (didPop, _) {
            if (!didPop) _close();
          },
          child: Material(
            color: Colors.black.withValues(alpha: 0.001),
            child: AnimatedBuilder(
              animation: _controller,
              builder: (context, child) {
                final raw = _controller.value.clamp(0.0, 1.0);
                final scrim = Positioned.fill(
                  child: GestureDetector(
                    onTap: _close,
                    child: ColoredBox(
                      color: Color.lerp(
                        Colors.transparent,
                        VoyagerColors.of(context).scrim,
                        raw,
                      )!,
                    ),
                  ),
                );
                if (reducedMotion) {
                  return Stack(
                    children: [
                      scrim,
                      Positioned.fromRect(
                        rect: targetRect,
                        child: Opacity(opacity: raw, child: child),
                      ),
                    ],
                  );
                }
                final t = VoyagerSpring.moveCurve.transform(raw);
                final rect = Rect.lerp(widget.anchorRect, targetRect, t)!;
                return Stack(
                  children: [
                    scrim,
                    // Laid out at its final size and scaled, not resized: a
                    // chart and a year of month tiles reflowed through the
                    // hero's width overflow on the first frames.
                    Positioned.fromRect(
                      rect: targetRect,
                      child: Transform(
                        alignment: Alignment.topLeft,
                        transform: Matrix4.identity()
                          ..translateByDouble(
                            rect.left - targetRect.left,
                            rect.top - targetRect.top,
                            0,
                            1,
                          )
                          ..scaleByDouble(
                            rect.width / targetRect.width,
                            rect.height / targetRect.height,
                            1,
                            1,
                          ),
                        child: Opacity(
                          opacity: (t / _kCardFadeInFraction).clamp(0.0, 1.0),
                          child: child,
                        ),
                      ),
                    ),
                  ],
                );
              },
              child: _NetFlowDetailCard(onClose: _close, onDayTap: _jumpTo),
            ),
          ),
        ),
      ),
    );
  }
}

class _NetFlowDetailCard extends ConsumerStatefulWidget {
  const _NetFlowDetailCard({required this.onClose, required this.onDayTap});

  final VoidCallback onClose;
  final ValueChanged<DateTime> onDayTap;

  @override
  ConsumerState<_NetFlowDetailCard> createState() => _NetFlowDetailCardState();
}

class _NetFlowDetailCardState extends ConsumerState<_NetFlowDetailCard> {
  /// The legend's solo series, or null for all three. Session-only.
  NetFlowSeries? _selected;

  /// The category the view is narrowed to, or null for All. Session-only.
  String? _categoryId;

  final _categoryMenuKey = GlobalKey<ContextMenuRegionState>();
  final _categoryButtonKey = GlobalKey();

  void _toggle(NetFlowSeries series) => setState(() {
    _selected = _selected == series ? null : series;
  });

  void _openCategoryMenu() {
    final box =
        _categoryButtonKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null) return;
    _categoryMenuKey.currentState?.openMenuAt(
      box.localToGlobal(box.size.bottomLeft(Offset.zero)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final transactions =
        ref.watch(transactionsProvider).valueOrNull ?? const [];
    final categories =
        ref.watch(financeCategoriesProvider).valueOrNull ?? const [];
    final range = ref.watch(
      financeUiPrefsProvider.select((prefs) => prefs.heroExpandRange),
    );

    // A category deleted while the view is open quietly falls back to All.
    final category = categories.where((c) => c.id == _categoryId).firstOrNull;
    final where = category == null
        ? null
        : (FinancialTransaction t) => t.tags.any(category.containsTag);

    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final rangeStart = financeHeroRangeStart(range, today);
    final flows = dailyNetSeries(
      transactions,
      from: rangeStart,
      to: today,
      where: where,
    );

    return Material(
      color: theme.colorScheme.surface,
      elevation: 8,
      borderRadius: BorderRadius.circular(20),
      clipBehavior: Clip.antiAlias,
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      'Net flow per day',
                      style: theme.textTheme.labelLarge,
                    ),
                  ),
                  IconButton(
                    onPressed: widget.onClose,
                    icon: const Icon(PhosphorIconsRegular.x, size: 20),
                    visualDensity: VisualDensity.compact,
                    tooltip: 'Close',
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Wrap(
                spacing: 12,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  SegmentedButton<FinanceHeroRange>(
                    showSelectedIcon: false,
                    style: SegmentedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      visualDensity: VisualDensity.compact,
                    ),
                    segments: [
                      for (final value in FinanceHeroRange.values)
                        ButtonSegment(
                          value: value,
                          label: Text(_rangeLabel(value)),
                        ),
                    ],
                    selected: {range},
                    onSelectionChanged: (set) {
                      if (set.isEmpty) return;
                      ref
                          .read(financeUiPrefsProvider.notifier)
                          .setHeroExpandRange(set.first);
                    },
                  ),
                  ContextMenuRegion(
                    key: _categoryMenuKey,
                    itemsBuilder: () => [
                      ContextMenuItem(
                        label: 'All categories',
                        icon: category == null
                            ? PhosphorIconsRegular.check
                            : null,
                        onTap: () => setState(() => _categoryId = null),
                      ),
                      for (final c in categories)
                        ContextMenuItem(
                          label: c.name,
                          icon: c.id == category?.id
                              ? PhosphorIconsRegular.check
                              : null,
                          onTap: () => setState(() => _categoryId = c.id),
                        ),
                    ],
                    child: TextButton.icon(
                      key: _categoryButtonKey,
                      onPressed: _openCategoryMenu,
                      icon: const Icon(PhosphorIconsRegular.funnel, size: 15),
                      label: Text(category?.name ?? 'All categories'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Align(
                alignment: Alignment.centerLeft,
                child: FinanceNetFlowLegend(
                  flows: flows,
                  selected: _selected,
                  onSelect: _toggle,
                ),
              ),
              const SizedBox(height: 10),
              SizedBox(
                height: _kExpandedChartHeight,
                child: Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: FinanceNetFlowChart(flows: flows, selected: _selected),
                ),
              ),
              const SizedBox(height: 12),
              Expanded(
                child: FinanceNetFlowCalendar(
                  transactions: transactions,
                  where: where,
                  series: _selected ?? NetFlowSeries.net,
                  rangeStart: rangeStart,
                  today: today,
                  onDayTap: widget.onDayTap,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

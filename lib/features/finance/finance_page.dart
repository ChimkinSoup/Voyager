import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/dev/dev_flags.dart';
import 'package:voyager/core/motion/motion.dart';
import 'package:voyager/core/soft_delete/soft_delete_toast.dart';
import 'package:voyager/core/text/prose_text_span.dart';
import 'package:voyager/core/text/styled_runs.dart';
import 'package:voyager/core/utils/ids.dart';
import 'package:voyager/core/widgets/context_menu.dart';
import 'package:voyager/core/widgets/glass_button.dart';
import 'package:voyager/core/widgets/keep_alive_scroll.dart';
import 'package:voyager/core/widgets/prose_highlight_underlay.dart';
import 'package:voyager/core/widgets/tag_chip.dart';
import 'package:voyager/domain/models/enums.dart';
import 'package:voyager/domain/models/finance_models.dart';
import 'package:voyager/domain/services/finance_origins.dart';
import 'package:voyager/features/finance/finance_analytics_view.dart';
import 'package:voyager/features/finance/finance_bill_radar.dart';
import 'package:voyager/features/finance/finance_budget_panel.dart';
import 'package:voyager/features/finance/finance_goals_view.dart';
import 'package:voyager/features/finance/finance_net_flow_hero.dart';
import 'package:voyager/features/finance/finance_transaction_modal.dart';
import 'package:voyager/features/finance/finance_ui_prefs.dart';
import 'package:voyager/features/shell/shell_page_storage_keys.dart';

/// Screen width at/above which the dashboard splits into ledger (left 60%) and
/// insights sidebar (right 40%).
const double _kSplitBreakpoint = 880;

class FinancePage extends ConsumerWidget {
  const FinancePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final transactionsAsync = ref.watch(transactionsProvider);
    final tagColorsAsync = ref.watch(tagColorsProvider);
    final tagColors = tagColorsAsync.valueOrNull ?? const <String, int>{};

    return Scaffold(
      backgroundColor: Colors.transparent,
      floatingActionButton: GlassButton(
        tooltip: 'Log transaction',
        onPressed: () => showFinanceTransactionModal(context, ref),
        icon: const Icon(PhosphorIconsRegular.plus),
        width: 56,
        height: 56,
        borderRadius: BorderRadius.circular(28),
        elevation: 3,
      ),
      body: transactionsAsync.when(
        data: (transactions) =>
            _FinanceView(transactions: transactions, tagColors: tagColors),
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => _LedgerError(
          onRetry: () => ref.invalidate(transactionsProvider),
        ),
      ),
    );
  }
}

class _FinanceView extends ConsumerStatefulWidget {
  const _FinanceView({required this.transactions, required this.tagColors});

  final List<FinancialTransaction> transactions;
  final Map<String, int> tagColors;

  @override
  ConsumerState<_FinanceView> createState() => _FinanceViewState();
}

/// Everything that affects what a `_TransactionRow` renders. Used to decide
/// whether a cached row widget instance (see `_FinanceViewState._rowFor`)
/// can be reused as-is.
typedef _TxnRowSignature = ({
  TransactionType type,
  int amountCents,
  String? origin,
  String? note,
  String tagsKey,
  Map<String, int> tagColors,
  // occurredAt and updatedAt aren't rendered by the row, but the cached
  // widget holds the whole FinancialTransaction and hands it to the edit
  // modal on tap. Without them a date-only edit keeps serving the pre-edit
  // model, so re-saving reverts the date and re-uses the stale version.
  // updatedAt is bumped by every repository write, so it covers version,
  // deletedAt and any field added later.
  DateTime occurredAt,
  DateTime updatedAt,
});

/// A day-group header in the flattened ledger entry list (see
/// `_FinanceViewState._ledgerEntries`).
class _LedgerDayHeader {
  const _LedgerDayHeader({required this.day, required this.netCents});
  final DateTime day;
  final int netCents;
}

/// Heads the future-dated day groups at the top of the ledger — transactions
/// no total counts yet (see [settledTransactions]).
class _LedgerUpcomingHeader {
  const _LedgerUpcomingHeader();
}

/// Marks the gap after a day group in the flattened ledger entry list.
class _LedgerSpacer {
  const _LedgerSpacer();
}

/// Stands in for the rows of a day a ledger jump landed on that has none.
class _LedgerEmptyDay {
  const _LedgerEmptyDay();
}

/// The flattened ledger plus the position of every transaction in it, built
/// once per build by `_FinanceViewState._ledgerModel`.
class _LedgerModel {
  const _LedgerModel({
    this.entries = const [],
    this.indexById = const {},
  });

  final List<Object> entries;
  final Map<String, int> indexById;
}

const _ledgerSpacer = _LedgerSpacer();
const _ledgerEmptyDay = _LedgerEmptyDay();
const _ledgerUpcomingHeader = _LedgerUpcomingHeader();

class _FinanceViewState extends ConsumerState<_FinanceView> {
  // Reuses the same _TransactionRow widget instance across rebuilds for
  // transactions whose _TxnRowSignature hasn't changed, so Flutter's element
  // reconciliation skips rebuilding them entirely — a single delete/edit
  // invalidates transactionsProvider wholesale (see _TransactionRow's
  // onLongPress below), which would otherwise reconstruct, and thus rebuild,
  // every mounted row, not just the one that changed. Keyed by transaction
  // id; pruned to the ids actually present at the end of every build.
  final _rowWidgetCache = <String, _TransactionRow>{};
  final _rowSignatureCache = <String, _TxnRowSignature>{};

  // Ledger jumps (from the hero's expanded view). Only one of the two
  // scrollers is attached at a time, depending on the split breakpoint.
  final _wideScroll = ScrollController();
  final _narrowScroll = ScrollController();
  final _headerKeys = <DateTime, GlobalKey>{};
  _LedgerModel _ledger = const _LedgerModel();

  /// The day the last jump landed on, when it has no rows — see
  /// [_ledgerModel]. Cleared by the next jump or by leaving the Ledger tab.
  DateTime? _emptyJumpDay;

  /// Bumped per jump so a slow search gives way to a newer request.
  var _jumpGeneration = 0;

  /// The tab the last build showed. A jump arrives with the Ledger tab
  /// already requested but not yet built.
  var _builtMode = FinanceViewMode.ledger;

  @override
  void dispose() {
    _wideScroll.dispose();
    _narrowScroll.dispose();
    super.dispose();
  }

  void _jumpToDay(DateTime day, {Future<void>? ready}) {
    final hasRows = widget.transactions.any(
      (t) =>
          t.occurredAt.year == day.year &&
          t.occurredAt.month == day.month &&
          t.occurredAt.day == day.day,
    );
    setState(() => _emptyJumpDay = hasRows ? null : day);
    _scrollToDay(
      day,
      ++_jumpGeneration,
      switchingTabs: _builtMode != FinanceViewMode.ledger,
      ready: ready,
    );
  }

  /// Scrolls the ledger until [day]'s header is at the top of it.
  ///
  /// The ledger is a lazy sliver of rows with different heights, so there is
  /// no offset to compute up front. Instead this bisects: jump, let a frame
  /// build, see whether the headers now on screen are newer or older than
  /// [day], and halve the range. Once the header itself has been built,
  /// [Scrollable.ensureVisible] finishes the move.
  ///
  /// Nothing moves until [ready] completes (the hero's view closing).
  ///
  /// When the jump also switches tabs, it waits the crossfade out first.
  /// [VoyagerCrossfadeIndex] wraps the arriving page in an opacity and a scale
  /// only while it animates, so the ledger's scroll view is rebuilt from
  /// scratch when those wrappers come off. A scroll started before that is
  /// disposed half-way, and the new view restores the half-way offset.
  Future<void> _scrollToDay(
    DateTime day,
    int generation, {
    required bool switchingTabs,
    Future<void>? ready,
  }) async {
    if (ready != null) await ready;
    if (!mounted || generation != _jumpGeneration) return;
    if (switchingTabs) {
      await Future<void>.delayed(
        (VoyagerMotion.reduced(context)
                ? VoyagerMotion.crossfade
                : kVoyagerCrossfadeDuration) +
            const Duration(milliseconds: 100),
      );
    }
    double? lower;
    double? upper;
    for (var attempt = 0; attempt < 40; attempt++) {
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted || generation != _jumpGeneration) return;

      final target = _headerKeys[day]?.currentContext;
      if (target != null && target.mounted) {
        await Scrollable.ensureVisible(
          target,
          duration: VoyagerMotion.reduced(context)
              ? Duration.zero
              : const Duration(milliseconds: 300),
          curve: Curves.easeOutCubic,
        );
        return;
      }

      final controller = _wideScroll.hasClients
          ? _wideScroll
          : _narrowScroll.hasClients
          ? _narrowScroll
          : null;
      // Not laid out yet (the tab is still switching in); try next frame.
      if (controller == null) continue;
      final position = controller.position;

      final built = [
        for (final entry in _headerKeys.entries)
          if (entry.value.currentContext != null) entry.key,
      ];
      // Newest day first, so a target older than everything built lies
      // further down.
      if (built.isNotEmpty && built.every((d) => d.isAfter(day))) {
        lower = position.pixels;
      } else if (built.isNotEmpty && built.every((d) => d.isBefore(day))) {
        upper = position.pixels;
      } else if (built.isNotEmpty) {
        // Built on both sides but not itself: it isn't in the ledger.
        return;
      }

      final double next;
      if (lower == null && upper == null) {
        final index = _ledger.entries.indexWhere(
          (e) => e is _LedgerDayHeader && e.day == day,
        );
        if (index < 0) return;
        next = position.maxScrollExtent * index / _ledger.entries.length;
      } else {
        final lo = lower ?? position.minScrollExtent;
        final hi = upper ?? position.maxScrollExtent;
        next = (lo + hi) / 2;
      }
      final clamped = next.clamp(
        position.minScrollExtent,
        position.maxScrollExtent,
      );
      if ((clamped - position.pixels).abs() < 1) return;
      position.jumpTo(clamped);
    }
  }

  _TransactionRow _rowFor(
    FinancialTransaction transaction,
    Map<String, int> tagColors,
  ) {
    final signature = (
      type: transaction.type,
      amountCents: transaction.amountCents,
      origin: transaction.origin,
      note: transaction.note,
      // transaction.tags is a fresh List instance on every fetch even when
      // unchanged, and a record's == on a List field is reference identity
      // — comparing it directly would defeat the cache for every tagged
      // row. The separator keeps ["ab"] and ["a", "b"] from colliding.
      tagsKey: transaction.tags.join(String.fromCharCode(0)),
      tagColors: tagColors,
      occurredAt: transaction.occurredAt,
      updatedAt: transaction.updatedAt,
    );
    final cached = _rowWidgetCache[transaction.id];
    if (cached != null && _rowSignatureCache[transaction.id] == signature) {
      return cached;
    }
    final row = _TransactionRow(
      key: ValueKey(transaction.id),
      transaction: transaction,
      tagColors: tagColors,
    );
    _rowWidgetCache[transaction.id] = row;
    _rowSignatureCache[transaction.id] = signature;
    return row;
  }

  /// Flattens the day-grouped ledger into an index a sliver can build
  /// lazily: a header, that day's transactions, then a spacer, newest day
  /// first. Days after today sit under one Upcoming header, so a post-dated
  /// row topping the feed reads as scheduled rather than as the latest
  /// spend. [_LedgerModel.indexById] records where each transaction landed so
  /// `findChildIndexCallback` can look a row up without scanning.
  ///
  /// [emptyDay] is a day a ledger jump landed on that holds no rows: it gets a
  /// header and a "no transactions" line in its date slot, so the jump shows
  /// the day it was asked for rather than a neighbour.
  _LedgerModel _ledgerModel(
    List<FinancialTransaction> transactions,
    DateTime now, {
    DateTime? emptyDay,
  }) {
    if (transactions.isEmpty) return const _LedgerModel();
    final groups = <DateTime, List<FinancialTransaction>>{};
    for (final t in transactions) {
      final day = DateTime(
        t.occurredAt.year,
        t.occurredAt.month,
        t.occurredAt.day,
      );
      groups.putIfAbsent(day, () => []).add(t);
    }
    if (emptyDay != null) groups.putIfAbsent(emptyDay, () => []);
    final days = groups.keys.toList()..sort((a, b) => b.compareTo(a));

    final today = DateTime(now.year, now.month, now.day);
    final entries = <Object>[];
    final indexById = <String, int>{};
    // Days sort newest first, so any future ones lead the list.
    if (days.first.isAfter(today)) entries.add(_ledgerUpcomingHeader);
    for (final day in days) {
      final dayTransactions = groups[day]!;
      final dayNet = dayTransactions.fold<int>(
        0,
        (sum, t) => sum + t.signedCents,
      );
      entries.add(_LedgerDayHeader(day: day, netCents: dayNet));
      if (dayTransactions.isEmpty) entries.add(_ledgerEmptyDay);
      for (final t in dayTransactions) {
        indexById[t.id] = entries.length;
        entries.add(t);
      }
      entries.add(_ledgerSpacer);
    }
    return _LedgerModel(entries: entries, indexById: indexById);
  }

  Widget _ledgerEntryAt(
    List<Object> entries,
    Map<String, int> tagColors,
    int index,
  ) {
    final entry = entries[index];
    if (entry is _LedgerDayHeader) {
      // Keyed so a ledger jump can find the header once it is built.
      return KeyedSubtree(
        key: _headerKeys.putIfAbsent(entry.day, GlobalKey.new),
        child: _DayHeader(day: entry.day, netCents: entry.netCents),
      );
    }
    if (entry is _LedgerSpacer) {
      return const SizedBox(height: 12);
    }
    if (entry is _LedgerEmptyDay) {
      return const _EmptyDayRow();
    }
    if (entry is _LedgerUpcomingHeader) {
      return const _UpcomingHeader();
    }
    return _rowFor(entry as FinancialTransaction, tagColors);
  }

  /// The ledger as a lazily-built sliver, or the empty state as a single
  /// sliver item when there are no transactions.
  Widget _ledgerSliver(
    _LedgerModel ledger,
    Map<String, int> tagColors, {
    String? tagFilter,
  }) {
    final entries = ledger.entries;
    if (entries.isEmpty) {
      return SliverToBoxAdapter(child: _EmptyLedger(tagFilter: tagFilter));
    }
    return SliverList(
      delegate: SliverChildBuilderDelegate(
        (context, index) => _ledgerEntryAt(entries, tagColors, index),
        childCount: entries.length,
        // A transaction added/removed anywhere shifts every entry after it
        // to a new index. Without this, the framework can't match a
        // `_TransactionRow`'s ValueKey back to its old Element when that
        // happens, so it destroys and recreates every shifted row instead of
        // reusing `_rowFor`'s cached widget — same issue as todo's row list.
        // The framework asks once per keyed child it is relocating, so this
        // has to be a map read: scanning `entries` here would make a single
        // rebuild quadratic in the size of the ledger.
        findChildIndexCallback: (key) =>
            key is ValueKey<String> ? ledger.indexById[key.value] : null,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final transactions = widget.transactions;
    final tagColors = widget.tagColors;
    final liveIds = {for (final t in transactions) t.id};
    _rowWidgetCache.removeWhere((id, _) => !liveIds.contains(id));
    _rowSignatureCache.removeWhere((id, _) => !liveIds.contains(id));

    final mode = ref.watch(
      financeUiPrefsProvider.select((prefs) => prefs.viewMode),
    );
    _builtMode = mode;
    final tagFilter = ref.watch(financeLedgerTagFilterProvider);
    final now = DateTime.now();

    ref.listen<FinanceLedgerJump?>(financeLedgerJumpProvider, (_, jump) {
      if (jump != null) _jumpToDay(jump.day, ready: jump.ready);
    });
    // The placeholder header a jump left behind belongs to that visit to the
    // ledger, not to the ledger.
    ref.listen<FinanceViewMode>(
      financeUiPrefsProvider.select((prefs) => prefs.viewMode),
      (_, next) {
        if (next != FinanceViewMode.ledger && _emptyJumpDay != null) {
          setState(() => _emptyJumpDay = null);
        }
      },
    );

    // Grouped once here rather than inside the LayoutBuilder below: it
    // doesn't depend on the constraints, and the builder re-runs on every
    // layout pass — every frame of a window-resize drag.
    //
    // The filter narrows the ledger only. The hero above it keeps reading the
    // whole month: it answers "how am I doing", which a filter applied to one
    // tag would turn into a different and much less useful number without
    // saying so.
    final ledger = _ledgerModel(
      tagFilter == null
          ? transactions
          : transactions
                .where(
                  (t) =>
                      t.type == TransactionType.expense &&
                      t.tags.contains(tagFilter),
                )
                .toList(),
      now,
      emptyDay: _emptyJumpDay,
    );
    _ledger = ledger;
    final ledgerDays = {
      for (final entry in ledger.entries)
        if (entry is _LedgerDayHeader) entry.day,
    };
    _headerKeys.removeWhere((day, _) => !ledgerDays.contains(day));

    final hero = FinanceNetFlowHero(transactions: transactions);

    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= _kSplitBreakpoint;
        final horizontal = wide ? 20.0 : 16.0;

        final header = Padding(
          padding: EdgeInsets.fromLTRB(horizontal, 20, horizontal, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              hero,
              const SizedBox(height: 12),
              Align(
                alignment: Alignment.centerLeft,
                child: SegmentedButton<FinanceViewMode>(
                  showSelectedIcon: false,
                  style: SegmentedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    visualDensity: VisualDensity.compact,
                  ),
                  segments: const [
                    ButtonSegment(
                      value: FinanceViewMode.ledger,
                      icon: Icon(PhosphorIconsRegular.receipt, size: 15),
                      label: Text('Ledger'),
                    ),
                    ButtonSegment(
                      value: FinanceViewMode.analytics,
                      icon: Icon(PhosphorIconsRegular.chartLine, size: 15),
                      label: Text('Analytics'),
                    ),
                    ButtonSegment(
                      value: FinanceViewMode.goals,
                      icon: Icon(PhosphorIconsRegular.flag, size: 15),
                      label: Text('Goals'),
                    ),
                  ],
                  selected: {mode},
                  onSelectionChanged: (set) {
                    if (set.isNotEmpty) {
                      ref
                          .read(financeUiPrefsProvider.notifier)
                          .setViewMode(set.first);
                    }
                  },
                ),
              ),
              if (mode == FinanceViewMode.ledger && tagFilter != null) ...[
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerLeft,
                  child: _LedgerFilterChip(
                    tag: tagFilter,
                    onClear: () => ref
                        .read(financeLedgerTagFilterProvider.notifier)
                        .state = null,
                  ),
                ),
              ],
            ],
          ),
        );

        final Widget ledgerBody;
        if (wide) {
          ledgerBody = Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                flex: 6,
                child: KeepAliveCustomScrollView(
                  storageKey: ShellPageStorageKeys.financeLedgerWide,
                  controller: _wideScroll,
                  slivers: [
                    SliverPadding(
                      padding: const EdgeInsets.fromLTRB(20, 4, 12, 96),
                      sliver: _ledgerSliver(
                        ledger,
                        tagColors,
                        tagFilter: tagFilter,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              const Expanded(flex: 4, child: _InsightsSidebar()),
            ],
          );
        } else {
          ledgerBody = KeepAliveCustomScrollView(
            storageKey: ShellPageStorageKeys.financeLedgerNarrow,
            controller: _narrowScroll,
            slivers: [
              SliverPadding(
                padding: EdgeInsets.fromLTRB(horizontal, 4, horizontal, 0),
                sliver: _ledgerSliver(ledger, tagColors, tagFilter: tagFilter),
              ),
              const SliverToBoxAdapter(child: SizedBox(height: 24)),
              SliverPadding(
                padding: EdgeInsets.fromLTRB(horizontal, 0, horizontal, 96),
                sliver: SliverToBoxAdapter(
                  child: Column(
                    children: const [
                      BillRadarPanel(),
                      SizedBox(height: 12),
                      BudgetPanel(),
                    ],
                  ),
                ),
              ),
            ],
          );
        }

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            header,
            Expanded(
              child: VoyagerCrossfadeIndex(
                index: mode.index,
                children: [
                  KeyedSubtree(
                    key: ValueKey(wide ? 'ledger-wide' : 'ledger-narrow'),
                    child: ledgerBody,
                  ),
                  const FinanceAnalyticsView(),
                  const FinanceGoalsView(),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// Ledger feed — reverse-chronological transactions grouped by day
//
// Built lazily via _FinanceViewState._ledgerSliver/_ledgerEntries above,
// which flattens the day-grouping this comment used to describe into an
// indexable list a SliverList can build on demand instead of constructing a
// row for every transaction ever logged on every rebuild.
// ---------------------------------------------------------------------------

class _DayHeader extends StatelessWidget {
  const _DayHeader({required this.day, required this.netCents});

  final DateTime day;
  final int netCents;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 8, bottom: 6),
      child: Row(
        children: [
          Text(
            _label(day),
            style: theme.textTheme.labelMedium?.copyWith(
              fontWeight: FontWeight.w700,
              color: theme.colorScheme.onSurfaceVariant,
              letterSpacing: 0.4,
            ),
          ),
          const Spacer(),
          Text(
            formatCents(netCents, signed: true),
            style: theme.textTheme.labelMedium?.copyWith(
              color: netCents >= 0
                  ? kIncomeGreen
                  : theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  String _label(DateTime day) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    if (day == today) return 'TODAY';
    // Calendar-day arithmetic, not a Duration: subtracting 24h from the
    // midnight after a DST transition lands at 23:00 or 01:00, which never
    // equals the day key and drops the label.
    if (day == DateTime(today.year, today.month, today.day - 1)) {
      return 'YESTERDAY';
    }
    if (day == DateTime(today.year, today.month, today.day + 1)) {
      return 'TOMORROW';
    }
    return DateFormat('EEEE, MMM d').format(day).toUpperCase();
  }
}

/// The body of a day a ledger jump landed on that has no transactions.
class _EmptyDayRow extends StatelessWidget {
  const _EmptyDayRow();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
      child: Text(
        'No transactions',
        style: theme.textTheme.bodyMedium?.copyWith(
          color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.7),
        ),
      ),
    );
  }
}

class _UpcomingHeader extends StatelessWidget {
  const _UpcomingHeader();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent = theme.colorScheme.primary;
    return Padding(
      padding: const EdgeInsets.only(top: 4, bottom: 2),
      child: Row(
        children: [
          Icon(PhosphorIconsRegular.clock, size: 14, color: accent),
          const SizedBox(width: 6),
          Text(
            'UPCOMING',
            style: theme.textTheme.labelMedium?.copyWith(
              fontWeight: FontWeight.w700,
              color: accent,
              letterSpacing: 0.4,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Not counted until its date',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _TransactionRow extends ConsumerWidget {
  const _TransactionRow({
    super.key,
    required this.transaction,
    required this.tagColors,
  });

  final FinancialTransaction transaction;
  final Map<String, int> tagColors;

  // Counts how many _TransactionRow builds land in the same frame, to check
  // whether the row cache (see _FinanceViewState._rowFor) is actually
  // holding — mirrors _TaskRowState's counter in todo_page.dart.
  static var _rowBuildsThisFrame = 0;
  static var _rowBuildFlushScheduled = false;

  static void _noteRowBuild() {
    if (!DevFlags.verboseSync) return;
    _rowBuildsThisFrame++;
    if (_rowBuildFlushScheduled) return;
    _rowBuildFlushScheduled = true;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      debugPrint(
        '[jank] _TransactionRow builds this frame: $_rowBuildsThisFrame',
      );
      _rowBuildsThisFrame = 0;
      _rowBuildFlushScheduled = false;
    });
  }

  /// Soft-deletes the row and offers an undo.
  ///
  /// Everything the continuation needs is captured up front: a sync tick can
  /// invalidate the ledger and unmount this row while the write is still in
  /// flight, and `ref` throws once that happens — the invalidate would be
  /// skipped and the ledger left showing the deleted entry.
  Future<void> _delete(BuildContext context, WidgetRef ref) async {
    final repo = ref.read(financeRepositoryProvider);
    final container = ProviderScope.containerOf(ref.context, listen: false);
    final overlay = Overlay.of(context, rootOverlay: true);
    final snapshot = transaction;

    await softDeleteWithUndo(
      overlay: overlay,
      message: deletedMessage(
        // Origin and note as the row titles them, minus the Expense/Deposit
        // fallback: an untitled row reads better as "Deleted transaction".
        [
          trimToNull(snapshot.origin),
          trimToNull(snapshot.note),
        ].nonNulls.join(' - '),
        fallback: 'transaction',
        prose: true,
      ),
      delete: () async {
        await repo.softDeleteTransaction(snapshot.id);
        container.invalidate(transactionsProvider);
        if (snapshot.roomEventId != null) {
          container.invalidate(assetRoomEventsProvider);
        }
      },
      restore: () async {
        // Rebuilt rather than copyWith'd: copyWith reads
        // `deletedAt ?? this.deletedAt`, so it cannot clear a tombstone.
        //
        // The version is resolved against disk rather than against the
        // snapshot — see [restoreVersionFrom].
        final current = await repo.getTransaction(snapshot.id);
        abortIfAlreadyRestored(
          found: current != null,
          deletedAt: current?.deletedAt,
        );
        await repo.upsertTransaction(
          FinancialTransaction(
            id: snapshot.id,
            createdAt: snapshot.createdAt,
            updatedAt: utcNow(),
            version: restoreVersionFrom(
              preDeleteVersion: snapshot.version,
              currentVersion: current?.version,
            ),
            type: snapshot.type,
            amountCents: snapshot.amountCents,
            occurredAt: snapshot.occurredAt,
            origin: snapshot.origin,
            note: snapshot.note,
            tags: snapshot.tags,
            roomEventId: snapshot.roomEventId,
          ),
        );
        // The delete took the paired room event with it; bring it back too.
        final roomEventId = snapshot.roomEventId;
        if (roomEventId != null) {
          await repo.restoreAssetRoomEvent(roomEventId);
          container.invalidate(assetRoomEventsProvider);
        }
        container.invalidate(transactionsProvider);
      },
    );
  }

  /// Flips an expense to a deposit or back, clearing its origin and leaving
  /// everything else alone.
  ///
  /// The stored amount is a magnitude and the sign lives in [type] (see
  /// [FinancialTransaction.signedCents]), so nothing about the money has to be
  /// recomputed. The origin goes for the same reason the sheet's type switch
  /// clears it: a store is not a source.
  Future<void> _convert(WidgetRef ref) async {
    final repo = ref.read(financeRepositoryProvider);
    // See _delete: the container outlives this row, `ref` doesn't.
    final container = ProviderScope.containerOf(ref.context, listen: false);
    final flipped = transaction.type == TransactionType.expense
        ? TransactionType.deposit
        : TransactionType.expense;
    await repo.upsertTransaction(
      transaction.copyWith(
        type: flipped,
        clearOrigin: true,
        updatedAt: utcNow(),
        version: transaction.version + 1,
      ),
    );
    container.invalidate(transactionsProvider);
  }

  /// Files the same transaction again under today's date.
  ///
  /// Today at the current time, not today at the original's time: the ledger
  /// orders a day's transactions by [FinancialTransaction.occurredAt], so
  /// carrying the old clock time over would drop the copy into the middle of
  /// today's group rather than at the end of it.
  Future<void> _duplicate(WidgetRef ref) async {
    final repo = ref.read(financeRepositoryProvider);
    // See _delete: the container outlives this row, `ref` doesn't.
    final container = ProviderScope.containerOf(ref.context, listen: false);
    final now = utcNow();
    await repo.upsertTransaction(
      FinancialTransaction(
        id: newId(),
        createdAt: now,
        updatedAt: now,
        type: transaction.type,
        amountCents: transaction.amountCents,
        occurredAt: DateTime.now(),
        origin: transaction.origin,
        note: transaction.note,
        tags: transaction.tags,
      ),
    );
    container.invalidate(transactionsProvider);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    _noteRowBuild();
    final theme = Theme.of(context);
    final accent = theme.colorScheme.primary;
    final isDeposit = transaction.type == TransactionType.deposit;
    final amountColor = isDeposit ? kIncomeGreen : accent;

    return ContextMenuRegion(
      // Built on right-click rather than eagerly: the ledger rebuilds
      // wholesale whenever a transaction changes, and these entries are only
      // ever looked at by the row actually being clicked.
      itemsBuilder: () => [
        // Not for a contribution or withdrawal: converting would flip what
        // the room thinks happened, and a duplicate would be cash with no
        // room event behind it.
        if (transaction.roomEventId == null) ...[
          ContextMenuItem(
            label: isDeposit ? 'Convert to expense' : 'Convert to deposit',
            icon: PhosphorIconsRegular.arrowsLeftRight,
            onTap: () => _convert(ref),
          ),
          ContextMenuItem(
            label: 'Duplicate',
            icon: PhosphorIconsRegular.copy,
            onTap: () => _duplicate(ref),
          ),
        ],
        ContextMenuItem(
          label: 'Delete',
          icon: PhosphorIconsRegular.trash,
          isDestructive: true,
          onTap: () => _delete(context, ref),
        ),
      ],
      // The row's own ink surface. Without one the hover highlight is painted
      // into whichever [Material] is furthest up the tree — the page's, which
      // sits outside the ledger's viewport and so is not clipped by it. A row
      // half-scrolled under the Ledger/Analytics/Goals bar had its grey wash
      // drawn across that bar. Transparent, so nothing else about the row
      // changes.
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: () =>
              showFinanceTransactionModal(context, ref, existing: transaction),
          onLongPress: () => _delete(context, ref),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Container(
                  width: 34,
                  height: 34,
                  decoration: BoxDecoration(
                    color: amountColor.withValues(alpha: 0.12),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    isDeposit
                        ? PhosphorIconsRegular.arrowDownLeft
                        : PhosphorIconsRegular.arrowUpRight,
                    size: 16,
                    color: amountColor,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      LedgerTitleText(
                        title: ledgerTransactionTitle(
                          transaction.origin,
                          transaction.note,
                          transaction.type,
                        ),
                      ),
                      if (transaction.tags.isNotEmpty) ...[
                        const SizedBox(height: 4),
                        Wrap(
                          spacing: 4,
                          runSpacing: 4,
                          children: [
                            for (final tag in transaction.tags)
                              TagChip(tag: tag, colorValue: tagColors[tag]),
                          ],
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                Text(
                  formatCents(transaction.signedCents, signed: true),
                  style: theme.textTheme.titleSmall?.copyWith(
                    color: amountColor,
                    fontWeight: FontWeight.w600,
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

/// A ledger row's one-line title: the origin a step larger and bold, then
/// ` - ` and the note in the row's regular style. With no origin it is just
/// the note (or the Expense/Deposit fallback), unemphasised.
///
/// The note is drawn as prose, the way the editors draw it: `**floss**` reads
/// as a bold word with its markers collapsed. The origin stays literal.
class LedgerTitleText extends StatelessWidget {
  const LedgerTitleText({super.key, required this.title});

  final LedgerTitle title;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final base =
        theme.textTheme.bodyMedium ?? DefaultTextStyle.of(context).style;
    final origin = title.origin;
    final detail = title.detail;
    final emphasis = ProseEmphasisTheme.of(scheme, scheme.primary);
    final ranges = detail == null
        ? const <StyledRange>[]
        : proseReadRanges(detail, emphasis);
    final text = Text.rich(
      TextSpan(
        style: base,
        children: [
          if (origin != null)
            TextSpan(
              text: origin,
              style: theme.textTheme.bodyLarge?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
          if (detail != null) ...[
            if (origin != null) const TextSpan(text: ' - '),
            buildStyledRuns(detail, base, ranges),
          ],
        ],
      ),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
    if (ranges.isEmpty) return text;
    // `==highlight==` comes back marked, not filled — see [kProseHighlightMark].
    return ProseHighlightUnderlay(
      color: emphasis.highlightColor!,
      child: text,
    );
  }
}

/// The whole page's failure state. A refetch is the only recovery a load
/// error has here, so it needs to be reachable without restarting the app.
class _LedgerError extends StatelessWidget {
  const _LedgerError({required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            PhosphorIconsRegular.warningCircle,
            size: 40,
            color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.4),
          ),
          const SizedBox(height: 12),
          Text(
            'Could not load your ledger.',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 8),
          TextButton(onPressed: onRetry, child: const Text('Retry')),
        ],
      ),
    );
  }
}

/// The tag the ledger is narrowed to, with the only way back out.
///
/// Always on screen while the filter stands: a ledger quietly missing most of
/// its rows is a bug report waiting to happen, so the reason it looks that way
/// has to be visible from the same place the rows aren't. The whole chip is
/// the clear target — no separate ✕.
class _LedgerFilterChip extends StatelessWidget {
  const _LedgerFilterChip({required this.tag, required this.onClear});

  final String tag;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent = theme.colorScheme.primary;
    return Material(
      type: MaterialType.transparency,
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: onClear,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          child: Text(
            'Expenses tagged #$tag',
            style: theme.textTheme.labelMedium?.copyWith(color: accent),
          ),
        ),
      ),
    );
  }
}

class _EmptyLedger extends StatelessWidget {
  const _EmptyLedger({this.tagFilter});

  /// The tag the ledger is filtered to, so an empty result says which question
  /// came back with nothing rather than claiming the ledger is bare.
  final String? tagFilter;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final filter = tagFilter;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 48),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            PhosphorIconsRegular.receipt,
            size: 40,
            color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.4),
          ),
          const SizedBox(height: 12),
          Text(
            filter != null
                ? 'No expenses tagged #$filter.'
                : 'No transactions yet.\nTap + to log your first one.',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Insights sidebar — placeholder panels for later phases
// ---------------------------------------------------------------------------

class _InsightsSidebar extends StatelessWidget {
  const _InsightsSidebar();

  @override
  Widget build(BuildContext context) {
    return ListView(
      // Keyed so the sidebar keeps its offset: it is rebuilt from scratch on
      // every tab switch and every crossing of the split breakpoint, and
      // without a key that resets a long subscription list to the top.
      key: ShellPageStorageKeys.financeInsights,
      padding: const EdgeInsets.fromLTRB(12, 4, 20, 96),
      children: const [BillRadarPanel(), SizedBox(height: 12), BudgetPanel()],
    );
  }
}

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:voyager/core/motion/motion.dart';
import 'package:voyager/core/widgets/glass_button.dart';
import 'package:voyager/core/widgets/voyager_prose_text.dart';
import 'package:voyager/core/widgets/weather_icon.dart';
import 'package:voyager/features/journal/on_this_day.dart';

/// `(day, scope)` pairs whose card has already slid out on its own on this
/// device. In memory only (ON_THIS_DAY_HLD.md §5.1), and in a provider rather
/// than a static so each ProviderScope — each test — starts empty.
final _onThisDayAutoExpandedProvider = Provider<Set<String>>((ref) => {});

/// The On this day card (ON_THIS_DAY_HLD.md §5). Tucked, it stands upright
/// with only its left edge showing, and that edge is what brings it back; out,
/// it sits by the right edge turned a few degrees counterclockwise, like a
/// card laid on a desk.
///
/// Sized to fill the journal content area; only the card takes hits, so
/// everything else passes through to the page underneath.
class OnThisDayOverlay extends ConsumerStatefulWidget {
  const OnThisDayOverlay({
    super.key,
    required this.today,
    required this.journalId,
    required this.ready,
    required this.onOpen,
    this.top = 72,
  });

  /// The local calendar day, at midnight.
  final DateTime today;

  /// The journal being viewed, or null for All journals.
  final String? journalId;

  /// Whether the page's entries have loaded; the auto-expand waits for it.
  final bool ready;
  final ValueChanged<String> onOpen;
  final double top;

  static const entranceDelay = Duration(milliseconds: 400);

  @override
  ConsumerState<OnThisDayOverlay> createState() => _OnThisDayOverlayState();
}

class _OnThisDayOverlayState extends ConsumerState<OnThisDayOverlay>
    with SingleTickerProviderStateMixin {
  static const _gutter = 16.0;
  static const _cardWidth = 220.0;
  static const _cardHeight = 300.0;

  /// How much of the tucked card's left edge stays on screen.
  static const _peek = 32.0;

  /// The out card's counterclockwise turn, in radians (about 4°).
  static const _outTilt = 0.07;
  static const _duration = Duration(milliseconds: 420);

  late final AnimationController _controller;
  late final CurvedAnimation _curve;
  var _expanded = false;
  var _hovered = false;
  var _page = 0;
  Timer? _autoExpandTimer;

  /// Whether the page is the shell's current one. The shell keeps visited
  /// pages mounted but unpainted, with their tickers off.
  var _onScreen = true;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this, duration: _duration);
    _curve = CurvedAnimation(
      parent: _controller,
      // The momentum spring's slight overshoot lets the card turn a hair past
      // its resting angle before it settles, like one set down on a desk.
      curve: VoyagerSpring.momentumCurve,
      reverseCurve: Curves.easeInOutCubic,
    );
  }

  String get _scopeKey =>
      '${widget.today.toIso8601String()}|${widget.journalId ?? '*'}';

  @override
  void didUpdateWidget(OnThisDayOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.today != widget.today ||
        oldWidget.journalId != widget.journalId) {
      _autoExpandTimer?.cancel();
      _autoExpandTimer = null;
      _page = 0;
      _hovered = false;
      _setExpanded(false, rebuild: false);
      // Straight to tucked: sliding in would show the new scope's memory.
      _controller.value = 0;
    }
  }

  @override
  void dispose() {
    _autoExpandTimer?.cancel();
    HardwareKeyboard.instance.removeHandler(_handleKey);
    _curve.dispose();
    _controller.dispose();
    super.dispose();
  }

  void _setExpanded(bool expanded, {bool rebuild = true}) {
    if (_expanded == expanded) return;
    if (rebuild) {
      setState(() => _expanded = expanded);
    } else {
      _expanded = expanded;
    }
    if (expanded) {
      HardwareKeyboard.instance.addHandler(_handleKey);
      _controller.forward();
    } else {
      HardwareKeyboard.instance.removeHandler(_handleKey);
      _controller.reverse();
    }
  }

  /// A modifier alone doesn't count as interacting; a shortcut's other key
  /// does.
  static final _modifiers = {
    LogicalKeyboardKey.shiftLeft,
    LogicalKeyboardKey.shiftRight,
    LogicalKeyboardKey.controlLeft,
    LogicalKeyboardKey.controlRight,
    LogicalKeyboardKey.altLeft,
    LogicalKeyboardKey.altRight,
    LogicalKeyboardKey.metaLeft,
    LogicalKeyboardKey.metaRight,
    LogicalKeyboardKey.capsLock,
    LogicalKeyboardKey.fn,
  };

  /// Any key press other than a lone modifier tucks it away; the card is
  /// mouse-only, so no key ever comes from inside it. Never consumes: the key
  /// still lands where it was going, typing included.
  bool _handleKey(KeyEvent event) {
    if (event is KeyDownEvent && !_modifiers.contains(event.logicalKey)) {
      _setExpanded(false);
    }
    return false;
  }

  void _maybeAutoExpand() {
    final seen = ref.read(_onThisDayAutoExpandedProvider);
    if (!widget.ready ||
        !_onScreen ||
        _autoExpandTimer != null ||
        seen.contains(_scopeKey)) {
      return;
    }
    // Recorded when it actually slides out, so a scope switch that cancels
    // the timer doesn't use up that scope's one entrance.
    final scopeKey = _scopeKey;
    _autoExpandTimer = Timer(OnThisDayOverlay.entranceDelay, () {
      _autoExpandTimer = null;
      // Left the page during the delay: keep the entrance for the return.
      if (!mounted || !_onScreen) return;
      seen.add(scopeKey);
      _setExpanded(true);
    });
  }

  void _dismiss(List<OnThisDayMatch> matches) {
    final dismissed = ref.read(onThisDayDismissedProvider.notifier);
    dismissed.state = {
      ...dismissed.state,
      for (final match in matches)
        onThisDayDismissalKey(match.entry.id, widget.today),
    };
    // The card is about to go, and a removed MouseRegion never gets onExit.
    _hovered = false;
    _setExpanded(false);
  }

  void _open(OnThisDayMatch match) {
    widget.onOpen(match.entry.id);
    _setExpanded(false);
  }

  @override
  Widget build(BuildContext context) {
    _onScreen = TickerMode.valuesOf(context).enabled;
    final dismissed = ref.watch(onThisDayDismissedProvider);
    final matches = [
      for (final match
          in ref
                  .watch(
                    onThisDayProvider((
                      day: widget.today,
                      journalId: widget.journalId,
                    )),
                  )
                  .valueOrNull ??
              const <OnThisDayMatch>[])
        if (!dismissed.contains(
          onThisDayDismissalKey(match.entry.id, widget.today),
        ))
          match,
    ];
    if (matches.isEmpty) {
      if (_expanded) _setExpanded(false, rebuild: false);
      return const SizedBox.shrink();
    }
    _maybeAutoExpand();
    final page = math.min(_page, matches.length - 1);
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = math.min(_cardWidth, constraints.maxWidth - 2 * _gutter);
        final reduced = VoyagerMotion.reduced(context);
        _controller.duration = reduced ? VoyagerMotion.crossfade : _duration;
        // From the out position to the one that leaves only [_peek] showing.
        final tuckDistance = width + _gutter - _peek;
        return Stack(
          children: [
            Positioned(
              top: widget.top,
              right: _gutter,
              width: width,
              height: _cardHeight,
              // Transforms outermost: a render box above them would hit-test
              // against the untransformed layout box, and the tucked strip
              // lies outside it.
              child: TweenAnimationBuilder<double>(
                tween: Tween(end: _hovered && !_expanded ? 6 : 0),
                duration: const Duration(milliseconds: 120),
                builder: (context, nudge, child) => AnimatedBuilder(
                  animation: _controller,
                  builder: (context, child) {
                    final t = reduced ? _controller.value : _curve.value;
                    final tucked = 1 - t;
                    return Transform.translate(
                      offset: Offset(tucked * (tuckDistance - nudge), 0),
                      child: Transform.rotate(
                        // Negative is counterclockwise.
                        angle: reduced ? 0 : -t * _outTilt,
                        child: child,
                      ),
                    );
                  },
                  child: child,
                ),
                // Hovering the tucked card nudges it a few pixels further
                // out, as a hint that it can be pulled.
                child: MouseRegion(
                  cursor: _expanded
                      ? MouseCursor.defer
                      : SystemMouseCursors.click,
                  onEnter: (_) => setState(() => _hovered = true),
                  onExit: (_) => setState(() => _hovered = false),
                  child: TapRegion(
                    onTapOutside: (_) => _setExpanded(false),
                    // Mouse-only in v1: nothing in the card takes focus, so
                    // Tab can never land on its hidden buttons.
                    child: ExcludeFocus(
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: _expanded ? null : () => _setExpanded(true),
                        child: _OnThisDayCard(
                          progress: _controller,
                          expanded: _expanded,
                          match: matches[page],
                          page: page,
                          pageCount: matches.length,
                          firstAgo: matches.first.shortAgo,
                          showJournal: widget.journalId == null,
                          onPage: (next) => setState(() => _page = next),
                          onOpen: () => _open(matches[page]),
                          onDismiss: () => _dismiss(matches),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _OnThisDayCard extends StatelessWidget {
  const _OnThisDayCard({
    required this.progress,
    required this.expanded,
    required this.match,
    required this.page,
    required this.pageCount,
    required this.firstAgo,
    required this.showJournal,
    required this.onPage,
    required this.onOpen,
    required this.onDismiss,
  });

  /// 0 tucked, 1 out: the contents fade in as the card comes out, and the
  /// edge's icon and count fade away.
  final Animation<double> progress;
  final bool expanded;
  final OnThisDayMatch match;
  final int page;
  final int pageCount;

  /// How far back the card's first (newest) match is, for the tucked strip.
  final String firstAgo;
  final bool showJournal;
  final ValueChanged<int> onPage;
  final VoidCallback onOpen;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final entry = match.entry;
    final journal = match.journal;
    final journalColor = Color(journal.colorValue ?? scheme.primary.toARGB32());
    final muted = scheme.onSurface.withValues(alpha: 0.65);
    final showMood = journal.showMood && entry.mood != null;
    final showWeather = journal.showWeather && entry.weatherIcon != null;
    final body = entry.body.trim();
    const smallButton = BoxConstraints(minWidth: 28, minHeight: 28);
    // The card is too narrow for padded 48px targets on touch platforms.
    final smallStyle = IconButton.styleFrom(
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
    );

    final contents = Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 6, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                PhosphorIconsRegular.clockCounterClockwise,
                size: 16,
                color: journalColor,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  'On this day',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleSmall,
                ),
              ),
              IconButton(
                tooltip: 'Dismiss',
                iconSize: 16,
                constraints: smallButton,
                style: smallStyle,
                padding: EdgeInsets.zero,
                onPressed: onDismiss,
                icon: const Icon(PhosphorIconsRegular.x),
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(right: 10),
            child: Text(
              match.label,
              style: theme.textTheme.labelSmall?.copyWith(color: muted),
            ),
          ),
          if (showJournal) ...[
            const SizedBox(height: 4),
            Row(
              children: [
                Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    color: journalColor,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(
                    journal.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelSmall,
                  ),
                ),
              ],
            ),
          ],
          const SizedBox(height: 12),
          Padding(
            padding: const EdgeInsets.only(right: 10),
            child: Text(
              entry.title.trim().isEmpty ? 'Untitled' : entry.title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.titleSmall,
            ),
          ),
          const SizedBox(height: 4),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(right: 10),
              child: body.isEmpty
                  ? const SizedBox.shrink()
                  : VoyagerProseText(
                      body,
                      maxLines: 7,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: scheme.onSurface.withValues(alpha: 0.78),
                      ),
                    ),
            ),
          ),
          if (showMood || showWeather)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Row(
                children: [
                  if (showMood) ...[
                    Icon(
                      PhosphorIconsRegular.smiley,
                      size: 16,
                      color: journalColor,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      'Mood ${entry.mood}/10',
                      style: theme.textTheme.labelSmall,
                    ),
                    const SizedBox(width: 12),
                  ],
                  if (showWeather)
                    Icon(
                      weatherIconData(entry.weatherIcon),
                      size: 16,
                      color: journalColor,
                      semanticLabel: entry.weatherIcon,
                    ),
                ],
              ),
            ),
          Row(
            children: [
              if (pageCount > 1) ...[
                IconButton(
                  tooltip: 'Newer',
                  iconSize: 14,
                  constraints: smallButton,
                  style: smallStyle,
                  padding: EdgeInsets.zero,
                  onPressed: page > 0 ? () => onPage(page - 1) : null,
                  icon: const Icon(PhosphorIconsRegular.caretLeft),
                ),
                Flexible(
                  child: Text(
                    '${page + 1} of $pageCount',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelSmall,
                  ),
                ),
                IconButton(
                  tooltip: 'Older',
                  iconSize: 14,
                  constraints: smallButton,
                  style: smallStyle,
                  padding: EdgeInsets.zero,
                  onPressed: page < pageCount - 1
                      ? () => onPage(page + 1)
                      : null,
                  icon: const Icon(PhosphorIconsRegular.caretRight),
                ),
              ],
              const Spacer(),
              Padding(
                padding: const EdgeInsets.only(left: 4, right: 6),
                child: GlassButton(
                  onPressed: onOpen,
                  label: 'Open',
                  dense: true,
                ),
              ),
            ],
          ),
        ],
      ),
    );

    return Material(
      elevation: 8,
      color: scheme.surfaceContainerHigh,
      // A faint edge in the memory's journal colour.
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: journalColor.withValues(alpha: 0.35)),
      ),
      clipBehavior: Clip.antiAlias,
      child: AnimatedBuilder(
        animation: progress,
        builder: (context, _) {
          final out = progress.value.clamp(0.0, 1.0);
          // Staggered so the two never overlap mid-swing: the edge's icon is
          // gone within the first third, and the contents arrive after it.
          final edge = (1 - out * 3).clamp(0.0, 1.0);
          final body = ((out - 0.25) / 0.75).clamp(0.0, 1.0);
          return Stack(
            children: [
              Positioned.fill(
                child: IgnorePointer(
                  ignoring: !expanded,
                  child: Opacity(opacity: body, child: contents),
                ),
              ),
              // What the tucked edge shows: the memory icon at the top, and at
              // the bottom how far back the first memory is with, for more
              // than one, how many are waiting below it.
              if (edge > 0)
                Positioned(
                  left: 0,
                  top: 0,
                  bottom: 0,
                  width: _OnThisDayOverlayState._peek,
                  child: Opacity(
                    opacity: edge,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      child: Column(
                        children: [
                          Icon(
                            PhosphorIconsRegular.clockCounterClockwise,
                            size: 16,
                            color: journalColor,
                          ),
                          const Spacer(),
                          Text(
                            firstAgo,
                            maxLines: 1,
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: journalColor,
                              fontSize: 9,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          // A badge, so the count doesn't read as a distance.
                          if (pageCount > 1) ...[
                            const SizedBox(height: 6),
                            Container(
                              constraints: const BoxConstraints(
                                minWidth: 18,
                                minHeight: 18,
                              ),
                              alignment: Alignment.center,
                              decoration: BoxDecoration(
                                color: journalColor.withValues(alpha: 0.22),
                                shape: BoxShape.circle,
                              ),
                              child: Text(
                                '$pageCount',
                                style: theme.textTheme.labelSmall?.copyWith(
                                  fontSize: 10,
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

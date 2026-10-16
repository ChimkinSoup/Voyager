import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:collection/collection.dart' show mergeSort;
import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/dev/dev_flags.dart';
import 'package:voyager/core/layout/touch_target.dart';
import 'package:voyager/core/motion/motion.dart';
import 'package:voyager/core/platform/platform_info.dart';
import 'package:voyager/core/soft_delete/soft_delete_toast.dart';
import 'package:voyager/core/theme/palette_color.dart';
import 'package:voyager/core/theme/voyager_theme.dart';
import 'package:voyager/core/utils/calendar_days.dart';
import 'package:voyager/core/utils/ids.dart';
import 'package:voyager/core/widgets/voyager_prose_text.dart';
import 'package:voyager/core/widgets/confirm_dialog.dart';
import 'package:voyager/core/widgets/color_picker_field.dart';
import 'package:voyager/core/widgets/context_menu.dart';
import 'package:voyager/core/widgets/ctrl_enter_to_submit_scope.dart';
import 'package:voyager/core/widgets/glass_button.dart';
import 'package:voyager/core/widgets/notification_urgency_dot.dart';
import 'package:voyager/core/widgets/spell_check_field_support.dart';
import 'package:voyager/core/widgets/spell_check_squiggle_layer.dart';
import 'package:voyager/core/widgets/voyager_checkbox.dart';
import 'package:voyager/core/widgets/voyager_text_field.dart';
import 'package:voyager/domain/models/analytics_models.dart';
import 'package:voyager/domain/models/enums.dart';
import 'package:voyager/domain/models/finance_models.dart';
import 'package:voyager/domain/models/notification_models.dart';
import 'package:voyager/domain/todo/todo_recurring_completion.dart';
import 'package:voyager/features/analytics/tracker_entry_row.dart';
import 'package:voyager/features/calendar/calendar_event_delete.dart';
import 'package:voyager/features/finance/finance_bill_radar.dart';
import 'package:voyager/features/finance/finance_subscription_modal.dart';
import 'package:voyager/features/notifications/scheduled_reminders_section.dart';
import 'package:voyager/features/settings/folder_backup_list_dialog.dart';
import 'package:voyager/features/settings/services/auto_backup_service.dart';
import 'package:voyager/features/settings/services/folder_backup_service.dart';
import 'package:voyager/features/todo/todo_list_actions.dart';
import 'package:voyager/features/shell/reveal_request.dart';
import 'package:voyager/core/text/prose_editing_controller.dart';
import 'package:voyager/core/text/prose_text_span.dart';
import 'package:voyager/core/vim/vim_enabled_scope.dart';
import 'package:voyager/core/vim/vim_text_overlay.dart';
import 'package:voyager/core/vim/vim_text_scope.dart';
import 'package:voyager/core/widgets/field_scroll_padding.dart';

/// Width of the inbox popover.
///
/// Wide enough that a reminder, a task title and its due-date subtitle each
/// get a line to themselves instead of wrapping — this panel holds sentences,
/// not the one-word entries the 220px picker popovers do.
///
/// Callers are expected to clamp it to the window: the popover's layout
/// delegate takes a width as a hard constraint and only slides the panel left
/// to make it fit, so this is wider than a phone screen.
const double kNotificationPopoverWidth = 532;

/// Whether the inbox's Log stats section is open.
///
/// Held here rather than read off [settingsProvider] so a toggle rebuilds only
/// the section: publishing settings rebuilds every page in the shell, which
/// stalled the section's open and close. Seeded from the stored value, which
/// [SettingsRepository.saveInboxLogStatsExpanded] keeps in step — and which
/// a settings publish can't move, since [SettingsRepository.saveSettings]
/// never writes it.
final _logStatsExpandedProvider = StateProvider<bool>(
  (ref) => ref.watch(
    settingsProvider.select(
      (s) => s.valueOrNull?.inboxLogStatsExpanded ?? false,
    ),
  ),
);

/// Where a growing section sits in the inbox's scroll content — its top, and
/// the gap from its bottom to the end of the content — for as long as
/// [_PinnedGrowthPhysics] should keep its bottom edge in view.
class _GrowthPin {
  ({double top, double below})? section;
}

/// Keeps the [_GrowthPin]ned section's bottom at the bottom of the inbox while
/// the section grows, without letting its top scroll off.
///
/// Applied in layout, as the content's new extent comes in, so the scroll
/// moves in the very frame the section grows. Until the panel reaches its
/// max height there is nothing to scroll and the panel just grows; past it,
/// the same growth carries on as a scroll, with no hand-off between the two.
class _PinnedGrowthPhysics extends ScrollPhysics {
  const _PinnedGrowthPhysics(this.pin, {super.parent});

  final _GrowthPin pin;

  @override
  _PinnedGrowthPhysics applyTo(ScrollPhysics? ancestor) =>
      _PinnedGrowthPhysics(pin, parent: buildParent(ancestor));

  @override
  double adjustPositionForNewDimensions({
    required ScrollMetrics oldPosition,
    required ScrollMetrics newPosition,
    required bool isScrolling,
    required double velocity,
  }) {
    final pixels = super.adjustPositionForNewDimensions(
      oldPosition: oldPosition,
      newPosition: newPosition,
      isScrolling: isScrolling,
      velocity: velocity,
    );
    final section = pin.section;
    if (section == null || isScrolling) return pixels;
    // Content ends `below` past the section, so this is the offset that puts
    // the section's bottom at the viewport's — capped where its top would
    // pass the viewport's.
    final pinned = math.min(
      newPosition.maxScrollExtent - section.below,
      section.top,
    );
    return math.max(pixels, pinned);
  }
}

/// The notification bell's popover content: pinned quick-reminders, the
/// unified urgency-sorted feed, a hidden/dismissed browser, and an embedded
/// daily-stats logger.
class NotificationInboxPopover extends ConsumerStatefulWidget {
  const NotificationInboxPopover({super.key});

  @override
  ConsumerState<NotificationInboxPopover> createState() =>
      _NotificationInboxPopoverState();
}

class _NotificationInboxPopoverState
    extends ConsumerState<NotificationInboxPopover> {
  /// How the header's Show hidden reaches the drawer at the bottom of the
  /// panel — a sibling, not an ancestor.
  final _hiddenKey = GlobalKey<_HiddenSectionState>();

  final _growthPin = _GrowthPin();

  @override
  Widget build(BuildContext context) {
    final maxHeight = MediaQuery.sizeOf(context).height * 0.75;
    return Material(
      type: MaterialType.transparency,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxHeight),
        // One scroll region, not several: no section carries its own
        // viewport, so dragging anywhere in the panel — the reminders
        // included — moves the whole thing as a single sheet. It is also
        // what [Scrollable.ensureVisible] scrolls when Hidden expands.
        //
        // Slivers rather than one box, so the Log stats rows are a list of
        // this scroll view's own: dragging one to an edge scrolls the panel.
        child: CustomScrollView(
          shrinkWrap: true,
          // Every section built, scrolled to or not, as in a Column: the
          // header's Show hidden reaches the Hidden section by its key. Not
          // infinity, which a shrink-wrapping viewport turns into NaN.
          scrollCacheExtent: const ScrollCacheExtent.pixels(1e6),
          physics: _PinnedGrowthPhysics(_growthPin),
          slivers: [
            SliverToBoxAdapter(
              child: _Header(
                onClearAll: _clearAll,
                onShowHidden: () => _hiddenKey.currentState?.reveal(),
              ),
            ),
            const SliverToBoxAdapter(child: _BackupAlertSection()),
            const SliverToBoxAdapter(child: _FolderBackupAlertSection()),
            const SliverToBoxAdapter(child: _PinnedNotesSection()),
            const SliverToBoxAdapter(child: ScheduledRemindersSection()),
            const SliverToBoxAdapter(child: _FeedSection()),
            _AnalyticsSection(growthPin: _growthPin),
            SliverToBoxAdapter(child: _HiddenSection(key: _hiddenKey)),
          ],
        ),
      ),
    );
  }

  Future<void> _clearAll() async {
    // Captured before the write: the popover may close while it runs, and
    // the undo has to outlive it.
    final container = ProviderScope.containerOf(context, listen: false);
    final overlay = Overlay.of(context, rootOverlay: true);
    final visible = await ref.read(visibleNotificationFeedProvider.future);
    if (visible.isEmpty) return;
    final repo = container.read(notificationRepositoryProvider);
    for (final item in visible) {
      await repo.dismiss(item.dismissalKey);
    }
    if (visible.any((item) => item.type == NotificationItemType.review)) {
      await _retireStaleReviewDismissals(container);
    }
    container.invalidate(notificationDismissalsProvider);
    _offerHideUndo(overlay: overlay, container: container, items: visible);
  }
}

/// The title a feed item goes by — a bill's is its name.
String _feedTitle(NotificationFeedItem item) => switch (item.type) {
  NotificationItemType.task => item.task!.title,
  NotificationItemType.event => item.event!.title,
  NotificationItemType.bill => item.bill!.name,
  NotificationItemType.review => _reviewPage(item.reviewSource!).label,
};

/// The page a review row stands for: its name, rail icon and route.
({String label, IconData icon, String path}) _reviewPage(ReviewSource source) =>
    switch (source) {
      ReviewSource.study => (
        label: 'Study',
        icon: PhosphorIconsRegular.cardsThree,
        path: '/study',
      ),
      ReviewSource.leetcode => (
        label: 'LeetCode',
        icon: PhosphorIconsRegular.code,
        path: '/leetcode',
      ),
    };

/// Tombstones the review dismissals left from earlier days, run whenever a
/// review row is hidden. Each day's hide has a key of its own, so without this
/// a queue hidden daily kept one live dismissal per day, forever.
Future<void> _retireStaleReviewDismissals(ProviderContainer container) async {
  final repo = container.read(notificationRepositoryProvider);
  final now = DateTime.now();
  for (final key in await repo.listDismissals()) {
    if (isStaleReviewDismissal(key, now)) await repo.undismiss(key);
  }
}

/// Offers Undo for [items], whose dismissals have already been written.
///
/// Undo brings back only what is still dismissed: a key restored from Hidden
/// in the meantime is skipped rather than tombstoned a second time, which
/// would bump its version and push a sync write for nothing.
void _offerHideUndo({
  required OverlayState overlay,
  required ProviderContainer container,
  required List<NotificationFeedItem> items,
}) {
  final first = items.first;
  showHideUndoToast(
    overlay: overlay,
    keys: [for (final item in items) item.dismissalKey],
    message: hiddenMessage(_feedTitle(first), fallback: first.type.name),
    restore: (keys) async {
      final repo = container.read(notificationRepositoryProvider);
      for (final key in keys) {
        final dismissal = await repo.getDismissal(key);
        if (dismissal == null || !dismissal.isDismissed) continue;
        await repo.undismiss(key);
      }
      container.invalidate(notificationDismissalsProvider);
    },
  );
}

class _Header extends ConsumerWidget {
  const _Header({required this.onClearAll, required this.onShowHidden});

  final VoidCallback onClearAll;
  final VoidCallback onShowHidden;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final visible =
        ref.watch(visibleNotificationFeedProvider.settled).valueOrNull ??
        const <NotificationFeedItem>[];
    final hidden =
        ref.watch(hiddenNotificationFeedProvider.settled).valueOrNull ??
        const <NotificationFeedItem>[];
    // Nothing to count when the feed is clear — the empty state below already
    // says so, and a "0 items" line under the title would be the popover
    // announcing its own emptiness twice.
    final sublabel = visible.isEmpty
        ? null
        : visible.length == 1
        ? '1 item needs attention'
        : '${visible.length} items need attention';

    return Padding(
      padding: EdgeInsets.fromLTRB(16, 14, 12, sublabel == null ? 8 : 10),
      child: Row(
        children: [
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Inbox',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (sublabel != null)
                  Text(
                    sublabel,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
              ],
            ),
          ),
          // Each action only appears where it has something to act on: no
          // opening an empty hidden list, no clearing an empty feed.
          if (hidden.isNotEmpty)
            Semantics(
              button: true,
              label: 'Show hidden',
              child: GlassButton(
                onPressed: onShowHidden,
                // An eye, not the restore arrow: this only opens the list.
                // Putting items back is done from inside it.
                icon: const Icon(PhosphorIconsRegular.eye, size: 14),
                tooltip: 'Show hidden',
                dense: true,
              ),
            ),
          if (hidden.isNotEmpty && visible.isNotEmpty) const SizedBox(width: 6),
          if (visible.isNotEmpty)
            Semantics(
              button: true,
              label: 'Clear all',
              child: GlassButton(
                onPressed: onClearAll,
                icon: const Icon(PhosphorIconsRegular.broom, size: 14),
                tooltip: 'Clear all',
                dense: true,
              ),
            ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Pinned notes
// ---------------------------------------------------------------------------

class _PinnedNotesSection extends ConsumerStatefulWidget {
  const _PinnedNotesSection();

  @override
  ConsumerState<_PinnedNotesSection> createState() =>
      _PinnedNotesSectionState();
}

class _PinnedNotesSectionState extends ConsumerState<_PinnedNotesSection> {
  final _controller = TextEditingController();
  final _focusNode = FocusNode();

  @override
  void initState() {
    super.initState();
    _focusNode.onKeyEvent = (node, event) {
      if (event is! KeyDownEvent) return KeyEventResult.ignored;
      if ((event.logicalKey == LogicalKeyboardKey.enter ||
              event.logicalKey == LogicalKeyboardKey.numpadEnter) &&
          !HardwareKeyboard.instance.isShiftPressed) {
        unawaited(_addNote());
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    };
  }

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  Future<void> _addNote() async {
    final text = _controller.text.trim();
    if (text.isEmpty) return;
    final note = PinnedNote(
      id: newId(),
      text: text,
      createdAt: utcNow(),
      updatedAt: utcNow(),
    );
    await ref.read(notificationRepositoryProvider).upsertPinnedNote(note);
    ref.invalidate(pinnedNotesProvider);
    _controller.clear();
  }

  Future<void> _updateNote(PinnedNote note, String newText) async {
    final trimmed = newText.trim();
    if (trimmed.isEmpty) {
      await _deleteNote(note.id);
      return;
    }
    if (trimmed == note.text) return;
    final updated = note.copyWith(
      text: trimmed,
      updatedAt: utcNow(),
      version: note.version + 1,
    );
    await ref.read(notificationRepositoryProvider).upsertPinnedNote(updated);
    ref.invalidate(pinnedNotesProvider);
  }

  Future<void> _deleteNote(String id) async {
    await ref.read(notificationRepositoryProvider).deletePinnedNote(id);
    ref.invalidate(pinnedNotesProvider);
  }

  /// The delete button's version, which offers an undo.
  ///
  /// Deliberately not what [_commitNote] calls when the user clears a note to
  /// empty: that is an edit, and a toast raised while someone is backspacing
  /// through their own text is noise rather than a safety net.
  Future<void> _deleteNoteWithUndo(PinnedNote note) async {
    // Captured before the write: deleting the note unmounts its row, and the
    // toast offering the undo has to outlive it.
    final container = ProviderScope.containerOf(context, listen: false);
    final overlay = Overlay.of(context, rootOverlay: true);

    await softDeleteWithUndo(
      overlay: overlay,
      message: deletedMessage(note.text, fallback: 'note', prose: true),
      delete: () => _deleteNote(note.id),
      restore: () async {
        final repository = container.read(notificationRepositoryProvider);
        // The version is resolved against disk rather than against the
        // snapshot — see [restoreVersionFrom].
        final current = await repository.getPinnedNote(note.id);
        abortIfAlreadyRestored(
          found: current != null,
          deletedAt: current?.deletedAt,
        );
        await repository.upsertPinnedNote(
          note.copyWith(
            clearDeletedAt: true,
            updatedAt: utcNow(),
            version: restoreVersionFrom(
              preDeleteVersion: note.version,
              currentVersion: current?.version,
            ),
          ),
        );
        container.invalidate(pinnedNotesProvider);
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final notesAsync = ref.watch(pinnedNotesProvider.settled);
    final notes = notesAsync.valueOrNull ?? const [];
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 2, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Text(
              'Reminders',
              style: theme.textTheme.labelMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          VoyagerTextField(
            controller: _controller,
            focusNode: _focusNode,
            // Same slot the rows below use, so the input and the notes it
            // produces are the same size.
            style: theme.textTheme.bodySmall,
            borderRadius: _kReminderFieldRadius,
            // Multiline so Shift+Enter can break a line; plain Enter is
            // caught by [_focusNode.onKeyEvent] and adds the note.
            maxLines: null,
            minLines: 1,
            keyboardType: TextInputType.multiline,
            onSubmitted: (_) => unawaited(_addNote()),
            decoration: const InputDecoration(
              hintText: 'Type a quick reminder…',
              isDense: true,
              contentPadding: _kReminderFieldPadding,
            ),
          ),
          if (notes.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              // Free-running: the list is as tall as it needs to be and the
              // popover's own scroll view carries it.
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final note in notes)
                    _PinnedNoteRow(
                      key: ValueKey(note.id),
                      note: note,
                      onUpdate: (newText) => _updateNote(note, newText),
                      onDelete: () => _deleteNoteWithUndo(note),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// `rounded.field` — the reminder input is a field like any other.
const double _kReminderFieldRadius = VoyagerTheme.fieldRadius;

const EdgeInsets _kReminderFieldPadding = EdgeInsets.symmetric(
  horizontal: 12,
  vertical: 10,
);

/// Where a pinned-note row keeps its text, measured from the row's own edges.
///
/// A row shows the note as a [Text] and edits it as a [TextField], and neither
/// one puts its glyphs at its content padding: this is the inset both are
/// worked back to, so the words don't move when the row is clicked. See
/// [_kPinnedNoteTextPadding] and [_pinnedNoteFieldPadding].
const EdgeInsets _kPinnedNoteTextInset = EdgeInsets.symmetric(
  horizontal: 8,
  vertical: 4,
);

/// [_kPinnedNoteTextInset] as padding around the display [Text], undoing the
/// two insets the field adds on its own: the decorator's input gap on the
/// left, and RenderEditable's caret strip on the right — that one comes out of
/// the width the field *wraps* at, so without it a note long enough to wrap
/// re-flows on the way into the editor.
final EdgeInsets _kPinnedNoteTextPadding = withCaretMargin(
  withInputGap(_kPinnedNoteTextInset),
);

/// [_kPinnedNoteTextInset] as content padding for the field the row turns into.
///
/// InputDecorator lays its text out half a visual-density offset *above* the
/// content padding and takes the whole offset back out of its own height (see
/// [withDensityShift]) — negative on desktop. Paying that back here leaves the
/// field's text on the line the [Text] was using, and the row at the height it
/// already had, on either density.
EdgeInsets _pinnedNoteFieldPadding(ThemeData theme) {
  final shift = theme.visualDensity.baseSizeAdjustment.dy / 2.0;
  return _kPinnedNoteTextInset.copyWith(
    top: _kPinnedNoteTextInset.top - shift,
    bottom: _kPinnedNoteTextInset.bottom - shift,
  );
}

/// The elbow drawn beside a line the text spilled onto by itself, in the
/// gutter [_kPinnedNoteTextInset] leaves to the left of the glyphs: 4px wide
/// and 4px clear of the first letter, which puts it past the 1.2px border the
/// row grows while it is being edited.
const double _kWrapMarkWidth = 4;
const double _kWrapMarkRise = 5;
const double _kWrapMarkGap = 4;
const double _kWrapMarkStroke = 1.1;

/// The bullet drawn beside a note's first line, in the gutter the elbows use:
/// one dot per reminder, so a stack of notes reads as separate entries however
/// many lines each of them runs to.
///
/// Decoration only — the row is already the click target, and the dot is
/// painted rather than laid out so it costs the text no width.
const double _kNoteBulletRadius = 1.75;

/// The bullet's centre, measured from the row's left edge: the middle of the
/// elbow's arm rather than its corner, which leaves a little more room to its
/// left without crowding the first letter.
final double _kNoteBulletCentre =
    _kPinnedNoteTextPadding.left - _kWrapMarkGap - _kWrapMarkWidth / 2;

/// How far above the baseline the middle of a lowercase word sits, in em: half
/// of Iosevka Aile's x-height (520 of 1000 units per em).
///
/// The bullet is centred on that and not on the line box, which stretches from
/// the ascender to the descender (0.965em and 0.215em) and so has a middle of
/// its own sitting 1.4px above the letters' at the size a note is set in. The
/// elbows keep the line box: one marks a *line*, and sits against the whole
/// band of it, where the dot stands in for the note's first word.
const double _kNoteBulletLift = 0.26;

/// Where a line's elbow sits vertically, in the painter's own coordinates.
double _noteMarkMiddle(ui.LineMetrics line) =>
    _kPinnedNoteTextPadding.top + line.baseline - line.ascent + line.height / 2;

/// Marks a note's first line with a bullet, and the lines [text] wrapped onto
/// by itself with an elbow — so a soft wrap reads differently from a line the
/// user ended with Shift+Enter, and from the start of the next note.
///
/// Sits over [child] rather than inside it because neither state of the row
/// can hold it: Flutter has no text-indent, and the only way to move a
/// [TextField]'s wrapped line would be to put a real newline in the note. The
/// mark is painted from the same layout the text got instead, which is why it
/// lands identically whether the row is showing the note or editing it — see
/// [_kPinnedNoteTextPadding], which both states are worked back to.
class _WrapMarks extends StatelessWidget {
  const _WrapMarks({
    required this.text,
    required this.style,
    required this.child,
    required this.spanBuilder,
    this.controller,
    this.strutStyle,
  });

  /// The strut the showing state lays its paragraph out with — [EditableText]
  /// falls back to `StrutStyle.fromTextStyle(style, forceStrutHeight: true)`
  /// while the row is being edited, and the display [Text] has none. Without
  /// it the two paragraphs report different `LineMetrics.height`, which is
  /// what the marks are positioned off.
  final StrutStyle? strutStyle;

  /// The note as the row is showing it. Ignored while [controller] is given.
  final String text;

  /// The style the text is actually laid out in — the display [Text]'s, or
  /// the field's, which may carry extra line height for the squiggles.
  final TextStyle style;
  final Widget child;

  /// The field's controller while the row is being edited: the marks follow
  /// the text as it is typed, and only the marks rebuild for it.
  final TextEditingController? controller;

  /// The note's paragraph, emphasis and all. A mark sits against a wrap point,
  /// and bold moves wrap points, so this has to be the same span the row is
  /// showing (EMPHASIS_FORMATTING.md §8).
  final ProseSpanBuilder spanBuilder;

  Widget _paint(BuildContext context, String text, Widget? child) {
    return CustomPaint(
      // In front: the field fills its box, and a mark painted behind it would
      // be the one thing about the row that changed on the way into the editor.
      foregroundPainter: _WrapMarkPainter(
        span: spanBuilder(text, style),
        strutStyle: strutStyle,
        // The size the paragraph is actually set at — what the bullet's lift
        // off the baseline is a fraction of. Null is the size the text itself
        // would fall back to.
        fontSize: style.fontSize ?? 14,
        textScaler: MediaQuery.textScalerOf(context),
        textDirection: Directionality.of(context),
        color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.35),
      ),
      child: child,
    );
  }

  @override
  Widget build(BuildContext context) {
    final controller = this.controller;
    if (controller == null) return _paint(context, text, child);
    return AnimatedBuilder(
      animation: controller,
      child: child,
      builder: (context, child) => _paint(context, controller.text, child),
    );
  }
}

class _WrapMarkPainter extends CustomPainter {
  const _WrapMarkPainter({
    required this.span,
    required this.strutStyle,
    required this.fontSize,
    required this.textScaler,
    required this.textDirection,
    required this.color,
  });

  final TextSpan span;
  final StrutStyle? strutStyle;
  final double fontSize;
  final TextScaler textScaler;
  final TextDirection textDirection;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    // The row's whole width less the insets both states keep — so this lays
    // the note out at the width it really wrapped at, in either state.
    final wrapWidth = size.width - _kPinnedNoteTextPadding.horizontal;
    if (span.toPlainText().isEmpty || wrapWidth <= 0) return;
    final painter = TextPainter(
      text: span,
      strutStyle: strutStyle,
      textScaler: textScaler,
      textDirection: textDirection,
    )..layout(maxWidth: wrapWidth);
    final lines = painter.computeLineMetrics();
    painter.dispose();
    if (lines.isEmpty) return;

    // On the first line's baseline — one ascent below the top of the
    // paragraph — lifted from there to the middle of its letters.
    canvas.drawCircle(
      Offset(
        _kNoteBulletCentre,
        _kPinnedNoteTextPadding.top +
            lines.first.ascent -
            textScaler.scale(fontSize) * _kNoteBulletLift,
      ),
      _kNoteBulletRadius,
      Paint()..color = color,
    );
    if (lines.length < 2) return;

    final right = _kPinnedNoteTextPadding.left - _kWrapMarkGap;
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = _kWrapMarkStroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    for (var i = 1; i < lines.length; i++) {
      // A line the user ended themselves reports a hard break; a line that
      // simply ran out of room does not. The mark belongs to what follows it.
      if (lines[i - 1].hardBreak) continue;
      final line = lines[i];
      final middle = _noteMarkMiddle(line);
      canvas.drawPath(
        Path()
          ..moveTo(right - _kWrapMarkWidth, middle - _kWrapMarkRise)
          ..lineTo(right - _kWrapMarkWidth, middle)
          ..lineTo(right, middle),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_WrapMarkPainter old) =>
      span != old.span ||
      strutStyle != old.strutStyle ||
      fontSize != old.fontSize ||
      textScaler != old.textScaler ||
      textDirection != old.textDirection ||
      color != old.color;
}

class _PinnedNoteRow extends StatefulWidget {
  const _PinnedNoteRow({
    super.key,
    required this.note,
    required this.onUpdate,
    required this.onDelete,
  });

  final PinnedNote note;
  final Future<void> Function(String newText) onUpdate;
  final Future<void> Function() onDelete;

  @override
  State<_PinnedNoteRow> createState() => _PinnedNoteRowState();
}

class _PinnedNoteRowState extends State<_PinnedNoteRow>
    with SingleTickerProviderStateMixin {
  late final AnimationController _exit;
  late final TextEditingController _editController;
  late final ProseEditingController _prose;
  late final FocusNode _editFocusNode;
  final GlobalKey<State<TextField>> _fieldKey = GlobalKey();
  bool _hovered = false;
  bool _isEditing = false;

  /// The text of an edit that has been committed but not yet read back.
  ///
  /// Storing a note is asynchronous, so between leaving the editor and the
  /// rewritten note arriving from the database this row's [widget.note] still
  /// carries the *pre-edit* text. Showing that is what made a reminder flick
  /// back to its old shape for a few frames on save.
  String? _pendingText;

  @override
  void initState() {
    super.initState();
    _exit = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 160),
    );
    _editController = TextEditingController(text: widget.note.text);
    _editFocusNode = FocusNode()
      ..addListener(() {
        if (!_editFocusNode.hasFocus && _isEditing) {
          unawaited(_submitEdit());
        }
      });
    _editFocusNode.onKeyEvent = (node, event) {
      if (event is! KeyDownEvent) return KeyEventResult.ignored;
      if ((event.logicalKey == LogicalKeyboardKey.enter ||
              event.logicalKey == LogicalKeyboardKey.numpadEnter) &&
          !HardwareKeyboard.instance.isShiftPressed) {
        unawaited(_submitEdit());
        _editFocusNode.unfocus();
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    };
    // A pinned note is a multiline prose body, so emphasis is always on. This
    // field is a raw [TextField] rather than one of the shared widgets, so it
    // does its own wrapping (EMPHASIS_FORMATTING.md §5.2).
    _prose = ProseEditingController(
      source: _editController,
      focusNode: _editFocusNode,
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _exit.duration = VoyagerMotion.reduced(context)
        ? Duration.zero
        : const Duration(milliseconds: 160);
  }

  @override
  void didUpdateWidget(covariant _PinnedNoteRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.note.text != oldWidget.note.text) {
      // Whatever the new text is — the edit landing, or a change from
      // somewhere else — the stored note is now the fresher of the two.
      _pendingText = null;
      if (!_isEditing) _editController.text = widget.note.text;
    }
  }

  @override
  void dispose() {
    _exit.dispose();
    // Before the focus node it listens to, and before the controller it wraps.
    _prose.dispose();
    _editController.dispose();
    _editFocusNode.dispose();
    super.dispose();
  }

  /// The note's text as this row should show it: the edit still in flight if
  /// there is one, the stored note otherwise.
  String get _text => _pendingText ?? widget.note.text;

  void _startEditing() {
    setState(() {
      _isEditing = true;
      _editController.text = _text;
      _editController.selection = TextSelection.collapsed(offset: _text.length);
    });
    _editFocusNode.requestFocus();
  }

  Future<void> _submitEdit() async {
    if (!_isEditing) return;
    final newText = _editController.text.trim();
    final changed = newText != _text;
    setState(() {
      _isEditing = false;
      // Held over for a delete as much as for a rewrite. An emptied note goes
      // out through the exit animation, and until the store has caught up
      // [widget.note] still carries the words that were just cleared — showing
      // those put the whole reminder back on screen for the frames it took to
      // collapse, which reads as the delete having failed.
      _pendingText = newText;
    });
    if (newText.isEmpty) {
      await _handleDelete();
    } else if (changed) {
      await widget.onUpdate(newText);
    }
  }

  Future<void> _handleDelete() async {
    await _exit.forward();
    if (!mounted) return;
    await widget.onDelete();
  }

  @override
  Widget build(BuildContext context) {
    final size = Tween<double>(
      begin: 1,
      end: 0,
    ).animate(CurvedAnimation(parent: _exit, curve: Curves.easeInCubic));
    final theme = Theme.of(context);

    final noteStyle = theme.textTheme.bodySmall ?? const TextStyle();

    Widget content;
    if (_isEditing) {
      final fieldContentPadding = _pinnedNoteFieldPadding(theme);
      final textStyle = withSquiggleRoom(noteStyle);
      content = VimTextScope(
        enabled:
            VimEnabledScope.of(context) &&
            vimSuitsField(keyboardType: TextInputType.multiline),
        controller: _editController,
        multiline: true,
        proseEmphasis: true,
        builder: (context, vim) {
          final overlayPadding = vimOverlayPadding(
            contentPadding: fieldContentPadding,
            density: theme.visualDensity,
            cursorWidth: vim.overlayCaretWidth,
            outlineGap: true,
            outlineCenter: true,
          );
          final emphasisTheme = ProseEmphasisTheme.of(
            theme.colorScheme,
            theme.colorScheme.primary,
          );
          _prose.emphasis = emphasisTheme;
          return VimOverlayHost(
            session: vim.session,
            snippetSession: vim.snippetSession,
            autocorrectSession: vim.autocorrectSession,
            overlayPaintsSelection: vim.overlayPaintsSelection,
            spanBuilder: _prose.overlaySpan,
            highlightFill: emphasisTheme.highlightColor,
            controller: _prose,
            focusNode: _editFocusNode,
            style: textStyle,
            accentColor: theme.colorScheme.primary,
            overlayPadding: overlayPadding,
            underlay: SpellCheckSquiggleLayer(
              spanBuilder: _prose.overlaySpan,
              controller: _prose,
              focusNode: _editFocusNode,
              style: textStyle,
              suppressActiveWord: vim.suppressSpellcheckActiveWord,
            ),
            child: wrapWithSecondaryTapWordSelect(
              fieldKey: _fieldKey,
              child: TextField(
                key: _fieldKey,
                controller: _prose,
                cursorColor: vim.overlayCaretColor(theme.colorScheme.primary),
                cursorWidth: vim.overlayCaretWidth,
                undoController: vim.undoController,
                focusNode: _editFocusNode,
                maxLines: null,
                minLines: 1,
                scrollPadding: kVoyagerFieldScrollPadding,
                scrollPhysics: const VoyagerFieldScrollPhysics(),
                contextMenuBuilder: voyagerTextContextMenuBuilder(
                  context,
                  snippetsAllowed: vim.snippetsAllowed,
                  spellcheckAllowed: true,
                  autocorrectSession: vim.autocorrectSession,
                ),
                spellCheckConfiguration:
                    const SpellCheckConfiguration.disabled(),
                keyboardType: TextInputType.multiline,
                onSubmitted: (_) => unawaited(_submitEdit()),
                style: textStyle,
                decoration: InputDecoration(
                  isDense: true,
                  contentPadding: fieldContentPadding,
                  filled: true,
                  fillColor: theme.colorScheme.onSurface.withValues(
                    alpha: 0.05,
                  ),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(
                      VoyagerTheme.fieldRadius,
                    ),
                    borderSide: BorderSide(
                      color: theme.colorScheme.primary.withValues(alpha: 0.6),
                      width: 1.2,
                    ),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(
                      VoyagerTheme.fieldRadius,
                    ),
                    borderSide: BorderSide(
                      color: theme.colorScheme.primary.withValues(alpha: 0.3),
                      width: 1.2,
                    ),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(
                      VoyagerTheme.fieldRadius,
                    ),
                    borderSide: BorderSide(
                      color: theme.colorScheme.primary.withValues(alpha: 0.6),
                      width: 1.2,
                    ),
                  ),
                ),
              ),
            ),
          );
        },
      );
    } else {
      content = Tooltip(
        message: 'Click to edit reminder',
        child: Padding(
          padding: _kPinnedNoteTextPadding,
          child: VoyagerProseText(_text, style: noteStyle),
        ),
      );
    }

    content = _WrapMarks(
      text: _text,
      style: _isEditing ? withSquiggleRoom(noteStyle) : noteStyle,
      // What each state's paragraph really uses: [EditableText]'s fallback
      // while editing, and none for the display [Text].
      strutStyle: _isEditing
          ? StrutStyle.fromTextStyle(
              withSquiggleRoom(noteStyle),
              forceStrutHeight: true,
            )
          : null,
      spanBuilder: _prose.overlaySpan,
      // The prose controller, not the raw one. Reveal is a function of the
      // focus as well as of the value — [ProseEditingController] listens to
      // the focus node for exactly that, and its doc is why the overlay layers
      // "come along too" — so listening to `_editController` would leave this,
      // §8's sixth layer, the one layer that does not relayout in the frame a
      // `**` appears or disappears. The wrap points move on that line and the
      // elbow marks stay against the old ones.
      controller: _isEditing ? _prose : null,
      child: content,
    );

    // The highlight and click target cover the text alone — exactly the box
    // the field takes over on click — not the taller row the delete X sets.
    // The X has its own hover fill, matching the feed dismiss control.
    content = AnimatedContainer(
      duration: const Duration(milliseconds: 120),
      decoration: BoxDecoration(
        color: _hovered && !_isEditing ? theme.hoverColor : Colors.transparent,
        borderRadius: BorderRadius.circular(VoyagerTheme.fieldRadius),
      ),
      child: content,
    );
    if (!_isEditing) {
      content = InkWell(
        onTap: _startEditing,
        borderRadius: BorderRadius.circular(VoyagerTheme.fieldRadius),
        // The highlight above already covers this on hover.
        hoverColor: Colors.transparent,
        child: content,
      );
    }

    final row = Padding(
      // Right inset only, matching the feed row's inner padding, so the
      // dismiss controls of both sections stand in one column. The left
      // is left alone: the note's own text inset already puts it on the
      // same pixel as the text in the input above it.
      padding: const EdgeInsets.only(right: 12),
      // The text alone sets the row's height, so one note's highlight meets
      // the next with no gap. The delete X is laid over the row's right end
      // rather than beside the text, shrunk to a square of the row's height
      // (the exit SizeTransition clips anything that spills past it); the
      // text keeps the X's slot clear either way, so the row is the same
      // size while it is being edited.
      child: Stack(
        children: [
          // Full width, as the Row this replaced was: the exit SizeTransition
          // hands the row loose constraints, which would let the text's box
          // shrink to its words.
          SizedBox(
            width: double.infinity,
            child: Padding(
              padding: EdgeInsetsDirectional.only(end: _inboxDismissSlotSize),
              child: content,
            ),
          ),
          if (!_isEditing)
            PositionedDirectional(
              top: 0,
              bottom: 0,
              end: 0,
              width: _inboxDismissSlotSize,
              child: Center(
                child: AspectRatio(
                  aspectRatio: 1,
                  child: _HoverRevealed(
                    revealed: _hovered,
                    child: _InboxDismissButton(onPressed: _handleDelete),
                  ),
                ),
              ),
            ),
        ],
      ),
    );

    return SizeTransition(
      sizeFactor: size,
      alignment: AlignmentDirectional.topStart,
      child: FadeTransition(
        opacity: size,
        child: MouseRegion(
          onEnter: (_) {
            if (!_hovered) setState(() => _hovered = true);
          },
          onExit: (_) {
            if (_hovered) setState(() => _hovered = false);
          },
          child: row,
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Unified feed
// ---------------------------------------------------------------------------

/// `rounded.row` — shared by the feed and hidden rows so a row is the same
/// shape wherever it appears in the popover.
const double _kInboxRowRadius = 16;

/// The feed row's leading column: one fixed box a checkbox or a type icon is
/// centred in, so a task and an event start their titles on the same pixel.
/// Sized to [VoyagerCheckbox]'s own footprint (a 20px box in 10px of padding),
/// which is the largest thing that goes in it.
const double _kFeedLeadingSlot = 40;

/// "Backups failing" — shown while there has been no successful automatic
/// backup on the last two days the app was open (AUTO_BACKUP_HLD.md §9.4).
///
/// Device-local and derived, like the backups themselves, so it has no
/// dismissal: it goes away when a backup succeeds or backups are turned off.
///
/// A click opens Settings at the automatic-backup tiles, where the status
/// says why; Retry claims its own taps first.
class _BackupAlertSection extends ConsumerWidget {
  const _BackupAlertSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final service = ref.watch(autoBackupServiceProvider);
    final status = service.status;
    if (status == null || !status.failing) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final running = status.health == AutoBackupHealth.backingUp;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {
        final router = GoRouter.of(context);
        ref.read(revealAutoBackupRequestProvider.notifier).state = true;
        Navigator.of(context).pop();
        router.go('/settings');
      },
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        child: Row(
          children: [
            const Icon(
              PhosphorIconsRegular.warningCircle,
              size: 20,
              color: Colors.amber,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Backups failing', style: theme.textTheme.bodyMedium),
                  Text(
                    status.detail,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            GlassButton(
              dense: true,
              label: running ? 'Retrying…' : 'Retry',
              onPressed: running ? null : service.runIfDue,
            ),
          ],
        ),
      ),
    );
  }
}

/// Folder backups that need the user (FOLDER_BACKUP_HLD.md §8.4): one row
/// per source whose folder shrank (Review) or whose backups are failing.
///
/// Derived from the service's status, like [_BackupAlertSection], so it has
/// no dismissal: a row goes when the hold is acknowledged or a check
/// succeeds. A click opens Settings at the folder-backup section; the buttons
/// claim their own taps first.
class _FolderBackupAlertSection extends ConsumerWidget {
  const _FolderBackupAlertSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final service = ref.watch(folderBackupServiceProvider);
    final alerts = [
      for (final s in service.status?.sources ?? const [])
        if (s.alert != null) s,
    ];
    if (alerts.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);
    return Column(
      children: [
        for (final status in alerts)
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () {
              final router = GoRouter.of(context);
              ref.read(revealFolderBackupsRequestProvider.notifier).state =
                  true;
              Navigator.of(context).pop();
              router.go('/settings');
            },
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: Row(
                children: [
                  Icon(
                    PhosphorIconsRegular.warningCircle,
                    size: 20,
                    color: status.alert == FolderBackupAlert.review
                        ? theme.colorScheme.error
                        : Colors.amber,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          status.alert == FolderBackupAlert.review
                              ? '${status.source.name} shrank'
                              : '${status.source.name} backups failing',
                          style: theme.textTheme.bodyMedium,
                        ),
                        Text(
                          status.detail,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (status.alert == FolderBackupAlert.review) ...[
                    GlassButton(
                      dense: true,
                      label: 'Show backups',
                      onPressed: () {
                        // The popover closes first; the list opens over the
                        // app on the root navigator, which outlives it.
                        final root = Navigator.of(
                          context,
                          rootNavigator: true,
                        ).context;
                        Navigator.of(context).pop();
                        showFolderBackupListDialog(
                          root,
                          sourceId: status.source.id,
                        );
                      },
                    ),
                    const SizedBox(width: 8),
                    GlassButton(
                      dense: true,
                      label: 'This was intentional',
                      onPressed: () => service.acceptDrop(status.source.id),
                    ),
                  ] else
                    GlassButton(
                      dense: true,
                      label: status.health == FolderBackupHealth.backingUp
                          ? 'Retrying…'
                          : 'Retry',
                      onPressed: status.health == FolderBackupHealth.backingUp
                          ? null
                          : () => service.backUpNow(status.source.id),
                    ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

class _FeedSection extends ConsumerWidget {
  const _FeedSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final feedAsync = ref.watch(visibleNotificationFeedProvider.settled);
    final items = feedAsync.valueOrNull ?? const <NotificationFeedItem>[];
    final hasNotes =
        (ref.watch(pinnedNotesProvider.settled).valueOrNull ?? const [])
            .isNotEmpty;
    if (items.isEmpty) return _FeedEmptyState(showPinHint: !hasNotes);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Only worth naming when there is a list of reminders above it to be
        // told apart from; on its own the feed is what the popover *is*.
        if (hasNotes)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text(
              'Notifications',
              style: theme.textTheme.labelMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        for (final item in items)
          _FeedRow(key: ValueKey(item.dismissalKey), item: item),
      ],
    );
  }
}

class _FeedEmptyState extends StatelessWidget {
  const _FeedEmptyState({required this.showPinHint});

  /// Whether to suggest pinning something. Only when there are no reminders
  /// either — with notes on screen the affordance has already been found.
  final bool showPinHint;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            PhosphorIconsRegular.checkCircle,
            size: 20,
            color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.5),
          ),
          const SizedBox(height: 10),
          Text(
            'All caught up',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          if (showPinHint) ...[
            const SizedBox(height: 4),
            Text(
              'Pin a reminder above to keep it handy.',
              textAlign: TextAlign.center,
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant.withValues(
                  alpha: 0.7,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _FeedRow extends ConsumerStatefulWidget {
  const _FeedRow({super.key, required this.item});

  final NotificationFeedItem item;

  @override
  ConsumerState<_FeedRow> createState() => _FeedRowState();
}

class _FeedRowState extends ConsumerState<_FeedRow>
    with SingleTickerProviderStateMixin {
  late final AnimationController _exit;
  bool _hovered = false;
  bool _completingNow = false;

  @override
  void initState() {
    super.initState();
    _exit = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 160),
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _exit.duration = VoyagerMotion.reduced(context)
        ? Duration.zero
        : const Duration(milliseconds: 160);
  }

  @override
  void dispose() {
    _exit.dispose();
    super.dispose();
  }

  Future<void> _dismiss() async {
    // Captured before the write: the popover may close while it runs, and the
    // toast offering the undo has to outlive the row.
    final container = ProviderScope.containerOf(context, listen: false);
    final overlay = Overlay.of(context, rootOverlay: true);
    final item = widget.item;
    // Stored on press — the exit animation must not gate the hide, or closing
    // the popover mid-animation would cancel a dismiss the user already asked
    // for.
    await container
        .read(notificationRepositoryProvider)
        .dismiss(item.dismissalKey);
    if (item.type == NotificationItemType.review) {
      await _retireStaleReviewDismissals(container);
    }
    container.invalidate(notificationDismissalsProvider);
    _offerHideUndo(overlay: overlay, container: container, items: [item]);
    if (mounted) await _exit.forward();
  }

  Future<void> _complete() async {
    setState(() => _completingNow = true);
    await _exit.forward();
    if (!mounted) return;
    final task = widget.item.task!;
    // Through the shared path rather than a lone `completed: true` here: a
    // repeating task ticked from the inbox has to roll on to its next
    // occurrence and stay live, exactly as it does on the To-Do page. Written
    // flat it simply vanished into the completed section and never came back.
    await completeTodoTask(
      repo: ref.read(todoRepositoryProvider),
      sync: ref.read(remoteSyncServiceProvider),
      taskId: task.id,
    );
    ref.invalidate(todoTasksProvider(task.listId));
    ref.invalidate(allTodoTasksProvider);
  }

  Future<void> _deleteTask() async {
    final task = widget.item.task!;
    // Captured before the card animates out: the row unmounts with it, and the
    // toast offering the undo has to outlive both.
    final container = ProviderScope.containerOf(context, listen: false);
    final overlay = Overlay.of(context, rootOverlay: true);
    final confirmed = await showConfirmDialog(
      context,
      title: 'Delete task?',
      message: '"${task.title}" will be moved to trash.',
    );
    if (!confirmed || !mounted) return;
    await _exit.forward();
    if (!mounted) return;
    // Through the shared path rather than a lone `softDeleteTask` here:
    // deleting a task from the inbox has to take its subtasks and its images
    // with it, exactly as deleting it from the To-Do page does. That path also
    // pushes the tombstones explicitly, which todo tasks need —
    // `DriftTodoRepository` is not wired to `SyncedWriteNotifier`, so without
    // an explicit push the task disappeared here and stayed live in Firestore.
    final deletion = await softDeleteTaskWithSubtasks(container, task);
    _invalidateTasks(container, task.listId);

    showSoftDeleteUndoToast(
      overlay: overlay,
      message: deletedMessage(task.title, fallback: 'task'),
      restore: () async {
        await restoreTaskWithSubtasks(container, deletion);
        _invalidateTasks(container, task.listId);
      },
    );
  }

  void _invalidateTasks(ProviderContainer container, String listId) {
    container.invalidate(todoTasksProvider(listId));
    container.invalidate(allTodoTasksProvider);
  }

  Future<void> _deleteEvent() async {
    final item = widget.item;
    final event = item.event!;
    // See [_deleteTask] on why both are captured before the delete.
    final container = ProviderScope.containerOf(context, listen: false);
    final overlay = Overlay.of(context, rootOverlay: true);

    // Through the calendar's own path: this row is one *occurrence* of what
    // may be a long series, so the prompt has to offer the same this/future/
    // all choice rather than tombstoning everything behind a confirm that
    // named a single evening.
    await deleteCalendarEventInteractive(
      context: context,
      container: container,
      overlay: overlay,
      event: event,
      occurrenceDay: item.occurrenceDate ?? item.dueAt,
      onConfirmed: () async {
        if (!mounted) return false;
        await _exit.forward();
        return mounted;
      },
    );
  }

  Future<void> _changeEventColor() async {
    final event = widget.item.event!;
    final palette = ref.read(colorPaletteProvider);
    final picked = await pickColorFromPalette(
      context,
      palette: palette,
      current: event.colorValue,
      title: 'Change color',
    );
    if (picked == null || !mounted) return;
    await ref
        .read(calendarRepositoryProvider)
        .upsertEvent(event.copyWith(colorValue: picked));
    ref.invalidate(calendarEventsProvider);
  }

  Future<void> _resetEventColor() async {
    final event = widget.item.event!;
    final calendars = ref.read(calendarsProvider).valueOrNull ?? const [];
    final settings = ref.read(settingsProvider).valueOrNull;
    final calendar = calendars
        .where((c) => c.id == event.calendarId)
        .firstOrNull;
    final defaultColor =
        calendar?.colorValue ?? settings?.accentColor ?? 0xFF7C9EFF;
    await ref
        .read(calendarRepositoryProvider)
        .upsertEvent(event.copyWith(colorValue: defaultColor));
    ref.invalidate(calendarEventsProvider);
  }

  Future<void> _deleteBill() async {
    final bill = widget.item.bill!;
    // See [_deleteTask] on why both are captured before the delete.
    final container = ProviderScope.containerOf(context, listen: false);
    final overlay = Overlay.of(context, rootOverlay: true);

    final confirmed = await showConfirmDialog(
      context,
      title: 'Delete subscription?',
      message: '"${bill.name}" will be moved to trash.',
    );
    if (!confirmed || !mounted) return;
    await _exit.forward();
    if (!mounted) return;
    final repository = container.read(financeRepositoryProvider);
    await repository.softDeleteSubscription(bill.id);
    container.invalidate(subscriptionsProvider);

    showSoftDeleteUndoToast(
      overlay: overlay,
      message: deletedMessage(bill.name, fallback: 'subscription'),
      restore: () async {
        // Rebuilt rather than `copyWith`'d: `copyWith` reads
        // `deletedAt ?? this.deletedAt`, so it cannot clear a tombstone.
        //
        // The version is resolved against disk rather than against the
        // snapshot — see [restoreVersionFrom].
        final current = await repository.getSubscription(bill.id);
        abortIfAlreadyRestored(
          found: current != null,
          deletedAt: current?.deletedAt,
        );
        await repository.upsertSubscription(
          Subscription(
            id: bill.id,
            createdAt: bill.createdAt,
            updatedAt: utcNow(),
            version: restoreVersionFrom(
              preDeleteVersion: bill.version,
              currentVersion: current?.version,
            ),
            name: bill.name,
            amountCents: bill.amountCents,
            period: bill.period,
            anchorDueDate: bill.anchorDueDate,
            paidThroughDate: bill.paidThroughDate,
            colorValue: bill.colorValue,
            note: bill.note,
            store: bill.store,
          ),
        );
        container.invalidate(subscriptionsProvider);
      },
    );
  }

  Future<void> _editBill() async {
    await showSubscriptionModal(context, ref, existing: widget.item.bill);
  }

  Future<void> _logBillPayment() async {
    await logSubscriptionPayment(context, ref, widget.item.bill!);
  }

  void _revealTask() {
    final task = widget.item.task!;
    final router = GoRouter.of(context);
    ref.read(revealRequestProvider.notifier).state = RevealRequest.task(task);
    Navigator.of(context).pop();
    router.go('/todo');
  }

  void _revealEvent() {
    final event = widget.item.event!;
    final router = GoRouter.of(context);
    // The occurrence this row stands for, so a repeating event opens on
    // tonight's month rather than the series anchor's.
    ref.read(revealRequestProvider.notifier).state = RevealRequest.event(
      event,
      day: widget.item.occurrenceDate,
    );
    Navigator.of(context).pop();
    router.go('/calendar');
  }

  void _openReviewPage() {
    final router = GoRouter.of(context);
    Navigator.of(context).pop();
    router.go(_reviewPage(widget.item.reviewSource!).path);
  }

  List<ContextMenuItem> _menuItems() {
    switch (widget.item.type) {
      case NotificationItemType.task:
        return [
          ContextMenuItem(
            label: 'Show in To-Do',
            icon: PhosphorIconsRegular.arrowSquareOut,
            onTap: _revealTask,
          ),
          ContextMenuItem(
            label: 'Delete',
            icon: PhosphorIconsRegular.trash,
            isDestructive: true,
            onTap: () => unawaited(_deleteTask()),
          ),
        ];
      case NotificationItemType.event:
        return [
          ContextMenuItem(
            label: 'Show in Calendar',
            icon: PhosphorIconsRegular.arrowSquareOut,
            onTap: _revealEvent,
          ),
          ContextMenuItem(
            label: 'Change color',
            icon: PhosphorIconsRegular.palette,
            onTap: () => unawaited(_changeEventColor()),
          ),
          ContextMenuItem(
            label: 'Default color',
            icon: PhosphorIconsRegular.arrowCounterClockwise,
            onTap: () => unawaited(_resetEventColor()),
          ),
          ContextMenuItem(
            label: 'Delete',
            icon: PhosphorIconsRegular.trash,
            isDestructive: true,
            onTap: () => unawaited(_deleteEvent()),
          ),
        ];
      case NotificationItemType.bill:
        return [
          ContextMenuItem(
            label: 'Edit',
            icon: PhosphorIconsRegular.pencilSimple,
            onTap: () => unawaited(_editBill()),
          ),
          ContextMenuItem(
            label: 'Delete',
            icon: PhosphorIconsRegular.trash,
            isDestructive: true,
            onTap: () => unawaited(_deleteBill()),
          ),
        ];
      case NotificationItemType.review:
        return [
          ContextMenuItem(
            label: 'Open ${_reviewPage(widget.item.reviewSource!).label}',
            icon: PhosphorIconsRegular.arrowSquareOut,
            onTap: _openReviewPage,
          ),
        ];
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final size = Tween<double>(
      begin: 1,
      end: 0,
    ).animate(CurvedAnimation(parent: _exit, curve: Curves.easeInCubic));
    return SizeTransition(
      sizeFactor: size,
      alignment: AlignmentDirectional.topStart,
      child: FadeTransition(
        opacity: size,
        child: ContextMenuRegion(
          items: _menuItems(),
          child: MouseRegion(
            onEnter: (_) {
              if (!_hovered) setState(() => _hovered = true);
            },
            onExit: (_) {
              if (_hovered) setState(() => _hovered = false);
            },
            // A click opens the thing the row stands for: a task or event in
            // its editor, a bill's Log payment sheet, a review queue on its
            // page. The checkbox and the dismiss button claim their own taps
            // first.
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: switch (widget.item.type) {
                NotificationItemType.task => _revealTask,
                NotificationItemType.event => _revealEvent,
                NotificationItemType.review => _openReviewPage,
                NotificationItemType.bill => () => unawaited(_logBillPayment()),
              },
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 1,
                ),
                // Hover highlight matching the todo/calendar row treatment
                // elsewhere in the app (same `theme.hoverColor` fill).
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 120),
                  decoration: BoxDecoration(
                    color: _hovered ? theme.hoverColor : Colors.transparent,
                    borderRadius: BorderRadius.circular(_kInboxRowRadius),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 5,
                    ),
                    child: Row(
                      children: [
                        // No gap after it: the leading slot is wider than what
                        // it holds, so the spacing is already inside the box.
                        _leading(theme),
                        Expanded(child: _FeedItemText(item: widget.item)),
                        const SizedBox(width: 6),
                        // Fixed-width slot, same as the tracker rows below —
                        // keeps the row's width constant whether or not the
                        // badge for this item's urgency is showing.
                        SizedBox(
                          width: 18,
                          child: Center(
                            child:
                                widget.item.type == NotificationItemType.review
                                // It never lights the bell, so no dot here.
                                ? null
                                : NotificationUrgencyDot(
                                    important:
                                        widget.item.urgency ==
                                        NotificationUrgency.important,
                                    accent: theme.colorScheme.primary,
                                  ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        // Fades in on hover, but stays a real target on touch,
                        // where hover never fires: an invisible-yet-tappable
                        // dismiss in the corner of every notification is worse
                        // than a visible one.
                        _HoverRevealed(
                          revealed: _hovered,
                          child: _InboxDismissButton(onPressed: _dismiss),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _leading(ThemeData theme) {
    final Widget child = switch (widget.item.type) {
      NotificationItemType.task => VoyagerCheckbox(
        value: _completingNow || widget.item.task!.completed,
        onChanged: (_) => unawaited(_complete()),
      ),
      NotificationItemType.event => Icon(
        PhosphorIconsRegular.calendarDot,
        size: 18,
        color: Color(
          resolvePaletteColor(widget.item.event!.colorValue, theme.brightness),
        ),
      ),
      NotificationItemType.bill => Icon(
        PhosphorIconsRegular.currencyDollar,
        size: 18,
        color: Color(
          resolvePaletteColor(widget.item.bill!.colorValue, theme.brightness),
        ),
      ),
      NotificationItemType.review => Icon(
        _reviewPage(widget.item.reviewSource!).icon,
        size: 18,
        color: theme.colorScheme.primary,
      ),
    };
    return SizedBox(
      width: _kFeedLeadingSlot,
      child: Center(child: child),
    );
  }
}

/// A feed item's title over its due / date · time / amount · due line — the
/// same two lines in the live feed and in Hidden, so a hidden item can be told
/// apart from its namesake the way it could before it was hidden.
class _FeedItemText extends StatelessWidget {
  const _FeedItemText({required this.item});

  final NotificationFeedItem item;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final title = _feedTitle(item);
    final isOverdue = _isOverdueItem(item.dueAt);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          title.isEmpty ? '(untitled)' : title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.bodySmall,
        ),
        Text(
          _subtitle(),
          style: theme.textTheme.labelSmall?.copyWith(
            color: isOverdue
                ? theme.colorScheme.error
                : theme.colorScheme.onSurfaceVariant,
            fontWeight: isOverdue ? FontWeight.w500 : null,
          ),
        ),
      ],
    );
  }

  bool _isOverdueItem(DateTime due) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final target = DateTime(due.year, due.month, due.day);
    return target.isBefore(today);
  }

  String _subtitle() {
    switch (item.type) {
      case NotificationItemType.task:
        return _dueLabel(item.dueAt);
      case NotificationItemType.event:
        return '${_dateLabel(item.dueAt)} · ${_timeLabel(item.dueAt)}';
      case NotificationItemType.bill:
        return '${formatCents(item.bill!.amountCents)} · ${_dueLabel(item.dueAt)}';
      case NotificationItemType.review:
        final count = item.reviewCount;
        return switch (item.reviewSource!) {
          ReviewSource.study => '$count card${count == 1 ? '' : 's'} due',
          ReviewSource.leetcode => '$count problem${count == 1 ? '' : 's'} due',
        };
    }
  }
}

/// "Today" / "Tomorrow" / "in N days" / "N days overdue", relative to now.
String _dueLabel(DateTime due) {
  final days = calendarDaysBetween(DateTime.now(), due);
  if (days == 0) return 'Today';
  if (days == 1) return 'Tomorrow';
  if (days < 0) return '${-days}d overdue';
  return 'in ${days}d';
}

String _dateLabel(DateTime date) {
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final target = DateTime(date.year, date.month, date.day);
  if (target == today) return 'Today';
  if (target == addCalendarDays(today, 1)) return 'Tomorrow';
  return '${date.month}/${date.day}';
}

String _timeLabel(DateTime date) {
  final hour = date.hour % 12 == 0 ? 12 : date.hour % 12;
  final minute = date.minute.toString().padLeft(2, '0');
  final period = date.hour < 12 ? 'AM' : 'PM';
  return '$hour:$minute $period';
}

// ---------------------------------------------------------------------------
// Footer
// ---------------------------------------------------------------------------

/// The row that opens one of the popover's two footer sections.
///
/// Both are the same control — a caret that turns, a label, and whatever the
/// section's own action is on the right — so that "Log stats" and
/// "Hidden (N)" read as a pair of drawers under the feed rather than as two
/// unrelated widgets that happen to be stacked.
class _FooterTrigger extends StatelessWidget {
  const _FooterTrigger({
    super.key,
    required this.expanded,
    required this.label,
    required this.onTap,
    this.icon,
    this.trailing,
  });

  final bool expanded;
  final String label;
  final VoidCallback onTap;
  final IconData? icon;

  /// Section action shown to the right of the label — the date controls, the
  /// restore button. Sits outside the tappable area so pressing it doesn't
  /// also collapse the section it belongs to.
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    // The InkWell sits *under* the row rather than around the label, so the
    // hover highlight spans the full width whether or not the section has
    // trailing controls. The label side ignores pointers and falls through to
    // it; [trailing] keeps its own taps.
    return Stack(
      children: [
        Positioned.fill(child: InkWell(onTap: onTap)),
        Row(
          children: [
            Expanded(
              child: IgnorePointer(
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 8,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        expanded
                            ? PhosphorIconsRegular.caretDown
                            : PhosphorIconsRegular.caretRight,
                        size: 12,
                        color: muted,
                      ),
                      const SizedBox(width: 6),
                      if (icon != null) ...[
                        Icon(icon, size: 16, color: muted),
                        const SizedBox(width: 6),
                      ],
                      Text(
                        label,
                        style: theme.textTheme.labelMedium?.copyWith(
                          color: muted,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            if (trailing != null)
              Padding(
                padding: const EdgeInsets.only(right: 20),
                child: trailing,
              ),
          ],
        ),
      ],
    );
  }
}

/// A [_FooterTrigger] action drawn as bare text on the header's own
/// background, so it reads as part of the title row rather than a chip.
class _FooterTextButton extends StatelessWidget {
  const _FooterTextButton({
    required this.onTap,
    this.label,
    this.icon,
    this.tooltip,
  });

  final VoidCallback onTap;
  final String? label;
  final IconData? icon;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final button = InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(6),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) Icon(icon, size: 14, color: muted),
            if (icon != null && label != null) const SizedBox(width: 6),
            if (label != null)
              Text(
                label!,
                style: theme.textTheme.labelMedium?.copyWith(color: muted),
              ),
          ],
        ),
      ),
    );
    return tooltip == null ? button : Tooltip(message: tooltip, child: button);
  }
}

// ---------------------------------------------------------------------------
// Hidden / dismissed items
// ---------------------------------------------------------------------------

class _HiddenSection extends ConsumerStatefulWidget {
  const _HiddenSection({super.key});

  @override
  ConsumerState<_HiddenSection> createState() => _HiddenSectionState();
}

class _HiddenSectionState extends ConsumerState<_HiddenSection>
    with SingleTickerProviderStateMixin {
  final GlobalKey _headerKey = GlobalKey();
  bool _expanded = false;
  final Set<String> _selected = {};

  /// Drives the rows' clip. The rows stay mounted until it is fully closed,
  /// so collapsing slides them under the drawer's bottom edge instead of
  /// dropping them on the first frame and animating only the empty space.
  late final AnimationController _drawer;
  late final CurvedAnimation _drawerCurve;

  @override
  void initState() {
    super.initState();
    _drawer = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 220),
    );
    _drawerCurve = CurvedAnimation(
      parent: _drawer,
      curve: VoyagerSpring.moveCurve,
    );
  }

  @override
  void dispose() {
    _drawerCurve.dispose();
    _drawer.dispose();
    super.dispose();
  }

  void _setExpanded(bool expanded) {
    setState(() => _expanded = expanded);
    expanded ? _drawer.forward() : _drawer.reverse();
  }

  void _toggleSelected(String key) {
    setState(() {
      if (!_selected.remove(key)) _selected.add(key);
    });
  }

  Future<void> _restoreSelected() async {
    // Captured before the awaits: closing the popover mid-restore must not
    // skip the invalidate on a keepAlive dismissals cache.
    final container = ProviderScope.containerOf(context, listen: false);
    final selected = _selected.toList();
    final repo = container.read(notificationRepositoryProvider);
    for (final key in selected) {
      await repo.undismiss(key);
    }
    if (mounted) setState(_selected.clear);
    container.invalidate(notificationDismissalsProvider);
  }

  /// Puts every hidden item back in the feed.
  Future<void> _restoreAll() async {
    // Captured before the awaits: closing the popover mid-restore must not
    // skip the invalidate on a keepAlive dismissals cache.
    final container = ProviderScope.containerOf(context, listen: false);
    final hidden = await container.read(hiddenNotificationFeedProvider.future);
    if (hidden.isEmpty) return;
    final repo = container.read(notificationRepositoryProvider);
    for (final item in hidden) {
      await repo.undismiss(item.dismissalKey);
    }
    container.invalidate(notificationDismissalsProvider);
  }

  void _toggleExpanded() {
    final expanding = !_expanded;
    _setExpanded(expanding);
    if (expanding) _scrollIntoView();
  }

  /// Opens the drawer and brings it on screen — the header's Show hidden.
  ///
  /// Never closes it: pressed with the drawer already open, it only scrolls.
  void reveal() {
    if (!_expanded) _setExpanded(true);
    _scrollIntoView();
  }

  void _scrollIntoView() {
    // Wait for the newly revealed rows to lay out, then scroll the popover
    // so the header lands at the top of the visible area — or as far down
    // as the content allows, if there isn't enough below it to do that.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final headerContext = _headerKey.currentContext;
      if (headerContext == null) return;
      Scrollable.ensureVisible(
        headerContext,
        alignment: 0.0,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final hiddenAsync = ref.watch(hiddenNotificationFeedProvider.settled);
    final hidden = hiddenAsync.valueOrNull ?? const <NotificationFeedItem>[];
    if (hidden.isEmpty) return const SizedBox.shrink();
    // Drop selections for items that are no longer hidden (e.g. restored
    // elsewhere, or escalated back into the main feed).
    _selected.retainAll(hidden.map((i) => i.dismissalKey).toSet());
    final curve = VoyagerMotion.reduced(context)
        ? Curves.easeOut
        : VoyagerSpring.moveCurve;
    // Flipped for the close, so it leaves fast and settles the way the open
    // does, rather than creeping out and snapping shut.
    _drawerCurve
      ..curve = curve
      ..reverseCurve = curve.flipped;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _FooterTrigger(
          key: _headerKey,
          expanded: _expanded,
          label: 'Hidden (${hidden.length})',
          onTap: _toggleExpanded,
          // Nothing to restore from a closed drawer. Open, it is one button or
          // the other — never Restore all beside a selection, where a mis-tap
          // would dump the rest of the list back into the feed.
          trailing: !_expanded
              ? null
              : _selected.isNotEmpty
              ? _FooterTextButton(
                  onTap: _restoreSelected,
                  label: 'Restore (${_selected.length})',
                )
              : _FooterTextButton(onTap: _restoreAll, label: 'Restore all'),
        ),
        // Animates both ways — growing open and shrinking closed — instead
        // of the row list just appearing/disappearing and snapping the
        // scroll view around it. Top-aligned, so closing clips from the
        // bottom and the rows slip under the panel's edge.
        AnimatedBuilder(
          animation: _drawer,
          builder: (context, rows) => _drawer.isDismissed
              ? const SizedBox.shrink()
              : SizeTransition(
                  sizeFactor: _drawerCurve,
                  alignment: Alignment.topCenter,
                  child: rows,
                ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(8, 0, 8, 6),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final item in hidden)
                  _HiddenRow(
                    key: ValueKey(item.dismissalKey),
                    item: item,
                    selected: _selected.contains(item.dismissalKey),
                    onToggle: () => _toggleSelected(item.dismissalKey),
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _HiddenRow extends StatelessWidget {
  const _HiddenRow({
    super.key,
    required this.item,
    required this.selected,
    required this.onToggle,
  });

  final NotificationFeedItem item;
  final bool selected;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Static, and no urgency dot: Hidden is archival, not a second feed.
    final (IconData glyph, Color color) = switch (item.type) {
      // A round tick rather than the feed's checkbox — beside the selection
      // box it would read as a second checkbox, and one that does nothing.
      NotificationItemType.task => (
        PhosphorIconsRegular.checkCircle,
        theme.colorScheme.primary,
      ),
      NotificationItemType.event => (
        PhosphorIconsRegular.calendarDot,
        Color(resolvePaletteColor(item.event!.colorValue, theme.brightness)),
      ),
      NotificationItemType.bill => (
        PhosphorIconsRegular.currencyDollar,
        Color(resolvePaletteColor(item.bill!.colorValue, theme.brightness)),
      ),
      NotificationItemType.review => (
        _reviewPage(item.reviewSource!).icon,
        theme.colorScheme.primary,
      ),
    };
    return InkWell(
      onTap: onToggle,
      borderRadius: BorderRadius.circular(_kInboxRowRadius),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
        child: Row(
          children: [
            _MiniCheckbox(value: selected, accent: theme.colorScheme.primary),
            const SizedBox(width: 10),
            Icon(glyph, size: 18, color: color),
            const SizedBox(width: 10),
            Expanded(child: _FeedItemText(item: item)),
          ],
        ),
      ),
    );
  }
}

/// Compact selection checkbox for the hidden-items multi-select — smaller
/// than [VoyagerCheckbox] to fit this section's dense list.
class _MiniCheckbox extends StatelessWidget {
  const _MiniCheckbox({required this.value, required this.accent});

  final bool value;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: 14,
      height: 14,
      decoration: BoxDecoration(
        color: value ? accent : Colors.transparent,
        borderRadius: BorderRadius.circular(3),
        border: Border.all(
          color: value
              ? accent
              : theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.5),
          width: 1.3,
        ),
      ),
      child: value
          ? Icon(PhosphorIconsBold.check, size: 10, color: onColorLabel(accent))
          : null,
    );
  }
}

// ---------------------------------------------------------------------------
// Embedded analytics / stats logging
// ---------------------------------------------------------------------------

class _AnalyticsSection extends ConsumerStatefulWidget {
  const _AnalyticsSection({required this.growthPin});

  /// Set while the body grows open, so the inbox scrolls with it.
  final _GrowthPin growthPin;

  @override
  ConsumerState<_AnalyticsSection> createState() => _AnalyticsSectionState();
}

class _AnalyticsSectionState extends ConsumerState<_AnalyticsSection> {
  late DateTime _selectedDate;
  final Map<String, GlobalKey<TrackerEntryRowState>> _rowKeys = {};
  final Set<String> _dirtyTrackerIds = {};

  /// Weekly, monthly and yearly trackers listed for [_selectedDate] so far.
  /// Each stays listed until the date changes, so logging one doesn't pull
  /// its row away mid-edit. See [_isListed].
  final Set<String> _keptTrackerIds = {};

  /// Collapsed until asked for. Logging a stat is a deliberate errand, not
  /// something to be presented with every time the bell is clicked — and
  /// leaving the body unbuilt keeps the trackers and their fields out of the
  /// popover (and out of [NotificationPopoverWarmup]) until they are wanted.
  /// Only their data is loaded ahead — see [_prewarm]. Once opened it stays open, across popovers and
  /// restarts, until closed again — see [_logStatsExpandedProvider].
  bool get _expanded => ref.read(_logStatsExpandedProvider);

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    _selectedDate = DateTime(now.year, now.month, now.day);
    if (!_expanded) unawaited(_prewarm());
  }

  /// Loads what the body's rows show while the section is still closed.
  ///
  /// Otherwise the first open lays the body out around loading bars, then
  /// again a frame later as the values arrive, and the rows jump mid-reveal.
  /// Every one of these providers is kept alive, so a read
  /// here is all the warming they need.
  Future<void> _prewarm() async {
    final trackers = await ref.read(trackersProvider.future);
    if (!mounted) return;
    for (final tracker in trackers) {
      if (tracker.deletedAt != null) continue;
      unawaited(
        tracker.type == TrackerType.counter
            ? ref.read(counterAdjustmentsProvider(tracker.id).future)
            : ref.read(trackerValuesProvider(tracker.id).future),
      );
    }
  }

  void _toggleExpanded() {
    final expanded = !_expanded;
    ref.read(_logStatsExpandedProvider.notifier).state = expanded;
    // Only a tap scrolls: a section restored open leaves the popover at
    // its top.
    if (expanded) {
      _pinWhileGrowing();
    } else {
      widget.growthPin.section = null;
    }
    unawaited(
      ref.read(settingsRepositoryProvider).saveInboxLogStatsExpanded(expanded),
    );
  }

  /// Has the inbox scroll along as the body grows open, keeping the section's
  /// bottom at the bottom of the visible area — or, once the section is
  /// taller than that, its header at the top. See [_PinnedGrowthPhysics].
  ///
  /// Measured now, from the collapsed layout: nothing above the section or
  /// below it moves while it grows.
  void _pinWhileGrowing() {
    final position = Scrollable.of(context).position;
    final sliver = context.findRenderObject()! as RenderSliver;
    final top = sliver.constraints.precedingScrollExtent;
    final content = position.maxScrollExtent + position.viewportDimension;
    widget.growthPin.section = (
      top: top,
      below: content - top - sliver.geometry!.scrollExtent,
    );
    _unpinOnceSettled();
  }

  /// Lets go of the pin once the section's height holds still between two
  /// frames, rather than when the reveal ends: the body can still resize
  /// after that, as the tracker rows' entries load.
  void _unpinOnceSettled([double? lastHeight]) {
    WidgetsBinding.instance
      ..addPostFrameCallback((_) {
        if (!mounted || !_expanded) return;
        final height = (context.findRenderObject()! as RenderSliver)
            .geometry!
            .scrollExtent;
        if (height != lastHeight) return _unpinOnceSettled(height);
        widget.growthPin.section = null;
      })
      ..scheduleFrame();
  }

  Future<void> _pickDate() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _selectedDate,
      firstDate: DateTime(now.year - 5),
      lastDate: now,
    );
    if (picked != null && mounted) await _setDate(picked);
  }

  void _resetToToday() {
    final now = DateTime.now();
    unawaited(_setDate(DateTime(now.year, now.month, now.day)));
  }

  /// Saves any typed-but-unsaved number before moving to [date]: a weekly,
  /// monthly or yearly row can drop out of the list on the new date, and
  /// would take its edit with it.
  Future<void> _setDate(DateTime date) async {
    await _saveAll();
    if (!mounted) return;
    setState(() {
      _selectedDate = date;
      _keptTrackerIds.clear();
    });
  }

  /// Whether [tracker] gets a row for [_selectedDate]. Daily trackers and
  /// counters always do: a counter's cadence only sets its graph's
  /// resolution, and its changes are always per day. A weekly, monthly or
  /// yearly one does on every day of its period until that period has a
  /// value — and then, once listed, for as long as this date is showing.
  /// Null while that tracker's values are still loading.
  bool? _isListed(WidgetRef ref, StatisticTracker tracker) {
    if (tracker.cadence == TrackerCadence.daily ||
        tracker.type == TrackerType.counter ||
        _keptTrackerIds.contains(tracker.id)) {
      return true;
    }
    // Not `.settled`: a refresh still serves the values from before it, and
    // those can predate the very log it is refreshing for.
    final valuesAsync = ref.watch(trackerValuesProvider(tracker.id));
    final values = valuesAsync.valueOrNull;
    if (values == null) return null;
    final period = ref
        .read(periodicPromptServiceProvider)
        .trackerPeriodStartFor(_selectedDate, tracker.cadence);
    if (hasValueForPeriod(values, period)) return false;
    // Only a finished read is kept, so a stale one can't pin a logged row.
    // Recorded during build, without a rebuild of its own: it changes no
    // output now, only what a later build keeps.
    if (!valuesAsync.isLoading) _keptTrackerIds.add(tracker.id);
    return true;
  }

  String _formatDate(DateTime d) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    if (d == today) return 'Today';
    final yesterday = today.subtract(const Duration(days: 1));
    if (d == yesterday) return 'Yesterday';
    return '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
  }

  GlobalKey<TrackerEntryRowState> _keyFor(String trackerId) =>
      _rowKeys.putIfAbsent(trackerId, () => GlobalKey<TrackerEntryRowState>());

  void _onDirtyChanged(String trackerId, bool dirty) {
    setState(() {
      if (dirty) {
        _dirtyTrackerIds.add(trackerId);
      } else {
        _dirtyTrackerIds.remove(trackerId);
      }
    });
  }

  /// Moves the row at [oldIndex] of [listed] to [newIndex] (counted with it
  /// already taken out) within [all], the full order that also holds the
  /// trackers not listed on this date, and saves that order to settings. It lands just above the listed row it
  /// was dropped on, or just below the last one, so the unlisted trackers
  /// keep their places relative to everything else.
  void _reorder(
    List<StatisticTracker> all,
    List<StatisticTracker> listed,
    int oldIndex,
    int newIndex,
  ) {
    final moved = listed[oldIndex].id;
    final rest = [for (final t in listed) t.id]..removeAt(oldIndex);
    if (rest.isEmpty) return;
    final before = [for (final t in all) t.id];
    final ids = [...before]..remove(moved);
    if (newIndex < rest.length) {
      ids.insert(ids.indexOf(rest[newIndex]), moved);
    } else {
      ids.insert(ids.indexOf(rest.last) + 1, moved);
    }
    // Dropped back where it was: saving would still move the settings clock
    // and upload them.
    if (listEquals(ids, before)) return;
    // Taken into the settings before it is written, so the rows take the new
    // order in the very next frame — rebuilt here, as the save tells no one.
    unawaited(ref.read(settingsProvider.notifier).saveInboxTrackerOrder(ids));
    setState(() {});
  }

  Future<void> _saveAll() async {
    for (final key in _rowKeys.values.toList()) {
      await key.currentState?.commit();
    }
  }

  /// Flushes any pending integer-tracker edit before letting a dismiss (tap
  /// outside, Escape) actually close the popover, so it isn't silently
  /// dropped. See [TrackerEntryRowState.commit] / [_saveAll].
  Future<void> _flushAndClose() async {
    await _saveAll();
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final expanded = ref.watch(_logStatsExpandedProvider);
    final isToday = _isSameDate(_selectedDate, DateTime.now());
    return SliverMainAxisGroup(
      slivers: [
        // The trigger doubles as the section's title row: caret, icon and
        // label on the left, the date controls it is titling on the right.
        SliverToBoxAdapter(
          child: _FooterTrigger(
            expanded: expanded,
            icon: PhosphorIconsRegular.chartBar,
            label: 'Log stats',
            onTap: _toggleExpanded,
            trailing: expanded
                ? Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (!isToday) ...[
                        _FooterTextButton(
                          onTap: _resetToToday,
                          icon: PhosphorIconsRegular.target,
                          tooltip: 'Jump to today',
                        ),
                        const SizedBox(width: 2),
                      ],
                      _FooterTextButton(
                        onTap: _pickDate,
                        icon: PhosphorIconsRegular.calendar,
                        label: _formatDate(_selectedDate),
                      ),
                    ],
                  )
                : null,
          ),
        ),
        _SliverReveal(
          open: expanded,
          duration: const Duration(milliseconds: 220),
          curve: VoyagerMotion.reduced(context)
              ? Curves.easeOut
              : VoyagerSpring.moveCurve,
          // In a Consumer of its own: [_SliverReveal] builds the body after
          // this build has ended, too late for this element's ref to keep
          // the body's watches.
          builder: (context) =>
              Consumer(builder: (context, ref, _) => _body(context, ref)),
        ),
      ],
    );
  }

  Widget _body(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final trackersAsync = ref.watch(trackersProvider.settled);
    // Watched for an order pulled from another device; read for this one's
    // own, which [SettingsNotifier.saveInboxTrackerOrder] sets silently.
    ref.watch(settingsProvider.select((s) => s.valueOrNull?.inboxTrackerOrder));
    final savedOrder =
        ref.read(settingsProvider).valueOrNull?.inboxTrackerOrder ??
        const <String>[];
    Widget note(Widget child) => SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: child,
      ),
    );
    final content = trackersAsync.when(
      data: (trackers) {
        // Every live tracker, listed on this date or not: a drag places the
        // moved row among them all. See [_reorder].
        final all = trackers.where((t) => t.deletedAt == null).toList()
          // Until the list is first dragged — and for a tracker made since —
          // the Analytics heatmap's layout: starred first, then by cadence,
          // each group in its manual order.
          ..sort((a, b) {
            if (a.starred != b.starred) return a.starred ? -1 : 1;
            if (!a.starred && a.cadence != b.cadence) {
              return a.cadence.index.compareTo(b.cadence.index);
            }
            return compareTrackerOrder(a, b);
          });
        // Then the saved order, with the trackers it doesn't name after it.
        final rank = {
          for (var i = 0; i < savedOrder.length; i++) savedOrder[i]: i,
        };
        int at(StatisticTracker t) => rank[t.id] ?? savedOrder.length;
        mergeSort(all, compare: (a, b) => at(a).compareTo(at(b)));

        final listing = [for (final t in all) _isListed(ref, t)];
        final listed = [
          for (var i = 0; i < all.length; i++)
            if (listing[i] ?? false) all[i],
        ];
        if (listed.isEmpty) {
          // Not "nothing left" while a tracker's values are still loading.
          if (listing.contains(null)) {
            return note(const LinearProgressIndicator());
          }
          return note(
            Text(
              all.isEmpty
                  ? 'No trackers yet.'
                  : 'Nothing left to log for this day.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          );
        }
        return SliverMainAxisGroup(
          slivers: [
            SliverReorderableList(
              itemCount: listed.length,
              onReorderItem: (oldIndex, newIndex) =>
                  _reorder(all, listed, oldIndex, newIndex),
              proxyDecorator: (child, index, animation) =>
                  Material(type: MaterialType.transparency, child: child),
              // Per row rather than around the section, which is slivers
              // here. Ungated, unlike the button: commit() skips any row
              // that isn't dirty.
              itemBuilder: (context, i) => CtrlEnterToSubmitScope(
                key: ValueKey(listed[i].id),
                onSubmit: _saveAll,
                child: TrackerEntryRow(
                  key: _keyFor(listed[i].id),
                  tracker: listed[i],
                  date: _selectedDate,
                  dragIndex: i,
                  onDirtyChanged: (dirty) =>
                      _onDirtyChanged(listed[i].id, dirty),
                ),
              ),
            ),
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Align(
                  alignment: Alignment.centerRight,
                  child: GlassButton(
                    onPressed: _dirtyTrackerIds.isEmpty ? null : _saveAll,
                    icon: const Icon(
                      PhosphorIconsRegular.checkCircle,
                      size: 14,
                    ),
                    label: 'Save',
                    dense: true,
                  ),
                ),
              ),
            ),
          ],
        );
      },
      loading: () => note(const LinearProgressIndicator()),
      error: (e, _) => SliverToBoxAdapter(child: Text('$e')),
    );
    return PopScope(
      canPop: _dirtyTrackerIds.isEmpty,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        _flushAndClose();
      },
      child: SliverPadding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        sliver: content,
      ),
    );
  }

  bool _isSameDate(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;
}

/// [AnimatedSize] for a sliver: grows [builder]'s sliver open from its top
/// edge when [open] turns true, and shrinks it away when it turns false.
///
/// Builds nothing while closed, so a closed section costs no rows. Starts
/// where [open] says without animating, as [AnimatedSize] does.
class _SliverReveal extends StatefulWidget {
  const _SliverReveal({
    required this.open,
    required this.duration,
    required this.curve,
    required this.builder,
  });

  final bool open;
  final Duration duration;
  final Curve curve;
  final WidgetBuilder builder;

  @override
  State<_SliverReveal> createState() => _SliverRevealState();
}

class _SliverRevealState extends State<_SliverReveal>
    with SingleTickerProviderStateMixin {
  late final _controller = AnimationController(
    vsync: this,
    duration: widget.duration,
    value: widget.open ? 1 : 0,
  )..addStatusListener(_onStatus);
  late final _curved = CurvedAnimation(
    parent: _controller,
    curve: widget.curve,
  );

  void _onStatus(AnimationStatus status) {
    // Fully closed: drop the body.
    if (status.isDismissed) setState(() {});
  }

  @override
  void didUpdateWidget(_SliverReveal oldWidget) {
    super.didUpdateWidget(oldWidget);
    _controller.duration = widget.duration;
    _curved.curve = widget.curve;
    if (widget.open != oldWidget.open) {
      widget.open ? _controller.forward() : _controller.reverse();
    }
  }

  @override
  void dispose() {
    _curved.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.open && _controller.isDismissed) {
      return const SliverToBoxAdapter();
    }
    return _RevealSliver(factor: _curved, sliver: widget.builder(context));
  }
}

/// Shows [factor] of [sliver]'s extent, clipping the rest away below.
class _RevealSliver extends SingleChildRenderObjectWidget {
  const _RevealSliver({required this.factor, required Widget sliver})
    : super(child: sliver);

  final Animation<double> factor;

  @override
  _RenderRevealSliver createRenderObject(BuildContext context) =>
      _RenderRevealSliver(factor);

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderRevealSliver renderObject,
  ) {
    renderObject.factor = factor;
  }
}

class _RenderRevealSliver extends RenderProxySliver {
  _RenderRevealSliver(this._factor);

  Animation<double> _factor;
  set factor(Animation<double> value) {
    if (identical(value, _factor)) return;
    if (attached) {
      _factor.removeListener(markNeedsLayout);
      value.addListener(markNeedsLayout);
    }
    _factor = value;
    markNeedsLayout();
  }

  final _clip = LayerHandle<ClipRectLayer>();

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _factor.addListener(markNeedsLayout);
  }

  @override
  void detach() {
    _factor.removeListener(markNeedsLayout);
    super.detach();
  }

  @override
  void dispose() {
    _clip.layer = null;
    super.dispose();
  }

  @override
  void performLayout() {
    final child = this.child!;
    child.layout(constraints, parentUsesSize: true);
    final childGeometry = child.geometry!;
    if (childGeometry.scrollOffsetCorrection != null) {
      geometry = SliverGeometry(
        scrollOffsetCorrection: childGeometry.scrollOffsetCorrection,
      );
      return;
    }
    final extent = childGeometry.scrollExtent * _factor.value;
    final paintExtent = calculatePaintOffset(constraints, from: 0, to: extent);
    geometry = SliverGeometry(
      scrollExtent: extent,
      paintExtent: paintExtent,
      maxPaintExtent: extent,
      cacheExtent: calculateCacheOffset(constraints, from: 0, to: extent),
      hasVisualOverflow:
          childGeometry.hasVisualOverflow ||
          extent < childGeometry.scrollExtent,
    );
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    final child = this.child;
    if (child == null || !geometry!.visible) {
      _clip.layer = null;
      return;
    }
    final childOffset =
        offset + (child.parentData! as SliverPhysicalParentData).paintOffset;
    if (_factor.value >= 1) {
      _clip.layer = null;
      context.paintChild(child, childOffset);
      return;
    }
    // The popover only scrolls down, so what's hidden is below.
    _clip.layer = context.pushClipRect(
      needsCompositing,
      offset,
      Offset.zero & Size(constraints.crossAxisExtent, geometry!.paintExtent),
      (context, _) => context.paintChild(child, childOffset),
      oldLayer: _clip.layer,
    );
  }
}

/// Pre-renders the notification inbox popover offscreen for two frames
/// immediately after login so the GPU rasteriser compiles all subwidget shaders
/// and builds widget trees before the user clicks the notification bell.
class NotificationPopoverWarmup extends StatefulWidget {
  const NotificationPopoverWarmup({super.key});

  @override
  State<NotificationPopoverWarmup> createState() =>
      _NotificationPopoverWarmupState();
}

class _NotificationPopoverWarmupState extends State<NotificationPopoverWarmup> {
  int _frames = 0;
  bool _done = false;

  @override
  void initState() {
    super.initState();
    if (DevFlags.disableCache) {
      _done = true;
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback(_onFrame);
  }

  void _onFrame(Duration _) {
    if (!mounted || DevFlags.disableCache) return;
    _frames++;
    if (_frames >= 2) {
      setState(() => _done = true);
    } else {
      WidgetsBinding.instance.addPostFrameCallback(_onFrame);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_done || DevFlags.disableCache) return const SizedBox.shrink();
    return TickerMode(
      enabled: false,
      child: Offstage(
        offstage: true,
        child: SizedBox(
          width: kNotificationPopoverWidth,
          height: 400,
          child: Material(
            type: MaterialType.transparency,
            child: const NotificationInboxPopover(),
          ),
        ),
      ),
    );
  }
}

/// Side of the inbox dismiss ✕ hover overlay. The 14px glyph sits in this
/// square; [kMinTouchTarget] (48) spilled a grey patch past the row highlight.
/// 30 still leaves 8px of slop around the icon. Android keeps 48 so a
/// fingertip still has somewhere to land.
const double _kInboxDismissSize = 30;

double get _inboxDismissSlotSize => isAndroid ? 48 : _kInboxDismissSize;

/// Compact dismiss ✕ used on inbox reminder and feed rows.
class _InboxDismissButton extends StatelessWidget {
  const _InboxDismissButton({required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      icon: const Icon(PhosphorIconsRegular.x, size: 14),
      padding: EdgeInsets.zero,
      // `constraints` alone would not have shrunk it: IconButton's default
      // padded tap target wraps the whole thing back out to 48 whatever the
      // constraints say, which is the oversized hover fill.
      style: IconButton.styleFrom(
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
      constraints: isAndroid
          ? kMinTouchTarget
          : const BoxConstraints.tightFor(
              width: _kInboxDismissSize,
              height: _kInboxDismissSize,
            ),
      onPressed: onPressed,
    );
  }
}

/// Reveals a control on pointer hover, and unconditionally where there is no
/// hover to enter.
///
/// A plain [AnimatedOpacity] at zero still hit-tests, so on a touch screen the
/// hover-only affordances in this popover were invisible *and* live — a tap in
/// the corner of a notification dismissed it with nothing to suggest it would.
/// Hidden here means out of the hit-test tree as well as out of sight.
class _HoverRevealed extends StatelessWidget {
  const _HoverRevealed({required this.revealed, required this.child});

  final bool revealed;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final visible = revealed || isAndroid;
    return IgnorePointer(
      ignoring: !visible,
      child: AnimatedOpacity(
        opacity: visible ? 1 : 0,
        duration: const Duration(milliseconds: 120),
        child: child,
      ),
    );
  }
}

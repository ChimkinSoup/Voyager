import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
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
import 'package:voyager/core/utils/ids.dart';
import 'package:voyager/core/widgets/voyager_prose_text.dart';
import 'package:voyager/core/widgets/confirm_dialog.dart';
import 'package:voyager/core/widgets/color_picker_field.dart';
import 'package:voyager/core/widgets/context_menu.dart';
import 'package:voyager/core/widgets/glass_button.dart';
import 'package:voyager/core/widgets/notification_urgency_dot.dart';
import 'package:voyager/core/widgets/spell_check_field_support.dart';
import 'package:voyager/core/widgets/spell_check_squiggle_layer.dart';
import 'package:voyager/core/widgets/voyager_checkbox.dart';
import 'package:voyager/core/widgets/voyager_text_field.dart';
import 'package:voyager/domain/models/enums.dart';
import 'package:voyager/domain/models/finance_models.dart';
import 'package:voyager/domain/models/notification_models.dart';
import 'package:voyager/features/analytics/tracker_entry_row.dart';
import 'package:voyager/features/calendar/calendar_event_delete.dart';
import 'package:voyager/features/finance/finance_subscription_modal.dart';
import 'package:voyager/features/todo/todo_list_actions.dart';
import 'package:voyager/features/shell/reveal_request.dart';
import 'package:voyager/core/text/prose_editing_controller.dart';
import 'package:voyager/core/text/prose_text_span.dart';
import 'package:voyager/core/vim/vim_enabled_scope.dart';
import 'package:voyager/core/vim/vim_text_overlay.dart';
import 'package:voyager/core/vim/vim_text_scope.dart';
import 'package:voyager/core/widgets/field_scroll_padding.dart';
import 'package:voyager/core/widgets/voyager_scroll_view.dart';

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

/// The notification bell's popover content: pinned quick-reminders, the
/// unified urgency-sorted feed, a hidden/dismissed browser, and an embedded
/// daily-stats logger.
class NotificationInboxPopover extends ConsumerWidget {
  const NotificationInboxPopover({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final maxHeight = MediaQuery.sizeOf(context).height * 0.75;
    return Material(
      type: MaterialType.transparency,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxHeight),
        // One scroll region, not several: no section carries its own
        // viewport, so dragging anywhere in the panel — the reminders
        // included — moves the whole thing as a single sheet. It is also
        // what [Scrollable.ensureVisible] scrolls when Hidden expands.
        child: VoyagerScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _Header(
                onClearAll: () => _clearAll(ref),
                onRestoreAll: () => _restoreAll(ref),
              ),
              const _PinnedNotesSection(),
              const _FeedSection(),
              const _AnalyticsSection(),
              const _HiddenSection(),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _clearAll(WidgetRef ref) async {
    final visible = await ref.read(visibleNotificationFeedProvider.future);
    if (visible.isEmpty) return;
    final repo = ref.read(notificationRepositoryProvider);
    for (final item in visible) {
      await repo.dismiss(item.dismissalKey);
    }
    ref.invalidate(notificationDismissalsProvider);
  }

  /// The inverse of [_clearAll]: puts every hidden item back in the feed.
  Future<void> _restoreAll(WidgetRef ref) async {
    final hidden = await ref.read(hiddenNotificationFeedProvider.future);
    if (hidden.isEmpty) return;
    final repo = ref.read(notificationRepositoryProvider);
    for (final item in hidden) {
      await repo.undismiss(item.dismissalKey);
    }
    ref.invalidate(notificationDismissalsProvider);
  }
}

class _Header extends ConsumerWidget {
  const _Header({required this.onClearAll, required this.onRestoreAll});

  final VoidCallback onClearAll;
  final VoidCallback onRestoreAll;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final visible =
        ref.watch(visibleNotificationFeedProvider).valueOrNull ??
        const <NotificationFeedItem>[];
    final hidden =
        ref.watch(hiddenNotificationFeedProvider).valueOrNull ??
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
          // restoring from an empty hidden list, no clearing an empty feed.
          if (hidden.isNotEmpty)
            Semantics(
              button: true,
              label: 'Restore all',
              child: GlassButton(
                onPressed: onRestoreAll,
                icon: const Icon(
                  PhosphorIconsRegular.arrowCounterClockwise,
                  size: 14,
                ),
                tooltip: 'Restore all',
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
      message: deletedMessage(note.text, fallback: 'note'),
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
    final notesAsync = ref.watch(pinnedNotesProvider);
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
const double _kReminderFieldRadius = 14;

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
    _kPinnedNoteTextPadding.top +
    line.baseline -
    line.ascent +
    line.height / 2;

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
                    borderRadius: BorderRadius.circular(6),
                    borderSide: BorderSide(
                      color: theme.colorScheme.primary.withValues(alpha: 0.6),
                      width: 1.2,
                    ),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(6),
                    borderSide: BorderSide(
                      color: theme.colorScheme.primary.withValues(alpha: 0.3),
                      width: 1.2,
                    ),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(6),
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
        child: InkWell(
          onTap: _startEditing,
          borderRadius: BorderRadius.circular(_kInboxRowRadius),
          // The row-wide highlight below already covers this on hover.
          hoverColor: Colors.transparent,
          child: Padding(
            padding: _kPinnedNoteTextPadding,
            child: VoyagerProseText(_text, style: noteStyle),
          ),
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
          // The row highlight covers the text; the delete X has its own
          // hover fill, matching the feed dismiss control.
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            decoration: BoxDecoration(
              color: _hovered && !_isEditing
                  ? theme.hoverColor
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(_kInboxRowRadius),
            ),
            // Right inset only, matching the feed row's inner padding, so the
            // dismiss controls of both sections stand in one column. The left
            // is left alone: the note's own text inset already puts it on the
            // same pixel as the text in the input above it.
            padding: const EdgeInsets.fromLTRB(0, 2, 12, 2),
            child: Row(
              children: [
                Expanded(child: content),
                // The delete X keeps its slot while the row is being edited,
                // just without the control in it. It is the tallest thing in
                // the row, so it — not the text or the field — is what sets
                // the row's height; dropping it on the way into the editor
                // shrank the row out from under the click that opened it.
                if (_isEditing)
                  SizedBox.square(dimension: _inboxDismissSlotSize)
                else
                  _HoverRevealed(
                    revealed: _hovered,
                    child: _InboxDismissButton(onPressed: _handleDelete),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Unified feed
// ---------------------------------------------------------------------------

/// `rounded.row` — shared by the reminder, feed, and hidden rows so a row is
/// the same shape wherever it appears in the popover.
const double _kInboxRowRadius = 16;

/// The feed row's leading column: one fixed box a checkbox or a type icon is
/// centred in, so a task and an event start their titles on the same pixel.
/// Sized to [VoyagerCheckbox]'s own footprint (a 20px box in 10px of padding),
/// which is the largest thing that goes in it.
const double _kFeedLeadingSlot = 40;

class _FeedSection extends ConsumerWidget {
  const _FeedSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final feedAsync = ref.watch(visibleNotificationFeedProvider);
    final items = feedAsync.valueOrNull ?? const <NotificationFeedItem>[];
    final hasNotes =
        (ref.watch(pinnedNotesProvider).valueOrNull ?? const []).isNotEmpty;
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
    await _exit.forward();
    if (!mounted) return;
    await ref
        .read(notificationRepositoryProvider)
        .dismiss(widget.item.dismissalKey);
    ref.invalidate(notificationDismissalsProvider);
  }

  Future<void> _complete() async {
    setState(() => _completingNow = true);
    await _exit.forward();
    if (!mounted) return;
    final task = widget.item.task!;
    final updated = task.copyWith(completed: true);
    await ref.read(todoRepositoryProvider).upsertTask(updated);
    unawaited(ref.read(remoteSyncServiceProvider).pushTodoTaskNow(updated));
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
            colorValue: bill.colorValue,
            note: bill.note,
          ),
        );
        container.invalidate(subscriptionsProvider);
      },
    );
  }

  Future<void> _editBill() async {
    await showSubscriptionModal(context, ref, existing: widget.item.bill);
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
    ref.read(revealRequestProvider.notifier).state = RevealRequest.event(event);
    Navigator.of(context).pop();
    router.go('/calendar');
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
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 1),
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
                      Expanded(child: _titleAndSubtitle(theme)),
                      const SizedBox(width: 6),
                      // Fixed-width slot, same as the tracker rows below —
                      // keeps the row's width constant whether or not the
                      // badge for this item's urgency is showing.
                      SizedBox(
                        width: 18,
                        child: Center(
                          child: NotificationUrgencyDot(
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
        color: Color(widget.item.event!.colorValue),
      ),
      NotificationItemType.bill => Icon(
        PhosphorIconsRegular.currencyDollar,
        size: 18,
        color: Color(widget.item.bill!.colorValue),
      ),
    };
    return SizedBox(
      width: _kFeedLeadingSlot,
      child: Center(child: child),
    );
  }

  Widget _titleAndSubtitle(ThemeData theme) {
    final item = widget.item;
    final title = switch (item.type) {
      NotificationItemType.task => item.task!.title,
      NotificationItemType.event => item.event!.title,
      NotificationItemType.bill => item.bill!.name,
    };
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
    final item = widget.item;
    switch (item.type) {
      case NotificationItemType.task:
        return _dueLabel(item.dueAt);
      case NotificationItemType.event:
        return '${_dateLabel(item.dueAt)} · ${_timeLabel(item.dueAt)}';
      case NotificationItemType.bill:
        return '${formatCents(item.bill!.amountCents)} · ${_dueLabel(item.dueAt)}';
    }
  }
}

/// "Today" / "Tomorrow" / "in N days" / "N days overdue", relative to now.
String _dueLabel(DateTime due) {
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final target = DateTime(due.year, due.month, due.day);
  final days = target.difference(today).inDays;
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
  if (target == today.add(const Duration(days: 1))) return 'Tomorrow';
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
                padding: const EdgeInsets.only(right: 12),
                child: trailing,
              ),
          ],
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Hidden / dismissed items
// ---------------------------------------------------------------------------

class _HiddenSection extends ConsumerStatefulWidget {
  const _HiddenSection();

  @override
  ConsumerState<_HiddenSection> createState() => _HiddenSectionState();
}

class _HiddenSectionState extends ConsumerState<_HiddenSection> {
  final GlobalKey _headerKey = GlobalKey();
  bool _expanded = false;
  final Set<String> _selected = {};

  void _toggleSelected(String key) {
    setState(() {
      if (!_selected.remove(key)) _selected.add(key);
    });
  }

  Future<void> _restoreSelected() async {
    final repo = ref.read(notificationRepositoryProvider);
    for (final key in _selected) {
      await repo.undismiss(key);
    }
    setState(_selected.clear);
    ref.invalidate(notificationDismissalsProvider);
  }

  void _toggleExpanded() {
    final expanding = !_expanded;
    setState(() => _expanded = expanding);
    if (!expanding) return;
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
    final hiddenAsync = ref.watch(hiddenNotificationFeedProvider);
    final hidden = hiddenAsync.valueOrNull ?? const <NotificationFeedItem>[];
    if (hidden.isEmpty) return const SizedBox.shrink();
    // Drop selections for items that are no longer hidden (e.g. restored
    // elsewhere, or escalated back into the main feed).
    _selected.retainAll(hidden.map((i) => i.dismissalKey).toSet());
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _FooterTrigger(
          key: _headerKey,
          expanded: _expanded,
          label: 'Hidden (${hidden.length})',
          onTap: _toggleExpanded,
          trailing: _expanded && _selected.isNotEmpty
              ? GlassButton(
                  onPressed: _restoreSelected,
                  label: 'Restore (${_selected.length})',
                  dense: true,
                )
              : null,
        ),
        // Animates both ways — growing open and shrinking closed — instead
        // of the row list just appearing/disappearing and snapping the
        // scroll view around it.
        AnimatedSize(
          duration: const Duration(milliseconds: 220),
          curve: VoyagerMotion.reduced(context)
              ? Curves.easeOut
              : VoyagerSpring.moveCurve,
          alignment: Alignment.topCenter,
          child: _expanded
              ? Padding(
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
                )
              : const SizedBox.shrink(),
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
    final title = switch (item.type) {
      NotificationItemType.task => item.task!.title,
      NotificationItemType.event => item.event!.title,
      NotificationItemType.bill => item.bill!.name,
    };
    return InkWell(
      onTap: onToggle,
      borderRadius: BorderRadius.circular(_kInboxRowRadius),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
        child: Row(
          children: [
            _MiniCheckbox(value: selected, accent: theme.colorScheme.primary),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                title.isEmpty ? '(untitled)' : title,
                style: theme.textTheme.bodySmall,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
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
          ? Icon(
              PhosphorIconsBold.check,
              size: 10,
              color: accent.computeLuminance() > 0.5
                  ? Colors.black
                  : Colors.white,
            )
          : null,
    );
  }
}

// ---------------------------------------------------------------------------
// Embedded analytics / stats logging
// ---------------------------------------------------------------------------

class _AnalyticsSection extends ConsumerStatefulWidget {
  const _AnalyticsSection();

  @override
  ConsumerState<_AnalyticsSection> createState() => _AnalyticsSectionState();
}

class _AnalyticsSectionState extends ConsumerState<_AnalyticsSection> {
  late DateTime _selectedDate;
  final Map<String, GlobalKey<TrackerEntryRowState>> _rowKeys = {};
  final Set<String> _dirtyTrackerIds = {};

  /// Collapsed until asked for. Logging a stat is a deliberate errand, not
  /// something to be presented with every time the bell is clicked — and
  /// leaving the body unbuilt keeps the trackers, their fields and their
  /// providers out of the popover (and out of [NotificationPopoverWarmup])
  /// until they are wanted.
  bool _expanded = false;

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    _selectedDate = DateTime(now.year, now.month, now.day);
  }

  Future<void> _pickDate() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _selectedDate,
      firstDate: DateTime(now.year - 5),
      lastDate: now,
    );
    if (picked != null && mounted) {
      setState(() => _selectedDate = picked);
    }
  }

  void _resetToToday() {
    final now = DateTime.now();
    setState(() => _selectedDate = DateTime(now.year, now.month, now.day));
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
    final isToday = _isSameDate(_selectedDate, DateTime.now());
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // The trigger doubles as the section's title row: caret, icon and
        // label on the left, the date controls it is titling on the right.
        _FooterTrigger(
          expanded: _expanded,
          icon: PhosphorIconsRegular.chartBar,
          label: 'Log stats',
          onTap: () => setState(() => _expanded = !_expanded),
          trailing: _expanded
              ? Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (!isToday) ...[
                      GlassButton(
                        onPressed: _resetToToday,
                        icon: const Icon(PhosphorIconsRegular.target, size: 14),
                        tooltip: 'Jump to today',
                        dense: true,
                      ),
                      const SizedBox(width: 6),
                    ],
                    GlassButton(
                      onPressed: _pickDate,
                      icon: const Icon(PhosphorIconsRegular.calendar, size: 14),
                      label: _formatDate(_selectedDate),
                      dense: true,
                    ),
                  ],
                )
              : null,
        ),
        AnimatedSize(
          duration: const Duration(milliseconds: 220),
          curve: VoyagerMotion.reduced(context)
              ? Curves.easeOut
              : VoyagerSpring.moveCurve,
          alignment: Alignment.topCenter,
          child: _expanded ? _body(context) : const SizedBox.shrink(),
        ),
      ],
    );
  }

  Widget _body(BuildContext context) {
    final theme = Theme.of(context);
    final trackersAsync = ref.watch(trackersProvider);
    return PopScope(
      canPop: _dirtyTrackerIds.isEmpty,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        _flushAndClose();
      },
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        child: trackersAsync.when(
              data: (trackers) {
                final daily = trackers
                    .where(
                      (t) =>
                          t.cadence == TrackerCadence.daily &&
                          t.deletedAt == null,
                    )
                    .toList();
                if (daily.isEmpty) {
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    child: Text(
                      'No daily trackers yet.',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  );
                }
                return Column(
                  children: [
                    for (final tracker in daily)
                      TrackerEntryRow(
                        key: _keyFor(tracker.id),
                        tracker: tracker,
                        date: _selectedDate,
                        onDirtyChanged: (dirty) =>
                            _onDirtyChanged(tracker.id, dirty),
                      ),
                    const SizedBox(height: 4),
                    Align(
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
                  ],
                );
              },
          loading: () => const Padding(
            padding: EdgeInsets.symmetric(vertical: 12),
            child: LinearProgressIndicator(),
          ),
          error: (e, _) => Text('$e'),
        ),
      ),
    );
  }

  bool _isSameDate(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;
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

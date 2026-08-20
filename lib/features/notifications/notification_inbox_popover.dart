import 'dart:async';

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
import 'package:voyager/core/utils/ids.dart';
import 'package:voyager/core/widgets/confirm_dialog.dart';
import 'package:voyager/core/widgets/color_picker_field.dart';
import 'package:voyager/core/widgets/context_menu.dart';
import 'package:voyager/core/widgets/contextual_popover.dart';
import 'package:voyager/core/widgets/glass_button.dart';
import 'package:voyager/core/widgets/notification_urgency_dot.dart';
import 'package:voyager/core/widgets/spell_check_field_support.dart';
import 'package:voyager/core/widgets/spell_check_squiggle_layer.dart';
import 'package:voyager/core/widgets/voyager_checkbox.dart';
import 'package:voyager/domain/models/enums.dart';
import 'package:voyager/domain/models/finance_models.dart';
import 'package:voyager/domain/models/notification_models.dart';
import 'package:voyager/features/analytics/tracker_entry_row.dart';
import 'package:voyager/features/finance/finance_subscription_modal.dart';
import 'package:voyager/features/shell/reveal_request.dart';
import 'package:voyager/core/vim/vim_enabled_scope.dart';
import 'package:voyager/core/vim/vim_text_overlay.dart';
import 'package:voyager/core/vim/vim_text_scope.dart';
import 'package:voyager/core/widgets/field_scroll_padding.dart';
import 'package:voyager/core/widgets/voyager_scroll_view.dart';

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
        child: VoyagerScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _Header(
                onClearAll: () => _clearAll(ref),
                onRestoreAll: () => _restoreAll(ref),
              ),
              const Divider(height: 1),
              const _PinnedNotesSection(),
              const Divider(height: 1),
              const _FeedSection(),
              const Divider(height: 1),
              const _AnalyticsSection(),
              const Divider(height: 1),
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

class _Header extends StatelessWidget {
  const _Header({required this.onClearAll, required this.onRestoreAll});

  final VoidCallback onClearAll;
  final VoidCallback onRestoreAll;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 12, 10),
      child: Row(
        children: [
          Text(
            'Inbox',
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
          const Spacer(),
          Tooltip(
            message: 'Restore all',
            child: InkResponse(
              onTap: onRestoreAll,
              radius: 18,
              child: Icon(
                PhosphorIconsRegular.arrowCounterClockwise,
                size: 18,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          const SizedBox(width: 14),
          Tooltip(
            message: 'Clear all',
            child: InkResponse(
              onTap: onClearAll,
              radius: 18,
              child: Icon(
                PhosphorIconsRegular.broom,
                size: 18,
                color: theme.colorScheme.onSurfaceVariant,
              ),
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
  final GlobalKey<State<TextField>> _fieldKey = GlobalKey();

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
    _controller.addListener(_forceSpellCheck);
    WidgetsBinding.instance.addPostFrameCallback((_) => _forceSpellCheck());
  }

  @override
  void dispose() {
    _controller.removeListener(_forceSpellCheck);
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _forceSpellCheck() {
    if (!mounted) return;
    forceSpellCheckDisplay(
      context: context,
      fieldKey: _fieldKey,
      focusNode: _focusNode,
    );
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

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final notesAsync = ref.watch(pinnedNotesProvider);
    final notes = notesAsync.valueOrNull ?? const [];
    const fieldContentPadding = EdgeInsets.symmetric(
      horizontal: 8,
      vertical: 8,
    );
    final textStyle = withSquiggleRoom(
      theme.textTheme.bodySmall?.copyWith(fontSize: 10) ?? const TextStyle(),
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          VimTextScope(
            enabled:
                VimEnabledScope.of(context) &&
                vimSuitsField(keyboardType: TextInputType.multiline),
            controller: _controller,
            multiline: true,
            builder: (context, vim) {
              const hintText = 'Type a quick reminder...';
              final overlayPadding = vimOverlayPadding(
                contentPadding: fieldContentPadding,
                density: theme.visualDensity,
                cursorWidth: vim.overlayCaretWidth,
                outlineGap: true,
                outlineCenter: true,
              );
              return VimOverlayHost(
                session: vim.session,
              snippetSession: vim.snippetSession,
                overlayPaintsSelection: vim.overlayPaintsSelection,
                controller: _controller,
                focusNode: _focusNode,
                style: textStyle,
                accentColor: theme.colorScheme.primary,
                overlayPadding: overlayPadding,
                hintText: hintText,
                underlay: SpellCheckSquiggleLayer(
                  controller: _controller,
                  focusNode: _focusNode,
                  style: textStyle,
                  suppressActiveWord: vim.suppressSpellcheckActiveWord,
                ),
                child: wrapWithSecondaryTapWordSelect(
                  fieldKey: _fieldKey,
                  child: TextField(
                    key: _fieldKey,
                    controller: _controller,
                    cursorColor: vim.overlayCaretColor(
                      theme.colorScheme.primary,
                    ),
                    cursorWidth: vim.overlayCaretWidth,
                    undoController: vim.undoController,
                    focusNode: _focusNode,
                    maxLines: null,
                    minLines: 1,
                    scrollPadding: kVoyagerFieldScrollPadding,
                    contextMenuBuilder: voyagerSpellCheckContextMenuBuilder,
                    spellCheckConfiguration:
                        buildVoyagerSpellCheckConfiguration(context),
                    keyboardType: TextInputType.multiline,
                    onSubmitted: (_) => unawaited(_addNote()),
                    style: textStyle,
                    decoration: InputDecoration(
                      isDense: true,
                      contentPadding: fieldContentPadding,
                      filled: true,
                      fillColor: theme.colorScheme.onSurface.withValues(
                        alpha: 0.04,
                      ),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: BorderSide.none,
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: BorderSide.none,
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: BorderSide(
                          color: theme.colorScheme.primary.withValues(
                            alpha: 0.6,
                          ),
                          width: 1.2,
                        ),
                      ),
                      hintText: hintText,
                      hintStyle: theme.textTheme.bodySmall?.copyWith(
                        fontSize: 10,
                        color: theme.colorScheme.onSurfaceVariant.withValues(
                          alpha: 0.6,
                        ),
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
          for (final note in notes)
            _PinnedNoteRow(
              key: ValueKey(note.id),
              note: note,
              onUpdate: (newText) => _updateNote(note, newText),
              onDelete: () => _deleteNote(note.id),
            ),
        ],
      ),
    );
  }
}

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

/// Marks the lines [text] wrapped onto by itself, so a soft wrap reads
/// differently from a line the user ended with Shift+Enter.
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
    this.controller,
  });

  /// The note as the row is showing it. Ignored while [controller] is given.
  final String text;

  /// The style the text is actually laid out in — the display [Text]'s, or
  /// the field's, which may carry extra line height for the squiggles.
  final TextStyle style;
  final Widget child;

  /// The field's controller while the row is being edited: the marks follow
  /// the text as it is typed, and only the marks rebuild for it.
  final TextEditingController? controller;

  Widget _paint(BuildContext context, String text, Widget? child) {
    return CustomPaint(
      // In front: the field fills its box, and a mark painted behind it would
      // be the one thing about the row that changed on the way into the editor.
      foregroundPainter: _WrapMarkPainter(
        text: text,
        style: style,
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
    required this.text,
    required this.style,
    required this.textScaler,
    required this.textDirection,
    required this.color,
  });

  final String text;
  final TextStyle style;
  final TextScaler textScaler;
  final TextDirection textDirection;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    // The row's whole width less the insets both states keep — so this lays
    // the note out at the width it really wrapped at, in either state.
    final wrapWidth = size.width - _kPinnedNoteTextPadding.horizontal;
    if (text.isEmpty || wrapWidth <= 0) return;
    final painter = TextPainter(
      text: TextSpan(text: text, style: style),
      textScaler: textScaler,
      textDirection: textDirection,
    )..layout(maxWidth: wrapWidth);
    final lines = painter.computeLineMetrics();
    painter.dispose();
    if (lines.length < 2) return;

    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = _kWrapMarkStroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final right = _kPinnedNoteTextPadding.left - _kWrapMarkGap;
    for (var i = 1; i < lines.length; i++) {
      // A line the user ended themselves reports a hard break; a line that
      // simply ran out of room does not. The mark belongs to what follows it.
      if (lines[i - 1].hardBreak) continue;
      final line = lines[i];
      final middle =
          _kPinnedNoteTextPadding.top +
          line.baseline -
          line.ascent +
          line.height / 2;
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
      text != old.text ||
      style != old.style ||
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
    _editController.addListener(_forceSpellCheck);
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
    _editController.removeListener(_forceSpellCheck);
    _editController.dispose();
    _editFocusNode.dispose();
    super.dispose();
  }

  /// The note's text as this row should show it: the edit still in flight if
  /// there is one, the stored note otherwise.
  String get _text => _pendingText ?? widget.note.text;

  void _forceSpellCheck() {
    if (!mounted || !_isEditing) return;
    forceSpellCheckDisplay(
      context: context,
      fieldKey: _fieldKey,
      focusNode: _editFocusNode,
    );
  }

  void _startEditing() {
    setState(() {
      _isEditing = true;
      _editController.text = _text;
      _editController.selection = TextSelection.collapsed(offset: _text.length);
    });
    _editFocusNode.requestFocus();
    WidgetsBinding.instance.addPostFrameCallback((_) => _forceSpellCheck());
  }

  Future<void> _submitEdit() async {
    if (!_isEditing) return;
    final newText = _editController.text.trim();
    final changed = newText.isNotEmpty && newText != _text;
    setState(() {
      _isEditing = false;
      // An emptied note is a delete: it plays its exit animation with the
      // text it already had, so there is nothing to hold over for it.
      if (changed) _pendingText = newText;
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

    final noteStyle =
        theme.textTheme.bodySmall?.copyWith(fontSize: 10) ?? const TextStyle();

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
        builder: (context, vim) {
          final overlayPadding = vimOverlayPadding(
            contentPadding: fieldContentPadding,
            density: theme.visualDensity,
            cursorWidth: vim.overlayCaretWidth,
            outlineGap: true,
            outlineCenter: true,
          );
          return VimOverlayHost(
            session: vim.session,
            snippetSession: vim.snippetSession,
            overlayPaintsSelection: vim.overlayPaintsSelection,
            controller: _editController,
            focusNode: _editFocusNode,
            style: textStyle,
            accentColor: theme.colorScheme.primary,
            overlayPadding: overlayPadding,
            underlay: SpellCheckSquiggleLayer(
              controller: _editController,
              focusNode: _editFocusNode,
              style: textStyle,
              suppressActiveWord: vim.suppressSpellcheckActiveWord,
            ),
            child: wrapWithSecondaryTapWordSelect(
              fieldKey: _fieldKey,
              child: TextField(
                key: _fieldKey,
                controller: _editController,
                cursorColor: vim.overlayCaretColor(theme.colorScheme.primary),
                cursorWidth: vim.overlayCaretWidth,
                undoController: vim.undoController,
                focusNode: _editFocusNode,
                maxLines: null,
                minLines: 1,
                scrollPadding: kVoyagerFieldScrollPadding,
                contextMenuBuilder: voyagerSpellCheckContextMenuBuilder,
                spellCheckConfiguration: buildVoyagerSpellCheckConfiguration(
                  context,
                ),
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
          borderRadius: BorderRadius.circular(6),
          // The row-wide highlight below already covers this on hover.
          hoverColor: Colors.transparent,
          child: Padding(
            padding: _kPinnedNoteTextPadding,
            child: Text(_text, style: noteStyle),
          ),
        ),
      );
    }

    content = _WrapMarks(
      text: _text,
      style: _isEditing ? withSquiggleRoom(noteStyle) : noteStyle,
      controller: _isEditing ? _editController : null,
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
              borderRadius: BorderRadius.circular(6),
            ),
            padding: const EdgeInsets.symmetric(vertical: 2),
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

class _FeedSection extends ConsumerWidget {
  const _FeedSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final feedAsync = ref.watch(visibleNotificationFeedProvider);
    final items = feedAsync.valueOrNull ?? const <NotificationFeedItem>[];
    if (items.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 20),
        child: Center(
          child: Text(
            'All caught up',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      );
    }
    return Column(
      children: [
        for (final item in items)
          _FeedRow(key: ValueKey(item.dismissalKey), item: item),
      ],
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
    final confirmed = await showConfirmDialog(
      context,
      title: 'Delete task?',
      message: '"${task.title}" will be moved to trash.',
    );
    if (!confirmed || !mounted) return;
    await _exit.forward();
    if (!mounted) return;
    final todoRepository = ref.read(todoRepositoryProvider);
    await todoRepository.softDeleteTask(task.id);
    // The tombstone has to be pushed explicitly, the way every other
    // soft-delete site in the app does it. `DriftTodoRepository` is not wired
    // to `SyncedWriteNotifier` — todo tasks upload through explicit pushes —
    // so without this the task disappeared here and stayed live in Firestore:
    // every other device kept showing it, and once the local tombstone aged
    // out of the retention window the next pull brought it back here too.
    final tombstone = await todoRepository.getTask(task.id);
    if (tombstone != null) {
      unawaited(ref.read(remoteSyncServiceProvider).pushTodoTaskNow(tombstone));
    }
    ref.invalidate(todoTasksProvider(task.listId));
    ref.invalidate(allTodoTasksProvider);
  }

  Future<void> _deleteEvent() async {
    final event = widget.item.event!;
    final confirmed = await showConfirmDialog(
      context,
      title: 'Delete event?',
      message: event.title.trim().isEmpty
          ? 'This event will be moved to trash.'
          : '"${event.title}" will be moved to trash.',
    );
    if (!confirmed || !mounted) return;
    await _exit.forward();
    if (!mounted) return;
    await ref.read(calendarRepositoryProvider).softDeleteEvent(event.id);
    ref.invalidate(calendarEventsProvider);
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
    final confirmed = await showConfirmDialog(
      context,
      title: 'Delete subscription?',
      message: '"${bill.name}" will be moved to trash.',
    );
    if (!confirmed || !mounted) return;
    await _exit.forward();
    if (!mounted) return;
    await ref.read(financeRepositoryProvider).softDeleteSubscription(bill.id);
    ref.invalidate(subscriptionsProvider);
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
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
              // Hover highlight matching the todo/calendar row treatment
              // elsewhere in the app (same `theme.hoverColor` fill).
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 120),
                decoration: BoxDecoration(
                  color: _hovered ? theme.hoverColor : Colors.transparent,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 5,
                  ),
                  child: Row(
                    children: [
                      _leading(theme),
                      const SizedBox(width: 10),
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
    switch (widget.item.type) {
      case NotificationItemType.task:
        final task = widget.item.task!;
        return VoyagerCheckbox(
          value: _completingNow || task.completed,
          onChanged: (_) => unawaited(_complete()),
        );
      case NotificationItemType.event:
        return Padding(
          padding: const EdgeInsets.all(10),
          child: Icon(
            PhosphorIconsRegular.calendarDot,
            size: 18,
            color: Color(widget.item.event!.colorValue),
          ),
        );
      case NotificationItemType.bill:
        return Padding(
          padding: const EdgeInsets.all(10),
          child: Icon(
            PhosphorIconsRegular.currencyDollar,
            size: 18,
            color: Color(widget.item.bill!.colorValue),
          ),
        );
    }
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
          style: theme.textTheme.bodySmall?.copyWith(fontSize: 11),
        ),
        Text(
          _subtitle(),
          style: theme.textTheme.labelSmall?.copyWith(
            fontSize: 9.5,
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
    final theme = Theme.of(context);
    final hiddenAsync = ref.watch(hiddenNotificationFeedProvider);
    final hidden = hiddenAsync.valueOrNull ?? const <NotificationFeedItem>[];
    if (hidden.isEmpty) return const SizedBox.shrink();
    // Drop selections for items that are no longer hidden (e.g. restored
    // elsewhere, or escalated back into the main feed).
    _selected.retainAll(hidden.map((i) => i.dismissalKey).toSet());
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Material(
          key: _headerKey,
          type: MaterialType.transparency,
          clipBehavior: Clip.antiAlias,
          borderRadius: const BorderRadius.vertical(
            bottom: Radius.circular(ContextualPopover.contentRadius),
          ),
          child: Row(
            children: [
              Expanded(
                child: InkWell(
                  onTap: _toggleExpanded,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 8,
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          _expanded
                              ? PhosphorIconsRegular.caretDown
                              : PhosphorIconsRegular.caretRight,
                          size: 12,
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                        const SizedBox(width: 6),
                        Text(
                          'Hidden (${hidden.length})',
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              if (_expanded && _selected.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(right: 12),
                  child: GlassButton(
                    onPressed: _restoreSelected,
                    label: 'Restore (${_selected.length})',
                    dense: true,
                  ),
                ),
            ],
          ),
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
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
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
      borderRadius: BorderRadius.circular(6),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
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
    final theme = Theme.of(context);
    final trackersAsync = ref.watch(trackersProvider);
    final isToday = _isSameDate(_selectedDate, DateTime.now());
    return PopScope(
      canPop: _dirtyTrackerIds.isEmpty,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        _flushAndClose();
      },
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(
                  PhosphorIconsRegular.chartBar,
                  size: 16,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(width: 8),
                Text(
                  'Log Stats',
                  style: theme.textTheme.labelMedium?.copyWith(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const Spacer(),
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
            ),
            const SizedBox(height: 8),
            trackersAsync.when(
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
          ],
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
          width: 380,
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

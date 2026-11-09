import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:voyager/core/spellcheck/autocorrect_enabled_scope.dart';
import 'package:voyager/core/text/list_text_editing.dart';
import 'package:voyager/core/text/merge_aware_undo.dart';
import 'package:voyager/core/text/newline_normalization.dart';
import 'package:voyager/core/vim/vim_enabled_scope.dart';
import 'package:voyager/core/vim/vim_text_overlay.dart';
import 'package:voyager/core/vim/vim_text_scope.dart';
import 'package:voyager/core/widgets/autocorrect_flash_layer.dart';
import 'package:voyager/core/widgets/field_hint_style.dart';
import 'package:voyager/core/widgets/field_scroll_padding.dart';
import 'package:voyager/core/widgets/spell_check_field_support.dart';
import 'package:voyager/core/widgets/spell_check_squiggle_layer.dart';
import 'package:voyager/features/gaia/companion/gaia_notch.dart';
import 'package:voyager/features/gaia/companion/gaia_vanish.dart';

/// Gaia's text field (after Aceternity UI's signup form input): a dark field
/// in a thin ring, lit by a light in the accent. The light shows while the
/// cursor is over the field or the field has focus, and goes to whichever
/// moved last: the cursor, or the caret. Switching between them, it fades out
/// where it was as it fades in where it's going.
class GaiaTextField extends StatefulWidget {
  const GaiaTextField({
    super.key,
    required this.controller,
    required this.focusNode,
    this.autofocus = false,
    this.minLines,
    this.maxLines = 1,
    this.expands = false,
    this.textAlignVertical,
    this.hintText,
    this.leading,
    this.trailing,
    this.onPaste,
    this.onAddWord,
    this.undoController,
    this.lists = false,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final bool autofocus;
  final int? minLines;
  final int? maxLines;
  final bool expands;
  final TextAlignVertical? textAlignVertical;
  final String? hintText;

  /// Sits inside the field at its bottom left, such as an attach button.
  final Widget? leading;

  /// Sits inside the field at its bottom right, such as a send button.
  final Widget? trailing;

  /// Paste from the right-click menu, in place of plain text paste.
  final VoidCallback? onPaste;

  /// "Add to dictionary" on a misspelled word's right-click menu; not
  /// offered without it.
  final void Function(String word)? onAddWord;

  /// An undo history its owner can start over; null for the field's own.
  final MergeAwareUndoController? undoController;

  /// `-` and `1.` lists as in Voyager's notes: Enter continues one and
  /// numbers follow every edit. Tab and Backspace are the owner's to wire,
  /// on its focus node.
  final bool lists;

  @override
  State<GaiaTextField> createState() => _GaiaTextFieldState();
}

/// The light's radius once fully shown.
const _radius = 100.0;

/// How fast the light closes on what it follows: the rate it closes the gap
/// at, per second.
const _follow = 18.0;

/// The field's fill and, until the cursor is over it, its edge.
const gaiaFieldFill = Color(0xFF27272A);
const _edge = Color(0xFF404040);

/// What the light follows.
enum _Source { cursor, caret }

class _GaiaTextFieldState extends State<GaiaTextField>
    with TickerProviderStateMixin {
  /// Where the light is, and where it's heading, in this field's
  /// coordinates.
  final _light = ValueNotifier(Offset.zero);
  var _target = Offset.zero;
  late final Ticker _ticker;
  var _lastTick = Duration.zero;

  late final _shown = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 300),
  );
  var _hovered = false;

  /// The light fading out where it was when it last switched what it
  /// follows, and how strong it was then; null once it's gone. [_swap] runs
  /// it out and the new one in.
  (Offset, double)? _outgoing;
  late final _swap =
      AnimationController(
        vsync: this,
        duration: const Duration(milliseconds: 150),
        value: 1,
      )..addStatusListener((status) {
        if (status == AnimationStatus.completed) _outgoing = null;
      });

  /// Set by a switch: the light's next move is a jump to its new spot, not
  /// a glide over to it.
  var _jump = false;

  /// Whichever moved last. Only edits, selection changes and focus make it
  /// the caret, so text scrolling under a resting cursor leaves it alone.
  var _source = _Source.caret;

  /// The cursor, in global coordinates, while it's over the field: the
  /// field can move or resize under a resting cursor.
  Offset? _cursor;

  /// The field's text, found once and found again if it's replaced.
  RenderEditable? _editable;

  /// Where the light was when the text was sent, on the caret or under the
  /// cursor, while the vanish sweeps it away.
  Offset? _sent;

  /// The text [_onEdit] last saw, to tell an edit from a caret move.
  late String _lastText;

  /// The text before the edit [_lastText] holds, for the list editing.
  late String _beforeEdit;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_tick);
    _lastText = _beforeEdit = widget.controller.text;
    widget.controller.addListener(_onEdit);
    widget.focusNode.addListener(_onFocus);
    SchedulerBinding.instance.addPostFrameCallback(_afterFrame);
  }

  @override
  void didUpdateWidget(GaiaTextField old) {
    super.didUpdateWidget(old);
    if (old.controller != widget.controller) {
      old.controller.removeListener(_onEdit);
      widget.controller.addListener(_onEdit);
      _lastText = _beforeEdit = widget.controller.text;
    }
    if (old.focusNode != widget.focusNode) {
      old.focusNode.removeListener(_onFocus);
      widget.focusNode.addListener(_onFocus);
      _onFocus();
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onEdit);
    widget.focusNode.removeListener(_onFocus);
    _ticker.dispose();
    _shown.dispose();
    _swap.dispose();
    _light.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _onHover(PointerEvent event) {
    if (!_hovered) setState(() => _hovered = true);
    _cursor = event.position;
    _switchTo(_Source.cursor);
    // Now, not after the frame, so the light is under the cursor in the
    // frame this move draws.
    _aim();
    _showOrHide();
  }

  void _onExit(PointerExitEvent event) {
    setState(() => _hovered = false);
    _cursor = null;
    if (widget.focusNode.hasFocus) {
      _switchTo(_Source.caret);
    } else {
      // Going out with the cursor, not over to a caret.
      _source = _Source.caret;
    }
    _showOrHide();
  }

  /// Text or selection changed, however it was changed: typing, a paste,
  /// an IME, Vim, autocorrect or code. Where the caret lands is read after
  /// the frame that lays it out.
  void _onEdit() {
    if (widget.controller.text != _lastText) {
      _beforeEdit = _lastText;
      _lastText = widget.controller.text;
      // Only typing scrolls the caret into view by itself: not a draft put
      // here from code, as switching chat, Edit & resend or the palette do.
      SchedulerBinding.instance.addPostFrameCallback((_) {
        if (mounted) bringCursorIntoView(fieldKey: _fieldKey);
      });
      SchedulerBinding.instance.ensureVisualUpdate();
    }
    if (!widget.focusNode.hasFocus) return;
    _switchTo(_Source.caret);
    SchedulerBinding.instance.ensureVisualUpdate();
  }

  void _onFocus() {
    // Focus leaving under the cursor hands the light back to it; leaving
    // with no cursor over the field, the light goes out on the caret.
    if (widget.focusNode.hasFocus) {
      _switchTo(_Source.caret);
    } else if (_hovered) {
      _switchTo(_Source.cursor);
    }
    _showOrHide();
  }

  /// Follows [source] from now on. While the light shows, it fades across:
  /// out where it is, in at its new spot.
  void _switchTo(_Source source) {
    if (source == _source) return;
    _source = source;
    _jump = true;
    if (_shown.value < 0.1 ||
        (MediaQuery.maybeDisableAnimationsOf(context) ?? false)) {
      _outgoing = null;
      _swap.value = 1;
      return;
    }
    // Mid-fade, the light going out is the one that was coming in, at the
    // strength it had reached.
    _outgoing = (_light.value, _swap.value);
    _swap.forward(from: 0);
  }

  void _showOrHide() {
    if (_hovered || widget.focusNode.hasFocus) {
      _shown.forward();
    } else {
      _shown.reverse();
    }
  }

  /// After every frame drawn, once it's laid out and scrolled, so the light
  /// keeps up with whatever moved the caret or the field: an edit, the field
  /// scrolling to show the caret, growing, reflowing or being resized. Costs
  /// no frames of its own.
  void _afterFrame(Duration _) {
    if (!mounted) return;
    SchedulerBinding.instance.addPostFrameCallback(_afterFrame);
    _keepCaretInView();
    _aim();
  }

  /// The text's size when [_keepCaretInView] last looked.
  Size? _textSize;

  /// Resized, as when the window snaps to half the screen, the text reflows
  /// under a scroll offset that no longer shows the caret: Flutter scrolls
  /// to it only on an edit or a caret move. Not while the text is sent and
  /// sweeping away.
  void _keepCaretInView() {
    final box = context.findRenderObject();
    if (box == null || !box.attached) return;
    var editable = _editable;
    if (editable == null || !editable.attached) {
      editable = _editable = findEditable(box);
    }
    if (editable == null || !editable.hasSize) return;
    final was = _textSize;
    _textSize = editable.size;
    if (was == null || was == editable.size) return;
    if (context.findAncestorStateOfType<GaiaVanishState>()?.sweep != null) {
      return;
    }
    bringCursorIntoView(fieldKey: _fieldKey);
  }

  /// Sends the light to what it follows, held inside the field so a caret
  /// scrolled out of view lights the edge nearest it.
  void _aim() {
    if (!_hovered && !widget.focusNode.hasFocus) return;
    final box = context.findRenderObject() as RenderBox?;
    if (box == null || !box.attached || !box.hasSize) return;
    final sweep = context.findAncestorStateOfType<GaiaVanishState>()?.sweep;
    if (sweep == null) _sent = null;
    final point = switch (_source) {
      _Source.cursor => _cursor == null ? null : box.globalToLocal(_cursor!),
      // Sent, the light stays where it was until the sweep reaches it, then
      // goes along with it, rather than racing the text back to the start.
      _Source.caret when sweep != null => _sweeping(box, sweep),
      _Source.caret => widget.focusNode.hasFocus ? _caret(box) : null,
    };
    if (point == null) return;
    final target = Offset(
      point.dx.clamp(0, box.size.width),
      point.dy.clamp(0, box.size.height),
    );
    if (target == _target && !_jump) return;
    _moveTo(
      target,
      glide:
          !_jump &&
          _source == _Source.caret &&
          !(MediaQuery.maybeDisableAnimationsOf(context) ?? false),
    );
    _jump = false;
  }

  /// Where the light was when sent, or the [sweep] (across the screen) once
  /// it's passed there, in [box]'s coordinates.
  Offset _sweeping(RenderBox box, double sweep) {
    final sent = _sent ??= _target;
    final x = sweep - box.localToGlobal(Offset.zero).dx;
    return Offset(math.min(sent.dx, x), sent.dy);
  }

  /// The caret's centre in [box]'s coordinates, scrolling included. Null
  /// when there's no caret, or the text isn't laid out to match it yet.
  Offset? _caret(RenderBox box) {
    var editable = _editable;
    if (editable == null || !editable.attached) {
      editable = _editable = findEditable(box);
    }
    final selection = widget.controller.selection;
    if (editable == null ||
        !editable.hasSize ||
        !selection.isValid ||
        selection.extentOffset > editable.plainText.length) {
      return null;
    }
    final caret = editable.getLocalRectForCaret(selection.extent);
    return editable.localToGlobal(caret.center, ancestor: box);
  }

  /// Puts the light on [target]. The cursor takes it straight there, as the
  /// cursor is already where the eye is; the caret's steps [glide]. Appearing,
  /// it starts there rather than gliding in from wherever it last went out.
  void _moveTo(Offset target, {required bool glide}) {
    _target = target;
    if (!glide || _shown.value < 0.1) {
      _ticker.stop();
      _light.value = target;
      return;
    }
    if (!_ticker.isActive) {
      _lastTick = Duration.zero;
      _ticker.start();
    }
  }

  void _tick(Duration elapsed) {
    final dt = (elapsed - _lastTick).inMicroseconds / 1e6;
    _lastTick = elapsed;
    final gap = _target - _light.value;
    if (gap.distance < 0.5) {
      _light.value = _target;
      _ticker.stop();
      return;
    }
    _light.value += gap * (1 - math.exp(-dt * _follow));
  }

  final _fieldKey = GlobalKey<State<TextField>>();
  final _scroll = ScrollController();

  /// The same function every build: a different one makes the field build
  /// its open menu afresh, replaying its entrance, as on every hover. Over a
  /// misspelled word, its corrections first, then "Add to dictionary".
  Widget _contextMenu(BuildContext context, EditableTextState state) {
    final value = state.textEditingValue;
    final misspelt = AutocorrectEnabledScope.of(context).service == null
        ? null
        : misspellingAtCursor(
            context,
            value.text,
            value.selection.extentOffset,
          );
    return gaiaTextMenu(
      context,
      state,
      onPaste: widget.onPaste,
      first: misspelt == null
          ? const []
          : [
              for (final suggestion in misspelt.suggestions.take(5))
                GaiaMenuItem(
                  label: suggestion,
                  icon: Icons.spellcheck,
                  onPressed: () {
                    state.userUpdateTextEditingValue(
                      value.replaced(misspelt.range, suggestion),
                      SelectionChangedCause.toolbar,
                    );
                    state.hideToolbar();
                  },
                ),
              if (widget.onAddWord case final add?)
                GaiaMenuItem(
                  label: 'Add to dictionary',
                  icon: Icons.library_add_outlined,
                  onPressed: () {
                    add(misspelt.range.textInside(value.text));
                    state.hideToolbar();
                  },
                ),
            ],
    );
  }

  /// The text itself, and over it what Voyager draws on its fields: the
  /// squiggles, autocorrect's flash, and Vim's caret and selection.
  Widget _field(BuildContext context, VimFieldBinding vim) {
    final theme = Theme.of(context);
    final accent = theme.colorScheme.primary;
    final style = withSquiggleRoom(
      theme.textTheme.bodyLarge!.copyWith(color: theme.colorScheme.onSurface),
    );
    final padding = EdgeInsets.fromLTRB(
      widget.leading == null ? 12 : 4,
      13,
      12,
      13,
    );
    // Borderless and unfilled, so no input gap: only the density's shift
    // and the strip kept for the caret.
    final overlay = withCaretMargin(
      withDensityShift(padding, theme.visualDensity),
      cursorWidth: vim.overlayCaretWidth,
    );
    final session = vim.session;
    final snippets = vim.snippetSession;
    final autocorrect = vim.autocorrectSession;
    Widget layer(Widget child) => Positioned.fill(
      child: IgnorePointer(
        child: Padding(padding: overlay, child: child),
      ),
    );
    final field = Stack(
      fit: StackFit.passthrough,
      children: [
        if (autocorrect != null)
          layer(
            AutocorrectFlashLayer(
              session: autocorrect,
              controller: widget.controller,
              style: style,
              color: accent,
              scrollController: _scroll,
            ),
          ),
        // The app above provides the checker, as the companion's does.
        if (AutocorrectEnabledScope.of(context).service != null)
          layer(
            SpellCheckSquiggleLayer(
              controller: widget.controller,
              focusNode: widget.focusNode,
              style: style,
              scrollController: _scroll,
              suppressActiveWord: vim.suppressSpellcheckActiveWord,
            ),
          ),
        wrapWithSecondaryTapWordSelect(
          fieldKey: _fieldKey,
          child: TextField(
            key: _fieldKey,
            controller: widget.controller,
            focusNode: widget.focusNode,
            // Typed edits only: a draft put here from code is left as it is.
            onChanged: widget.lists
                ? (_) => applyListEditing(
                    controller: widget.controller,
                    previousText: _beforeEdit,
                  )
                : null,
            scrollController: _scroll,
            autofocus: widget.autofocus,
            minLines: widget.minLines,
            maxLines: widget.maxLines,
            expands: widget.expands,
            style: style,
            textAlignVertical: widget.textAlignVertical,
            contextMenuBuilder: _contextMenu,
            inputFormatters: [newlineFormatterFor(widget.maxLines)],
            // Long text paints on through the padding, for the clip below to
            // cut off at the border along with what's over it.
            clipBehavior: Clip.none,
            scrollPhysics: const VoyagerFieldScrollPhysics(),
            // The squiggles are the layer's: results of the field's own
            // would have it drop the controller's text span.
            spellCheckConfiguration: const SpellCheckConfiguration.disabled(),
            // Held back for Vim's overlay, which draws the caret.
            cursorColor: vim.overlayCaretColor(accent),
            cursorWidth: vim.overlayCaretWidth,
            undoController: vim.undoController,
            decoration: InputDecoration(
              hintText: widget.hintText,
              // In the text's own metrics, so Vim's block caret repaints the
              // hint's first letter at the size it was drawn.
              hintStyle: fieldHintStyle(context, style),
              // The field paints its own fill and edge.
              filled: false,
              border: InputBorder.none,
              enabledBorder: InputBorder.none,
              focusedBorder: InputBorder.none,
              isDense: true,
              // Less on the left past a leading button.
              contentPadding: padding,
            ),
          ),
        ),
        if (session != null || snippets != null)
          layer(
            VimTextOverlay(
              session: session,
              snippetSession: snippets,
              controller: widget.controller,
              focusNode: widget.focusNode,
              style: style,
              accentColor: accent,
              scrollController: _scroll,
              hintText: widget.hintText,
            ),
          ),
      ],
    );
    // The one clip for the text and every layer: they don't clip themselves.
    Widget clipped = ClipRect(child: field);
    if (widget.undoController case final undo?) {
      clipped = MergeAwareUndoScope(controller: undo, child: clipped);
    } else if (widget.lists) {
      // Flutter's own undo then restores the text, which list editing
      // mustn't rewrite mid-restore; see [ListEditingUndoGuard].
      clipped = ListEditingUndoGuard(child: clipped);
    }
    return session == null
        ? clipped
        : vimSelectionTheme(
            context: context,
            hideNativeSelection: vim.overlayPaintsSelection,
            child: clipped,
          );
  }

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: _onHover,
      onHover: _onHover,
      onExit: _onExit,
      child: CustomPaint(
        painter: _LightPainter(
          light: _light,
          outgoing: () => _outgoing,
          swap: _swap,
          shown: _shown,
          color: Theme.of(context).colorScheme.primary,
        ),
        // The light shows only in this gap round the field.
        child: Padding(
          padding: const EdgeInsets.all(2),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 400),
            decoration: BoxDecoration(
              color: gaiaFieldFill,
              borderRadius: BorderRadius.circular(6),
              // The light takes over from the edge under the cursor.
              boxShadow: [
                if (!_hovered)
                  const BoxShadow(color: _edge, blurRadius: 1, spreadRadius: 1),
              ],
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                if (widget.leading case final leading?)
                  Padding(
                    padding: const EdgeInsets.all(4),
                    child: TextFieldTapRegion(child: leading),
                  ),
                Expanded(
                  // Long prompts scroll without a bar.
                  child: ScrollConfiguration(
                    behavior: const _NoScrollbars(),
                    // Voyager's Vim, snippets and autocorrect (§9.5), as its
                    // own fields have them.
                    child: VimTextScope(
                      enabled: VimEnabledScope.of(context),
                      controller: widget.controller,
                      undoController: widget.undoController,
                      multiline: true,
                      builder: _field,
                    ),
                  ),
                ),
                if (widget.trailing case final trailing?)
                  Padding(
                    padding: const EdgeInsets.all(4),
                    // Part of the field, so clicking it keeps the focus.
                    child: TextFieldTapRegion(child: trailing),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Builds no scrollbar, even for a multiline field, which turns bars back on
/// over a plain `scrollbars: false`.
class _NoScrollbars extends MaterialScrollBehavior {
  const _NoScrollbars();

  @override
  Widget buildScrollbar(
    BuildContext context,
    Widget child,
    ScrollableDetails details,
  ) => child;
}

/// The light: a radial gradient at [light], growing in as [shown] runs, and
/// fading in as [swap] fades out the [outgoing] one.
class _LightPainter extends CustomPainter {
  _LightPainter({
    required this.light,
    required this.outgoing,
    required this.swap,
    required this.shown,
    required this.color,
  }) : super(repaint: Listenable.merge([light, swap, shown]));

  final ValueNotifier<Offset> light;
  final (Offset, double)? Function() outgoing;
  final Animation<double> swap;
  final Animation<double> shown;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final radius = _radius * Curves.easeOut.transform(shown.value);
    if (radius == 0) return;
    canvas.clipRRect(
      RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(8)),
    );
    if (outgoing() case (final at, final from)?) {
      _glow(canvas, at, radius, from * (1 - swap.value));
    }
    _glow(canvas, light.value, radius, swap.value);
  }

  void _glow(Canvas canvas, Offset at, double radius, double strength) {
    if (strength <= 0) return;
    final lit = color.withValues(alpha: color.a * strength);
    canvas.drawPaint(
      Paint()
        ..shader = ui.Gradient.radial(
          at,
          radius,
          [lit, lit.withValues(alpha: 0)],
          [0, 0.8],
        ),
    );
  }

  @override
  bool shouldRepaint(_LightPainter old) => old.color != color;
}

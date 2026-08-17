import 'package:flutter/material.dart';
import 'package:voyager/core/vim/vim_enabled_scope.dart';
import 'package:voyager/core/vim/vim_text_overlay.dart';
import 'package:voyager/core/vim/vim_text_scope.dart';
import 'package:voyager/core/motion/motion.dart';
import 'package:voyager/core/widgets/field_hint_style.dart';
import 'package:voyager/core/widgets/field_scroll_padding.dart';
import 'package:voyager/core/widgets/spell_check_field_support.dart';
import 'package:voyager/core/widgets/spell_check_squiggle_layer.dart';

/// Content padding the note field renders with — spelled out explicitly,
/// rather than left for Flutter's InputDecorator to compute implicitly, so
/// [SpellCheckSquiggleLayer]'s overlay can derive the exact same geometry and
/// stay pixel-aligned with the real text.
///
/// The field carries the theme's outline border (an `InputDecoration.border`
/// of [InputBorder.none] would not suppress it — the theme's state-specific
/// `enabledBorder`/`focusedBorder` win), so these insets are measured from
/// that outline: the horizontal ones are short by the input gap InputDecorator
/// adds for it (see [withInputGap]), leaving the text 10px in from the stroke
/// on every side.
const _kNoteFieldContentPadding = EdgeInsets.fromLTRB(6, 10, 6, 10);

/// The Dream Journal's collapsible scratchpad: a corner "sticky note" that
/// peeks from the bottom-right and expands into a small note-taking card on
/// tap.
class DreamStickyNote extends StatefulWidget {
  const DreamStickyNote({
    super.key,
    required this.controller,
    required this.onChanged,
    this.focusNode,
    this.accentColor,
  });

  final TextEditingController controller;
  final ValueChanged<String> onChanged;
  final FocusNode? focusNode;
  final Color? accentColor;

  @override
  State<DreamStickyNote> createState() => _DreamStickyNoteState();
}

class _DreamStickyNoteState extends State<DreamStickyNote>
    with SingleTickerProviderStateMixin {
  static const _peekSize = 56.0;
  static const _expandedWidth = 280.0;
  static const _expandedHeight = 220.0;

  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 280),
  );
  var _expanded = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _toggleExpanded() {
    setState(() => _expanded = !_expanded);
    if (_expanded) {
      _controller.forward();
    } else {
      _controller.reverse();
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent = widget.accentColor ?? theme.colorScheme.primary;
    final reduced = VoyagerMotion.reduced(context);
    final curved = CurvedAnimation(
      parent: _controller,
      curve: reduced ? Curves.easeOut : VoyagerSpring.drawerCurve,
      reverseCurve: Curves.easeIn,
    );

    return Positioned(
      right: 20,
      bottom: 20,
      child: AnimatedBuilder(
        animation: curved,
        builder: (context, _) {
          final t = curved.value;
          final width = lerpDouble(_peekSize, _expandedWidth, t);
          final height = lerpDouble(_peekSize, _expandedHeight, t);
          final contentOpacity = ((t - 0.5) / 0.5).clamp(0.0, 1.0);
          return Material(
            elevation: 3 + 5 * t,
            color: Color.lerp(
              theme.colorScheme.surfaceContainerHighest,
              theme.colorScheme.surface,
              t,
            ),
            shadowColor: Colors.black.withValues(alpha: 0.25),
            borderRadius: BorderRadius.circular(14),
            // Material clips nothing by default, so note text scrolling
            // through the field's viewport painted straight over the card's
            // rounded top corners instead of disappearing behind them.
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              borderRadius: BorderRadius.circular(14),
              onTap: _expanded ? null : _toggleExpanded,
              child: SizedBox(
                width: width,
                height: height,
                child: contentOpacity <= 0
                    ? _StickyNoteCorner(color: accent)
                    : Opacity(
                        opacity: contentOpacity,
                        child: _StickyNoteContents(
                          controller: widget.controller,
                          onChanged: widget.onChanged,
                          focusNode: widget.focusNode,
                          accentColor: accent,
                          onClose: _toggleExpanded,
                        ),
                      ),
              ),
            ),
          );
        },
      ),
    );
  }

  double lerpDouble(double a, double b, double t) => a + (b - a) * t;
}

/// The peeking corner sliver — a hint of the note before the user taps it.
///
/// Drawn in the page accent rather than the usual muted on-surface tone: it
/// floats over the dream body's text field, where the muted shade was close
/// enough to the field's own text colour that the icon disappeared into it.
class _StickyNoteCorner extends StatelessWidget {
  const _StickyNoteCorner({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Icon(Icons.sticky_note_2_outlined, size: 22, color: color),
    );
  }
}

class _StickyNoteContents extends StatefulWidget {
  const _StickyNoteContents({
    required this.controller,
    required this.onChanged,
    required this.accentColor,
    required this.onClose,
    this.focusNode,
  });

  final TextEditingController controller;
  final ValueChanged<String> onChanged;
  final Color accentColor;
  final VoidCallback onClose;
  final FocusNode? focusNode;

  @override
  State<_StickyNoteContents> createState() => _StickyNoteContentsState();
}

class _StickyNoteContentsState extends State<_StickyNoteContents> {
  FocusNode? _ownedFocusNode;
  final GlobalKey<State<TextField>> _fieldKey = GlobalKey();
  late final ScrollController _scrollController = ScrollController();

  FocusNode get _focusNode => widget.focusNode ?? _ownedFocusNode!;

  @override
  void initState() {
    super.initState();
    if (widget.focusNode == null) {
      _ownedFocusNode = FocusNode();
    }
    widget.controller.addListener(_forceSpellCheck);
    WidgetsBinding.instance.addPostFrameCallback((_) => _forceSpellCheck());
  }

  @override
  void didUpdateWidget(covariant _StickyNoteContents oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_forceSpellCheck);
      widget.controller.addListener(_forceSpellCheck);
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_forceSpellCheck);
    _ownedFocusNode?.dispose();
    _scrollController.dispose();
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

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final textStyle = withSquiggleRoom(
      theme.textTheme.bodySmall ?? const TextStyle(),
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 10, 6, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'Dream notes',
                  style: theme.textTheme.labelMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              IconButton(
                tooltip: 'Close',
                icon: const Icon(Icons.close, size: 18),
                visualDensity: VisualDensity.compact,
                onPressed: widget.onClose,
              ),
            ],
          ),
          Expanded(
            // The header's trailing padding is cut short to let the close
            // button's own hit-box padding reach the card edge; the field's
            // outline is a visible box, so it makes that gap up here and sits
            // evenly inset on both sides.
            child: Padding(
              padding: const EdgeInsets.only(right: 8),
              child: VimTextScope(
                enabled: VimEnabledScope.of(context) && vimSuitsField(),
                controller: widget.controller,
                multiline: true,
                builder: (context, vim) {
                  const hintText =
                      'Jot a quick note to jog your memory later...';
                  final overlayPadding = vimOverlayPadding(
                    contentPadding: _kNoteFieldContentPadding,
                    density: theme.visualDensity,
                    cursorWidth: vim.overlayCaretWidth,
                    outlineGap: true,
                  );
                  return VimOverlayHost(
                    session: vim.session,
              snippetSession: vim.snippetSession,
                    overlayPaintsSelection: vim.overlayPaintsSelection,
                    controller: widget.controller,
                    focusNode: _focusNode,
                    style: textStyle,
                    accentColor: theme.colorScheme.primary,
                    overlayPadding: overlayPadding,
                    scrollController: _scrollController,
                    hintText: hintText,
                    fit: StackFit.expand,
                    underlay: SpellCheckSquiggleLayer(
                      controller: widget.controller,
                      focusNode: _focusNode,
                      style: textStyle,
                      scrollController: _scrollController,
                      suppressActiveWord: vim.suppressSpellcheckActiveWord,
                    ),
                    child: wrapWithSecondaryTapWordSelect(
                      fieldKey: _fieldKey,
                      child: TextField(
                        key: _fieldKey,
                        controller: widget.controller,
                        focusNode: _focusNode,
                        scrollController: _scrollController,
                        onChanged: widget.onChanged,
                        cursorColor: vim.overlayCaretColor(
                          theme.colorScheme.primary,
                        ),
                        cursorWidth: vim.overlayCaretWidth,
                        undoController: vim.undoController,
                        maxLines: null,
                        expands: true,
                        scrollPadding: kVoyagerFieldScrollPadding,
                        contextMenuBuilder: voyagerSpellCheckContextMenuBuilder,
                        spellCheckConfiguration:
                            buildVoyagerSpellCheckConfiguration(context),
                        textAlignVertical: TextAlignVertical.top,
                        style: textStyle,
                        decoration: InputDecoration(
                          isDense: true,
                          contentPadding: _kNoteFieldContentPadding,
                          hintText: hintText,
                          // Matched to the field's own text metrics — see
                          // [fieldHintStyle]. The theme's hint is a `bodyMedium`
                          // with a lower baseline than this `bodySmall` text, and
                          // InputDecorator baseline-aligns the input to whichever
                          // of the two sits lower — pushing the real glyphs a
                          // couple of pixels below where this field's overlays
                          // (the Vim block caret, the squiggles) compute them.
                          hintStyle: fieldHintStyle(context, textStyle),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }
}

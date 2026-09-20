import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/constants/leetcode_constants.dart';
import 'package:voyager/core/motion/motion.dart';
import 'package:voyager/core/theme/app_fonts.dart';
import 'package:voyager/core/theme/voyager_theme.dart';
import 'package:voyager/core/widgets/glass_button.dart';
import 'package:voyager/core/widgets/selector_pill.dart';
import 'package:voyager/core/widgets/voyager_scroll_view.dart';
import 'package:voyager/core/widgets/voyager_toast.dart';
import 'package:voyager/domain/models/leetcode_models.dart';
import 'package:voyager/features/leetcode/leetcode_code_controller.dart';
import 'package:voyager/features/leetcode/leetcode_code_field.dart';
import 'package:voyager/features/leetcode/leetcode_comment_stripper.dart';
import 'package:voyager/features/leetcode/leetcode_scratch_diff.dart';
import 'package:voyager/features/leetcode/leetcode_scratch_draft.dart';

/// Fraction of the width the pad takes beside the card, per the locked 35/65
/// split. The card keeps its own cap, so on a wide window the pad simply gets
/// the room the card refuses.
const double kLeetCodeScratchWidthFraction = 0.35;

/// Under this the two panes stop being two panes: the pad goes below the card
/// and the whole thing scrolls.
const double kLeetCodeScratchStackBreakpoint = 720;

/// How much of the window the expanded editor takes. Short of the full screen
/// on purpose — the margin is the "outside" a click lands in to collapse it,
/// which is the only way back other than the close button (Escape belongs to
/// Vim).
const double _kExpandedInset = 0.04;

/// The scratch code pad beside a Study or Cram card: somewhere to type an
/// attempt before going and running it on LeetCode.
///
/// Nothing typed here reaches the problem. It is not a solution, it is not
/// graded, and it never syncs — see [LeetCodeScratchSessionController].
///
/// The text area is a live editor, so the pad can be typed in where it sits.
/// Everything around it — the header, the margins — expands the pad instead,
/// since a text box that jumps to fullscreen when clicked could never be
/// typed in at all.
class LeetCodeScratchPad extends StatelessWidget {
  const LeetCodeScratchPad({
    super.key,
    required this.problem,
    required this.entry,
    required this.controller,
    required this.focusNode,
    required this.onCodeChanged,
    required this.onExpand,
  });

  final LeetCodeProblem problem;
  final LeetCodeScratchEntry entry;
  final LeetCodeCodeController controller;

  /// The pad's own focus, so the session's `C` shortcut can put the caret
  /// here without going through the editor's internals.
  final FocusNode focusNode;

  final ValueChanged<String> onCodeChanged;
  final VoidCallback onExpand;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // The header sits *on* the code box's paper rather than the app's, so it
    // takes its colours from there — Atom One dark is dark under a light app
    // theme, where `onSurface` would be black on near-black.
    final palette = leetCodeCodePalette(context);

    // One notepad: a single bordered sheet whose top strip is the expand
    // affordance and whose body is the editor, rather than a label floating
    // six pixels above an unrelated box.
    return Container(
      decoration: BoxDecoration(
        color: palette.background,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: theme.colorScheme.outline.withValues(alpha: 0.3),
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // The header is the expand affordance: a strip that is unambiguously
          // not the text area, so clicking it can mean something other than
          // "put the caret here".
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: onExpand,
            child: Container(
              height: 30,
              padding: const EdgeInsets.symmetric(horizontal: 10),
              decoration: BoxDecoration(
                color: palette.foreground.withValues(alpha: 0.07),
                border: Border(
                  bottom: BorderSide(
                    color: palette.foreground.withValues(alpha: 0.18),
                  ),
                ),
              ),
              child: Row(
                children: [
                  Text(
                    'Scratch',
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: palette.foreground.withValues(alpha: 0.75),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    labelForLeetCodeLanguage(entry.language),
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.primary,
                    ),
                  ),
                  const Spacer(),
                  Icon(
                    PhosphorIconsRegular.arrowsOut,
                    size: 14,
                    color: palette.foreground.withValues(alpha: 0.6),
                  ),
                  const SizedBox(width: 4),
                  Text(
                    'Expand',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: palette.foreground.withValues(alpha: 0.6),
                    ),
                  ),
                ],
              ),
            ),
          ),
          Expanded(
            child: _ScratchEditor(
              controller: controller,
              focusNode: focusNode,
              onCodeChanged: onCodeChanged,
              // The notepad above already draws the paper and the border.
              framed: false,
            ),
          ),
        ],
      ),
    );
  }
}

/// The editor itself, wired so every keystroke reaches the session controller.
class _ScratchEditor extends StatefulWidget {
  const _ScratchEditor({
    required this.controller,
    required this.focusNode,
    required this.onCodeChanged,
    this.framed = true,
  });

  final LeetCodeCodeController controller;
  final FocusNode focusNode;
  final ValueChanged<String> onCodeChanged;

  /// Whether the editor draws its own frame, or sits inside one the caller
  /// has already drawn — see [LeetCodeScratchPad].
  final bool framed;

  @override
  State<_ScratchEditor> createState() => _ScratchEditorState();
}

class _ScratchEditorState extends State<_ScratchEditor> {
  String _lastReported = '';

  @override
  void initState() {
    super.initState();
    _lastReported = widget.controller.fullText;
    widget.controller.addListener(_onChanged);
  }

  @override
  void didUpdateWidget(covariant _ScratchEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_onChanged);
      widget.controller.addListener(_onChanged);
      _lastReported = widget.controller.fullText;
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onChanged);
    super.dispose();
  }

  /// The controller notifies on selection moves too, which are not edits —
  /// reporting those would restart the autosave debounce on every arrow key.
  void _onChanged() {
    final text = widget.controller.fullText;
    if (text == _lastReported) return;
    _lastReported = text;
    widget.onCodeChanged(text);
  }

  @override
  Widget build(BuildContext context) => LeetCodeCodeSurface(
    controller: widget.controller,
    focusNode: widget.focusNode,
    framed: widget.framed,
  );
}

/// Opens the pad's fullscreen editor, growing out of [anchorRect] the way the
/// detail view grows out of a tapped tile.
///
/// Returns once it has collapsed again, so the caller can put the session's
/// keyboard handling back.
Future<void> openLeetCodeScratchOverlay(
  BuildContext context, {
  required LeetCodeProblem problem,
  required LeetCodeCodeController controller,
  required Rect anchorRect,
  required String language,
  required ValueChanged<String> onCodeChanged,
  required ValueChanged<String> onLanguageChanged,
  required VoidCallback onClear,
}) {
  return Navigator.of(context, rootNavigator: true).push(
    PageRouteBuilder<void>(
      opaque: false,
      barrierColor: Colors.transparent,
      barrierDismissible: false,
      transitionDuration: Duration.zero,
      reverseTransitionDuration: Duration.zero,
      pageBuilder: (context, animation, secondaryAnimation) =>
          _ScratchOverlay(
            problem: problem,
            controller: controller,
            anchorRect: anchorRect,
            language: language,
            onCodeChanged: onCodeChanged,
            onLanguageChanged: onLanguageChanged,
            onClear: onClear,
          ),
    ),
  );
}

class _ScratchOverlay extends StatefulWidget {
  const _ScratchOverlay({
    required this.problem,
    required this.controller,
    required this.anchorRect,
    required this.language,
    required this.onCodeChanged,
    required this.onLanguageChanged,
    required this.onClear,
  });

  final LeetCodeProblem problem;
  final LeetCodeCodeController controller;
  final Rect anchorRect;
  final String language;
  final ValueChanged<String> onCodeChanged;
  final ValueChanged<String> onLanguageChanged;
  final VoidCallback onClear;

  @override
  State<_ScratchOverlay> createState() => _ScratchOverlayState();
}

/// Same reveal fraction the detail view uses, so the two overlays open with
/// one motion vocabulary.
const double _kFadeInFraction = 0.3;

class _ScratchOverlayState extends State<_ScratchOverlay>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  final _editorFocus = FocusNode(debugLabel: 'scratchExpandedEditor');
  bool _closing = false;
  bool _comparing = false;
  late String _language = widget.language;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 260),
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _controller.forward();
      // The editor is re-inflated at this position rather than moved here, so
      // it arrives with no input connection however the pad below was focused.
      _editorFocus.requestFocus();
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    _editorFocus.dispose();
    super.dispose();
  }

  Future<void> _close() async {
    if (_closing) return;
    _closing = true;
    await _controller.reverse();
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _copy() async {
    // What the user typed, whatever that is — an empty pad copies an empty
    // string rather than refusing, so the button never reads as broken.
    await Clipboard.setData(ClipboardData(text: widget.controller.fullText));
    if (!mounted) return;
    showVoyagerToast(
      context,
      message: 'Code copied',
      icon: PhosphorIconsRegular.check,
      // Without a dwell the toast has no clock, and this one carries no
      // actions — so it stays click-through on screen for the life of the app
      // with nothing to dismiss it. Same wait the Copy in `leetcode_actions`
      // gives the toast it raises for the saved solution.
      dwell: const Duration(milliseconds: 1400),
    );
  }

  Future<void> _openOnLeetCode() async {
    final url = widget.problem.leetcodeUrl;
    if (url == null) return;
    await launchUrl(Uri.parse(url), webOnlyWindowName: '_blank');
  }

  /// Same two passes the Track modal's Strip runs, and for the same reason the
  /// rewrite goes through [CodeController.fullText] — an assigned value is
  /// re-diffed from its length and a multi-line deletion reads as a backspace.
  void _stripComments() {
    final source = widget.controller.fullText;
    final stripped = stripLeetCodeTrailingBlankLine(
      stripLeetCodeLineComments(source, _language),
    );
    if (stripped == source) return;
    final caret = widget.controller.selection.baseOffset;
    widget.controller.fullText = stripped;
    widget.controller.selection = TextSelection.collapsed(
      offset: caret < 0 ? stripped.length : caret.clamp(0, stripped.length),
    );
    widget.onCodeChanged(stripped);
  }

  void _setLanguage(String language) {
    setState(() => _language = language);
    widget.onLanguageChanged(language);
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final inset = EdgeInsets.symmetric(
      horizontal: size.width * _kExpandedInset,
      vertical: size.height * _kExpandedInset,
    );
    final targetRect = inset.deflateRect(Offset.zero & size);
    final reducedMotion = VoyagerMotion.reduced(context);

    return PopScope(
      // The route pops instantly (its transition is zero), so a system back
      // would make the editor vanish rather than shrink back into the pad.
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _close();
      },
      child: Material(
        color: Colors.transparent,
        child: AnimatedBuilder(
          animation: _controller,
          builder: (context, child) {
            final raw = _controller.value.clamp(0.0, 1.0);
            // The scrim is the click target that collapses the editor — the
            // whole reason the expanded panel stops short of the screen edge.
            final scrim = Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _close,
                child: Container(
                  color: Color.lerp(
                    Colors.transparent,
                    VoyagerColors.of(context).scrim,
                    raw,
                  ),
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
                // Laid out at its final size and scaled, never resized: the
                // toolbar and editor must not reflow into the collapsed pad's
                // narrow starting width on the way in.
                Positioned.fromRect(
                  rect: targetRect,
                  child: Transform(
                    alignment: Alignment.topLeft,
                    transform: Matrix4.identity()
                      ..translate(
                        rect.left - targetRect.left,
                        rect.top - targetRect.top,
                      )
                      ..scale(
                        rect.width / targetRect.width,
                        rect.height / targetRect.height,
                      ),
                    child: Opacity(
                      opacity: (t / _kFadeInFraction).clamp(0.0, 1.0),
                      child: child,
                    ),
                  ),
                ),
              ],
            );
          },
          child: _ExpandedCard(
            problem: widget.problem,
            controller: widget.controller,
            editorFocus: _editorFocus,
            language: _language,
            comparing: _comparing,
            onClose: _close,
            onCopy: _copy,
            onOpenOnLeetCode: _openOnLeetCode,
            onClear: widget.onClear,
            onStrip: _stripComments,
            onToggleCompare: () => setState(() => _comparing = !_comparing),
            onLanguageChanged: _setLanguage,
            onCodeChanged: widget.onCodeChanged,
          ),
        ),
      ),
    );
  }
}

class _ExpandedCard extends StatelessWidget {
  const _ExpandedCard({
    required this.problem,
    required this.controller,
    required this.editorFocus,
    required this.language,
    required this.comparing,
    required this.onClose,
    required this.onCopy,
    required this.onOpenOnLeetCode,
    required this.onClear,
    required this.onStrip,
    required this.onToggleCompare,
    required this.onLanguageChanged,
    required this.onCodeChanged,
  });

  final LeetCodeProblem problem;
  final LeetCodeCodeController controller;
  final FocusNode editorFocus;
  final String language;
  final bool comparing;
  final VoidCallback onClose;
  final VoidCallback onCopy;
  final VoidCallback onOpenOnLeetCode;
  final VoidCallback onClear;
  final VoidCallback onStrip;
  final VoidCallback onToggleCompare;
  final ValueChanged<String> onLanguageChanged;
  final ValueChanged<String> onCodeChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hasUrl = problem.leetcodeUrl != null;

    return Material(
      color: theme.colorScheme.surface,
      elevation: 8,
      borderRadius: BorderRadius.circular(20),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                GlassButton(
                  dense: true,
                  height: 32,
                  icon: const Icon(PhosphorIconsRegular.x),
                  tooltip: 'Close the scratch pad',
                  onPressed: onClose,
                ),
                const SizedBox(width: 8),
                Expanded(
                  // The card behind this may be hiding the question name, and
                  // the pad is opened during that same review — a title in the
                  // toolbar would hand straight back what the card is
                  // withholding. The slot keeps its width either way, so the
                  // buttons don't move when the setting is on.
                  child: Consumer(
                    builder: (context, ref, _) {
                      final hidden =
                          ref
                              .watch(settingsProvider)
                              .valueOrNull
                              ?.leetCodeHideQuestionName ??
                          false;
                      return Text(
                        hidden ? 'Scratch' : problem.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleSmall,
                      );
                    },
                  ),
                ),
                const SizedBox(width: 8),
                GlassButton(
                  dense: true,
                  height: 32,
                  icon: const Icon(PhosphorIconsRegular.copy),
                  label: 'Copy',
                  tooltip: 'Copy what you typed',
                  onPressed: onCopy,
                ),
                const SizedBox(width: 6),
                GlassButton(
                  dense: true,
                  height: 32,
                  icon: const Icon(PhosphorIconsRegular.arrowSquareOut),
                  label: 'Open',
                  // Kept visible rather than removed, so the row does not
                  // change shape between problems — but coloured as the dead
                  // control it is when the title has no slug to link to.
                  color: hasUrl ? null : theme.colorScheme.error,
                  tooltip: hasUrl
                      ? 'Open this problem on LeetCode'
                      : 'This problem has no LeetCode link',
                  onPressed: hasUrl ? onOpenOnLeetCode : null,
                ),
                const SizedBox(width: 6),
                GlassButton(
                  dense: true,
                  height: 32,
                  icon: const Icon(PhosphorIconsRegular.eraser),
                  label: 'Clear',
                  tooltip: 'Reset the pad to its starter template',
                  onPressed: onClear,
                ),
                const SizedBox(width: 6),
                GlassButton(
                  dense: true,
                  height: 32,
                  icon: const Icon(Icons.comments_disabled_outlined),
                  label: 'Strip',
                  tooltip:
                      'Remove ${labelForLeetCodeLanguage(language)} comments '
                      'and the trailing blank line',
                  onPressed: onStrip,
                ),
                const SizedBox(width: 6),
                GlassButton(
                  dense: true,
                  height: 32,
                  icon: const Icon(PhosphorIconsRegular.columns),
                  label: 'Compare',
                  color: comparing ? theme.colorScheme.primary : null,
                  tooltip: 'Compare against the saved solution',
                  onPressed: onToggleCompare,
                ),
              ],
            ),
            const SizedBox(height: 10),
            SizedBox(
              height: 30,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: leetCodeCodeLanguages.length,
                separatorBuilder: (_, _) => const SizedBox(width: 6),
                itemBuilder: (context, index) {
                  final lang = leetCodeCodeLanguages[index];
                  return SizedBox(
                    width: 84,
                    child: SelectorPill(
                      dense: true,
                      label: labelForLeetCodeLanguage(lang),
                      isActive: lang == language,
                      fillWhenActive: true,
                      onTap: () => onLanguageChanged(lang),
                    ),
                  );
                },
              ),
            ),
            const SizedBox(height: 10),
            Expanded(
              child: comparing
                  ? LeetCodeScratchCompare(
                      scratch: controller.fullText,
                      problem: problem,
                    )
                  : _ScratchEditor(
                      controller: controller,
                      focusNode: editorFocus,
                      onCodeChanged: onCodeChanged,
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Side-by-side comparison of the scratch pad against the problem's saved
/// solution.
///
/// Both columns are built from one aligned row list, so a row index means the
/// same place in both — that is what lets one scroll position drive them
/// without the two drifting apart wherever a side is longer.
///
/// Shown regardless of **Hide solution code**: that setting is about what the
/// card volunteers, and this is the user explicitly asking to see the answer.
class LeetCodeScratchCompare extends StatefulWidget {
  const LeetCodeScratchCompare({
    super.key,
    required this.scratch,
    required this.problem,
  });

  final String scratch;
  final LeetCodeProblem problem;

  @override
  State<LeetCodeScratchCompare> createState() => _LeetCodeScratchCompareState();
}

class _LeetCodeScratchCompareState extends State<LeetCodeScratchCompare> {
  final _left = ScrollController();
  final _right = ScrollController();

  /// Guards the mirror so writing one controller's offset into the other
  /// cannot bounce straight back and fight the drag.
  bool _syncing = false;

  @override
  void initState() {
    super.initState();
    _left.addListener(() => _mirror(_left, _right));
    _right.addListener(() => _mirror(_right, _left));
  }

  @override
  void dispose() {
    _left.dispose();
    _right.dispose();
    super.dispose();
  }

  void _mirror(ScrollController from, ScrollController to) {
    if (_syncing || !from.hasClients || !to.hasClients) return;
    final offset = from.offset.clamp(
      to.position.minScrollExtent,
      to.position.maxScrollExtent,
    );
    if ((to.offset - offset).abs() < 0.5) return;
    _syncing = true;
    to.jumpTo(offset);
    _syncing = false;
  }

  /// The first non-empty saved solution — the same rule the deck's **Copy
  /// code** menu item uses, so "the solution" means one thing everywhere.
  String? get _solution {
    for (final solution in widget.problem.solutions) {
      if (solution.code.trim().isNotEmpty) return solution.code;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final solution = _solution;
    if (solution == null) {
      return Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: _DiffPane(
              title: 'Your scratch',
              rows: [
                for (final (i, line) in widget.scratch.split('\n').indexed)
                  LeetCodeDiffRow(
                    kind: LeetCodeDiffKind.same,
                    left: line,
                    leftNumber: i + 1,
                  ),
              ],
              side: _DiffSide.left,
              controller: _left,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Center(
              child: Text(
                'No saved solution',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
                ),
              ),
            ),
          ),
        ],
      );
    }

    final rows = leetCodeDiffLines(widget.scratch, solution);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: _DiffPane(
            title: 'Your scratch',
            rows: rows,
            side: _DiffSide.left,
            controller: _left,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: _DiffPane(
            title: 'Saved solution',
            rows: rows,
            side: _DiffSide.right,
            controller: _right,
          ),
        ),
      ],
    );
  }
}

enum _DiffSide { left, right }

/// One column of the comparison: the rows this side holds, tinted by what
/// happened to them.
class _DiffPane extends StatelessWidget {
  const _DiffPane({
    required this.title,
    required this.rows,
    required this.side,
    required this.controller,
  });

  final String title;
  final List<LeetCodeDiffRow> rows;
  final _DiffSide side;
  final ScrollController controller;

  /// Red where this side has a line the other does not, green where it is the
  /// side that carries the difference. A row present on neither side is a
  /// spacer holding the two columns in step, and takes no colour at all.
  Color? _tint(LeetCodeDiffRow row, ThemeData theme) {
    final mine = side == _DiffSide.left ? row.left : row.right;
    if (mine == null) return theme.colorScheme.onSurface.withValues(alpha: 0.03);
    return switch (row.kind) {
      LeetCodeDiffKind.same => null,
      LeetCodeDiffKind.changed || LeetCodeDiffKind.removed =>
        side == _DiffSide.left
            ? const Color(0xFFE0714A).withValues(alpha: 0.16)
            : const Color(0xFF4CAF7D).withValues(alpha: 0.16),
      LeetCodeDiffKind.added => const Color(0xFF4CAF7D).withValues(alpha: 0.16),
    };
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final textStyle = AppFonts.style(
      fontSize: 13,
    ).copyWith(fontFamily: AppFonts.monoFamily, color: theme.colorScheme.onSurface);
    final numberStyle = textStyle.copyWith(
      color: theme.colorScheme.onSurface.withValues(alpha: 0.4),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: Text(
            title,
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
            ),
          ),
        ),
        Expanded(
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: theme.colorScheme.outline.withValues(alpha: 0.3),
              ),
            ),
            clipBehavior: Clip.antiAlias,
            child: VoyagerScrollView(
              controller: controller,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final row in rows)
                    Container(
                      color: _tint(row, theme),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 1,
                      ),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          SizedBox(
                            width: 30,
                            child: Text(
                              '${(side == _DiffSide.left ? row.leftNumber : row.rightNumber) ?? ''}',
                              textAlign: TextAlign.right,
                              style: numberStyle,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              (side == _DiffSide.left ? row.left : row.right) ??
                                  '',
                              style: textStyle,
                              // Never wraps: a wrapped line would make this
                              // row taller than its opposite number and the
                              // two columns would stop lining up.
                              maxLines: 1,
                              overflow: TextOverflow.clip,
                              softWrap: false,
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

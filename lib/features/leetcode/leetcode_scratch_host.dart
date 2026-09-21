import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/session_resume/session_checkpoint_controller.dart';
import 'package:voyager/core/widgets/voyager_scroll_view.dart';
import 'package:voyager/domain/models/leetcode_models.dart';
import 'package:voyager/features/leetcode/leetcode_cheat_providers.dart';
import 'package:voyager/features/leetcode/leetcode_scratch_draft.dart';
import 'package:voyager/features/leetcode/leetcode_scratch_pad.dart';
import 'package:voyager/features/leetcode/leetcode_scratch_session.dart';

/// Height the pad takes when the window is too narrow to put it beside the
/// card and it goes underneath instead.
const double _kStackedPadHeight = 300;

/// Everything a Study or Cram session needs to carry a scratch code pad:
/// the session controller, the split layout, and the fullscreen editor.
///
/// A mixin rather than a wrapper widget because the pad is not a decoration
/// around the session — it changes how the card is laid out, what the keyboard
/// does, and when the page is allowed to grade. Both pages want the same
/// answers to all of that.
mixin LeetCodeScratchHost<T extends ConsumerStatefulWidget>
    on ConsumerState<T> {
  /// The problems the session opened over.
  Set<String> get scratchProblemIds;

  /// The page's checkpoint. Scratch has no file of its own: what is typed
  /// belongs to the run, and the run is what is written down.
  SessionCheckpointController get sessionCheckpoint;

  LeetCodeScratchSessionController? _scratch;

  /// Pads from a resumed run, held until there is a controller to put them
  /// in — the checkpoint is read before the setting has resolved.
  ///
  /// With the setting off they stay here untouched and go back into the
  /// checkpoint as they came, so turning the pad on later still finds them.
  LeetCodeScratchSession? _primed;

  /// Whether the setting said yes, latched the first time settings resolved.
  ///
  /// Read once on purpose: turning the toggle off mid-session would have to
  /// decide what happens to everything already typed, and the answer the spec
  /// takes is that the setting applies to the *next* session.
  bool? _scratchSettingLatched;

  final _padKey = GlobalKey();
  final _padFocus = FocusNode(debugLabel: 'leetCodeScratchPad');

  bool _expanding = false;

  bool get scratchEnabled => _scratch != null;

  /// The pads as they stand, for the checkpoint to write down.
  LeetCodeScratchSession? get scratchSnapshot =>
      _scratch?.snapshot() ?? _primed;

  /// Hands the session the pads it was typed with before it was left.
  void primeScratch(LeetCodeScratchSession? blob) {
    if (blob == null) return;
    _primed = blob;
    if (_scratch != null) _applyPrimed(_scratch!);
  }

  /// Throws the pads away, for a Start over: the run they belonged to is not
  /// one the user is coming back to.
  void resetScratch() {
    _primed = null;
    _scratch?.reset();
  }

  void _applyPrimed(LeetCodeScratchSessionController controller) {
    final blob = _primed;
    if (blob == null) return;
    _primed = null;
    controller.restore(blob);
    // A run left with the editor open comes back with it open — the pad has
    // to be laid out again first, since the overlay grows out of where it
    // ends up.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final problem = scratchCurrentProblem;
      if (problem == null || !controller.entryFor(problem).expanded) return;
      _expandScratch();
    });
  }

  /// Whether something other than the card owns the session's input.
  ///
  /// Grading and the cram swipe both stop here: with the caret in the pad the
  /// user is typing, while the fullscreen editor is up the card is not even on
  /// screen, and while the cheat sheet is up the session is behind a scrim.
  ///
  /// Read rather than watched — this is called from key and gesture handlers
  /// as well as from `build`. The pages watch the provider themselves, which
  /// is what rebuilds them when the sheet opens or closes.
  bool get scratchHasSessionInput =>
      _padFocus.hasFocus ||
      _expanding ||
      ref.read(leetCodeCheatSheetOpenProvider);

  @override
  void initState() {
    super.initState();
    _padFocus.addListener(_onPadFocusChanged);
  }

  void _onPadFocusChanged() {
    // The grading row dims while the pad has the caret, so the page has to
    // rebuild on the focus change itself.
    if (mounted) setState(() {});
  }

  /// Creates the session's scratch state the first time settings resolve.
  /// Call at the top of `build`.
  void syncScratch() {
    if (_scratchSettingLatched != null) return;
    final settings = ref.watch(settingsProvider).valueOrNull;
    if (settings == null) return;

    final enabled = settings.leetCodeEnableScratchCode;
    _scratchSettingLatched = enabled;
    if (!enabled) return;

    _discardLegacyScratchFile();
    final controller = LeetCodeScratchSessionController(
      onChanged: sessionCheckpoint.persist,
    );
    _scratch = controller;
    _applyPrimed(controller);
  }

  /// Drops pads for problems deleted out from under the session.
  void retainScratch(Set<String> liveIds) => _scratch?.retainOnly(liveIds);

  /// Writes what is pending ahead of the debounce — called where the user has
  /// visibly finished with a pad, which is every problem advance.
  void flushScratch() => sessionCheckpoint.flush();

  /// Focuses the pad, and opens it fullscreen — the locked behaviour for `C`,
  /// which is one key for "I want to write code now".
  void focusScratch() {
    if (_scratch == null || _expanding) return;
    _padFocus.requestFocus();
    _expandScratch();
  }

  Future<void> _expandScratch() async {
    final controller = _scratch;
    final problem = scratchCurrentProblem;
    if (controller == null || problem == null || _expanding) return;

    final box = _padKey.currentContext?.findRenderObject() as RenderBox?;
    final rect = box == null
        ? Offset.zero & MediaQuery.sizeOf(context)
        : box.localToGlobal(Offset.zero) & box.size;

    setState(() => _expanding = true);
    controller.update(problem.id, expanded: true);

    await openLeetCodeScratchOverlay(
      context,
      problem: problem,
      controller: controller.controllerFor(problem),
      anchorRect: rect,
      language: controller.entryFor(problem).language,
      onCodeChanged: (code) => controller.update(problem.id, code: code),
      onLanguageChanged: (language) =>
          controller.update(problem.id, language: language),
      onClear: () => controller.clear(problem),
    );

    if (!mounted) return;
    controller.update(problem.id, expanded: false);
    // The pad is closed for good now, so this is one of the moments worth
    // beating the debounce to.
    flushScratch();
    setState(() => _expanding = false);
  }

  /// The card the pad sits beside, or null on a completion screen. Supplied by
  /// the page, because Study reads it off the head of its queue and Cram off
  /// its buckets.
  LeetCodeProblem? get scratchCurrentProblem;

  /// Lays the card and the pad out together.
  ///
  /// [cardKey] and the card's own size cap stay exactly as the page had them —
  /// with the pad off, this returns the card in the same box it always used.
  Widget buildScratchArea({required GlobalKey cardKey, required Widget card}) {
    final controller = _scratch;
    final problem = scratchCurrentProblem;

    return LayoutBuilder(
      builder: (context, constraints) {
        Widget sizedCard(double width) => SizedBox(
          key: cardKey,
          width: width,
          height: math.min(constraints.maxHeight, 720),
          child: card,
        );

        if (controller == null || problem == null) {
          return Center(child: sizedCard(math.min(constraints.maxWidth, 760)));
        }

        final entry = controller.entryFor(problem);
        final pad = KeyedSubtree(
          key: _padKey,
          child: LeetCodeScratchPad(
            // Remounts on the problem, and on a recovery restore — both are
            // the buffer being replaced rather than typed into.
            key: ValueKey('${problem.id}#${controller.generation}'),
            problem: problem,
            entry: entry,
            controller: controller.controllerFor(problem),
            focusNode: _padFocus,
            onCodeChanged: (code) => controller.update(problem.id, code: code),
            onExpand: _expandScratch,
          ),
        );

        if (constraints.maxWidth < kLeetCodeScratchStackBreakpoint) {
          // Too narrow for two columns: stack them and let the user scroll to
          // whichever they are working in.
          return VoyagerScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(
                  key: cardKey,
                  height: math.min(constraints.maxHeight, 720),
                  child: card,
                ),
                const SizedBox(height: 12),
                SizedBox(height: _kStackedPadHeight, child: pad),
              ],
            ),
          );
        }

        const gap = 16.0;
        final padWidth =
            constraints.maxWidth * kLeetCodeScratchWidthFraction - gap;
        // The card keeps its own cap, so a very wide window gives the spare
        // room back to the margins rather than stretching either pane.
        final cardWidth = math.min(
          constraints.maxWidth - padWidth - gap,
          760.0,
        );
        return Center(
          child: Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              sizedCard(cardWidth),
              const SizedBox(width: gap),
              SizedBox(
                width: padWidth,
                height: math.min(constraints.maxHeight, 720),
                child: pad,
              ),
            ],
          ),
        );
      },
    );
  }

  @override
  void dispose() {
    _padFocus.removeListener(_onPadFocusChanged);
    _padFocus.dispose();
    // Disposal is an exit, not an ending: the × button, Back to deck and a
    // system back all leave a session that is not finished, and what was
    // typed stays with it in the checkpoint until it is.
    _scratch?.dispose();
    super.dispose();
  }
}

/// The file scratch used to live in, before it moved into the session
/// checkpoint. One left over from a build before the move is a run nobody can
/// resume any more, so it goes the first time a session opens.
var _legacyScratchSwept = false;

Future<void> _discardLegacyScratchFile() async {
  if (_legacyScratchSwept) return;
  _legacyScratchSwept = true;
  try {
    final dir = await getApplicationDocumentsDirectory();
    final file = File(p.join(dir.path, 'leetcode_scratch_session.json'));
    if (await file.exists()) await file.delete();
  } catch (error) {
    // Nothing here is worth interrupting a session for: at worst a stale
    // file stays on disk, unread.
    debugPrint('Legacy scratch file could not be cleared: $error');
  }
}

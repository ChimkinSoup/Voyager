import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/widgets/voyager_scroll_view.dart';
import 'package:voyager/core/widgets/voyager_toast.dart';
import 'package:voyager/domain/models/leetcode_models.dart';
import 'package:voyager/features/leetcode/leetcode_scratch_draft_store.dart';
import 'package:voyager/features/leetcode/leetcode_scratch_pad.dart';
import 'package:voyager/features/leetcode/leetcode_scratch_session.dart';

/// Height the pad takes when the window is too narrow to put it beside the
/// card and it goes underneath instead.
const double _kStackedPadHeight = 300;

/// Everything a Study or Cram session needs to carry a scratch code pad:
/// the session controller, the split layout, the fullscreen editor, and the
/// crash-recovery offer.
///
/// A mixin rather than a wrapper widget because the pad is not a decoration
/// around the session — it changes how the card is laid out, what the keyboard
/// does, and when the page is allowed to grade. Both pages want the same
/// answers to all of that.
mixin LeetCodeScratchHost<T extends ConsumerStatefulWidget>
    on ConsumerState<T> {
  /// The problems the session opened over.
  Set<String> get scratchProblemIds;

  LeetCodeScratchSessionController? _scratch;

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

  /// Whether the pad currently owns the session's input.
  ///
  /// Grading and the cram swipe both stop here: with the caret in the pad the
  /// user is typing, and while the fullscreen editor is up the card is not
  /// even on screen.
  bool get scratchHasSessionInput => _padFocus.hasFocus || _expanding;

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

    final controller = LeetCodeScratchSessionController(
      store: ref.read(leetCodeScratchDraftStoreProvider),
      problemIds: scratchProblemIds,
    );
    _scratch = controller;
    // Reading the file and offering what it holds both have to wait for the
    // frame this was created in to finish.
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final orphan = await controller.start();
      if (!mounted || orphan == null) return;
      _offerRecovery(controller);
    });
  }

  void _offerRecovery(LeetCodeScratchSessionController controller) {
    showVoyagerToast(
      context,
      message: 'Your last session left scratch code behind.',
      icon: PhosphorIconsRegular.clockCounterClockwise,
      // Dismissing without answering means discard, which is safe: this
      // session already owns the file, so the orphan is only in memory.
      dwell: const Duration(seconds: 12),
      actions: [
        VoyagerToastAction(
          label: 'Restore',
          onPressed: () {
            controller.restoreRecoverable();
            if (!mounted) return;
            setState(() {});
            // A run that died with the editor open comes back with it open —
            // the pad has to be laid out again first, since the overlay grows
            // out of where it ends up.
            final problem = scratchCurrentProblem;
            if (problem == null || !controller.entryFor(problem).expanded) {
              return;
            }
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) _expandScratch();
            });
          },
        ),
        VoyagerToastAction(
          label: 'Discard',
          onPressed: controller.discardRecoverable,
        ),
      ],
    );
  }

  /// Drops pads for problems deleted out from under the session.
  void retainScratch(Set<String> liveIds) => _scratch?.retainOnly(liveIds);

  /// Writes what is pending ahead of the debounce — called where the user has
  /// visibly finished with a pad, which is every problem advance.
  void flushScratch() => _scratch?.flushNow();


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
    controller.flushNow();
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
  Widget buildScratchArea({
    required GlobalKey cardKey,
    required Widget card,
  }) {
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
          return Center(
            child: sizedCard(math.min(constraints.maxWidth, 760)),
          );
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
    // Disposal *is* the normal exit — the × button, Back to deck, and a system
    // back all pop the route and land here, while a crash never does. So this
    // is the one place that has to delete the recovery file, and the only
    // reason a file is ever left behind for the next session to find.
    _scratch?.end();
    _scratch?.dispose();
    super.dispose();
  }
}

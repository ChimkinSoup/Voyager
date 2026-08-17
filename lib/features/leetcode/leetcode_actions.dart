import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:voyager/app/providers.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:voyager/core/widgets/confirm_dialog.dart';
import 'package:voyager/core/widgets/context_menu.dart';
import 'package:voyager/domain/models/leetcode_api_models.dart';
import 'package:voyager/domain/models/leetcode_models.dart';
import 'package:voyager/domain/models/study_models.dart';
import 'package:voyager/domain/services/leetcode_srs_engine.dart';
import 'package:voyager/features/leetcode/leetcode_loading_toast.dart';
import 'package:voyager/features/leetcode/leetcode_track_draft.dart';
import 'package:voyager/features/leetcode/leetcode_track_draft_store.dart';
import 'package:voyager/features/leetcode/leetcode_track_modal.dart';

/// Writes [problem] through the repository and out to sync, then refreshes
/// the page's problem list. Every mutation below funnels through here.
Future<void> _save(WidgetRef ref, LeetCodeProblem problem) async {
  await ref.read(leetCodeRepositoryProvider).upsertProblem(problem);
  ref.read(remoteSyncServiceProvider).pushLeetCodeProblem(problem);
  ref.invalidate(leetcodeProblemsProvider);
}

/// Opens the Track flow: with a LeetCode username saved, the user's most
/// recent accepted submission is fetched first so the form arrives prefilled.
/// Any failure there just opens an empty form — the fetch is a convenience,
/// not a precondition for tracking a problem by hand.
///
/// The lookup runs whether or not a local draft is waiting, because it is what
/// decides between them: a draft whose problem name is the one just solved is
/// the same piece of work, and resuming it beats handing back a blank prefill
/// of a form the user had already half-written. Any other draft is set aside
/// and offered rather than opened, and a lookup that can't answer falls back to
/// the draft if there is one.
///
/// Shared by the Track button and the Review Deck's empty state, which offers
/// the same action rather than pointing at the button.
Future<void> startLeetCodeTrackFlow(BuildContext context, WidgetRef ref) async {
  // Started before the network call rather than awaited first: a local file
  // read has no business adding to the time the fetch toast is up.
  final draftFuture = ref.read(leetCodeTrackDraftStoreProvider).load();
  final username = ref.read(settingsProvider).value?.leetcodeUsername?.trim();

  LeetCodeApiQuestion? recent;
  if (username != null && username.isNotEmpty) {
    final dismissToast = showLeetCodeToast(
      context,
      message: 'Fetching your latest submission…',
    );
    try {
      recent = await ref
          .read(leetCodeApiClientProvider)
          .fetchMostRecentAcceptedSubmission(username);
    } catch (_) {
      // Handled the same as "no submission": the draft, or an empty form.
    }
    dismissToast();
  }

  final draft = await draftFuture;
  if (!context.mounted) return;

  if (recent == null) {
    await showLeetCodeTrackModal(
      context,
      ref,
      draft: draft,
      draftOutcome: draft == null
          ? LeetCodeTrackDraftOutcome.none
          : LeetCodeTrackDraftOutcome.resumedAfterFetchFailure,
    );
    return;
  }

  final resume = draft != null && leetCodeTrackDraftMatches(draft, recent.title);
  await showLeetCodeTrackModal(
    context,
    ref,
    prefill: resume ? null : recent,
    draft: draft,
    draftOutcome: draft == null
        ? LeetCodeTrackDraftOutcome.none
        : resume
        ? LeetCodeTrackDraftOutcome.resumed
        : LeetCodeTrackDraftOutcome.mismatch,
  );
}

/// Persists a Study-session grade. Returns the graded problem so the session
/// can decide whether it needs re-queueing this round.
Future<LeetCodeProblem> gradeAndSaveLeetCodeProblem(
  WidgetRef ref,
  LeetCodeProblem problem,
  StudyGrade grade,
) async {
  final graded = gradeLeetCodeProblem(problem, grade);
  await _save(ref, graded);
  return graded;
}

/// Forgets how well the user knows [problem] — its content is untouched.
/// Returns the reset problem so a session can put the same copy back in its
/// queue.
Future<LeetCodeProblem> resetLeetCodeProgress(
  WidgetRef ref,
  LeetCodeProblem problem,
) async {
  final reset = resetLeetCodeProblemSrs(problem);
  await _save(ref, reset);
  return reset;
}

/// Returns whether the problem was actually deleted, so a session that was
/// showing it knows whether to move on.
Future<bool> deleteLeetCodeProblem(
  BuildContext context,
  WidgetRef ref,
  LeetCodeProblem problem,
) async {
  final confirmed = await showConfirmDialog(
    context,
    title: 'Delete "${problem.title}"?',
    message: 'This problem and everything tracked with it — code, notes, and '
        'review history — will be removed.',
  );
  if (!confirmed) return false;

  final repo = ref.read(leetCodeRepositoryProvider);
  await repo.softDeleteProblem(problem.id);
  final tombstone = await repo.getProblem(problem.id);
  if (tombstone != null) {
    ref.read(remoteSyncServiceProvider).pushLeetCodeProblem(tombstone);
  }
  ref.invalidate(leetcodeProblemsProvider);
  return true;
}

/// The right-click menu for a tracked problem, wherever one is listed.
///
/// One builder rather than a menu per surface: a problem is the same object
/// on the dashboard feed as it is on a review-deck card, and a user who has
/// learned "right-click gives me Edit and Copy code" should not find a
/// shorter menu on the other page.
///
/// [onOpenDetail] is the caller's own zoom-out — the detail view grows from
/// whatever was clicked, so only the caller knows the rect to start from.
///
/// [onResetProgress] and [onDelete] default to performing the action and
/// nothing else, which is all a grid tile needs. A session overrides them
/// because it also has to move off the card it was showing.
List<ContextMenuItem> leetCodeProblemMenuItems({
  required BuildContext context,
  required WidgetRef ref,
  required LeetCodeProblem problem,
  required VoidCallback onOpenDetail,
  VoidCallback? onResetProgress,
  VoidCallback? onDelete,
}) {
  final url = problem.leetcodeUrl;
  return [
    ContextMenuItem(
      label: 'Open details…',
      icon: PhosphorIconsRegular.arrowsOutSimple,
      onTap: onOpenDetail,
    ),
    ContextMenuItem(
      label: 'Edit…',
      icon: PhosphorIconsRegular.pencilSimple,
      onTap: () => showLeetCodeTrackModal(context, ref, existing: problem),
    ),
    ContextMenuItem(
      label: 'Open on LeetCode',
      icon: PhosphorIconsRegular.arrowSquareOut,
      enabled: url != null,
      onTap: url == null ? null : () => launchUrl(Uri.parse(url)),
    ),
    ContextMenuItem(
      label: 'Copy code',
      icon: PhosphorIconsRegular.copySimple,
      enabled: _firstCodeOf(problem) != null,
      onTap: _firstCodeOf(problem) == null
          ? null
          : () => copyLeetCodeCode(context, problem),
    ),
    ContextMenuItem(
      label: 'Reset progress',
      icon: PhosphorIconsRegular.arrowCounterClockwise,
      // Nothing to forget on a problem that has never been reviewed.
      enabled: !problem.isNew,
      onTap: problem.isNew
          ? null
          : (onResetProgress ?? () => resetLeetCodeProgress(ref, problem)),
    ),
    ContextMenuItem(
      label: 'Delete',
      icon: PhosphorIconsRegular.trash,
      isDestructive: true,
      onTap: onDelete ?? () => deleteLeetCodeProblem(context, ref, problem),
    ),
  ];
}

/// The code of the first solution that has any.
///
/// One menu item can only copy one of them, and the first is the one the deck
/// treats as primary everywhere else. Picking the first *non-empty* one rather
/// than solution 1 flatly keeps the item working when the primary solution was
/// written up in prose with no code attached.
String? _firstCodeOf(LeetCodeProblem problem) {
  for (final solution in problem.solutions) {
    if (solution.code.isNotEmpty) return solution.code;
  }
  return null;
}

/// Puts the saved solution on the clipboard, confirmed with the same toast
/// the Track button uses — dismissed on a timer, since there's nothing to
/// wait for.
Future<void> copyLeetCodeCode(
  BuildContext context,
  LeetCodeProblem problem,
) async {
  await Clipboard.setData(ClipboardData(text: _firstCodeOf(problem) ?? ''));
  if (!context.mounted) return;
  final dismiss = showLeetCodeToast(
    context,
    message: 'Code copied',
    icon: PhosphorIconsRegular.check,
  );
  Future.delayed(const Duration(milliseconds: 1400), dismiss);
}

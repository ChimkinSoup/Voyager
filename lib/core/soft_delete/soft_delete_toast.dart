import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:voyager/core/soft_delete/restore_contract.dart';
import 'package:voyager/core/widgets/voyager_toast.dart';

export 'package:voyager/core/soft_delete/restore_contract.dart';

/// How long an undo offer stands before the toast takes itself away.
///
/// Long enough to notice the deletion and change your mind, and the toast
/// holds this clock while the pointer is on it — so the number is a floor on
/// how long the offer lasts, not a ceiling.
const kSoftDeleteUndoDwell = Duration(seconds: 8);

/// How much of a title the toast will quote before it starts eating the
/// sentence.
///
/// A toast is a notice about the item, not the item itself: quoted in full, a
/// long title stretches the card most of the way across the window and pushes
/// Undo out towards the edge of the screen. Cutting the name here rather than
/// letting the card's own ellipsis cut the message is what keeps the closing
/// quote on.
const _kQuotedNameLimit = 48;

/// `Deleted "<name>"`, or `Deleted <fallback>` for something never titled.
///
/// [fallback] is the noun on its own — 'entry', 'event', 'task' — so an
/// untitled row reads as a sentence rather than as a pair of empty quotes.
///
/// A name longer than [_kQuotedNameLimit] is cut down to it and ellipsised.
String deletedMessage(String? name, {required String fallback}) {
  final trimmed = name?.trim();
  if (trimmed == null || trimmed.isEmpty) return 'Deleted $fallback';
  return 'Deleted "${_capName(trimmed)}"';
}

/// [name] cut to [_kQuotedNameLimit] grapheme clusters, ellipsised when it had
/// to be cut at all.
///
/// Counted in clusters rather than code units so the cut can never land inside
/// an emoji or a combining accent. Trailing whitespace goes with the cut —
/// a name that happens to break on a space would otherwise read as `"one two
/// …"`.
String _capName(String name) {
  final clusters = name.characters;
  if (clusters.length <= _kQuotedNameLimit) return name;
  return '${clusters.take(_kQuotedNameLimit).toString().trimRight()}…';
}

/// Offers [restore] for [kSoftDeleteUndoDwell] after a delete that has already
/// happened.
///
/// [overlay] must have been resolved *before* the delete: deleting a row
/// unmounts the widget that asked for it, and the toast has to outlive that.
/// `Overlay.of(context, rootOverlay: true)` belongs to the app rather than to
/// the surface that raised it, so it is still there when Undo is pressed.
///
/// For the same reason [restore] must close over a [ProviderContainer] —
/// captured with `ProviderScope.containerOf(context, listen: false)` — and not
/// over a `WidgetRef`, which throws once its widget is gone.
VoyagerToast showSoftDeleteUndoToast({
  required OverlayState overlay,
  required String message,
  required Future<void> Function() restore,
}) {
  // One offer at a time per overlay. Toasts are all positioned at the same
  // place, so a second delete inside the dwell would otherwise draw its card
  // straight over the first one's — two stacked offers, only one of them
  // legible, and no way to tell which Undo you are pressing. The older offer
  // is dropped rather than queued: the delete the user is looking at is the
  // one they might want back. Dismissing does not run its restore, so the
  // first delete simply stands.
  _standingOffer[overlay]?.dismiss();

  final toast = showVoyagerToastIn(
    overlay,
    message: message,
    icon: PhosphorIconsRegular.trash,
    dwell: kSoftDeleteUndoDwell,
    actions: [
      VoyagerToastAction(
        label: 'Undo',
        // The toast dismisses on press either way. A restore that fails leaves
        // the row deleted, which is the state the user can already see — there
        // is nothing useful to say about it in a card that is on its way out.
        onPressed: () => unawaited(_guarded(overlay, restore)),
      ),
    ],
  );
  _standingOffer[overlay] = toast;
  // The slot is a strong reference held against the *root* overlay, which
  // lives as long as the app does. Without this the last deletion's whole
  // object graph — the snapshot, the captured container, the removed overlay
  // entry — is retained for the rest of the session. Guarded on identity so a
  // toast that has already been replaced cannot clear its successor's slot.
  unawaited(
    toast.done.whenComplete(() {
      if (identical(_standingOffer[overlay], toast)) {
        _standingOffer[overlay] = null;
      }
    }),
  );
  return toast;
}

/// The undo offer currently standing in each overlay, so the next one can take
/// its place. An [Expando] rather than a map so an overlay that goes away takes
/// its entry with it.
final _standingOffer = Expando<VoyagerToast>('soft delete undo offer');

/// Runs [delete], then offers [restore] for [kSoftDeleteUndoDwell].
///
/// Returns whether the delete actually landed, so a caller that took the row
/// out of its own in-memory state can put it back — or rather, never take it
/// out. A session that drops a card on a failed delete has it vanish from the
/// run while it is still live on disk, and cram can never re-admit it.
///
/// A delete that throws offers no undo — undoing something that never happened
/// is worse than saying nothing — and is reported here rather than left to the
/// caller. It was the caller's job once and no caller took it: most of them
/// have already torn their surface down by the time [delete] runs, the panel
/// closed or the row dropped from an optimistic list, so a throw left the row
/// alive on disk, the surface gone, nothing said, and the error loose in the
/// zone. One report here cannot be forgotten by the next call site.
///
/// Note there is no `container` parameter. The two closures are where the work
/// lives, and each already captures whatever it needs to reach the repository
/// and the providers — a container passed in here would only be handed
/// straight back out again.
Future<bool> softDeleteWithUndo({
  required OverlayState overlay,
  required String message,
  required Future<void> Function() delete,
  required Future<void> Function() restore,
}) async {
  try {
    await delete();
  } catch (error, stackTrace) {
    showVoyagerToastIn(
      overlay,
      message: 'Could not delete.',
      icon: PhosphorIconsRegular.warning,
      dwell: const Duration(seconds: 4),
    );
    FlutterError.reportError(
      FlutterErrorDetails(
        exception: error,
        stack: stackTrace,
        library: 'soft_delete_toast',
        context: ErrorDescription('while soft-deleting for "$message"'),
      ),
    );
    return false;
  }
  showSoftDeleteUndoToast(
    overlay: overlay,
    message: message,
    restore: restore,
  );
  return true;
}

Future<void> _guarded(
  OverlayState overlay,
  Future<void> Function() restore,
) async {
  try {
    await restore();
  } on RestoreSuperseded {
    // Not a failure: a pull brought the row back on its own while the offer
    // stood, and the restore refused to write its older snapshot over it. Said
    // out loud, because the press would otherwise appear to do nothing at all.
    showVoyagerToastIn(
      overlay,
      message: 'Already restored',
      icon: PhosphorIconsRegular.info,
      dwell: const Duration(seconds: 3),
    );
  } catch (error, stackTrace) {
    debugPrint('[soft-delete] undo failed: $error\n$stackTrace');
  }
}

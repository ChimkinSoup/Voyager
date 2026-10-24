import 'dart:io';
import 'dart:math' as math;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:super_drag_and_drop/super_drag_and_drop.dart';
import 'package:voyager/core/media/media_clipboard.dart';
import 'package:voyager/core/sound/app_sounds.dart';
import 'package:voyager/core/theme/voyager_theme.dart';
import 'package:voyager/core/widgets/confirm_dialog.dart';
import 'package:voyager/core/widgets/ctrl_enter_to_submit_scope.dart';
import 'package:voyager/core/widgets/glass_button.dart';
import 'package:voyager/core/widgets/voyager_dialog.dart';
import 'package:voyager/core/widgets/voyager_text_field.dart';
import 'package:voyager/domain/models/photo_series_models.dart';
import 'package:voyager/domain/services/media_ingest.dart';
import 'package:voyager/features/notifications/secure_vault_session.dart';
import 'package:voyager/features/photo_series/photo_align_editor.dart';
import 'package:voyager/features/photo_series/photo_capture_screen.dart';
import 'package:voyager/features/photo_series/photo_frame.dart';
import 'package:voyager/features/photo_series/photo_series_playback.dart';
import 'package:voyager/features/photo_series/photo_series_providers.dart';
import 'package:voyager/features/photo_series/photo_series_service.dart';
import 'package:voyager/features/photo_series/vault_activity.dart';
import 'package:voyager/features/photo_series/vault_image_cache.dart';

/// Opens the check-in stepper (PHOTO_SERIES_HLD.md §7.3): one step per angle
/// of [angles], each taking a file, a paste or a drop, then a review with the
/// date and note. On Android the steps are the camera's, and the dialog opens
/// at the review with what it took. With [checkIn] and a single angle, it
/// gives that check-in the angle's photo instead — added, or replacing the
/// one it had.
///
/// Needs an unlocked vault, and closes if it locks. One at a time, app-wide:
/// does nothing while another is open.
Future<void> showPhotoCheckInDialog(
  BuildContext context, {
  required PhotoSeries series,
  required List<PhotoSeriesAngle> angles,
  PhotoCheckIn? checkIn,
}) {
  if (_openCheckIn != null) return Future.value();
  final navigator = Navigator.of(context, rootNavigator: true);
  // The route it all opens over, for [closeOtherPhotoCheckIn] to pop back
  // to: a predicate that holds at once pops nothing.
  late Route<dynamic> below;
  navigator.popUntil((route) {
    below = route;
    return true;
  });
  final done = _showCheckIn(
    context,
    series: series,
    angles: angles,
    checkIn: checkIn,
  );
  _open = (seriesId: series.id, navigator: navigator, below: below, done: done);
  return done.whenComplete(() {
    // Not a newer one's, opened once this one's navigator had gone.
    if (identical(_open?.done, done)) _open = null;
  });
}

typedef _OpenCheckIn = ({
  String seriesId,
  NavigatorState navigator,
  Route<dynamic> below,
  Future<void> done,
});

/// The check-in open, at its camera or its dialog — both on the root
/// navigator, so they outlive the detail that opened them.
_OpenCheckIn? _open;

/// The open check-in's save while it runs: a check-in mid-save can't be
/// discarded any more.
Future<void>? _openSave;

/// [_open], unless its navigator has gone — torn down with the app, by a hot
/// restart or at the end of a test — taking the check-in with it.
_OpenCheckIn? get _openCheckIn =>
    (_open?.navigator.mounted ?? false) ? _open : null;

/// Before a notification tap starts a check-in of [seriesId]: asks whether to
/// discard one open for another series, and closes it if so. False when the
/// user keeps it; true when there is none, or it is [seriesId]'s own.
Future<bool> closeOtherPhotoCheckIn(
  BuildContext context,
  String seriesId,
) async {
  final open = _openCheckIn;
  if (open == null || open.seriesId == seriesId) return true;
  final discard = await showConfirmDialog(
    context,
    title: 'Discard check-in?',
    message:
        'A check-in of another series is open. Its photos and note are not '
        'kept.',
    cancelLabel: 'Keep',
    confirmLabel: 'Discard',
  );
  // A lock closes the check-in and this prompt with it: nothing to keep.
  final locked =
      context.mounted &&
      ProviderScope.containerOf(
            context,
            listen: false,
          ).read(secureVaultSessionProvider) ==
          null;
  if (!discard && !locked) return false;
  // Closed meanwhile, saved or locked.
  if (_openCheckIn != open) return true;
  if (_openSave case final save?) {
    // Saved anyway, or failed: then it's closed like any other.
    await save.catchError((_) {});
    if (_openCheckIn != open) return true;
  }
  open.navigator.popUntil((route) => route == open.below || route.isFirst);
  await open.done;
  return true;
}

Future<void> _showCheckIn(
  BuildContext context, {
  required PhotoSeries series,
  required List<PhotoSeriesAngle> angles,
  PhotoCheckIn? checkIn,
}) async {
  assert(checkIn == null || angles.length == 1);
  Map<String, Uint8List>? captured;
  if (photoCaptureSupported && checkIn == null) {
    captured = await showPhotoCaptureScreen(context, angles: angles);
    if (captured == null || !context.mounted) return;
  }
  return showVoyagerDialog<void>(
    context: context,
    builder: (context) => _CheckInDialog(
      series: series,
      angles: angles,
      checkIn: checkIn,
      captured: captured,
    ),
  );
}

/// A photo picked for one step, still plain, in memory only.
class _Picked {
  const _Picked(this.bytes, this.takenOn, [this.aligned]);

  final Uint8List bytes;

  /// When the file says it was taken: EXIF, else its modified date. Null for
  /// a paste or a drop with neither.
  final DateTime? takenOn;

  /// The transform the user gave it in the alignment editor, if they did.
  /// Only its transform means anything.
  final PhotoCheckInImage? aligned;
}

class _CheckInDialog extends ConsumerStatefulWidget {
  const _CheckInDialog({
    required this.series,
    required this.angles,
    required this.checkIn,
    required this.captured,
  });

  final PhotoSeries series;
  final List<PhotoSeriesAngle> angles;
  final PhotoCheckIn? checkIn;

  /// The camera's photos by angle id, taken today; the dialog starts at the
  /// review with them.
  final Map<String, Uint8List>? captured;

  @override
  ConsumerState<_CheckInDialog> createState() => _CheckInDialogState();
}

class _CheckInDialogState extends ConsumerState<_CheckInDialog> {
  final _picked = <String, _Picked>{};
  final _note = TextEditingController();

  /// [_CheckInDialog.angles] still live: one removed on another device while
  /// this is open leaves, with its photo, rather than saving into nothing.
  late var _angles = widget.angles;

  /// The step on screen: an angle's index, or [_reviewStep].
  var _step = 0;
  DateTime? _date;
  String? _error;
  bool _saving = false;

  int get _reviewStep => _angles.length;
  bool get _replacing => widget.checkIn != null;

  @override
  void initState() {
    super.initState();
    // The pop guard follows the note: one typed is asked about too.
    var noted = false;
    _note.addListener(() {
      final now = _note.text.trim().isNotEmpty;
      if (now != noted) setState(() => noted = now);
    });
    if (widget.captured case final captured?) {
      for (final MapEntry(:key, :value) in captured.entries) {
        // Checked as a file, paste or drop is: one refused shows as skipped,
        // with why, rather than failing the save.
        try {
          validateIngestInput(value);
        } on MediaIngestException catch (error) {
          _error = error.message;
          continue;
        }
        _picked[key] = _Picked(value, null);
      }
      // Every one refused: at the first step, to take another.
      _step = _picked.isEmpty ? 0 : _reviewStep;
    }
  }

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  /// The day the first photo picked says it was taken, else today — until
  /// the user picks a day themselves. Never past today: a camera clock ahead
  /// of ours can date a photo there.
  DateTime get _takenOn {
    if (_date case final date?) return date;
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    for (final angle in _angles) {
      if (_picked[angle.id]?.takenOn case final takenOn?) {
        return takenOn.isAfter(today) ? today : takenOn;
      }
    }
    return today;
  }

  /// Drops the angles [snapshot] no longer holds — all of them with the
  /// series — staying on the step that was on screen, or the one now in its
  /// place, and says which went.
  void _follow(PhotoSeriesSnapshot? snapshot) {
    if (snapshot == null) return;
    final seriesLive = snapshot.series.any((s) => s.id == widget.series.id);
    final live = seriesLive
        ? {for (final angle in snapshot.angles) angle.id}
        : const <String>{};
    final gone = [
      for (final angle in _angles)
        if (!live.contains(angle.id)) angle,
    ];
    if (gone.isEmpty) return;
    final shown = _step < _angles.length ? _angles[_step].id : null;
    _angles = [
      for (final angle in _angles)
        if (live.contains(angle.id)) angle,
    ];
    for (final angle in gone) {
      _picked.remove(angle.id);
    }
    final index = _angles.indexWhere((angle) => angle.id == shown);
    _step = shown == null
        ? _reviewStep
        : index >= 0
        ? index
        : math.min(_step, _reviewStep);
    final names = gone.map((angle) => angle.name).join(', ');
    _error = seriesLive
        ? '$names ${gone.length == 1 ? 'was' : 'were'} removed on another '
              'device.'
        : 'This series was deleted on another device.';
  }

  void _take(Uint8List bytes, {DateTime? modified}) {
    try {
      validateIngestInput(bytes);
    } on MediaIngestException catch (error) {
      setState(() => _error = error.message);
      return;
    }
    final exif = photoTakenOnFromExif(bytes);
    final fallback = modified == null
        ? null
        : DateTime(modified.year, modified.month, modified.day);
    setState(() {
      _error = null;
      _picked[_angles[_step].id] = _Picked(bytes, exif ?? fallback);
    });
  }

  Future<void> _chooseFile() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['png', 'jpg', 'jpeg', 'webp', 'heic'],
    );
    final path = result?.files.single.path;
    if (path == null || !mounted) return;
    final file = File(path);
    final bytes = await file.readAsBytes();
    final modified = await file.lastModified();
    if (mounted) _take(bytes, modified: modified);
  }

  Future<void> _capture(PhotoSeriesAngle angle) async {
    final taken = await showPhotoCaptureScreen(context, angles: [angle]);
    final bytes = taken?[angle.id];
    if (bytes != null && mounted) _take(bytes);
  }

  Future<void> _paste() async {
    final contents = await const MediaClipboard().read();
    final bytes = contents.imageBytes;
    if (!mounted) return;
    if (bytes == null) {
      setState(() => _error = 'There is no image on the clipboard.');
      return;
    }
    _take(bytes);
  }

  Future<void> _drop(PerformDropEvent event) async {
    for (final item in event.session.items) {
      final reader = item.dataReader;
      if (reader == null) continue;
      final bytes = await MediaClipboard.readImageFrom(reader);
      if (bytes != null) {
        if (mounted) _take(bytes);
        return;
      }
    }
  }

  /// Photos picked can't always be picked again — the camera's, or a paste
  /// once the clipboard has moved on — and a note typed is gone for good.
  bool get _asksToDiscard => _picked.isNotEmpty || _note.text.trim().isNotEmpty;

  /// Cancel, Esc and the back gesture: asks first when there is something
  /// to lose.
  Future<void> _cancel() async {
    // Too late to discard: the save goes through either way.
    if (_saving) return;
    if (_asksToDiscard &&
        !await showConfirmDialog(
          context,
          title: _replacing ? 'Discard photo?' : 'Discard check-in?',
          message: _replacing
              ? 'The photo picked is not kept.'
              : 'Its photos and note are not kept.',
          confirmLabel: 'Discard',
        )) {
      return;
    }
    if (mounted) Navigator.pop(context);
  }

  /// Ctrl+Enter: what Next or Save would do, once there is a photo for it —
  /// never a Skip.
  void _submit() {
    if (_saving || _picked.isEmpty) return;
    if (_step < _reviewStep && !_replacing) {
      if (_picked.containsKey(_angles[_step].id)) _next();
      return;
    }
    _save();
  }

  void _next() => setState(() {
    _step++;
    _error = null;
  });

  /// [angle] as it is now: [_angles] are as they were when this opened,
  /// before its first photo, say, fixed its frame.
  PhotoSeriesAngle _live(PhotoSeriesAngle angle) =>
      ref
          .read(photoSeriesSnapshotProvider)
          .valueOrNull
          ?.angles
          .where((live) => live.id == angle.id)
          .firstOrNull ??
      angle;

  /// [angle]'s photos the picked one can be aligned over, oldest first: not
  /// the one it replaces.
  List<PhotoFrameEntry> _alignFrames(PhotoSeriesAngle angle) {
    final snapshot = ref.read(photoSeriesSnapshotProvider).valueOrNull;
    if (snapshot == null) return const [];
    return [
      for (final frame in photoAngleFrames(snapshot, angle.id))
        if (frame.checkIn.id != widget.checkIn?.id) frame,
    ];
  }

  /// The latest of [frames] the check-in comes after, as the grid orders
  /// them: a new one comes after every one on its day.
  PhotoCheckInImage? _previous(List<PhotoFrameEntry> frames) {
    final checkIn = widget.checkIn;
    final takenOn = checkIn?.takenOn ?? _takenOn;
    return frames
        .where((frame) {
          final byDate = frame.checkIn.takenOn.compareTo(takenOn);
          return byDate < 0 ||
              (byDate == 0 &&
                  (checkIn == null ||
                      frame.checkIn.createdAt.isBefore(checkIn.createdAt)));
        })
        .lastOrNull
        ?.image;
  }

  /// Aligns [angle]'s picked photo over its reference, keeping the transform
  /// for the save.
  Future<void> _align(PhotoSeriesAngle angle) async {
    final picked = _picked[angle.id]!;
    final now = DateTime.now();
    final frames = _alignFrames(angle);
    final aligned = await showPickedPhotoAlignEditor(
      context,
      angle: _live(angle),
      frames: frames,
      takenOn: widget.checkIn?.takenOn ?? _takenOn,
      previous: _previous(frames),
      // Not a row: only carries the transform.
      image:
          picked.aligned ??
          PhotoCheckInImage(
            id: '',
            checkInId: '',
            angleId: angle.id,
            blobId: '',
            createdAt: now,
            updatedAt: now,
          ),
      bytes: picked.bytes,
    );
    // Cancelled, or the photo went meanwhile.
    if (aligned == null || !mounted || !identical(_picked[angle.id], picked)) {
      return;
    }
    setState(
      () => _picked[angle.id] = _Picked(picked.bytes, picked.takenOn, aligned),
    );
  }

  Future<void> _pickDate() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _takenOn,
      firstDate: DateTime(1900),
      lastDate: DateTime(now.year, now.month, now.day),
    );
    if (picked != null && mounted) setState(() => _date = picked);
  }

  Future<void> _store(
    SecureVaultSession session,
    PhotoSeriesService service,
  ) async {
    if (widget.checkIn case final checkIn?) {
      final angle = widget.angles.single;
      await service.setPhoto(
        session: session,
        checkIn: checkIn,
        angleId: angle.id,
        bytes: _picked[angle.id]!.bytes,
        aligned: _picked[angle.id]!.aligned,
      );
    } else {
      await service.createCheckIn(
        session: session,
        series: widget.series,
        takenOn: _takenOn,
        photos: {
          for (final entry in _picked.entries) entry.key: entry.value.bytes,
        },
        aligned: {
          for (final entry in _picked.entries) entry.key: ?entry.value.aligned,
        },
        note: _note.text,
      );
    }
  }

  Future<void> _save() async {
    final session = ref.read(secureVaultSessionProvider);
    if (session == null || _saving) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    final service = ref.read(photoSeriesServiceProvider);
    final save = _store(session, service);
    _openSave = save;
    try {
      await save;
    } on MediaIngestException catch (error) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = error.message;
        });
      }
      return;
    } on PhotoSeriesException catch (error) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = error.message;
        });
      }
      return;
    } catch (_) {
      // Anything else still reaches the error log, but leaves the dialog
      // usable rather than stuck on "Saving…".
      if (mounted) {
        setState(() {
          _saving = false;
          _error = 'Could not save the check-in.';
        });
      }
      rethrow;
    } finally {
      _openSave = null;
    }
    // Replacing one photo is not a check-in.
    if (mounted && !_replacing) {
      ref.read(appSoundsProvider).play(AppSound.photoCheckIn);
    }
    // A lock mid-save has already closed this; popping again would close
    // the page under it.
    if (mounted && (ModalRoute.of(context)?.isCurrent ?? false)) {
      Navigator.pop(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    // A lock takes the photos with it, and the dialog: nothing here could be
    // sealed any more.
    ref.listen(secureVaultSessionProvider, (_, session) {
      final route = ModalRoute.of(context);
      // Not once it's closing: that would close the page under it.
      if (session != null || route == null || !route.isActive) return;
      // With the camera or the date picker, when one is up.
      Navigator.of(context)
        ..popUntil((r) => r == route)
        ..pop();
    });
    _follow(ref.watch(photoSeriesSnapshotProvider).valueOrNull);
    final theme = Theme.of(context);
    final onReview = _step == _reviewStep;
    final angle = onReview ? null : _angles[_step];
    final title = _replacing
        ? '${widget.angles.single.name} photo'
        : onReview
        ? 'Check in'
        : '${angle!.name} · ${_step + 1} of ${_angles.length}';
    return VaultActivity(
      // A lock's pop goes through regardless.
      child: PopScope(
        canPop: !_asksToDiscard && !_saving,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) _cancel();
        },
        child: CallbackShortcuts(
          bindings: {
            if (!onReview) ...{
              const SingleActivator(LogicalKeyboardKey.keyV, control: true):
                  _paste,
              const SingleActivator(LogicalKeyboardKey.keyV, meta: true):
                  _paste,
            },
          },
          child: CtrlEnterToSubmitScope(
            onSubmit: _submit,
            autofocus: true,
            child: AlertDialog(
              title: Text(title),
              content: SizedBox(
                width: 440,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // None left: only why.
                    if (angle != null)
                      _intake(context, angle)
                    else if (_angles.isNotEmpty)
                      _review(),
                    if (_error case final error?)
                      Padding(
                        padding: const EdgeInsets.only(top: 12),
                        child: Text(
                          error,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.error,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              actions: _actions(onReview: onReview, angle: angle),
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> _actions({
    required bool onReview,
    required PhotoSeriesAngle? angle,
  }) {
    final cancel = GlassButton(
      onPressed: _saving ? null : _cancel,
      label: 'Cancel',
      dense: true,
    );
    if (_replacing) {
      return [
        cancel,
        GlassButton(
          onPressed: _saving || _picked.isEmpty ? null : _save,
          label: _saving ? 'Saving…' : 'Save',
          dense: true,
        ),
      ];
    }
    return [
      cancel,
      if (_step > 0)
        GlassButton(
          onPressed: _saving
              ? null
              : () => setState(() {
                  _step--;
                  _error = null;
                }),
          label: 'Back',
          dense: true,
        ),
      if (!onReview)
        GlassButton(
          onPressed: _next,
          label: _picked.containsKey(angle!.id) ? 'Next' : 'Skip',
          dense: true,
        )
      else
        // Saving with no photo is refused (§7.3).
        GlassButton(
          onPressed: _saving || _picked.isEmpty ? null : _save,
          label: _saving ? 'Saving…' : 'Save',
          dense: true,
        ),
    ];
  }

  Widget _intake(BuildContext context, PhotoSeriesAngle angle) {
    final theme = Theme.of(context);
    final picked = _picked[angle.id];
    final area = Container(
      height: 280,
      decoration: BoxDecoration(
        border: Border.all(
          color: theme.colorScheme.onSurface.withValues(alpha: 0.2),
        ),
        borderRadius: BorderRadius.circular(VoyagerTheme.fieldRadius),
      ),
      clipBehavior: Clip.antiAlias,
      child: switch (picked) {
        _Picked(:final bytes, aligned: final aligned?) => Center(
          child: AlignedPhotoFrame(
            aspect: _live(angle).frameAspect ?? kDefaultPhotoFrameAspect,
            image: aligned,
            child: PlainPhotoPreview(bytes: bytes),
          ),
        ),
        _Picked(:final bytes) => PlainPhotoPreview(bytes: bytes),
        null => Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                PhosphorIconsRegular.image,
                size: 32,
                color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
              ),
              const SizedBox(height: 8),
              Text(
                'Drop a photo here, paste one, or choose a file',
                style: theme.textTheme.bodySmall,
              ),
            ],
          ),
        ),
      },
    );
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_dropTargetsSupported)
          DropRegion(
            formats: _formats,
            onDropOver: (event) =>
                event.session.items.any((i) => _formats.any(i.canProvide))
                ? DropOperation.copy
                : DropOperation.none,
            onPerformDrop: _drop,
            child: area,
          )
        else
          area,
        const SizedBox(height: 10),
        // Onto a second line when they don't fit: with Camera, they don't.
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            if (photoCaptureSupported)
              GlassButton(
                onPressed: () => _capture(angle),
                icon: const Icon(PhosphorIconsRegular.camera, size: 13),
                label: 'Camera',
                dense: true,
              ),
            GlassButton(
              onPressed: _chooseFile,
              icon: const Icon(PhosphorIconsRegular.folderOpen, size: 13),
              label: picked == null ? 'Choose file…' : 'Choose another…',
              dense: true,
            ),
            GlassButton(
              onPressed: _paste,
              icon: const Icon(PhosphorIconsRegular.clipboard, size: 13),
              label: 'Paste',
              dense: true,
            ),
            // Over the angle's reference, which its first photo has none of.
            if (picked != null && _alignFrames(angle).isNotEmpty)
              GlassButton(
                onPressed: () => _align(angle),
                icon: const Icon(PhosphorIconsRegular.frameCorners, size: 13),
                label: 'Align',
                dense: true,
              ),
            if (picked != null)
              GlassButton(
                onPressed: () => setState(() => _picked.remove(angle.id)),
                label: 'Clear',
                dense: true,
              ),
          ],
        ),
      ],
    );
  }

  Widget _review() {
    final theme = Theme.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          height: 110,
          child: Row(
            children: [
              for (final (i, angle) in _angles.indexed)
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: InkWell(
                      // Back to that angle's step.
                      onTap: () => setState(() => _step = i),
                      child: Column(
                        children: [
                          Expanded(
                            child: Container(
                              decoration: BoxDecoration(
                                border: Border.all(
                                  color: theme.colorScheme.onSurface.withValues(
                                    alpha: 0.15,
                                  ),
                                ),
                                borderRadius: BorderRadius.circular(
                                  VoyagerTheme.fieldRadius,
                                ),
                              ),
                              clipBehavior: Clip.antiAlias,
                              child: switch (_picked[angle.id]) {
                                final picked? => PlainPhotoPreview(
                                  bytes: picked.bytes,
                                  fit: BoxFit.cover,
                                ),
                                null => Center(
                                  child: Text(
                                    'Skipped',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: theme.textTheme.bodySmall,
                                  ),
                                ),
                              },
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            angle.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.labelSmall,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 14),
        Row(
          children: [
            Text('Date', style: theme.textTheme.labelMedium),
            const SizedBox(width: 12),
            GlassButton(
              onPressed: _pickDate,
              icon: const Icon(PhosphorIconsRegular.calendarBlank, size: 13),
              label: DateFormat.yMMMEd().format(_takenOn),
              dense: true,
            ),
          ],
        ),
        const SizedBox(height: 12),
        VoyagerTextField(
          controller: _note,
          sensitive: true,
          maxLines: 4,
          minLines: 2,
          decoration: const InputDecoration(
            labelText: 'Note (optional)',
            hintText: 'Encrypted with your vault',
            isDense: true,
          ),
        ),
      ],
    );
  }
}

const _formats = [Formats.png, Formats.jpeg, Formats.webp, Formats.heic];

/// [DropRegion] needs a native channel `flutter test` doesn't have — see
/// `MediaDropTarget`.
final bool _dropTargetsSupported = !Platform.environment.containsKey(
  'FLUTTER_TEST',
);

import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:super_drag_and_drop/super_drag_and_drop.dart';
import 'package:voyager/core/media/media_clipboard.dart';
import 'package:voyager/core/theme/voyager_theme.dart';
import 'package:voyager/core/widgets/glass_button.dart';
import 'package:voyager/core/widgets/voyager_dialog.dart';
import 'package:voyager/core/widgets/voyager_text_field.dart';
import 'package:voyager/domain/models/photo_series_models.dart';
import 'package:voyager/domain/services/media_ingest.dart';
import 'package:voyager/features/notifications/secure_vault_session.dart';
import 'package:voyager/features/photo_series/photo_series_providers.dart';
import 'package:voyager/features/photo_series/photo_series_service.dart';
import 'package:voyager/features/photo_series/vault_activity.dart';
import 'package:voyager/features/photo_series/vault_image_cache.dart';

/// Opens the check-in stepper (PHOTO_SERIES_HLD.md §7.3): one step per angle
/// of [angles], each taking a file, a paste or a drop, then a review with the
/// date and note. With [checkIn] and a single angle, it gives that check-in
/// the angle's photo instead — added, or replacing the one it had.
///
/// Needs an unlocked vault, and closes if it locks.
Future<void> showPhotoCheckInDialog(
  BuildContext context, {
  required PhotoSeries series,
  required List<PhotoSeriesAngle> angles,
  PhotoCheckIn? checkIn,
}) {
  assert(checkIn == null || angles.length == 1);
  return showVoyagerDialog<void>(
    context: context,
    builder: (context) =>
        _CheckInDialog(series: series, angles: angles, checkIn: checkIn),
  );
}

/// A photo picked for one step, still plain, in memory only.
class _Picked {
  const _Picked(this.bytes, this.takenOn);

  final Uint8List bytes;

  /// When the file says it was taken: EXIF, else its modified date. Null for
  /// a paste or a drop with neither.
  final DateTime? takenOn;
}

class _CheckInDialog extends ConsumerStatefulWidget {
  const _CheckInDialog({
    required this.series,
    required this.angles,
    required this.checkIn,
  });

  final PhotoSeries series;
  final List<PhotoSeriesAngle> angles;
  final PhotoCheckIn? checkIn;

  @override
  ConsumerState<_CheckInDialog> createState() => _CheckInDialogState();
}

class _CheckInDialogState extends ConsumerState<_CheckInDialog> {
  final _picked = <String, _Picked>{};
  final _note = TextEditingController();

  /// The step on screen: an angle's index, or [_reviewStep].
  var _step = 0;
  DateTime? _date;
  String? _error;
  bool _saving = false;

  int get _reviewStep => widget.angles.length;
  bool get _replacing => widget.checkIn != null;

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
    for (final angle in widget.angles) {
      if (_picked[angle.id]?.takenOn case final takenOn?) {
        return takenOn.isAfter(today) ? today : takenOn;
      }
    }
    return today;
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
      _picked[widget.angles[_step].id] = _Picked(bytes, exif ?? fallback);
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

  Future<void> _save() async {
    final session = ref.read(secureVaultSessionProvider);
    if (session == null || _saving) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    final service = ref.read(photoSeriesServiceProvider);
    try {
      if (widget.checkIn case final checkIn?) {
        final angle = widget.angles.single;
        await service.setPhoto(
          session: session,
          checkIn: checkIn,
          angleId: angle.id,
          bytes: _picked[angle.id]!.bytes,
        );
      } else {
        await service.createCheckIn(
          session: session,
          series: widget.series,
          takenOn: _takenOn,
          photos: {
            for (final entry in _picked.entries) entry.key: entry.value.bytes,
          },
          note: _note.text,
        );
      }
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
      // Not once it's closing: that would close the page under it.
      if (session == null && (ModalRoute.of(context)?.isCurrent ?? false)) {
        Navigator.of(context).maybePop();
      }
    });
    final theme = Theme.of(context);
    final onReview = _step == _reviewStep;
    final angle = onReview ? null : widget.angles[_step];
    final title = _replacing
        ? '${widget.angles.single.name} photo'
        : onReview
        ? 'Check in'
        : '${angle!.name} · ${_step + 1} of ${widget.angles.length}';
    return VaultActivity(
      child: CallbackShortcuts(
        bindings: {
          if (!onReview) ...{
            const SingleActivator(LogicalKeyboardKey.keyV, control: true):
                _paste,
            const SingleActivator(LogicalKeyboardKey.keyV, meta: true): _paste,
          },
        },
        child: Focus(
          autofocus: true,
          child: AlertDialog(
            title: Text(title),
            content: SizedBox(
              width: 440,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (angle != null) _intake(context, angle) else _review(),
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
    );
  }

  List<Widget> _actions({
    required bool onReview,
    required PhotoSeriesAngle? angle,
  }) {
    final cancel = GlassButton(
      onPressed: _saving ? null : () => Navigator.pop(context),
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
          onPressed: () => setState(() {
            _step++;
            _error = null;
          }),
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
      child: picked != null
          ? PlainPhotoPreview(bytes: picked.bytes)
          : Center(
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
        Row(
          children: [
            GlassButton(
              onPressed: _chooseFile,
              icon: const Icon(PhosphorIconsRegular.folderOpen, size: 13),
              label: picked == null ? 'Choose file…' : 'Choose another…',
              dense: true,
            ),
            const SizedBox(width: 8),
            GlassButton(
              onPressed: _paste,
              icon: const Icon(PhosphorIconsRegular.clipboard, size: 13),
              label: 'Paste',
              dense: true,
            ),
            const Spacer(),
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
              for (final (i, angle) in widget.angles.indexed)
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

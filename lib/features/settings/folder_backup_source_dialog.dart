import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/platform/windows_folder_picker.dart';
import 'package:voyager/core/widgets/confirm_dialog.dart';
import 'package:voyager/core/widgets/glass_button.dart';
import 'package:voyager/core/widgets/voyager_dialog.dart';
import 'package:voyager/core/widgets/voyager_dropdown_button.dart';
import 'package:voyager/core/widgets/voyager_toast.dart';
import 'package:voyager/features/settings/services/folder_backup_service.dart';

/// Add folder… or Edit… (§9.4). With [source], edits it; the folder itself
/// is fixed.
Future<void> showFolderBackupSourceDialog(
  BuildContext context, {
  FolderBackupSource? source,
}) {
  return showVoyagerDialog<void>(
    context: context,
    builder: (_) => _FolderBackupSourceDialog(source: source),
  );
}

class _FolderBackupSourceDialog extends ConsumerStatefulWidget {
  const _FolderBackupSourceDialog({this.source});

  final FolderBackupSource? source;

  @override
  ConsumerState<_FolderBackupSourceDialog> createState() =>
      _FolderBackupSourceDialogState();
}

class _FolderBackupSourceDialogState
    extends ConsumerState<_FolderBackupSourceDialog> {
  late final _name = TextEditingController(text: widget.source?.name ?? '');
  late String? _folder = widget.source?.sourcePath;
  late String? _destination = widget.source?.destination;
  late Duration _interval =
      widget.source?.interval ?? defaultFolderBackupInterval;
  late int _threshold =
      widget.source?.thresholdPercent ?? defaultSizeDropThreshold;
  late bool _enabled = widget.source?.enabled ?? true;

  /// The background walk's total, once it's in.
  int? _folderBytes;
  int? _free;
  String? _error;
  bool _saving = false;

  bool get _editing => widget.source != null;

  @override
  void initState() {
    super.initState();
    if (_folder != null) unawaited(_measure());
    if (_destination != null) unawaited(_measureFree());
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _measure() async {
    final folder = _folder;
    if (folder == null) return;
    try {
      final (bytes, _) = await ref
          .read(folderBackupServiceProvider)
          .estimate(folder);
      if (mounted && folder == _folder) setState(() => _folderBytes = bytes);
    } catch (_) {
      // The estimate is a hint; saving reports what's actually wrong.
    }
  }

  Future<void> _measureFree() async {
    final destination = _destination;
    if (destination == null) return;
    final free = await ref
        .read(folderBackupServiceProvider)
        .freeBytesAt(destination);
    if (mounted && destination == _destination) setState(() => _free = free);
  }

  Future<void> _pickFolder() async {
    final picked = await pickFolder(title: 'Folder to back up');
    if (picked == null || !mounted) return;
    setState(() {
      _folder = picked;
      _folderBytes = null;
      _error = null;
      if (_name.text.trim().isEmpty) _name.text = p.basename(picked);
    });
    await _measure();
  }

  Future<void> _pickDestination() async {
    final picked = await pickFolder(title: 'Where to keep the backups');
    if (picked == null || !mounted) return;
    setState(() {
      _destination = picked;
      _free = null;
      _error = null;
    });
    await _measureFree();
  }

  Future<void> _save() async {
    final folder = _folder;
    final destination = _destination;
    if (folder == null || destination == null) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    final service = ref.read(folderBackupServiceProvider);
    try {
      final source = widget.source;
      if (source == null) {
        await service.addSource(
          name: _name.text,
          sourcePath: folder,
          destination: destination,
          interval: _interval,
          thresholdPercent: _threshold,
        );
      } else {
        // The destination is checked before anything is saved, so a refusal
        // or a cancel leaves the other edits unsaved too.
        final moved = !p.equals(destination, source.destination);
        bool? withoutMoving;
        if (moved) {
          withoutMoving = await _checkDestination(source, destination);
          if (withoutMoving == null) return;
        }
        await service.updateSource(
          source.copyWith(
            name: _name.text,
            interval: _interval,
            thresholdPercent: _threshold,
            enabled: _enabled,
          ),
        );
        if (moved && mounted) {
          _changeDestination(source, destination, withoutMoving!);
        }
      }
    } on FolderBackupFailure catch (e) {
      if (mounted) setState(() => _error = e.message);
      return;
    } finally {
      if (mounted) setState(() => _saving = false);
    }
    if (mounted) Navigator.of(context).pop();
  }

  /// §9.5. Checked here so a refusal shows in the dialog. Returns whether to
  /// change without moving, or null to stay in the dialog.
  Future<bool?> _checkDestination(
    FolderBackupSource source,
    String destination,
  ) async {
    final service = ref.read(folderBackupServiceProvider);
    await service.checkPlacement(source, destination);
    if (await Directory(source.subfolderPath).exists() ||
        await Directory(source.destination).exists()) {
      return false;
    }
    if (!mounted) return null;
    final withoutMoving = await showConfirmDialog(
      context,
      title: 'Connect ${source.destination} to move its backups',
      message:
          'Or change without moving: backups start afresh at the new '
          'destination, and the old ones stay listed as removed until the '
          'drive is back.',
      confirmLabel: 'Change without moving',
    );
    return withoutMoving && mounted ? true : null;
  }

  /// The move itself runs on after the dialog closes, with its progress on
  /// the Settings row.
  void _changeDestination(
    FolderBackupSource source,
    String destination,
    bool withoutMoving,
  ) {
    final service = ref.read(folderBackupServiceProvider);
    final overlay = Overlay.of(context, rootOverlay: true);
    unawaited(
      service
          .changeDestination(
            source.id,
            destination,
            withoutMoving: withoutMoving,
          )
          .then(
            (_) {},
            onError: (Object e) => showVoyagerToastIn(
              overlay,
              message: "Couldn't move the backups: $e",
              icon: PhosphorIconsRegular.warning,
              dwell: const Duration(seconds: 8),
            ),
          ),
    );
  }

  Future<void> _remove() async {
    final source = widget.source!;
    final confirmed = await showConfirmDialog(
      context,
      title: 'Remove ${source.name}',
      message:
          'Voyager stops backing it up. Its backups are kept and listed as '
          'removed until you delete them.',
      confirmLabel: 'Remove',
    );
    if (!confirmed) return;
    await ref.read(folderBackupServiceProvider).removeSource(source.id);
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final folder = _folder;
    final destination = _destination;
    final bytes = _folderBytes;
    final free = _free;
    // A full rotation is 7 copies of the folder (§9.4).
    final rotation = bytes == null ? null : bytes * 7;
    final tight = rotation != null && free != null && rotation > free / 2;

    Widget pathRow(String label, String? path, VoidCallback? onPick) => Row(
      children: [
        SizedBox(width: 110, child: Text(label)),
        Expanded(
          child: Text(
            path ?? 'Not chosen',
            style: path == null ? muted : null,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        if (onPick != null)
          GlassButton(dense: true, onPressed: onPick, label: 'Choose…'),
      ],
    );

    return AlertDialog(
      title: Text(_editing ? 'Edit folder backup' : 'Add folder backup'),
      content: SizedBox(
        width: 600,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            pathRow('Folder', folder, _editing ? null : _pickFolder),
            if (bytes != null)
              Padding(
                padding: const EdgeInsets.only(left: 110, bottom: 4),
                child: Text(
                  'About ${formatFolderBackupBytes(bytes)} · a full rotation '
                  'takes about ${formatFolderBackupBytes(rotation!)} '
                  '(7 × the folder)',
                  style: tight
                      ? muted?.copyWith(color: Colors.amber.shade800)
                      : muted,
                ),
              ),
            const SizedBox(height: 8),
            TextField(
              controller: _name,
              decoration: const InputDecoration(labelText: 'Name'),
            ),
            const SizedBox(height: 12),
            pathRow('Destination', destination, _pickDestination),
            if (folder != null &&
                destination != null &&
                folderBackupSameDrive(folder, destination))
              Padding(
                padding: const EdgeInsets.only(left: 110, bottom: 4),
                child: Text(
                  "This won't protect against that drive failing.",
                  style: muted,
                ),
              ),
            const SizedBox(height: 8),
            Row(
              children: [
                const SizedBox(width: 110, child: Text('Every')),
                SizedBox(
                  width: 180,
                  child: VoyagerDropdownButtonFormField<Duration>(
                    initialValue: _interval,
                    isExpanded: true,
                    items: [
                      for (final interval in folderBackupIntervals)
                        DropdownMenuItem(
                          value: interval,
                          child: Text(formatFolderBackupInterval(interval)),
                        ),
                    ],
                    onChanged: (v) => setState(() => _interval = v!),
                  ),
                ),
              ],
            ),
            Row(
              children: [
                const SizedBox(width: 110, child: Text('Warn if it shrinks')),
                Expanded(
                  child: Slider(
                    value: _threshold.toDouble(),
                    min: minSizeDropThreshold.toDouble(),
                    max: maxSizeDropThreshold.toDouble(),
                    divisions:
                        (maxSizeDropThreshold - minSizeDropThreshold) ~/ 5,
                    label: '$_threshold%',
                    onChanged: (v) => setState(() => _threshold = v.round()),
                  ),
                ),
                SizedBox(width: 48, child: Text('$_threshold%')),
              ],
            ),
            if (_editing)
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Back up this folder'),
                value: _enabled,
                onChanged: (v) => setState(() => _enabled = v),
              ),
            if (_error case final error?)
              Padding(
                padding: const EdgeInsets.only(top: 8),
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
      actions: [
        if (_editing)
          GlassButton(
            dense: true,
            onPressed: _saving ? null : _remove,
            label: 'Remove folder…',
          ),
        GlassButton(
          dense: true,
          onPressed: () => Navigator.of(context).pop(),
          label: 'Cancel',
        ),
        GlassButton(
          dense: true,
          onPressed: _saving || folder == null || destination == null
              ? null
              : _save,
          label: _editing ? 'Save' : 'Add',
        ),
      ],
    );
  }
}

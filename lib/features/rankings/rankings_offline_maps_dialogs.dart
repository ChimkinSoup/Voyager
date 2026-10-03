import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:voyager/core/widgets/confirm_dialog.dart';
import 'package:voyager/core/widgets/glass_button.dart';
import 'package:voyager/core/widgets/labeled_text_field.dart';
import 'package:voyager/core/widgets/voyager_dialog.dart';
import 'package:voyager/features/rankings/rankings_offline_maps.dart';

String _formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  const units = ['KB', 'MB', 'GB'];
  var value = bytes / 1024;
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  return '${value.toStringAsFixed(value >= 10 ? 0 : 1)} ${units[unit]}';
}

/// Asks for a name for [bounds], then downloads it for offline use.
Future<void> showRankingOfflineDownloadDialog(
  BuildContext context,
  LatLngBounds bounds,
) => showVoyagerDialog<void>(
  context: context,
  barrierDismissible: false,
  builder: (_) => _DownloadDialog(bounds: bounds),
);

class _DownloadDialog extends ConsumerStatefulWidget {
  const _DownloadDialog({required this.bounds});

  final LatLngBounds bounds;

  @override
  ConsumerState<_DownloadDialog> createState() => _DownloadDialogState();
}

class _DownloadDialogState extends ConsumerState<_DownloadDialog> {
  final _name = TextEditingController();

  /// Tiles done so far, or null before the download starts.
  int? _done;
  var _cancelled = false;
  String? _error;

  late final _network = ref.read(rankingMapNetworkTilesProvider)!;
  late final _tileCount = rankingOfflineTileCount(
    widget.bounds,
    _network.minimumZoom,
    _network.maximumZoom,
  );

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _download() async {
    final name = _name.text.trim();
    if (name.isEmpty) return;
    setState(() {
      _done = 0;
      _error = null;
    });
    try {
      await ref
          .read(rankingOfflineAreasProvider.notifier)
          .download(
            name: name,
            bounds: widget.bounds,
            network: _network,
            onProgress: (done) {
              if (mounted) setState(() => _done = done);
            },
            cancelled: () => _cancelled,
          );
      if (mounted) Navigator.of(context).pop();
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _done = null;
        _error =
            'The download stopped partway. Check your connection and try '
            'again.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final done = _done;
    final tooBig = _tileCount > rankingOfflineMaxTiles;

    return AlertDialog(
      title: const Text('Download this area'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Keeps the part of the map on screen on this device, so it '
              'draws without a connection.',
              style: muted,
            ),
            const SizedBox(height: 12),
            if (tooBig)
              Text(
                'This area is too large to download ($_tileCount tiles, the '
                'most is $rankingOfflineMaxTiles). Zoom in and try again.',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.error,
                ),
              )
            else if (done == null) ...[
              LabeledTextField(
                label: 'Name',
                controller: _name,
                hintText: 'e.g. Downtown',
                autofocus: true,
                onChanged: (_) => setState(() {}),
                onSubmitted: (_) => _download(),
              ),
              const SizedBox(height: 8),
              Text('$_tileCount tiles', style: muted),
            ] else ...[
              LinearProgressIndicator(value: done / _tileCount),
              const SizedBox(height: 8),
              Text('$done of $_tileCount tiles', style: muted),
            ],
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(
                _error!,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
            ],
          ],
        ),
      ),
      actions: [
        GlassButton(
          dense: true,
          label: 'Cancel',
          onPressed: () {
            _cancelled = true;
            Navigator.of(context).pop();
          },
        ),
        if (!tooBig && done == null)
          GlassButton(
            dense: true,
            label: 'Download',
            onPressed: _name.text.trim().isEmpty ? null : _download,
          ),
      ],
    );
  }
}

/// How much the downloaded areas take up, opening their list.
class RankingOfflineMapsTile extends ConsumerWidget {
  const RankingOfflineMapsTile({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final areas = ref.watch(rankingOfflineAreasProvider).valueOrNull;
    final bytes = areas?.fold<int>(0, (sum, area) => sum + area.byteSize);
    return ListTile(
      title: const Text('Offline maps'),
      subtitle: Text(
        areas == null
            ? 'Measuring…'
            : areas.isEmpty
            ? 'None yet. Download an area from the Rankings map'
            : '${areas.length} ${areas.length == 1 ? 'area' : 'areas'}'
                  ' · ${_formatBytes(bytes!)}',
      ),
      trailing: const Icon(PhosphorIconsRegular.mapTrifold),
      onTap: () => showVoyagerDialog<void>(
        context: context,
        builder: (_) => const _OfflineMapsDialog(),
      ),
    );
  }
}

class _OfflineMapsDialog extends ConsumerStatefulWidget {
  const _OfflineMapsDialog();

  @override
  ConsumerState<_OfflineMapsDialog> createState() => _OfflineMapsDialogState();
}

class _OfflineMapsDialogState extends ConsumerState<_OfflineMapsDialog> {
  var _busy = false;

  Future<void> _delete(List<RankingOfflineArea> areas) async {
    final confirmed = await showConfirmDialog(
      context,
      title: areas.length == 1
          ? 'Delete offline map'
          : 'Delete all offline maps',
      message: areas.length == 1
          ? 'Removes "${areas.single.name}" from this device. Its map will '
                'need a connection again.'
          : 'Removes all ${areas.length} areas from this device. Their maps '
                'will need a connection again.',
      confirmLabel: areas.length == 1 ? 'Delete' : 'Delete all',
    );
    if (!confirmed || !mounted) return;
    setState(() => _busy = true);
    final notifier = ref.read(rankingOfflineAreasProvider.notifier);
    for (final area in areas) {
      await notifier.delete(area.id);
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final areas = ref.watch(rankingOfflineAreasProvider).valueOrNull;
    final bytes = areas?.fold<int>(0, (sum, area) => sum + area.byteSize);

    return AlertDialog(
      title: const Text('Offline maps'),
      contentPadding: const EdgeInsets.fromLTRB(24, 12, 24, 0),
      content: SizedBox(
        width: 480,
        height: 360,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Areas of the Rankings map kept on this device. Download one '
              'with the download button on the map.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            if (bytes != null && areas!.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                '${_formatBytes(bytes)} on disk',
                style: theme.textTheme.labelMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
            const SizedBox(height: 12),
            Expanded(
              child: areas == null
                  ? const Center(child: CircularProgressIndicator())
                  : areas.isEmpty
                  ? Center(
                      child: Text(
                        'No offline maps.',
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    )
                  : ListView(
                      children: [
                        for (final area in areas)
                          ListTile(
                            contentPadding: EdgeInsets.zero,
                            title: Text(area.name),
                            subtitle: Text(
                              '${_formatBytes(area.byteSize)}'
                              ' · ${area.tileCount} tiles',
                            ),
                            trailing: IconButton(
                              tooltip: 'Delete',
                              icon: Icon(
                                PhosphorIconsRegular.trash,
                                color: theme.colorScheme.error,
                              ),
                              onPressed: _busy ? null : () => _delete([area]),
                            ),
                          ),
                      ],
                    ),
            ),
          ],
        ),
      ),
      actions: [
        if (areas != null && areas.length > 1)
          GlassButton(
            dense: true,
            onPressed: _busy ? null : () => _delete(areas),
            label: 'Delete all',
            color: theme.colorScheme.error,
          ),
        GlassButton(
          dense: true,
          onPressed: _busy ? null : () => Navigator.of(context).pop(),
          label: 'Close',
        ),
      ],
    );
  }
}

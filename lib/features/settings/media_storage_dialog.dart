import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/media/widgets/media_image.dart';
import 'package:voyager/core/media/widgets/media_lightbox.dart';
import 'package:voyager/core/widgets/confirm_dialog.dart';
import 'package:voyager/core/widgets/glass_button.dart';
import 'package:voyager/core/widgets/voyager_dialog.dart';
import 'package:voyager/domain/models/media_models.dart';

/// Every stored image and how many live references still point at it.
class MediaLibraryEntry {
  const MediaLibraryEntry({required this.asset, required this.referenceCount});

  final MediaAsset asset;
  final int referenceCount;
}

Future<void> showMediaStorageDialog(BuildContext context) {
  return showVoyagerDialog<void>(
    context: context,
    builder: (_) => const _MediaStorageDialog(),
  );
}

class _MediaStorageDialog extends ConsumerStatefulWidget {
  const _MediaStorageDialog();

  @override
  ConsumerState<_MediaStorageDialog> createState() =>
      _MediaStorageDialogState();
}

class _MediaStorageDialogState extends ConsumerState<_MediaStorageDialog> {
  var _entries = const <MediaLibraryEntry>[];
  var _loaded = false;
  var _busy = false;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    final service = ref.read(mediaServiceProvider);
    final assets = await service.repository.listAssets();
    final entries = <MediaLibraryEntry>[];
    for (final asset in assets) {
      final references = await service.repository.listReferencesForAsset(
        asset.id,
      );
      entries.add(
        MediaLibraryEntry(asset: asset, referenceCount: references.length),
      );
    }
    entries.sort((a, b) => b.asset.createdAt.compareTo(a.asset.createdAt));
    if (!mounted) return;
    setState(() {
      _entries = entries;
      _loaded = true;
    });
  }

  void _invalidateUsage() {
    ref.invalidate(mediaStorageUsageProvider);
    ref.invalidate(mediaDiskLowProvider);
  }

  Future<void> _deleteOne(MediaAsset asset) async {
    final confirmed = await showConfirmDialog(
      context,
      title: 'Delete image',
      message:
          'This removes the image from every entry that uses it and deletes '
          'the copy on this device immediately.',
    );
    if (!confirmed || !mounted) return;

    setState(() => _busy = true);
    await ref
        .read(mediaServiceProvider)
        .deleteAssetEverywhere(
          asset.id,
          storage: ref.read(mediaStorageProvider),
        );
    _invalidateUsage();
    if (!mounted) return;
    await _reload();
    if (!mounted) return;
    setState(() => _busy = false);
  }

  Future<void> _deleteAll() async {
    if (_entries.isEmpty) return;
    final count = _entries.length;
    final confirmed = await showConfirmDialog(
      context,
      title: 'Delete all images',
      message:
          'This removes all $count ${count == 1 ? 'image' : 'images'} from '
          'everywhere they are attached and deletes their local copies '
          'immediately.',
      confirmLabel: 'Delete all',
    );
    if (!confirmed || !mounted) return;

    setState(() => _busy = true);
    final service = ref.read(mediaServiceProvider);
    final storage = ref.read(mediaStorageProvider);
    for (final entry in [..._entries]) {
      await service.deleteAssetEverywhere(entry.asset.id, storage: storage);
    }
    _invalidateUsage();
    if (!mounted) return;
    await _reload();
    if (!mounted) return;
    setState(() => _busy = false);
  }

  void _openLightbox(int index) {
    showMediaLightbox(
      context,
      assets: [for (final entry in _entries) entry.asset],
      initialIndex: index,
    );
  }

  static String _formatBytes(int bytes) {
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

  @override
  Widget build(BuildContext context) {
    ref.listen(mediaServiceProvider, (_, _) => _reload());

    final theme = Theme.of(context);
    final usage = ref.watch(mediaStorageUsageProvider).valueOrNull;
    final summary = usage == null
        ? 'Measuring…'
        : '${usage.assetCount} ${usage.assetCount == 1 ? 'image' : 'images'}'
              ' · ${_formatBytes(usage.byteSize)} on disk';

    return AlertDialog(
      title: const Text('Image storage'),
      contentPadding: const EdgeInsets.fromLTRB(24, 12, 24, 0),
      content: SizedBox(
        width: 560,
        height: 420,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Browse every image stored on this device. Deleting one removes '
              'it from every journal entry, task, and card that uses it.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              summary,
              style: theme.textTheme.labelMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 12),
            Expanded(
              child: !_loaded
                  ? const Center(child: CircularProgressIndicator())
                  : _entries.isEmpty
                  ? Center(
                      child: Text(
                        'No images stored.',
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    )
                  : GridView.builder(
                      gridDelegate:
                          const SliverGridDelegateWithFixedCrossAxisCount(
                            crossAxisCount: 4,
                            mainAxisSpacing: 8,
                            crossAxisSpacing: 8,
                          ),
                      itemCount: _entries.length,
                      itemBuilder: (context, index) {
                        final entry = _entries[index];
                        return _GridTile(
                          entry: entry,
                          busy: _busy,
                          onOpen: () => _openLightbox(index),
                          onDelete: () => _deleteOne(entry.asset),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
      actions: [
        if (_entries.isNotEmpty)
          GlassButton(
            dense: true,
            onPressed: _busy ? null : _deleteAll,
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

class _GridTile extends StatelessWidget {
  const _GridTile({
    required this.entry,
    required this.busy,
    required this.onOpen,
    required this.onDelete,
  });

  final MediaLibraryEntry entry;
  final bool busy;
  final VoidCallback onOpen;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final references = entry.referenceCount;

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: busy ? null : onOpen,
        child: Stack(
          fit: StackFit.expand,
          children: [
            MediaImage(
              asset: entry.asset,
              fit: BoxFit.cover,
              borderRadius: BorderRadius.circular(8),
            ),
            if (references > 0)
              Positioned(
                left: 4,
                bottom: 4,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surface.withValues(alpha: 0.88),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 5,
                      vertical: 2,
                    ),
                    child: Text(
                      references == 1 ? '1 use' : '$references uses',
                      style: theme.textTheme.labelSmall,
                    ),
                  ),
                ),
              ),
            Positioned(
              top: 4,
              right: 4,
              child: Material(
                color: theme.colorScheme.surface.withValues(alpha: 0.88),
                borderRadius: BorderRadius.circular(6),
                child: InkWell(
                  onTap: busy ? null : onDelete,
                  borderRadius: BorderRadius.circular(6),
                  child: Padding(
                    padding: const EdgeInsets.all(4),
                    child: Icon(
                      PhosphorIconsRegular.trash,
                      size: 14,
                      color: theme.colorScheme.error,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}


import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:super_drag_and_drop/super_drag_and_drop.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/media/media_clipboard.dart';
import 'package:voyager/core/media/widgets/media_attach.dart';
import 'package:voyager/core/media/widgets/media_image.dart';
import 'package:voyager/core/media/widgets/media_lightbox.dart';
import 'package:voyager/core/soft_delete/soft_delete_toast.dart';
import 'package:voyager/core/widgets/confirm_dialog.dart';
import 'package:voyager/domain/models/media_models.dart';
import 'package:voyager/core/widgets/scroll_offset_isolate.dart';

/// The shared ordered-image strip.
///
/// The whole of a feature's integration: hand it `(collection, documentId)`
/// and it owns attaching, ordering, removing, the lightbox and every transfer
/// state. Nothing about todo, rankings or any other surface is known here —
/// which is what the design means by adding images to a page being a matter
/// of passing an owner rather than writing upload code.
class MediaGalleryStrip extends ConsumerStatefulWidget {
  const MediaGalleryStrip({
    super.key,
    required this.collection,
    required this.documentId,
    this.facet = MediaFacet.gallery,
    this.accentColor,
    this.thumbnailSize = 72,
    this.emptyLabel = 'Add images',
  });

  final String collection;
  final String documentId;
  final MediaFacet facet;
  final Color? accentColor;
  final double thumbnailSize;
  final String emptyLabel;

  @override
  ConsumerState<MediaGalleryStrip> createState() => _MediaGalleryStripState();
}

class _MediaGalleryStripState extends ConsumerState<MediaGalleryStrip> {
  var _references = const <MediaReference>[];
  var _assets = const <MediaAsset>[];
  var _busy = false;
  bool _dropActive = false;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  @override
  void didUpdateWidget(MediaGalleryStrip oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.documentId != widget.documentId ||
        oldWidget.collection != widget.collection ||
        oldWidget.facet != widget.facet) {
      _reload();
    }
  }

  Future<void> _reload() async {
    // Guarded before `ref`, not just before `setState`. The strip lives inside
    // a journal entry or task editor the user is free to close during the undo
    // window, and `ref.read` on a disposed State throws a `StateError` —
    // swallowed by the undo's crash guard, so the reference came back on disk
    // with the failure invisible.
    if (!mounted) return;
    final service = ref.read(mediaServiceProvider);
    final references = await service.referencesFor(
      widget.collection,
      widget.documentId,
      facet: widget.facet,
    );
    final assets = await service.assetsFor(references);
    if (!mounted) return;
    setState(() {
      _references = references;
      _assets = assets;
    });
  }

  /// Runs an attach, showing the strip's busy state while it is in flight.
  Future<void> _ingestAll(List<Uint8List> images) async {
    if (images.isEmpty || _busy) return;
    setState(() => _busy = true);
    try {
      await attachImagesForOwner(
        ref,
        messenger: ScaffoldMessenger.of(context),
        overlay: Overlay.of(context, rootOverlay: true),
        images: images,
        collection: widget.collection,
        documentId: widget.documentId,
        facet: widget.facet,
      );
    } finally {
      if (mounted) setState(() => _busy = false);
      await _reload();
    }
  }

  Future<void> _pickFiles() async => _ingestAll(await pickImageFiles());

  /// Ctrl/Cmd+V onto the strip.
  ///
  /// Only the image half of the clipboard is consumed here — a strip has no
  /// text to paste into, so text on the clipboard is simply left alone rather
  /// than being dropped somewhere it was not asked for.
  Future<void> _pasteFromClipboard() async {
    final contents = await const MediaClipboard().read();
    if (!contents.hasImage) return;
    await _ingestAll([contents.imageBytes!]);
  }

  Future<void> _remove(MediaReference reference) async {
    // Captured before the confirm: removing the image rebuilds the strip, and
    // the toast offering the undo has to outlive the tile that asked for it.
    final container = ProviderScope.containerOf(context, listen: false);
    final overlay = Overlay.of(context, rootOverlay: true);

    final confirmed = await showConfirmDialog(
      context,
      title: 'Remove image',
      message:
          'The image is removed from this item. It is kept for 30 days before '
          'being deleted for good.',
      confirmLabel: 'Remove',
    );
    if (!confirmed) return;
    final media = container.read(mediaServiceProvider);
    await softDeleteWithUndo(
      overlay: overlay,
      message: 'Image removed',
      delete: () async {
        await media.removeReference(reference.id);
        await _reload();
      },
      // Detaching a reference is not deleting the picture, so the message says
      // "removed" rather than "deleted" — the blob only starts its own 30-day
      // clock once nothing points at it.
      restore: () async {
        await media.restoreReference(reference);
        await _reload();
      },
    );
  }

  /// [newIndex] is already adjusted for the removal — that is what
  /// `onReorderItem` does, and why it is used in place of the deprecated
  /// `onReorder`, which would need the index corrected by hand.
  Future<void> _reorder(int oldIndex, int newIndex) async {
    final ordered = [..._references];
    ordered.insert(newIndex, ordered.removeAt(oldIndex));
    setState(() => _references = ordered);
    await ref.read(mediaServiceProvider).reorderReferences(ordered);
    await _reload();
  }

  void _openLightbox(int index) {
    showMediaLightbox(context, assets: _assets, initialIndex: index);
  }

  @override
  Widget build(BuildContext context) {
    // Re-reads the rows when anything in the module changes — a finished
    // upload clearing a badge, a purge on another surface. Watching alone
    // would only repaint the snapshots this state already holds, so the
    // badge would stay on an image that had long since synced.
    //
    // `_reload` calls setState rather than notifying the service, so this
    // cannot feed itself.
    ref.listen(mediaServiceProvider, (_, _) => _reload());

    final theme = Theme.of(context);
    final accent = widget.accentColor ?? theme.colorScheme.primary;

    return DropRegion(
      formats: const [Formats.png, Formats.jpeg, Formats.webp, Formats.heic],
      onDropOver: (event) {
        final accepted = event.session.items.any(
          (item) =>
              item.canProvide(Formats.png) ||
              item.canProvide(Formats.jpeg) ||
              item.canProvide(Formats.webp) ||
              item.canProvide(Formats.heic),
        );
        if (accepted != _dropActive) {
          // Scheduled out of the hit-test callback: setState during a drop
          // event runs inside the platform's own dispatch.
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) setState(() => _dropActive = accepted);
          });
        }
        return accepted ? DropOperation.copy : DropOperation.none;
      },
      onDropLeave: (_) {
        if (mounted) setState(() => _dropActive = false);
      },
      onPerformDrop: (event) async {
        if (mounted) setState(() => _dropActive = false);
        final images = <Uint8List>[];
        for (final item in event.session.items) {
          final reader = item.dataReader;
          if (reader == null) continue;
          final bytes = await MediaClipboard.readImageFrom(reader);
          if (bytes != null) images.add(bytes);
        }
        await _ingestAll(images);
      },
      child: Shortcuts(
        shortcuts: const {
          SingleActivator(LogicalKeyboardKey.keyV, control: true):
              _PasteImageIntent(),
          SingleActivator(LogicalKeyboardKey.keyV, meta: true):
              _PasteImageIntent(),
        },
        child: Actions(
          actions: {
            _PasteImageIntent: CallbackAction<_PasteImageIntent>(
              onInvoke: (_) {
                _pasteFromClipboard();
                return null;
              },
            ),
          },
          child: Focus(
            canRequestFocus: true,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 140),
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: _dropActive
                      ? accent
                      : theme.dividerColor.withValues(alpha: 0.5),
                  width: _dropActive ? 1.5 : 1,
                ),
              ),
              child: _references.isEmpty
                  ? _EmptyStrip(
                      label: widget.emptyLabel,
                      accent: accent,
                      busy: _busy,
                      onPick: _pickFiles,
                    )
                  : _Thumbnails(
                      references: _references,
                      assets: _assets,
                      size: widget.thumbnailSize,
                      accent: accent,
                      busy: _busy,
                      onOpen: _openLightbox,
                      onRemove: _remove,
                      onReorder: _reorder,
                      onPick: _pickFiles,
                    ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Intent for the strip's paste shortcut, so Ctrl+V is bound through the
/// shortcut system rather than a raw key listener that would fight the text
/// fields around it.
class _PasteImageIntent extends Intent {
  const _PasteImageIntent();
}

class _EmptyStrip extends StatelessWidget {
  const _EmptyStrip({
    required this.label,
    required this.accent,
    required this.busy,
    required this.onPick,
  });

  final String label;
  final Color accent;
  final bool busy;
  final Future<void> Function() onPick;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: busy ? null : onPick,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 8),
        child: Row(
          children: [
            Icon(PhosphorIconsRegular.imageSquare, size: 18, color: accent),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                busy ? 'Adding…' : label,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.65),
                ),
              ),
            ),
            Text(
              'Paste, drop or click',
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onSurface.withValues(alpha: 0.4),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Thumbnails extends StatelessWidget {
  const _Thumbnails({
    required this.references,
    required this.assets,
    required this.size,
    required this.accent,
    required this.busy,
    required this.onOpen,
    required this.onRemove,
    required this.onReorder,
    required this.onPick,
  });

  final List<MediaReference> references;
  final List<MediaAsset> assets;
  final double size;
  final Color accent;
  final bool busy;
  final void Function(int index) onOpen;
  final Future<void> Function(MediaReference reference) onRemove;
  final Future<void> Function(int oldIndex, int newIndex) onReorder;
  final Future<void> Function() onPick;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: size + 12,
      // This horizontal strip sits inside vertically scrolling editors and
      // panels, and would otherwise adopt their offset when it mounts —
      // see [ScrollOffsetIsolate].
      child: ScrollOffsetIsolate(
        child: ReorderableListView.builder(
          scrollDirection: Axis.horizontal,
          buildDefaultDragHandles: false,
          onReorderItem: onReorder,
          // The trailing "+" is a footer rather than a list item, so it cannot
          // be dragged into the middle of the order.
          footer: Padding(
            padding: const EdgeInsets.only(left: 6),
            child: _AddButton(accent: accent, busy: busy, onPick: onPick),
          ),
          itemCount: references.length,
          itemBuilder: (context, index) {
            final reference = references[index];
            // The asset list is built by skipping rows whose asset has gone, so
            // it can be shorter than the reference list.
            final asset = index < assets.length ? assets[index] : null;
            return ReorderableDragStartListener(
              key: ValueKey(reference.id),
              index: index,
              child: Padding(
                padding: const EdgeInsets.only(right: 6),
                child: _Thumbnail(
                  asset: asset,
                  size: size,
                  onOpen: () => onOpen(index),
                  onRemove: () => onRemove(reference),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

class _Thumbnail extends StatefulWidget {
  const _Thumbnail({
    required this.asset,
    required this.size,
    required this.onOpen,
    required this.onRemove,
  });

  final MediaAsset? asset;
  final double size;
  final VoidCallback onOpen;
  final Future<void> Function() onRemove;

  @override
  State<_Thumbnail> createState() => _ThumbnailState();
}

class _ThumbnailState extends State<_Thumbnail> {
  var _hovered = false;

  @override
  Widget build(BuildContext context) {
    final asset = widget.asset;
    if (asset == null) return SizedBox.square(dimension: widget.size);

    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onOpen,
        child: SizedBox.square(
          dimension: widget.size,
          child: Stack(
            fit: StackFit.expand,
            children: [
              MediaImage(asset: asset, fit: BoxFit.cover),
              if (MediaTransferBadge.isPending(asset))
                Positioned(
                  left: 3,
                  bottom: 3,
                  child: MediaTransferBadge(asset: asset),
                ),
              // Remove appears on hover only, so a strip at rest is images
              // rather than images plus a row of controls.
              if (_hovered)
                Positioned(
                  top: 2,
                  right: 2,
                  child: _ThumbnailAction(
                    icon: PhosphorIconsRegular.x,
                    tooltip: 'Remove image',
                    onPressed: widget.onRemove,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ThumbnailAction extends StatelessWidget {
  const _ThumbnailAction({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });

  final IconData icon;
  final String tooltip;
  final Future<void> Function() onPressed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: () => onPressed(),
        borderRadius: BorderRadius.circular(6),
        child: Container(
          padding: const EdgeInsets.all(3),
          decoration: BoxDecoration(
            color: theme.colorScheme.surface.withValues(alpha: 0.85),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Icon(icon, size: 12, color: theme.colorScheme.onSurface),
        ),
      ),
    );
  }
}

class _AddButton extends StatelessWidget {
  const _AddButton({
    required this.accent,
    required this.busy,
    required this.onPick,
  });

  final Color accent;
  final bool busy;
  final Future<void> Function() onPick;

  @override
  Widget build(BuildContext context) {
    // The border and the ink have to be the same box, or the highlight sits
    // inset from the outline and the tile lights up with an unlit ring around
    // it. [Ink] paints the decoration into the Material's own ink layer, so
    // the [InkWell] beneath it is bounded by exactly the shape that is
    // drawn — and the local Material clips the splash to the same radius
    // rather than letting the far-away ancestor Material square it off.
    return Tooltip(
      message: 'Add images',
      child: Material(
        type: MaterialType.transparency,
        borderRadius: BorderRadius.circular(10),
        clipBehavior: Clip.antiAlias,
        child: Ink(
          width: 44,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: accent.withValues(alpha: 0.5)),
          ),
          child: InkWell(
            onTap: busy ? null : () => onPick(),
            borderRadius: BorderRadius.circular(10),
            child: busy
                ? Center(
                    child: SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: accent,
                      ),
                    ),
                  )
                : Icon(PhosphorIconsRegular.plus, size: 16, color: accent),
          ),
        ),
      ),
    );
  }
}

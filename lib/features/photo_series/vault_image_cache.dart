import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/secure_vault/vault_media_service.dart';
import 'package:voyager/features/notifications/secure_vault_session.dart';
import 'package:voyager/features/photo_series/photo_series_providers.dart';

/// Decoded vault photos, in memory only (PHOTO_SERIES_HLD.md §6.3).
///
/// Not Flutter's image cache: that one outlives a lock, and keeps encoded
/// bytes besides. Each cache belongs to one unlocked session and is disposed
/// when it ends, its images with it. Callers get their own [ui.Image.clone]
/// and dispose it, so evicting here never pulls an image out from under a
/// widget still painting it.
class VaultImageCache {
  VaultImageCache({required this._media, required this._session});

  final VaultMediaService _media;
  final SecureVaultSession _session;

  /// Thumbnails are 384 px, about 0.6 MB decoded; full images up to 2048
  /// px, about 16 MB.
  static const _thumbCapacity = 150;
  static const _fullCapacity = 6;

  /// Least recently used first.
  final _thumbs = <String, ui.Image>{};
  final _full = <String, ui.Image>{};
  final _loading = <String, Future<void>>{};
  bool _disposed = false;

  /// [blobId]'s thumbnail, or its full image without [thumb], as a clone the
  /// caller disposes. Null when it can't be had yet — not downloaded, or
  /// never to open under this vault.
  Future<ui.Image?> load(String blobId, {required bool thumb}) async {
    final cache = thumb ? _thumbs : _full;
    final hit = cache.remove(blobId);
    if (hit != null) {
      cache[blobId] = hit;
      return hit.clone();
    }
    final key = '${thumb ? 't' : 'f'}:$blobId';
    await (_loading[key] ??= _decode(blobId, thumb: thumb).whenComplete(() {
      // A block, not an arrow: the arrow would return the removed future —
      // this one — and whenComplete would wait on it forever.
      _loading.remove(key);
    }));
    if (_disposed) return null;
    // Looked up again rather than handed over: every caller waiting on the
    // one decode takes its own clone.
    return cache[blobId]?.clone();
  }

  Future<void> _decode(String blobId, {required bool thumb}) async {
    final blob = await _media.repository.getBlob(blobId);
    if (blob == null || _disposed) return;
    final bytes = await _media.open(blob, _session.key, thumb: thumb);
    if (bytes == null || _disposed) return;
    final ui.FrameInfo frame;
    try {
      final codec = await ui.instantiateImageCodec(bytes);
      frame = await codec.getNextFrame();
      codec.dispose();
    } catch (error) {
      // Opened but not an image — nothing a retry would change.
      debugPrint('[vault media] could not decode $blobId: $error');
      return;
    }
    if (_disposed) {
      frame.image.dispose();
      return;
    }
    final cache = thumb ? _thumbs : _full;
    cache.remove(blobId)?.dispose();
    cache[blobId] = frame.image;
    while (cache.length > (thumb ? _thumbCapacity : _fullCapacity)) {
      final oldest = cache.keys.first;
      cache.remove(oldest)!.dispose();
    }
  }

  void dispose() {
    _disposed = true;
    for (final image in [..._thumbs.values, ..._full.values]) {
      image.dispose();
    }
    _thumbs.clear();
    _full.clear();
  }
}

/// One vault photo, decrypted into memory and painted. While locked, or
/// until the file is here, it shows [placeholder].
class VaultPhoto extends ConsumerStatefulWidget {
  const VaultPhoto({
    super.key,
    required this.blobId,
    required this.thumb,
    this.fit = BoxFit.cover,
    this.placeholder,
  });

  final String blobId;
  final bool thumb;
  final BoxFit fit;
  final Widget? placeholder;

  @override
  ConsumerState<VaultPhoto> createState() => _VaultPhotoState();
}

class _VaultPhotoState extends ConsumerState<VaultPhoto> {
  ui.Image? _image;
  VaultImageCache? _cache;
  bool _loading = false;

  @override
  void didUpdateWidget(VaultPhoto oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.blobId != widget.blobId || oldWidget.thumb != widget.thumb) {
      _setImage(null);
      _load();
    }
  }

  @override
  void dispose() {
    _image?.dispose();
    super.dispose();
  }

  void _setImage(ui.Image? image) {
    _image?.dispose();
    _image = image;
  }

  Future<void> _load() async {
    final cache = _cache;
    if (cache == null || _loading) return;
    _loading = true;
    final blobId = widget.blobId;
    final thumb = widget.thumb;
    final ui.Image? image;
    try {
      image = await cache.load(blobId, thumb: thumb);
    } catch (error) {
      // Left to the next notification to try again.
      debugPrint('[vault media] could not show $blobId: $error');
      return;
    } finally {
      _loading = false;
    }
    if (!mounted ||
        cache != _cache ||
        blobId != widget.blobId ||
        thumb != widget.thumb) {
      image?.dispose();
      // The widget moved on mid-load, and its own load bailed on this one.
      if (mounted) _load();
      return;
    }
    setState(() => _setImage(image));
  }

  @override
  Widget build(BuildContext context) {
    final cache = ref.watch(vaultImageCacheProvider);
    if (cache != _cache) {
      _cache = cache;
      _setImage(null);
      if (cache != null) _load();
    }
    // A download landing is the cue to try a photo that wasn't here.
    ref.listen(vaultMediaServiceProvider, (_, _) {
      if (_image == null) _load();
    });
    final image = _image;
    if (image == null) {
      return widget.placeholder ?? const _PhotoPlaceholder();
    }
    return RawImage(
      image: image,
      fit: widget.fit,
      filterQuality: FilterQuality.medium,
    );
  }
}

class _PhotoPlaceholder extends StatelessWidget {
  const _PhotoPlaceholder();

  @override
  Widget build(BuildContext context) => ColoredBox(
    color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.06),
  );
}

/// Plain bytes not yet sealed — a photo picked for a check-in — decoded and
/// painted without passing through Flutter's image cache.
class PlainPhotoPreview extends StatefulWidget {
  const PlainPhotoPreview({
    super.key,
    required this.bytes,
    this.fit = BoxFit.contain,
  });

  final Uint8List bytes;
  final BoxFit fit;

  @override
  State<PlainPhotoPreview> createState() => _PlainPhotoPreviewState();
}

class _PlainPhotoPreviewState extends State<PlainPhotoPreview> {
  ui.Image? _image;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _decode();
  }

  @override
  void didUpdateWidget(PlainPhotoPreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.bytes, widget.bytes)) _decode();
  }

  @override
  void dispose() {
    _image?.dispose();
    super.dispose();
  }

  Future<void> _decode() async {
    final bytes = widget.bytes;
    try {
      final codec = await ui.instantiateImageCodec(bytes, targetWidth: 1024);
      final frame = await codec.getNextFrame();
      codec.dispose();
      if (!mounted || !identical(bytes, widget.bytes)) {
        frame.image.dispose();
        return;
      }
      setState(() {
        _image?.dispose();
        _image = frame.image;
        _failed = false;
      });
    } catch (_) {
      // HEIC on a Windows without the codec: ingest says so on save.
      if (mounted) setState(() => _failed = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final image = _image;
    if (image == null) {
      return _failed
          ? const Center(child: Text('No preview'))
          : const _PhotoPlaceholder();
    }
    return RawImage(image: image, fit: widget.fit);
  }
}

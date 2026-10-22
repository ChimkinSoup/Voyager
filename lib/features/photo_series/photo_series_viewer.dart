import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:voyager/core/theme/voyager_theme.dart';
import 'package:voyager/domain/models/photo_series_models.dart';
import 'package:voyager/features/notifications/secure_vault_session.dart';
import 'package:voyager/features/photo_series/photo_frame.dart';
import 'package:voyager/features/photo_series/photo_series_providers.dart';
import 'package:voyager/features/photo_series/photo_series_service.dart';
import 'package:voyager/features/photo_series/vault_activity.dart';
import 'package:voyager/features/photo_series/vault_image_cache.dart';

/// One check-in as the viewer pages through it: its photos by angle id.
typedef PhotoViewerEntry = ({
  PhotoCheckIn checkIn,
  Map<String, PhotoCheckInImage> images,
});

/// What the viewer shows of a snapshot: the check-ins it pages through,
/// oldest first, and the series' angles.
typedef PhotoViewerContents = ({
  List<PhotoViewerEntry> entries,
  List<PhotoSeriesAngle> angles,
});

/// The full-screen viewer (PHOTO_SERIES_HLD.md §7.2): one check-in at a
/// time, left and right to its neighbours, up and down through its angles,
/// with the note underneath, each photo aligned onto its angle's frame.
/// Opens on [initialCheckInId]. Reads [contents] from each snapshot, so a
/// check-in or photo arriving from another device shows while it is open
/// (BUG-305). Closes when the vault locks, or nothing is left to show.
Future<void> showPhotoSeriesViewer(
  BuildContext context, {
  required PhotoViewerContents Function(PhotoSeriesSnapshot snapshot) contents,
  required String initialCheckInId,
}) {
  return Navigator.of(context, rootNavigator: true).push(
    PageRouteBuilder<void>(
      opaque: false,
      barrierColor: Colors.black87,
      barrierDismissible: true,
      barrierLabel: 'Close photo',
      pageBuilder: (_, _, _) =>
          _PhotoViewer(contents: contents, initialCheckInId: initialCheckInId),
      transitionsBuilder: (_, animation, _, child) =>
          FadeTransition(opacity: animation, child: child),
      transitionDuration: const Duration(milliseconds: 160),
    ),
  );
}

class _PhotoViewer extends ConsumerStatefulWidget {
  const _PhotoViewer({required this.contents, required this.initialCheckInId});

  final PhotoViewerContents Function(PhotoSeriesSnapshot snapshot) contents;
  final String initialCheckInId;

  @override
  ConsumerState<_PhotoViewer> createState() => _PhotoViewerState();
}

class _PhotoViewerState extends ConsumerState<_PhotoViewer> {
  /// The snapshot [_contents] was read from.
  late PhotoSeriesSnapshot? _snapshot = ref
      .read(photoSeriesSnapshotProvider)
      .valueOrNull;
  late PhotoViewerContents _contents = switch (_snapshot) {
    final snapshot? => widget.contents(snapshot),
    null => (entries: const [], angles: const []),
  };
  late int _index = math.max(
    0,
    _contents.entries.indexWhere(
      (e) => e.checkIn.id == widget.initialCheckInId,
    ),
  );
  late final _pages = PageController(initialPage: _index);

  /// The check-in being looked at, kept as the list around it changes.
  late String _checkInId = widget.initialCheckInId;

  /// The angle being looked at, kept across check-ins where it can be.
  String? _angleId;
  final _zoom = <String, TransformationController>{};
  bool _zoomed = false;

  /// Notes opened so far, by check-in id.
  final _notes = <String, Future<String?>>{};

  List<PhotoViewerEntry> get _entries => _contents.entries;

  /// Takes [snapshot]'s contents, staying on the same check-in — or, when
  /// it is gone, on the one now in its place.
  void _follow(PhotoSeriesSnapshot? snapshot) {
    if (snapshot == null || identical(snapshot, _snapshot)) return;
    _snapshot = snapshot;
    _contents = widget.contents(snapshot);
    if (_entries.isEmpty) return;
    var index = _entries.indexWhere((e) => e.checkIn.id == _checkInId);
    if (index < 0) index = math.min(_index, _entries.length - 1);
    _checkInId = _entries[index].checkIn.id;
    if (index == _index) return;
    _index = index;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _pages.hasClients && _pages.page?.round() != _index) {
        _pages.jumpToPage(_index);
      }
    });
  }

  @override
  void dispose() {
    _pages.dispose();
    for (final controller in _zoom.values) {
      controller.dispose();
    }
    super.dispose();
  }

  /// The angles [entry] has a photo of, in the series' order.
  List<PhotoSeriesAngle> _anglesOf(PhotoViewerEntry entry) => [
    for (final angle in _contents.angles)
      if (entry.images.containsKey(angle.id)) angle,
  ];

  PhotoSeriesAngle _angleFor(PhotoViewerEntry entry) {
    final shown = _anglesOf(entry);
    return shown.firstWhere(
      (angle) => angle.id == _angleId,
      orElse: () => shown.first,
    );
  }

  TransformationController _zoomFor(String imageId) =>
      _zoom.putIfAbsent(imageId, () {
        final controller = TransformationController();
        controller.addListener(() {
          final zoomed = controller.value.getMaxScaleOnAxis() > 1.001;
          if (zoomed != _zoomed) setState(() => _zoomed = zoomed);
        });
        return controller;
      });

  /// Leaving a photo resets its zoom, which [_zoomed] follows: one left
  /// zoomed would keep the pager locked on the next.
  void _unzoom() {
    for (final controller in _zoom.values) {
      controller.value = Matrix4.identity();
    }
  }

  void _page(int by) {
    final target = _index + by;
    if (target < 0 || target >= _entries.length) return;
    _pages.animateToPage(
      target,
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOut,
    );
  }

  void _angle(int by) {
    final entry = _entries[_index];
    final shown = _anglesOf(entry);
    final at = shown.indexOf(_angleFor(entry));
    final target = at + by;
    if (target < 0 || target >= shown.length) return;
    _unzoom();
    setState(() => _angleId = shown[target].id);
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(secureVaultSessionProvider, (_, session) {
      // Not once it's closing: that would close the page under it.
      if (session == null && (ModalRoute.of(context)?.isCurrent ?? false)) {
        Navigator.of(context).maybePop();
      }
    });
    final session = ref.watch(secureVaultSessionProvider);
    _follow(ref.watch(photoSeriesSnapshotProvider).valueOrNull);
    if (_entries.isEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && (ModalRoute.of(context)?.isCurrent ?? false)) {
          Navigator.of(context).maybePop();
        }
      });
      return const SizedBox.shrink();
    }
    final entry = _entries[_index];
    final angle = _angleFor(entry);
    final shownAngles = _anglesOf(entry);
    return VaultActivity(
      child: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.escape): () =>
              Navigator.of(context).maybePop(),
          const SingleActivator(LogicalKeyboardKey.arrowLeft): () => _page(-1),
          const SingleActivator(LogicalKeyboardKey.arrowRight): () => _page(1),
          const SingleActivator(LogicalKeyboardKey.arrowUp): () => _angle(-1),
          const SingleActivator(LogicalKeyboardKey.arrowDown): () => _angle(1),
        },
        child: Focus(
          autofocus: true,
          child: Scaffold(
            backgroundColor: Colors.transparent,
            body: Column(
              children: [
                Expanded(
                  child: Stack(
                    children: [
                      PageView.builder(
                        controller: _pages,
                        itemCount: _entries.length,
                        // A zoomed photo keeps the drag to walk around it.
                        physics: _zoomed
                            ? const NeverScrollableScrollPhysics()
                            : null,
                        scrollBehavior: const _AnyDeviceDrag(),
                        onPageChanged: (index) {
                          _unzoom();
                          setState(() {
                            _index = index;
                            _checkInId = _entries[index].checkIn.id;
                          });
                        },
                        itemBuilder: (context, index) {
                          final pageEntry = _entries[index];
                          final pageAngle = _angleFor(pageEntry);
                          final image = pageEntry.images[pageAngle.id]!;
                          return GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onTap: () => Navigator.of(context).maybePop(),
                            child: InteractiveViewer(
                              transformationController: _zoomFor(image.id),
                              minScale: 1,
                              maxScale: 8,
                              child: Padding(
                                padding: const EdgeInsets.fromLTRB(
                                  48,
                                  56,
                                  48,
                                  12,
                                ),
                                child: Center(
                                  // Taps on the photo itself don't close.
                                  child: GestureDetector(
                                    onTap: () {},
                                    child: AlignedPhotoFrame(
                                      aspect:
                                          pageAngle.frameAspect ??
                                          kDefaultPhotoFrameAspect,
                                      image: image,
                                      child: VaultPhoto(
                                        key: ValueKey(image.blobId),
                                        blobId: image.blobId,
                                        thumb: false,
                                        fit: BoxFit.contain,
                                        // The thumbnail while the full image
                                        // decodes or downloads.
                                        placeholder: VaultPhoto(
                                          blobId: image.blobId,
                                          thumb: true,
                                          fit: BoxFit.contain,
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          );
                        },
                      ),
                      Positioned(
                        top: 16,
                        left: 24,
                        right: 24,
                        child: Row(
                          children: [
                            Text(
                              DateFormat.yMMMEd().format(entry.checkIn.takenOn),
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 15,
                              ),
                            ),
                            const SizedBox(width: 12),
                            Text(
                              '${_index + 1} / ${_entries.length}',
                              style: const TextStyle(color: Colors.white60),
                            ),
                            const Spacer(),
                            IconButton(
                              tooltip: 'Close',
                              color: Colors.white,
                              icon: const Icon(PhosphorIconsRegular.x),
                              onPressed: () => Navigator.of(context).maybePop(),
                            ),
                          ],
                        ),
                      ),
                      if (_index > 0)
                        _Chevron(
                          alignment: Alignment.centerLeft,
                          icon: PhosphorIconsRegular.caretLeft,
                          tooltip: 'Previous check-in',
                          onPressed: () => _page(-1),
                        ),
                      if (_index < _entries.length - 1)
                        _Chevron(
                          alignment: Alignment.centerRight,
                          icon: PhosphorIconsRegular.caretRight,
                          tooltip: 'Next check-in',
                          onPressed: () => _page(1),
                        ),
                    ],
                  ),
                ),
                if (shownAngles.length > 1)
                  Wrap(
                    spacing: 6,
                    children: [
                      for (final shown in shownAngles)
                        ChoiceChip(
                          label: Text(shown.name),
                          selected: shown.id == angle.id,
                          selectedColor: Theme.of(context).colorScheme.primary,
                          checkmarkColor: Theme.of(
                            context,
                          ).colorScheme.onPrimary,
                          labelStyle: TextStyle(
                            color: shown.id == angle.id
                                ? Theme.of(context).colorScheme.onPrimary
                                : null,
                          ),
                          onSelected: (_) =>
                              setState(() => _angleId = shown.id),
                        ),
                    ],
                  ),
                if (session != null && entry.checkIn.hasNote)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(48, 10, 48, 0),
                    child: FutureBuilder<String?>(
                      future: _notes.putIfAbsent(
                        entry.checkIn.id,
                        () =>
                            PhotoSeriesService.openNote(session, entry.checkIn),
                      ),
                      builder: (context, snapshot) => Text(
                        snapshot.data ?? '',
                        textAlign: TextAlign.center,
                        maxLines: 4,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: Colors.white70),
                      ),
                    ),
                  ),
                const SizedBox(height: 20),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Chevron extends StatelessWidget {
  const _Chevron({
    required this.alignment,
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });

  final Alignment alignment;
  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => Align(
    alignment: alignment,
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.35),
          borderRadius: BorderRadius.circular(VoyagerTheme.fieldRadius),
        ),
        child: IconButton(
          tooltip: tooltip,
          color: Colors.white,
          icon: Icon(icon),
          onPressed: onPressed,
        ),
      ),
    ),
  );
}

/// Lets a mouse drag turn the page too — Material's list holds no mouse.
class _AnyDeviceDrag extends MaterialScrollBehavior {
  const _AnyDeviceDrag();

  @override
  Set<PointerDeviceKind> get dragDevices => PointerDeviceKind.values.toSet();
}

import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/motion/motion_prefs.dart';
import 'package:voyager/core/secure_vault/secure_vault_service.dart';
import 'package:voyager/core/theme/voyager_theme.dart';
import 'package:voyager/core/widgets/glass_button.dart';
import 'package:voyager/domain/models/photo_series_models.dart';
import 'package:voyager/domain/photo_series/photo_series_periods.dart';
import 'package:voyager/features/notifications/secure_vault_dialogs.dart';
import 'package:voyager/features/notifications/secure_vault_session.dart';
import 'package:voyager/features/photo_series/photo_series_detail.dart';
import 'package:voyager/features/photo_series/photo_series_dialogs.dart';
import 'package:voyager/features/photo_series/photo_series_providers.dart';
import 'package:voyager/features/photo_series/vault_activity.dart';
import 'package:voyager/features/photo_series/vault_image_cache.dart';
import 'package:voyager/features/shell/reveal_request.dart';
import 'package:voyager/routing/app_router.dart';

/// The Photos page (PHOTO_SERIES_HLD.md §4): every series as a card, and a
/// series' detail pushed over it. Everything plain shows while the vault is
/// locked; the photos need it open.
class PhotoSeriesPage extends ConsumerStatefulWidget {
  const PhotoSeriesPage({super.key});

  @override
  ConsumerState<PhotoSeriesPage> createState() => _PhotoSeriesPageState();
}

class _PhotoSeriesPageState extends ConsumerState<PhotoSeriesPage> {
  late final _router = ref.read(routerProvider);
  late final _visibleFlag = ref.read(photoSeriesPageVisibleProvider.notifier);
  bool _visible = false;

  @override
  void initState() {
    super.initState();
    _router.routerDelegate.addListener(_onLocation);
    _onLocation();
    // A request made before the page first mounted.
    Future.microtask(_takeRevealRequest);
  }

  /// Opens the series an inbox row, sticky or OS notification asked for, over
  /// whatever this page had pushed — or back to its detail, when that series
  /// is already open.
  void _takeRevealRequest() {
    if (!mounted) return;
    final id = ref.read(revealPhotoSeriesRequestProvider);
    if (id == null) return;
    ref.read(revealPhotoSeriesRequestProvider.notifier).state = null;
    var open = false;
    Navigator.of(context).popUntil((route) {
      open = route is _PhotoSeriesDetailRoute && route.seriesId == id;
      return open || route.isFirst;
    });
    if (!open) openPhotoSeries(context, id);
  }

  @override
  void dispose() {
    _router.routerDelegate.removeListener(_onLocation);
    final flag = _visibleFlag;
    Future.microtask(() {
      if (flag.mounted) flag.state = false;
    });
    super.dispose();
  }

  /// After the current frame: the router can announce a change mid-build,
  /// when no provider may change.
  void _onLocation() => Future.microtask(_applyLocation);

  /// Leaving the page blurs every thumbnail again (§7.1).
  void _applyLocation() {
    if (!mounted) return;
    final visible = photoSeriesPageVisible(_router);
    _visibleFlag.state = visible;
    if (visible == _visible) return;
    _visible = visible;
    if (!visible) ref.read(photoRevealedCheckInsProvider.notifier).state = {};
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<String?>(revealPhotoSeriesRequestProvider, (_, id) {
      if (id != null) Future.microtask(_takeRevealRequest);
    });
    return const VaultActivity(child: _SeriesList());
  }
}

class _SeriesList extends ConsumerWidget {
  const _SeriesList();

  Future<void> _create(BuildContext context, WidgetRef ref, int count) async {
    final form = await showPhotoSeriesDialog(context);
    if (form == null) return;
    final series = await ref
        .read(photoSeriesServiceProvider)
        .createSeries(
          name: form.name,
          cadence: form.cadence,
          sortOrder: count,
          angleNames: [for (final angle in form.angles) angle.name],
          reminder: form.reminder,
        );
    if (context.mounted) openPhotoSeries(context, series.id);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final snapshot =
        ref.watch(photoSeriesSnapshotProvider).valueOrNull ??
        PhotoSeriesSnapshot.empty;
    final theme = Theme.of(context);
    final now = ref.watch(photoSeriesTodayProvider);
    return Material(
      type: MaterialType.transparency,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(24, 20, 24, 24),
        children: [
          Row(
            children: [
              Text('Photos', style: theme.textTheme.headlineSmall),
              const Spacer(),
              const PhotoVaultLockButton(),
            ],
          ),
          const SizedBox(height: 16),
          LayoutBuilder(
            builder: (context, constraints) {
              final columns = (constraints.maxWidth / 260).floor().clamp(1, 6);
              final width =
                  (constraints.maxWidth - (columns - 1) * 12) / columns;
              return Wrap(
                spacing: 12,
                runSpacing: 12,
                children: [
                  for (final series in snapshot.series)
                    SizedBox(
                      width: width,
                      child: _SeriesCard(
                        series: series,
                        snapshot: snapshot,
                        now: now,
                      ),
                    ),
                  SizedBox(
                    width: width,
                    child: _NewSeriesCard(
                      onTap: () =>
                          _create(context, ref, snapshot.series.length),
                    ),
                  ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}

/// Opens [seriesId]'s detail over the list, in the page's branch.
void openPhotoSeries(BuildContext context, String seriesId) {
  Navigator.of(context).push(_PhotoSeriesDetailRoute(seriesId));
}

/// Zooms the detail in while the list zooms past it and fades out.
///
/// Both pages are transparent over the shell's background, so the list has to
/// fade itself. The platform's zoom transition never fades the page it leaves
/// — it counts on the page arriving to cover it — so the list stayed on
/// screen under the detail until the push ended and it vanished at once.
class _PhotoSeriesDetailRoute extends PageRouteBuilder<void> {
  _PhotoSeriesDetailRoute(this.seriesId)
    : super(
        transitionDuration: const Duration(milliseconds: 300),
        reverseTransitionDuration: const Duration(milliseconds: 250),
        pageBuilder: (_, _, _) => PhotoSeriesDetail(seriesId: seriesId),
        transitionsBuilder: (context, animation, _, child) => _zoom(
          context,
          animation,
          child,
          fade: const Interval(0.25, 1, curve: Curves.easeOut),
          scale: Tween(begin: 0.94, end: 1),
        ),
      );

  final String seriesId;

  /// What the list does while the detail comes and goes.
  @override
  DelegatedTransitionBuilder? get delegatedTransition =>
      (context, _, secondaryAnimation, _, child) => _zoom(
        context,
        ReverseAnimation(secondaryAnimation),
        child,
        // Gone before the detail is more than faintly there, so the two never
        // sit on top of each other half-faded.
        fade: const Interval(0.6, 1, curve: Curves.easeIn),
        scale: Tween(begin: 1.06, end: 1),
      );

  /// [child] fading in and scaling to full size as [animation] completes.
  static Widget _zoom(
    BuildContext context,
    Animation<double> animation,
    Widget? child, {
    required Curve fade,
    required Tween<double> scale,
  }) {
    final faded = FadeTransition(
      opacity: CurvedAnimation(parent: animation, curve: fade),
      child: child,
    );
    if (VoyagerMotion.reduced(context)) return faded;
    return ScaleTransition(
      scale: scale.animate(
        CurvedAnimation(parent: animation, curve: Curves.fastOutSlowIn),
      ),
      child: faded,
    );
  }
}

/// The newest check-in's first photo, by the series' angle order.
PhotoCheckInImage? photoSeriesCover(
  PhotoSeries series,
  PhotoSeriesSnapshot snapshot,
) {
  final angleOrder = {
    for (final angle in snapshot.angles)
      if (angle.seriesId == series.id) angle.id: angle.sortOrder,
  };
  final checkIns = [
    for (final checkIn in snapshot.checkIns)
      if (checkIn.seriesId == series.id) checkIn,
  ]..sort((a, b) => b.takenOn.compareTo(a.takenOn));
  for (final checkIn in checkIns) {
    final images = [
      for (final image in snapshot.images)
        if (image.checkInId == checkIn.id &&
            angleOrder.containsKey(image.angleId))
          image,
    ]..sort((a, b) => angleOrder[a.angleId]!.compareTo(angleOrder[b.angleId]!));
    if (images.isNotEmpty) return images.first;
  }
  return null;
}

class _SeriesCard extends ConsumerWidget {
  const _SeriesCard({
    required this.series,
    required this.snapshot,
    required this.now,
  });

  final PhotoSeries series;
  final PhotoSeriesSnapshot snapshot;
  final DateTime now;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final stats = photoSeriesStats(
      series: series,
      checkIns: snapshot.checkIns,
      images: snapshot.images,
      now: now,
    );
    final cover = photoSeriesCover(series, snapshot);
    final unlocked = ref.watch(
      secureVaultSessionProvider.select((s) => s != null),
    );
    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => openPhotoSeries(context, series.id),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            AspectRatio(
              aspectRatio: 4 / 3,
              child: cover == null
                  ? ColoredBox(
                      color: theme.colorScheme.onSurface.withValues(
                        alpha: 0.05,
                      ),
                      child: Icon(
                        PhosphorIconsRegular.images,
                        size: 32,
                        color: theme.colorScheme.onSurface.withValues(
                          alpha: 0.3,
                        ),
                      ),
                    )
                  // Always blurred here; a photo is revealed in its grid.
                  : ClipRect(
                      child: ImageFiltered(
                        imageFilter: ui.ImageFilter.blur(
                          sigmaX: 18,
                          sigmaY: 18,
                        ),
                        child: unlocked
                            ? VaultPhoto(blobId: cover.blobId, thumb: true)
                            : const SizedBox.expand(),
                      ),
                    ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    series.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleMedium,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    [
                      photoCadenceLabel(series.cadence),
                      '${stats.checkIns} check-in${stats.checkIns == 1 ? '' : 's'}',
                      if (stats.currentStreak > 0)
                        '${stats.currentStreak} streak',
                    ].join(' · '),
                    style: theme.textTheme.bodySmall,
                  ),
                  const SizedBox(height: 6),
                  PhotoPeriodBadge(done: stats.currentDone),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// "Done" or "Due" for the current period.
class PhotoPeriodBadge extends StatelessWidget {
  const PhotoPeriodBadge({super.key, required this.done});

  final bool done;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = done ? scheme.primary : scheme.tertiary;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(VoyagerTheme.fieldRadius),
      ),
      child: Text(
        done ? 'Done' : 'Due',
        style: Theme.of(context).textTheme.labelSmall?.copyWith(color: color),
      ),
    );
  }
}

class _NewSeriesCard extends StatelessWidget {
  const _NewSeriesCard({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: EdgeInsets.zero,
      child: InkWell(
        onTap: onTap,
        child: SizedBox(
          height: 120,
          child: Center(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(PhosphorIconsRegular.plus, size: 18),
                const SizedBox(width: 8),
                Text('New series', style: theme.textTheme.titleSmall),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Locks an open vault from the page.
class PhotoVaultLockButton extends ConsumerWidget {
  const PhotoVaultLockButton({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final unlocked = ref.watch(
      secureVaultSessionProvider.select((s) => s != null),
    );
    if (!unlocked) return const SizedBox.shrink();
    return GlassButton(
      onPressed: () => ref.read(secureVaultSessionProvider.notifier).lock(),
      icon: const Icon(PhosphorIconsRegular.lockSimple, size: 13),
      label: 'Lock',
      dense: true,
    );
  }
}

/// The page's unlock prompt (§4.1): a password field in place, with the
/// vault's reset beside it, or the way to make a vault when there is none.
class PhotoVaultUnlockCard extends ConsumerStatefulWidget {
  const PhotoVaultUnlockCard({super.key, this.focusNode});

  /// Focused by the controls that need the vault open.
  final FocusNode? focusNode;

  @override
  ConsumerState<PhotoVaultUnlockCard> createState() =>
      _PhotoVaultUnlockCardState();
}

class _PhotoVaultUnlockCardState extends ConsumerState<PhotoVaultUnlockCard> {
  final _password = TextEditingController();
  String? _error;
  bool _busy = false;

  @override
  void dispose() {
    _password.dispose();
    super.dispose();
  }

  Future<void> _unlock() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    String? error;
    try {
      error = await unlockSecureVault(ref, _password.text);
    } on SecureVaultException catch (e) {
      error = e.message;
    }
    if (!mounted) return;
    _password.clear();
    setState(() {
      _busy = false;
      _error = error;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final header = ref.watch(secureVaultHeaderProvider);
    final hasVault = header.valueOrNull != null;
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                const Icon(PhosphorIconsRegular.lockSimple, size: 18),
                const SizedBox(width: 8),
                Text(
                  hasVault
                      ? 'Unlock to see photos'
                      : 'Set up a vault to store photos',
                  style: theme.textTheme.titleSmall,
                ),
              ],
            ),
            const SizedBox(height: 12),
            if (!hasVault)
              GlassButton(
                onPressed: header.isLoading
                    ? null
                    : () => showSecureVaultSetupDialog(context, ref),
                label: 'Set up vault…',
                focusNode: widget.focusNode,
                canRequestFocus: true,
                dense: true,
              )
            else ...[
              Row(
                children: [
                  SizedBox(
                    width: 260,
                    // A plain field, as the vault's own dialogs use: no Vim,
                    // snippets or suggestions.
                    child: TextField(
                      controller: _password,
                      focusNode: widget.focusNode,
                      obscureText: true,
                      enableSuggestions: false,
                      autocorrect: false,
                      enableIMEPersonalizedLearning: false,
                      keyboardType: TextInputType.visiblePassword,
                      decoration: const InputDecoration(
                        labelText: 'Password',
                        isDense: true,
                        contentPadding: EdgeInsets.fromLTRB(8, 16, 8, 8),
                      ),
                      onSubmitted: (_) => _unlock(),
                    ),
                  ),
                  const SizedBox(width: 8),
                  GlassButton(
                    onPressed: _busy ? null : _unlock,
                    label: 'Unlock',
                    dense: true,
                  ),
                ],
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
              const SizedBox(height: 6),
              TextButton(
                onPressed: () => showSecureVaultResetDialog(context, ref),
                child: const Text('Reset vault'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

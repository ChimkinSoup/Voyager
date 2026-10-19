import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/domain/models/photo_series_models.dart';
import 'package:voyager/features/notifications/secure_vault_session.dart';
import 'package:voyager/features/photo_series/photo_series_service.dart';
import 'package:voyager/features/photo_series/vault_image_cache.dart';

/// The page's route, and its shell destination's path.
const kPhotoSeriesPath = '/photo-series';

/// Whether the Photos page is the shell's visible branch.
bool photoSeriesPageVisible(GoRouter router) {
  final path = router.routerDelegate.currentConfiguration.uri.path;
  return path == kPhotoSeriesPath || path.startsWith('$kPhotoSeriesPath/');
}

/// [photoSeriesPageVisible], kept by the page as the location changes, for
/// the inbox: closing it doesn't lock the vault while Photos is on screen
/// (PHOTO_SERIES_HLD.md §6.4).
final photoSeriesPageVisibleProvider = StateProvider<bool>((ref) => false);

final photoSeriesServiceProvider = Provider<PhotoSeriesService>((ref) {
  return PhotoSeriesService(
    repository: ref.watch(photoSeriesRepositoryProvider),
    media: ref.watch(vaultMediaServiceProvider.notifier),
  );
});

/// Every live series row, kept current by the database itself — a pull or
/// a restore shows without anyone invalidating it.
final photoSeriesSnapshotProvider = StreamProvider<PhotoSeriesSnapshot>((ref) {
  return ref.watch(photoSeriesRepositoryProvider).watchSnapshot();
});

/// The decrypted photos, for as long as the vault stays unlocked: a new,
/// empty cache with each unlock, and none while locked.
final vaultImageCacheProvider = Provider<VaultImageCache?>((ref) {
  final session = ref.watch(secureVaultSessionProvider);
  if (session == null) return null;
  final cache = VaultImageCache(
    media: ref.watch(vaultMediaServiceProvider.notifier),
    session: session,
  );
  ref.onDispose(cache.dispose);
  return cache;
});

/// The check-ins whose thumbnail has been clicked out of its blur (§7.1).
/// Emptied when the vault locks and when the page is left.
final photoRevealedCheckInsProvider = StateProvider<Set<String>>((ref) {
  ref.watch(secureVaultSessionProvider.select((s) => s?.vaultId));
  return const {};
});

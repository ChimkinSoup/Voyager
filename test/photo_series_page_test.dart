// The Photos page while locked and unlocked, and the vault session it shares
// with the inbox (PHOTO_SERIES_HLD.md §4.1, §6.4, §7.1).

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:fake_async/fake_async.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:image/image.dart' as img;
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/secure_vault/vault_media_service.dart';
import 'package:voyager/core/theme/voyager_theme.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/data/remote/in_memory_sync.dart';
import 'package:voyager/data/services/vault_media_file_store.dart';
import 'package:voyager/domain/models/enums.dart';
import 'package:voyager/domain/models/photo_series_models.dart';
import 'package:voyager/domain/models/settings_models.dart';
import 'package:voyager/domain/repositories/media_storage.dart';
import 'package:voyager/features/notifications/notification_inbox_popover.dart';
import 'package:voyager/features/notifications/secure_vault_session.dart';
import 'package:voyager/features/photo_series/photo_series_detail.dart';
import 'package:voyager/features/photo_series/photo_series_page.dart';
import 'package:voyager/features/photo_series/photo_series_providers.dart';
import 'package:voyager/features/photo_series/vault_image_cache.dart';
import 'package:voyager/features/shell/reveal_request.dart';
import 'package:voyager/routing/app_router.dart';

import 'fakes/fake_weather_api_client.dart';

const _password = 'correct horse';

class _NoStorage implements MediaStorage {
  @override
  String? get currentUid => null;

  @override
  Future<void> upload(String path, Uint8List bytes, String mimeType) async {}

  @override
  Future<Uint8List> download(String path) =>
      throw const MediaStoragePermanentFailure('offline');

  @override
  Future<void> delete(String path) async {}
}

Uint8List _jpeg() {
  final image = img.Image(width: 30, height: 40);
  for (final pixel in image) {
    pixel.r = (pixel.x * 7) % 256;
  }
  return img.encodeJpg(image);
}

DateTime _today() {
  final now = DateTime.now();
  return DateTime(now.year, now.month, now.day);
}

Future<ProviderContainer> _container(WidgetTester tester) async {
  final db = AppDatabase.inMemory();
  addTearDown(db.close);
  final dir = (await tester.runAsync(
    () => Directory.systemTemp.createTemp('voyager_photo_page'),
  ))!;
  addTearDown(() => dir.delete(recursive: true));
  final container = ProviderContainer(
    overrides: [
      databaseProvider.overrideWithValue(db),
      syncRepositoryProvider.overrideWithValue(InMemorySyncRepository()),
      weatherApiClientProvider.overrideWithValue(FakeWeatherApiClient()),
      mediaStorageProvider.overrideWithValue(_NoStorage()),
      // Fixed, so no midnight timer outlives the widget tree; the timer has
      // its own test below.
      photoSeriesTodayProvider.overrideWithValue(_today()),
      vaultMediaServiceProvider.overrideWith(
        (ref) => VaultMediaService(
          repository: ref.watch(photoSeriesRepositoryProvider),
          fileStore: VaultMediaFileStore(root: dir),
          storage: _NoStorage(),
          readSettings: () async =>
              const AppSettings().copyWith(mediaRemoteUploadsEnabled: false),
        ),
      ),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

/// Creates the vault (real key derivation, off the fake clock) and unlocks
/// it, as the setup dialog would.
Future<void> _unlock(WidgetTester tester, ProviderContainer container) async {
  final service = container.read(secureVaultServiceProvider);
  await tester.runAsync(() async {
    var header = await service.localHeader();
    final key = header == null
        ? await service.create(_password)
        : (await service.unlock(_password))!;
    header = await service.localHeader();
    container
        .read(secureVaultSessionProvider.notifier)
        .unlock(key, header!.vaultId);
  });
  container.invalidate(secureVaultHeaderProvider);
  await _settle(tester);
}

/// A weekly series with one check-in a week ago and one this week.
Future<PhotoSeries> _seed(
  WidgetTester tester,
  ProviderContainer container,
) async {
  late PhotoSeries series;
  await tester.runAsync(() async {
    final service = container.read(photoSeriesServiceProvider);
    series = await service.createSeries(
      name: 'Progress',
      cadence: TrackerCadence.weekly,
      sortOrder: 0,
      angleNames: ['Front'],
    );
    final angle =
        (await container.read(photoSeriesRepositoryProvider).listAngles())
            .single;
    final session = container.read(secureVaultSessionProvider)!;
    final today = DateTime.now();
    for (final day in [today.subtract(const Duration(days: 7)), today]) {
      await service.createCheckIn(
        session: session,
        series: series,
        takenOn: day,
        photos: {angle.id: _jpeg()},
      );
    }
  });
  return series;
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 80));
  }
}

Future<void> _pumpDetail(
  WidgetTester tester,
  ProviderContainer container,
  String seriesId,
) async {
  tester.view.physicalSize = const Size(1200, 1000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: VoyagerTheme.dark(),
        home: PhotoSeriesDetail(seriesId: seriesId),
      ),
    ),
  );
  // The snapshot stream's first read.
  await tester.runAsync(
    () => container.read(photoSeriesSnapshotProvider.future),
  );
  await _settle(tester);
}

void main() {
  testWidgets('locked: stats and strip show, photos and Check in need the '
      'vault', (tester) async {
    final container = await _container(tester);
    await _unlock(tester, container);
    final series = await _seed(tester, container);
    container.read(secureVaultSessionProvider.notifier).lock();

    await _pumpDetail(tester, container, series.id);

    expect(find.text('check-ins'), findsOneWidget);
    expect(find.text('2'), findsWidgets);
    expect(find.text('Unlock to see photos'), findsOneWidget);
    // Nothing decrypted: placeholders in place of every thumbnail.
    expect(find.byType(VaultPhoto), findsNothing);
    expect(find.byType(Tooltip), findsWidgets);

    await tester.tap(find.text('Check in'));
    await _settle(tester);
    expect(find.textContaining('1 of 1'), findsNothing);
    final field = tester.widget<EditableText>(find.byType(EditableText));
    expect(field.focusNode.hasFocus, isTrue);
  });

  testWidgets('a first click reveals, a second opens the viewer; locking '
      'blurs and closes it', (tester) async {
    final container = await _container(tester);
    await _unlock(tester, container);
    final series = await _seed(tester, container);
    await _pumpDetail(tester, container, series.id);

    expect(find.text('Unlock to see photos'), findsNothing);
    final tiles = find.byType(VaultPhoto);
    expect(tiles, findsNWidgets(2));
    expect(find.byType(ImageFiltered), findsNWidgets(2));

    // Lands on the eye drawn over the blur, which is part of the tile.
    await tester.tap(tiles.first, warnIfMissed: false);
    await _settle(tester);
    expect(container.read(photoRevealedCheckInsProvider), hasLength(1));
    expect(find.byType(ImageFiltered), findsOneWidget);

    await tester.tap(find.byType(VaultPhoto).first);
    await _settle(tester);
    expect(find.text('2 / 2'), findsOneWidget);

    container.read(secureVaultSessionProvider.notifier).lock();
    await _settle(tester);
    expect(find.text('2 / 2'), findsNothing);
    expect(container.read(photoRevealedCheckInsProvider), isEmpty);
    expect(find.text('Unlock to see photos'), findsOneWidget);
  });

  testWidgets('the first load of a photo completes, as do the ones waiting '
      'on it', (tester) async {
    final container = await _container(tester);
    await _unlock(tester, container);
    await _seed(tester, container);
    final blobId = (await tester.runAsync(
      () => container.read(photoSeriesRepositoryProvider).listImages(),
    ))!.first.blobId;
    final cache = container.read(vaultImageCacheProvider)!;

    // Two callers on one decode, as a tile and a card showing one photo.
    final images = await tester.runAsync(
      () => Future.wait([
        cache.load(blobId, thumb: true),
        cache.load(blobId, thumb: true),
      ]).timeout(const Duration(seconds: 10)),
    );
    expect(images, everyElement(isNotNull));
    for (final image in images!) {
      image!.dispose();
    }
  });

  group('closing the inbox', () {
    Future<ProviderContainer> pumpInbox(WidgetTester tester) async {
      tester.view.physicalSize = const Size(600, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final container = await _container(tester);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: VoyagerTheme.dark(),
            home: const Scaffold(body: NotificationInboxPopover()),
          ),
        ),
      );
      await _settle(tester);
      await _unlock(tester, container);
      return container;
    }

    Future<void> close(WidgetTester tester, ProviderContainer container) async {
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(home: SizedBox()),
        ),
      );
      await tester.pump();
    }

    testWidgets('leaves the vault open while Photos is on screen', (
      tester,
    ) async {
      final container = await pumpInbox(tester);
      container.read(photoSeriesPageVisibleProvider.notifier).state = true;

      await close(tester, container);
      expect(container.read(secureVaultSessionProvider), isNotNull);
    });

    testWidgets('locks it on any other page', (tester) async {
      final container = await pumpInbox(tester);

      await close(tester, container);
      expect(container.read(secureVaultSessionProvider), isNull);
    });
  });

  // DateTime.now() can't be faked, so this pins the mechanism: one timer,
  // due at the next local midnight, that rebuilds the provider — which arms
  // the next one.
  test("today's date is recomputed at local midnight", () {
    fakeAsync((async) {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      // Taken first, so the provider's own reading is no earlier.
      final now = DateTime.now();
      container.listen(photoSeriesTodayProvider, (_, _) {});
      expect(
        container.read(photoSeriesTodayProvider),
        DateTime(now.year, now.month, now.day),
      );
      final untilMidnight = DateTime(
        now.year,
        now.month,
        now.day + 1,
      ).difference(now);
      expect(async.pendingTimers, hasLength(1));
      expect(
        async.pendingTimers.single.duration,
        lessThanOrEqualTo(untilMidnight),
      );
      final first = async.pendingTimers.single;

      async.elapse(untilMidnight + const Duration(seconds: 1));
      container.read(photoSeriesTodayProvider);
      // Rebuilt: the first timer fired, and the rebuild armed a new one.
      expect(async.pendingTimers, hasLength(1));
      expect(async.pendingTimers.single, isNot(same(first)));
    });
  });

  // Both pages are transparent over the shell, and the platform's zoom
  // transition never fades the page it leaves: the list sat under the
  // detail, faint and enlarged, until the push ended and dropped it at once.
  testWidgets(
    'opening a series fades the list out before it is dropped',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 1000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final db = AppDatabase.inMemory();
      addTearDown(db.close);
      final router = GoRouter(
        initialLocation: kPhotoSeriesPath,
        routes: [
          GoRoute(
            path: kPhotoSeriesPath,
            builder: (_, _) => const PhotoSeriesPage(),
          ),
        ],
      );
      addTearDown(router.dispose);
      final container = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(db),
          syncRepositoryProvider.overrideWithValue(InMemorySyncRepository()),
          weatherApiClientProvider.overrideWithValue(FakeWeatherApiClient()),
          photoSeriesTodayProvider.overrideWithValue(_today()),
          routerProvider.overrideWithValue(router),
        ],
      );
      addTearDown(container.dispose);
      final stamp = DateTime.now().toUtc();
      await tester.runAsync(
        () => container
            .read(photoSeriesRepositoryProvider)
            .saveAll(
              series: [
                PhotoSeries(
                  id: 's',
                  name: 'Progress',
                  createdAt: stamp,
                  updatedAt: stamp,
                ),
              ],
            ),
      );
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp.router(
            theme: VoyagerTheme.dark(),
            routerConfig: router,
          ),
        ),
      );
      await tester.runAsync(
        () => container.read(photoSeriesSnapshotProvider.future),
      );
      await _settle(tester);

      /// How opaque the list is drawn: every fade above it, multiplied.
      double listOpacity() {
        var opacity = 1.0;
        RenderObject? node = tester.renderObject(find.text('New series'));
        while (node != null) {
          if (node is RenderAnimatedOpacity) opacity *= node.opacity.value;
          if (node is RenderOpacity) opacity *= node.opacity;
          node = node.parent;
        }
        return opacity;
      }

      expect(listOpacity(), 1);
      await tester.tap(find.text('Progress'));
      final samples = <double>[];
      for (var i = 0; i < 40; i++) {
        await tester.pump(const Duration(milliseconds: 16));
        if (find.text('New series').evaluate().isEmpty) break;
        samples.add(listOpacity());
      }

      expect(find.byType(PhotoSeriesDetail), findsOneWidget);
      expect(find.text('New series'), findsNothing);
      // It fades all the way out while still on screen, and never comes back.
      expect(samples.last, lessThan(0.01));
      for (var i = 1; i < samples.length; i++) {
        expect(samples[i], lessThanOrEqualTo(samples[i - 1]));
      }
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );

  // A reveal for the series already open used to pop to the list and zoom a
  // fresh detail in over it.
  testWidgets('a reveal for the open series goes back to its detail', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final db = AppDatabase.inMemory();
    addTearDown(db.close);
    final router = GoRouter(
      initialLocation: kPhotoSeriesPath,
      routes: [
        GoRoute(
          path: kPhotoSeriesPath,
          builder: (_, _) => const PhotoSeriesPage(),
        ),
      ],
    );
    addTearDown(router.dispose);
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        syncRepositoryProvider.overrideWithValue(InMemorySyncRepository()),
        weatherApiClientProvider.overrideWithValue(FakeWeatherApiClient()),
        photoSeriesTodayProvider.overrideWithValue(_today()),
        routerProvider.overrideWithValue(router),
      ],
    );
    addTearDown(container.dispose);
    final stamp = DateTime.now().toUtc();
    await tester.runAsync(
      () => container
          .read(photoSeriesRepositoryProvider)
          .saveAll(
            series: [
              PhotoSeries(
                id: 's',
                name: 'Progress',
                createdAt: stamp,
                updatedAt: stamp,
              ),
            ],
          ),
    );
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(
          theme: VoyagerTheme.dark(),
          routerConfig: router,
        ),
      ),
    );
    await tester.runAsync(
      () => container.read(photoSeriesSnapshotProvider.future),
    );
    await _settle(tester);

    await tester.tap(find.text('Progress'));
    await _settle(tester);
    final detail = tester.element(find.byType(PhotoSeriesDetail));
    unawaited(
      Navigator.of(
        detail,
      ).push(MaterialPageRoute<void>(builder: (_) => const Text('viewer'))),
    );
    await _settle(tester);

    container.read(revealPhotoSeriesRequestProvider.notifier).state = 's';
    await _settle(tester);
    // The viewer's exit runs longer than one settle.
    await tester.pump(const Duration(seconds: 1));

    expect(find.text('viewer'), findsNothing);
    expect(find.text('New series'), findsNothing);
    expect(tester.element(find.byType(PhotoSeriesDetail)), same(detail));
  });
}

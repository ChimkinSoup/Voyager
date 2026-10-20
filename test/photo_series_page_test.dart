// The Photos page while locked and unlocked, and the vault session it shares
// with the inbox (PHOTO_SERIES_HLD.md §4.1, §6.4, §7.1).

import 'dart:async';
import 'dart:math' as math;
import 'dart:io';
import 'dart:ui' as ui;

import 'package:fake_async/fake_async.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:image/image.dart' as img;
import 'package:intl/intl.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/secure_vault/secure_window.dart';
import 'package:voyager/core/secure_vault/vault_media_service.dart';
import 'package:voyager/core/theme/voyager_theme.dart';
import 'package:voyager/core/widgets/glass_button.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/data/remote/in_memory_sync.dart';
import 'package:voyager/data/services/vault_media_file_store.dart';
import 'package:voyager/domain/models/enums.dart';
import 'package:voyager/domain/models/media_models.dart';
import 'package:voyager/domain/models/photo_series_models.dart';
import 'package:voyager/domain/models/settings_models.dart';
import 'package:voyager/domain/photo_series/photo_series_periods.dart';
import 'package:voyager/domain/repositories/media_storage.dart';
import 'package:voyager/domain/services/media_ingest.dart';
import 'package:voyager/features/notifications/notification_inbox_popover.dart';
import 'package:voyager/features/notifications/secure_vault_dialogs.dart';
import 'package:voyager/features/notifications/secure_vault_session.dart';
import 'package:voyager/features/photo_series/photo_capture_screen.dart';
import 'package:voyager/features/photo_series/photo_check_in_dialog.dart';
import 'package:voyager/features/photo_series/photo_series_detail.dart';
import 'package:voyager/features/photo_series/photo_series_dialogs.dart';
import 'package:voyager/features/photo_series/photo_frame.dart';
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

/// [files] is where the vault's files go, for a test that reaches into it.
Future<ProviderContainer> _container(
  WidgetTester tester, {
  List<Override> overrides = const [],
  Directory? files,
  AppSettings? settings,
}) async {
  final db = AppDatabase.inMemory();
  addTearDown(db.close);
  final dir =
      files ??
      (await tester.runAsync(
        () => Directory.systemTemp.createTemp('voyager_photo_page'),
      ))!;
  if (files == null) addTearDown(() => dir.delete(recursive: true));
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
              settings ??
              const AppSettings().copyWith(mediaRemoteUploadsEnabled: false),
        ),
      ),
      ...overrides,
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

/// A weekly series with one check-in a week ago and one this week, or one
/// for each of [daysAgo].
Future<PhotoSeries> _seed(
  WidgetTester tester,
  ProviderContainer container, {
  List<int> daysAgo = const [7, 0],
  TrackerCadence cadence = TrackerCadence.weekly,
}) async {
  late PhotoSeries series;
  await tester.runAsync(() async {
    final service = container.read(photoSeriesServiceProvider);
    series = await service.createSeries(
      name: 'Progress',
      cadence: cadence,
      sortOrder: 0,
      angleNames: ['Front'],
    );
    final angle =
        (await container.read(photoSeriesRepositoryProvider).listAngles())
            .single;
    final session = container.read(secureVaultSessionProvider)!;
    final today = DateTime.now();
    for (final day in [
      for (final n in daysAgo) today.subtract(Duration(days: n)),
    ]) {
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

/// Lets real I/O — reads, decryption, decoding — finish, pumping between.
Future<void> _drain(WidgetTester tester) async {
  // Each step of a chain started in the fake zone needs a turn of both.
  for (var i = 0; i < 40; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    // Fake time too, for the database's own timers.
    await tester.pump(const Duration(milliseconds: 50));
  }
}

/// The series' detail; [pushed] over a home page, as the app has it, so a
/// stray pop shows.
Future<void> _pumpDetail(
  WidgetTester tester,
  ProviderContainer container,
  String seriesId, {
  bool pushed = false,
}) async {
  tester.view.physicalSize = const Size(1200, 1000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: VoyagerTheme.dark(),
        home: pushed
            ? Builder(
                builder: (context) => TextButton(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => PhotoSeriesDetail(seriesId: seriesId),
                    ),
                  ),
                  child: const Text('home'),
                ),
              )
            : PhotoSeriesDetail(seriesId: seriesId),
      ),
    ),
  );
  if (pushed) await tester.tap(find.text('home'));
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

  group('playback', () {
    /// The image Playback is drawing, null while none is.
    ui.Image? drawn(WidgetTester tester) {
      final raw = find.descendant(
        of: find.byType(AlignedPhotoFrame),
        matching: find.byType(RawImage),
      );
      return raw.evaluate().isEmpty ? null : tester.widget<RawImage>(raw).image;
    }

    testWidgets('decodes frames at the size drawn and steps through them', (
      tester,
    ) async {
      final container = await _container(tester);
      await _unlock(tester, container);
      final series = await _seed(tester, container);
      await _pumpDetail(tester, container, series.id);

      await tester.tap(find.text('Playback'));
      await _drain(tester);
      expect(find.textContaining('1 / 2'), findsOneWidget);
      final first = drawn(tester);
      expect(first, isNotNull);
      // The 30 × 40 photo is never decoded larger than it is.
      expect(first!.width, 30);

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await _drain(tester);
      expect(find.textContaining('2 / 2'), findsOneWidget);
      expect(drawn(tester), isNotNull);

      // Ends the idle-lock timer the taps armed.
      container.read(secureVaultSessionProvider.notifier).lock();
      await tester.pump();
    });

    testWidgets('once stops at the last frame; the speed is remembered', (
      tester,
    ) async {
      final container = await _container(tester);
      await _unlock(tester, container);
      final series = await _seed(tester, container);
      await _pumpDetail(tester, container, series.id);
      await tester.tap(find.text('Playback'));
      await _drain(tester);

      await tester.tap(find.text('Once'));
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      // 4 fps by default: a frame every 250 ms.
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(find.textContaining('2 / 2'), findsOneWidget);
      expect(find.byTooltip('Play (Space)'), findsOneWidget);

      tester.widget<Slider>(find.byType(Slider)).onChangeEnd!(12);
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 200)),
      );
      final saved = await tester.runAsync(
        () => container.read(photoSeriesRepositoryProvider).listSeries(),
      );
      expect(saved!.single.playbackFps, 12);

      // Ends the idle-lock timer the taps armed.
      container.read(secureVaultSessionProvider.notifier).lock();
      await tester.pump();
    });

    // The window used to look only backwards from the last frame, so a loop
    // of more than 11 waited for ever on a first frame nothing loaded.
    testWidgets('a loop of many frames wraps from the last to the first', (
      tester,
    ) async {
      final container = await _container(tester);
      await _unlock(tester, container);
      final series = await _seed(
        tester,
        container,
        daysAgo: [for (var w = 12; w >= 0; w--) w * 7],
      );
      await _pumpDetail(tester, container, series.id);
      await tester.tap(find.text('Playback'));
      await _drain(tester);
      for (var i = 0; i < 12; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      }
      await _drain(tester);
      expect(find.textContaining('13 / 13'), findsOneWidget);

      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      for (var i = 0; i < 4; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(find.textContaining('1 / 13'), findsOneWidget);

      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      container.read(secureVaultSessionProvider.notifier).lock();
      await tester.pump();
    });

    testWidgets('the frame on screen going away moves the playhead back', (
      tester,
    ) async {
      final container = await _container(tester);
      await _unlock(tester, container);
      final series = await _seed(tester, container);
      await _pumpDetail(tester, container, series.id);
      await tester.tap(find.text('Playback'));
      await _drain(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await _drain(tester);
      expect(find.textContaining('2 / 2'), findsOneWidget);

      final latest = (await tester.runAsync(
        () => container.read(photoSeriesRepositoryProvider).listCheckIns(),
      ))!.reduce((a, b) => a.takenOn.isAfter(b.takenOn) ? a : b);
      await tester.runAsync(
        () => container.read(photoSeriesServiceProvider).deleteCheckIn(latest),
      );
      await _drain(tester);
      expect(tester.takeException(), isNull);
      expect(find.textContaining('1 / 1'), findsOneWidget);

      container.read(secureVaultSessionProvider.notifier).lock();
      await tester.pump();
    });

    testWidgets('needs the vault, and locking drops back to the grid', (
      tester,
    ) async {
      final container = await _container(tester);
      await _unlock(tester, container);
      final series = await _seed(tester, container);
      await _pumpDetail(tester, container, series.id);
      await tester.tap(find.text('Playback'));
      await _drain(tester);
      expect(find.byType(AlignedPhotoFrame), findsOneWidget);

      container.read(secureVaultSessionProvider.notifier).lock();
      await _settle(tester);
      expect(find.byType(AlignedPhotoFrame), findsNothing);
      expect(find.text('Unlock to see photos'), findsOneWidget);

      await tester.tap(find.text('Compare'));
      await _settle(tester);
      expect(find.text('Side by side'), findsNothing);
      final field = tester.widget<EditableText>(find.byType(EditableText));
      expect(field.focusNode.hasFocus, isTrue);
    });
  });

  testWidgets('compare: first vs latest, then a quick pick and each mode', (
    tester,
  ) async {
    final container = await _container(tester);
    await _unlock(tester, container);
    final series = await _seed(tester, container);
    await _pumpDetail(tester, container, series.id);

    await tester.tap(find.text('Compare'));
    await _drain(tester);
    final date = DateFormat.yMMMd();
    final today = _today();
    final weekAgo = today.subtract(const Duration(days: 7));
    expect(find.text('A · ${date.format(weekAgo)}'), findsWidgets);
    expect(find.text('B · ${date.format(today)}'), findsWidgets);
    expect(find.text('7 days'), findsOneWidget);
    expect(find.byType(AlignedPhotoFrame), findsNWidgets(2));

    await tester.tap(find.text('~1 month ago'));
    await _settle(tester);
    // The nearest there is.
    expect(find.text('A · ${date.format(weekAgo)}'), findsWidgets);

    await tester.tap(find.text('Slider'));
    await _drain(tester);
    expect(find.byType(AlignedPhotoFrame), findsNWidgets(2));
    expect(find.byType(ClipRect), findsWidgets);

    await tester.tap(find.text('Overlay'));
    await _drain(tester);
    expect(find.byType(Opacity), findsWidgets);
    expect(find.byType(AlignedPhotoFrame), findsNWidgets(2));

    // Ends the idle-lock timer the taps armed.
    container.read(secureVaultSessionProvider.notifier).lock();
    await tester.pump();
  });

  // Nearest to a month before B was B itself, so A and B were one photo.
  testWidgets('compare: a quick pick never lands on B', (tester) async {
    final container = await _container(tester);
    await _unlock(tester, container);
    final series = await _seed(tester, container, daysAgo: [150, 0]);
    await _pumpDetail(tester, container, series.id);
    await tester.tap(find.text('Compare'));
    await _drain(tester);
    final date = DateFormat.yMMMd();
    final old = _today().subtract(const Duration(days: 150));

    await tester.tap(find.text('Previous'));
    await _settle(tester);
    await tester.tap(find.text('~1 month ago'));
    await _settle(tester);
    expect(find.text('A · ${date.format(old)}'), findsWidgets);

    container.read(secureVaultSessionProvider.notifier).lock();
    await tester.pump();
  });

  group('alignment', () {
    /// The series' photos, oldest first.
    Future<List<PhotoCheckInImage>> images(
      WidgetTester tester,
      ProviderContainer container,
    ) async {
      final repository = container.read(photoSeriesRepositoryProvider);
      final takenOn = {
        for (final checkIn in (await tester.runAsync(repository.listCheckIns))!)
          checkIn.id: checkIn.takenOn,
      };
      return (await tester.runAsync(repository.listImages))!..sort(
        (a, b) => takenOn[a.checkInId]!.compareTo(takenOn[b.checkInId]!),
      );
    }

    /// Opens the context menu of the [index]th tile, newest first, and picks
    /// [item].
    Future<void> menu(WidgetTester tester, int index, String item) async {
      await tester.tap(
        find.byType(VaultPhoto).at(index),
        buttons: kSecondaryButton,
        warnIfMissed: false,
      );
      await _settle(tester);
      await tester.tap(find.text(item));
      await _drain(tester);
    }

    testWidgets('zooms about the cursor, nudges, and saves on Done', (
      tester,
    ) async {
      final container = await _container(tester);
      await _unlock(tester, container);
      final series = await _seed(tester, container);
      await _pumpDetail(tester, container, series.id);

      await menu(tester, 0, 'Align');
      expect(find.textContaining('Align Front'), findsOneWidget);
      // The reference underneath, the photo being aligned over it.
      final frames = find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byType(AlignedPhotoFrame),
      );
      expect(frames, findsNWidgets(2));
      final width = tester.getSize(frames.last).width;
      final centre = tester.getCenter(frames.last);

      // Twice the size, about a point 50 px right of the centre: the photo's
      // centre ends up 50 px left of it.
      final mouse = TestPointer(1, PointerDeviceKind.mouse);
      await tester.sendEventToBinding(
        mouse.hover(centre + const Offset(50, 0)),
      );
      await tester.sendEventToBinding(
        mouse.scroll(Offset(0, -400 * math.log(2))),
      );
      await tester.pump();
      expect(find.textContaining('Zoom 200%'), findsOneWidget);
      // Shift + → nudges 10 px.
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.pump();

      await tester.tap(find.widgetWithText(GlassButton, 'Done'));
      await _drain(tester);
      expect(find.textContaining('Align Front'), findsNothing);
      final latest = (await images(tester, container)).last;
      expect(latest.alignScale, closeTo(2, 1e-6));
      expect(latest.alignDx, closeTo(-40 / width, 1e-6));
      expect(latest.alignDy, closeTo(0, 1e-6));
      expect(latest.alignRotation, 0);

      container.read(secureVaultSessionProvider.notifier).lock();
      await tester.pump();
    });

    testWidgets('copies from the previous photo; any photo can be the '
        'reference', (tester) async {
      final container = await _container(tester);
      await _unlock(tester, container);
      final series = await _seed(tester, container);
      final service = container.read(photoSeriesServiceProvider);
      final first = (await images(tester, container)).first;
      await tester.runAsync(
        () => service.setAlignment(
          first.copyWith(alignScale: 1.5, alignRotation: 0.1, alignDx: 0.2),
        ),
      );
      await _pumpDetail(tester, container, series.id);

      await menu(tester, 0, 'Align');
      await tester.tap(find.text('Copy from previous'));
      await tester.pump();
      await tester.tap(find.widgetWithText(GlassButton, 'Done'));
      await _drain(tester);
      final latest = (await images(tester, container)).last;
      expect(latest.alignScale, 1.5);
      expect(latest.alignRotation, 0.1);
      expect(latest.alignDx, 0.2);

      // The first photo is the reference until another is picked.
      Future<String?> reference() async => (await tester.runAsync(
        container.read(photoSeriesRepositoryProvider).listAngles,
      ))!.single.referenceImageId;
      await menu(tester, 1, 'Use as reference');
      expect(await reference(), isNull);
      await tester.tapAt(Offset.zero);
      await _settle(tester);
      await menu(tester, 0, 'Use as reference');
      expect(await reference(), latest.id);

      container.read(secureVaultSessionProvider.notifier).lock();
      await tester.pump();
    });

    testWidgets('replacing the reference photo hands it the role', (
      tester,
    ) async {
      final container = await _container(tester);
      await _unlock(tester, container);
      await _seed(tester, container);
      final repository = container.read(photoSeriesRepositoryProvider);
      final service = container.read(photoSeriesServiceProvider);
      final latest = (await images(tester, container)).last;
      await tester.runAsync(() async {
        await service.setReference(latest);
        await service.setPhoto(
          session: container.read(secureVaultSessionProvider)!,
          checkIn: (await repository.getCheckIn(latest.checkInId))!,
          angleId: latest.angleId,
          bytes: _jpeg(),
        );
      });
      final replacement = (await images(tester, container)).last;
      expect(replacement.id, isNot(latest.id));
      final angle = (await tester.runAsync(repository.listAngles))!.single;
      expect(angle.referenceImageId, replacement.id);
    });

    testWidgets('the viewer draws the photo aligned', (tester) async {
      final container = await _container(tester);
      await _unlock(tester, container);
      final series = await _seed(tester, container);
      final latest = (await images(tester, container)).last;
      await tester.runAsync(
        () => container
            .read(photoSeriesServiceProvider)
            .setAlignment(latest.copyWith(alignScale: 1.5)),
      );
      await _pumpDetail(tester, container, series.id);

      await tester.tap(find.byType(VaultPhoto).first, warnIfMissed: false);
      await _settle(tester);
      await tester.tap(find.byType(VaultPhoto).first);
      await _settle(tester);
      expect(find.text('2 / 2'), findsOneWidget);
      final frame = tester.widget<AlignedPhotoFrame>(
        find.byType(AlignedPhotoFrame),
      );
      expect(frame.image.alignScale, 1.5);

      container.read(secureVaultSessionProvider.notifier).lock();
      await tester.pump();
    });

    testWidgets('the arrow keys still nudge after a slider is dragged', (
      tester,
    ) async {
      final container = await _container(tester);
      await _unlock(tester, container);
      final series = await _seed(tester, container);
      await _pumpDetail(tester, container, series.id);
      await menu(tester, 0, 'Align');

      await tester.tap(find.byType(Slider).last);
      await tester.pump();
      final rotation = find.textContaining('°');
      final before = tester.widget<Text>(rotation).data;
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      expect(tester.widget<Text>(rotation).data, before);

      await tester.tap(find.widgetWithText(GlassButton, 'Done'));
      await _drain(tester);
      expect((await images(tester, container)).last.alignDx, greaterThan(0));

      container.read(secureVaultSessionProvider.notifier).lock();
      await tester.pump();
    });

    // Done's save closed the editor, then the lock closed it again — the
    // series under it, while the editor was still fading out.
    testWidgets('a lock while Done saves leaves the series open', (
      tester,
    ) async {
      final container = await _container(tester);
      await _unlock(tester, container);
      final series = await _seed(tester, container);
      await _pumpDetail(tester, container, series.id, pushed: true);
      await menu(tester, 0, 'Align');
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();

      await tester.tap(find.widgetWithText(GlassButton, 'Done'));
      container.read(secureVaultSessionProvider.notifier).lock();
      await _drain(tester);
      expect(find.textContaining('Align Front'), findsNothing);
      expect(find.byType(PhotoSeriesDetail), findsOneWidget);
    });

    // The same double close as Done's, from the viewer.
    testWidgets('a lock while the viewer closes leaves the series open', (
      tester,
    ) async {
      final container = await _container(tester);
      await _unlock(tester, container);
      final series = await _seed(tester, container);
      await _pumpDetail(tester, container, series.id, pushed: true);
      await tester.tap(find.byType(VaultPhoto).first, warnIfMissed: false);
      await _settle(tester);
      await tester.tap(find.byType(VaultPhoto).first);
      await _settle(tester);
      expect(find.text('2 / 2'), findsOneWidget);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      container.read(secureVaultSessionProvider.notifier).lock();
      await _drain(tester);
      expect(find.text('2 / 2'), findsNothing);
      expect(find.byType(PhotoSeriesDetail), findsOneWidget);
    });

    testWidgets('locking closes the editor unsaved', (tester) async {
      final container = await _container(tester);
      await _unlock(tester, container);
      final series = await _seed(tester, container);
      await _pumpDetail(tester, container, series.id);
      await menu(tester, 0, 'Align');
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();

      container.read(secureVaultSessionProvider.notifier).lock();
      await _settle(tester);
      expect(find.textContaining('Align Front'), findsNothing);
      expect((await images(tester, container)).last.alignDx, 0);
    });
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

  // On Android the camera opens over the dialog, from its Camera button.
  testWidgets('a lock closes the check-in dialog under another screen', (
    tester,
  ) async {
    final container = await _container(tester);
    await _unlock(tester, container);
    final series = await _seed(tester, container);
    await _pumpDetail(tester, container, series.id, pushed: true);
    await tester.tap(find.text('Check in'));
    await _settle(tester);
    expect(find.text('Front · 1 of 1'), findsOneWidget);
    unawaited(
      Navigator.of(
        tester.element(find.text('Front · 1 of 1')),
        rootNavigator: true,
      ).push(MaterialPageRoute<void>(builder: (_) => const Text('camera'))),
    );
    await _settle(tester);

    container.read(secureVaultSessionProvider.notifier).lock();
    await _settle(tester);
    // The camera closes itself; here, a stand-in that doesn't.
    expect(find.text('camera'), findsOneWidget);
    Navigator.of(tester.element(find.text('camera'))).pop();
    await _settle(tester);

    expect(find.text('Front · 1 of 1'), findsNothing);
    expect(find.byType(PhotoSeriesDetail), findsOneWidget);
  });

  group('a notification tap', () {
    testWidgets('with the vault open, starts a check-in of its series', (
      tester,
    ) async {
      final container = await _container(tester);
      await _unlock(tester, container);
      final series = await _seed(tester, container);
      container.read(photoSeriesCheckInRequestProvider.notifier).state =
          series.id;

      await _pumpDetail(tester, container, series.id);

      expect(find.text('Front · 1 of 1'), findsOneWidget);
      expect(container.read(photoSeriesCheckInRequestProvider), isNull);
    });

    testWidgets('while locked, opens only the detail', (tester) async {
      final container = await _container(tester);
      await _unlock(tester, container);
      final series = await _seed(tester, container);
      container.read(secureVaultSessionProvider.notifier).lock();
      container.read(photoSeriesCheckInRequestProvider.notifier).state =
          series.id;

      await _pumpDetail(tester, container, series.id);

      expect(find.text('Front · 1 of 1'), findsNothing);
      expect(find.text('Unlock to see photos'), findsOneWidget);
      // Dropped, so a later unlock doesn't start one out of nowhere.
      expect(container.read(photoSeriesCheckInRequestProvider), isNull);
      await _unlock(tester, container);
      expect(find.text('Front · 1 of 1'), findsNothing);
    });

    testWidgets('for the open series, starts its check-in there', (
      tester,
    ) async {
      final container = await _container(tester);
      await _unlock(tester, container);
      final series = await _seed(tester, container);
      await _pumpDetail(tester, container, series.id);
      expect(find.text('Front · 1 of 1'), findsNothing);

      container.read(photoSeriesCheckInRequestProvider.notifier).state =
          series.id;
      await _settle(tester);

      expect(find.text('Front · 1 of 1'), findsOneWidget);
    });

    // A check-in open under another series' would stay there, still open.
    for (final discard in [true, false]) {
      testWidgets('for another series mid-check-in, asks first: '
          '${discard ? 'Discard closes it' : 'Keep leaves it'}', (
        tester,
      ) async {
        final container = await _container(tester);
        await _unlock(tester, container);
        final series = await _seed(tester, container);
        await _pumpDetail(tester, container, series.id);
        await tester.tap(find.text('Check in'));
        await _settle(tester);
        expect(find.text('Front · 1 of 1'), findsOneWidget);

        final closed = closeOtherPhotoCheckIn(
          tester.element(find.byType(PhotoSeriesDetail)),
          'another-series',
        );
        await _settle(tester);
        await tester.tap(find.text(discard ? 'Discard' : 'Keep'));
        await _settle(tester);

        expect(await closed, discard);
        expect(
          find.text('Front · 1 of 1'),
          discard ? findsNothing : findsOneWidget,
        );
        expect(find.byType(PhotoSeriesDetail), findsOneWidget);
        // Stops its idle timer, which the taps started.
        container.read(secureVaultSessionProvider.notifier).lock();
        await _settle(tester);
      });
    }

    testWidgets("for the series mid-check-in, doesn't ask", (tester) async {
      final container = await _container(tester);
      await _unlock(tester, container);
      final series = await _seed(tester, container);
      await _pumpDetail(tester, container, series.id);
      await tester.tap(find.text('Check in'));
      await _settle(tester);

      final closed = closeOtherPhotoCheckIn(
        tester.element(find.byType(PhotoSeriesDetail)),
        series.id,
      );
      await _settle(tester);

      expect(await closed, isTrue);
      expect(find.text('Discard check-in?'), findsNothing);
      expect(find.text('Front · 1 of 1'), findsOneWidget);
      // Stops its idle timer, which the taps started.
      container.read(secureVaultSessionProvider.notifier).lock();
      await _settle(tester);
    });
  });

  // FLAG_SECURE (§6.8): set while the vault is open, on any page.
  testWidgets('the window is secure while the vault is open', (tester) async {
    final calls = <bool>[];
    SecureWindow.useAndroid = true;
    addTearDown(() => SecureWindow.useAndroid = false);
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('voyager/secure_window'),
      (call) async {
        if (call.method == 'set') calls.add(call.arguments as bool);
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('voyager/secure_window'),
        null,
      ),
    );
    final container = await _container(tester);
    expect(calls, isEmpty);

    await _unlock(tester, container);
    expect(calls.last, isTrue);

    container.read(secureVaultSessionProvider.notifier).lock();
    await _settle(tester);
    expect(calls.last, isFalse);
  });

  // On Android the dialog's photos are the camera's, which can't be picked
  // again. Replacing a photo skips the camera, which tests don't have.
  testWidgets('with a photo on Android, closing the check-in asks first', (
    tester,
  ) async {
    photoCaptureSupported = true;
    addTearDown(() => photoCaptureSupported = false);
    final file = File(
      '${Directory.systemTemp.createTempSync('voyager_photo').path}/a.jpg',
    )..writeAsBytesSync(_jpeg());
    addTearDown(() => file.parent.deleteSync(recursive: true));
    FilePicker.platform = _FakeFilePicker(file.path);
    final container = await _container(tester);
    await _unlock(tester, container);
    final series = await _seed(tester, container);
    await _pumpDetail(tester, container, series.id);
    await tester.tap(
      find.byType(VaultPhoto).first,
      buttons: kSecondaryButton,
      warnIfMissed: false,
    );
    await _settle(tester);
    // A submenu opens on hover.
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await mouse.addPointer(location: tester.getCenter(find.text('Photo')));
    await _settle(tester);
    await tester.tap(find.text('Replace Front'));
    await _settle(tester);
    expect(find.text('Front photo'), findsOneWidget);
    await tester.tap(find.text('Choose file…'));
    await _drain(tester);
    expect(find.text('Choose another…'), findsOneWidget);

    // Cancel, then the back gesture: each asks, and Cancel keeps the photo.
    await tester.tap(find.text('Cancel'));
    await _settle(tester);
    expect(find.text('Discard photo?'), findsOneWidget);
    await tester.tap(find.text('Cancel').last);
    await _settle(tester);
    expect(find.text('Discard photo?'), findsNothing);
    expect(find.text('Front photo'), findsOneWidget);

    await tester.binding.handlePopRoute();
    await _settle(tester);
    expect(find.text('Discard photo?'), findsOneWidget);
    await tester.tap(find.text('Cancel').last);
    await _settle(tester);
    expect(find.text('Front photo'), findsOneWidget);

    // The scrim asks too; Discard closes it.
    await tester.tapAt(const Offset(5, 5));
    await _settle(tester);
    expect(find.text('Discard photo?'), findsOneWidget);
    await tester.tap(find.text('Discard'));
    await _settle(tester);
    expect(find.text('Front photo'), findsNothing);
    expect(find.text('Discard photo?'), findsNothing);
    // Stops its idle timer, which the taps started.
    container.read(secureVaultSessionProvider.notifier).lock();
    await _settle(tester);
  });
  group('Phase 28A', () {
    testWidgets('BUG-284: a rejected Create keeps the caret in Name', (
      tester,
    ) async {
      final container = await _container(tester);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: VoyagerTheme.dark(),
            home: Builder(
              builder: (context) => TextButton(
                onPressed: () => showPhotoSeriesDialog(context),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await _settle(tester);
      // Name is the first field.
      bool nameFocused() => tester
          .widget<EditableText>(find.byType(EditableText).first)
          .focusNode
          .hasFocus;

      await tester.testTextInput.receiveAction(TextInputAction.done);
      await _settle(tester);
      expect(find.text('Give the series a name.'), findsOneWidget);
      expect(nameFocused(), isTrue);

      await tester.tap(find.text('Create'));
      await _settle(tester);
      expect(nameFocused(), isTrue);
    });

    testWidgets('BUG-285: a wrong password keeps the caret in the field', (
      tester,
    ) async {
      final container = await _container(tester);
      await _unlock(tester, container);
      final series = await _seed(tester, container);
      container.read(secureVaultSessionProvider.notifier).lock();
      await _pumpDetail(tester, container, series.id);

      final password = find.widgetWithText(TextField, 'Password');
      await tester.tap(password);
      await tester.enterText(password, 'wrong');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      for (var i = 0; i < 20; i++) {
        if (find.text('Wrong password.').evaluate().isNotEmpty) break;
        await _drain(tester);
      }
      expect(find.text('Wrong password.'), findsOneWidget);
      final field = tester.widget<EditableText>(find.byType(EditableText));
      expect(field.controller.text, isEmpty);
      expect(field.focusNode.hasFocus, isTrue);
    });

    group('BUG-286: closing a check-in with work in it asks first', () {
      Future<ProviderContainer> open(WidgetTester tester) async {
        final container = await _container(tester);
        await _unlock(tester, container);
        final series = await _seed(tester, container);
        await _pumpDetail(tester, container, series.id);
        await tester.tap(find.text('Check in'));
        await _settle(tester);
        expect(find.text('Front · 1 of 1'), findsOneWidget);
        return container;
      }

      testWidgets('a photo picked: Esc asks, Cancel keeps it', (tester) async {
        final file = File(
          '${Directory.systemTemp.createTempSync('voyager_photo').path}/a.jpg',
        )..writeAsBytesSync(_jpeg());
        addTearDown(() => file.parent.deleteSync(recursive: true));
        FilePicker.platform = _FakeFilePicker(file.path);
        final container = await open(tester);
        await tester.tap(find.text('Choose file…'));
        await _drain(tester);
        expect(find.text('Choose another…'), findsOneWidget);

        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await _settle(tester);
        expect(find.text('Discard check-in?'), findsOneWidget);
        await tester.tap(find.text('Cancel').last);
        await _settle(tester);
        expect(find.text('Choose another…'), findsOneWidget);

        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await _settle(tester);
        await tester.tap(find.text('Discard'));
        await _settle(tester);
        expect(find.text('Front · 1 of 1'), findsNothing);
        container.read(secureVaultSessionProvider.notifier).lock();
        await _settle(tester);
      });

      testWidgets('only a note typed: Esc from the note asks', (tester) async {
        final container = await open(tester);
        await tester.tap(find.text('Skip'));
        await _settle(tester);
        // The review's one field.
        await tester.enterText(find.byType(EditableText), 'typed note');
        await _settle(tester);

        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await _settle(tester);
        expect(find.text('Discard check-in?'), findsOneWidget);
        await tester.tap(find.text('Cancel').last);
        await _settle(tester);
        expect(find.text('typed note'), findsOneWidget);
        container.read(secureVaultSessionProvider.notifier).lock();
        await _settle(tester);
      });

      testWidgets('nothing picked or typed: Esc closes at once', (
        tester,
      ) async {
        final container = await open(tester);
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await _settle(tester);
        expect(find.text('Discard check-in?'), findsNothing);
        expect(find.text('Front · 1 of 1'), findsNothing);
        container.read(secureVaultSessionProvider.notifier).lock();
        await _settle(tester);
      });
    });

    testWidgets('BUG-288/290: the grid groups a weekly series by month, and a '
        'far done mark scrolls to its check-in', (tester) async {
      final container = await _container(tester);
      await _unlock(tester, container);
      final weeks = [for (var i = 0; i < 80; i++) i * 7];
      final series = await _seed(tester, container, daysAgo: weeks);
      await _pumpDetail(tester, container, series.id);

      // A month's check-ins share a row, under the month's label.
      final now = DateTime.now();
      expect(
        find.text(DateFormat.yMMMM().format(DateTime(now.year, now.month))),
        findsOneWidget,
      );
      expect(find.textContaining('Week of'), findsNothing);
      final tops = [
        for (final element in find.byType(VaultPhoto).evaluate())
          tester.getTopLeft(find.byWidget(element.widget)).dy,
      ];
      expect(tops.toSet().length, lessThan(tops.length));

      final oldest = now.subtract(Duration(days: weeks.last));
      final oldestDay = DateTime(oldest.year, oldest.month, oldest.day);
      final oldestDate = find.text(DateFormat.yMMMd().format(oldestDay));
      expect(oldestDate.hitTestable(), findsNothing);
      final week = DateFormat.yMMMd().format(
        photoPeriodStart(oldestDay, TrackerCadence.weekly),
      );
      final mark = find.descendant(
        of: find.byWidgetPredicate(
          (w) => w is Tooltip && w.message == 'Week of $week · done',
        ),
        matching: find.byType(InkWell),
      );
      tester.widget<InkWell>(mark).onTap!();
      for (var i = 0; i < 30; i++) {
        await tester.pump(const Duration(milliseconds: 80));
      }
      expect(oldestDate.hitTestable(), findsOneWidget);
      container.read(secureVaultSessionProvider.notifier).lock();
      await _settle(tester);
    });

    testWidgets('a yearly series is one grid group, its tiles sharing a row', (
      tester,
    ) async {
      final container = await _container(tester);
      await _unlock(tester, container);
      final series = await _seed(
        tester,
        container,
        daysAgo: const [0, 365, 730],
        cadence: TrackerCadence.yearly,
      );
      await _pumpDetail(tester, container, series.id);

      final tops = [
        for (final element in find.byType(VaultPhoto).evaluate())
          tester.getTopLeft(find.byWidget(element.widget)).dy,
      ];
      expect(tops, hasLength(3));
      expect(tops.toSet(), hasLength(1));
      container.read(secureVaultSessionProvider.notifier).lock();
      await _settle(tester);
    });

    testWidgets('BUG-289: a photo that fails to decode saves nothing', (
      tester,
    ) async {
      final container = await _container(tester);
      await _unlock(tester, container);
      final series = await _seed(tester, container, daysAgo: const []);
      final repository = container.read(photoSeriesRepositoryProvider);
      final service = container.read(photoSeriesServiceProvider);
      final session = container.read(secureVaultSessionProvider)!;
      final big = img.Image(width: 400, height: 300);
      for (final pixel in big) {
        pixel
          ..r = (pixel.x * 7) % 256
          ..g = (pixel.y * 5) % 256;
      }
      final whole = img.encodeJpg(big);
      // The first 40% of a valid JPEG, as `p08-truncated.jpg`.
      final truncated = Uint8List.sublistView(
        whole,
        0,
        (whole.length * 0.4).round(),
      );
      await tester.runAsync(() async {
        await service.saveAngles(series, [
          for (final angle in await repository.listAngles())
            (id: angle.id, name: angle.name),
          (id: null, name: 'Back'),
        ]);
        final angles = await repository.listAngles();
        final front = angles.firstWhere((a) => a.name == 'Front');
        final back = angles.firstWhere((a) => a.name == 'Back');
        await expectLater(
          service.createCheckIn(
            session: session,
            series: series,
            takenOn: DateTime.now(),
            // The good one first, as in the report.
            photos: {back.id: _jpeg(), front.id: truncated},
          ),
          throwsA(
            isA<MediaIngestException>().having(
              (e) => e.message,
              'message',
              'That image could not be read.',
            ),
          ),
        );
        expect(await repository.listBlobs(includeDeleted: true), isEmpty);
        expect(await repository.listImages(includeDeleted: true), isEmpty);
      });
    });

    testWidgets('BUG-291: with ten angles, the tile date and Skipped stay on '
        'one line', (tester) async {
      final container = await _container(tester);
      await _unlock(tester, container);
      late PhotoSeries series;
      await tester.runAsync(() async {
        final service = container.read(photoSeriesServiceProvider);
        series = await service.createSeries(
          name: 'Ten',
          cadence: TrackerCadence.weekly,
          sortOrder: 0,
          angleNames: [for (var i = 1; i <= 10; i++) 'Angle $i'],
        );
        final angles = await container
            .read(photoSeriesRepositoryProvider)
            .listAngles();
        await service.createCheckIn(
          session: container.read(secureVaultSessionProvider)!,
          series: series,
          takenOn: DateTime.now(),
          photos: {angles.first.id: _jpeg()},
        );
      });
      await _pumpDetail(tester, container, series.id);
      double lines(Finder text) {
        final paragraph = tester.renderObject<RenderParagraph>(text);
        return paragraph.size.height /
            paragraph.getFullHeightForCaret(const TextPosition(offset: 0));
      }

      expect(
        // The tile's, after the stats row's first – latest.
        lines(find.text(DateFormat.yMMMd().format(_today())).last),
        lessThan(1.5),
      );

      await tester.tap(find.text('Check in'));
      await _settle(tester);
      for (var i = 0; i < 10; i++) {
        await tester.tap(find.text('Skip'));
        await _settle(tester);
      }
      final skipped = find.text('Skipped');
      expect(skipped, findsNWidgets(10));
      for (final element in skipped.evaluate()) {
        expect(lines(find.byWidget(element.widget)), lessThan(1.5));
      }
      container.read(secureVaultSessionProvider.notifier).lock();
      await _settle(tester);
    });

    testWidgets('BUG-292: in Light the Due and Done badges clear 4.5:1', (
      tester,
    ) async {
      double contrast(Color a, Color b) {
        final (x, y) = (a.computeLuminance(), b.computeLuminance());
        return (math.max(x, y) + 0.05) / (math.min(x, y) + 0.05);
      }

      final theme = VoyagerTheme.light();
      for (final done in [true, false]) {
        await tester.pumpWidget(
          MaterialApp(
            theme: theme,
            home: Scaffold(body: PhotoPeriodBadge(done: done)),
          ),
        );
        final text = tester.widget<Text>(find.text(done ? 'Done' : 'Due'));
        final box = tester.widget<Container>(
          find.ancestor(
            of: find.byWidget(text),
            matching: find.byType(Container),
          ),
        );
        final fill = (box.decoration! as BoxDecoration).color!;
        expect(
          contrast(
            text.style!.color!,
            Color.alphaBlend(fill, theme.scaffoldBackgroundColor),
          ),
          greaterThanOrEqualTo(4.5),
        );
      }
    });
  });

  group('Phase 28B', () {
    /// Seals [image]'s blob under another vault, as far as its row says, so
    /// it never opens again.
    Future<void> damage(
      WidgetTester tester,
      ProviderContainer container,
      PhotoCheckInImage image,
    ) async {
      final repository = container.read(photoSeriesRepositoryProvider);
      await tester.runAsync(() async {
        final blob = (await repository.getBlob(image.blobId))!;
        await repository.upsertBlob(
          VaultBlob(
            id: blob.id,
            vaultId: 'another-vault',
            width: blob.width,
            height: blob.height,
            byteSize: blob.byteSize,
            thumbByteSize: blob.thumbByteSize,
            createdAt: blob.createdAt,
            updatedAt: blob.updatedAt,
          ),
        );
      });
    }

    testWidgets('BUG-298: the Overlay slider is named and reads out its '
        'value', (tester) async {
      final container = await _container(tester);
      await _unlock(tester, container);
      final series = await _seed(tester, container);
      await _pumpDetail(tester, container, series.id);
      await tester.tap(find.text('Compare'));
      await _drain(tester);
      await tester.tap(find.text('Overlay'));
      await _settle(tester);

      expect(find.text('B over A'), findsOneWidget);
      expect(find.text('50%'), findsOneWidget);
      tester.widget<Slider>(find.byType(Slider)).onChanged!(0);
      await tester.pump();
      expect(find.text('0%'), findsOneWidget);

      container.read(secureVaultSessionProvider.notifier).lock();
      await tester.pump();
    });

    testWidgets("BUG-299: stopped on a photo that won't open, Playback says "
        'so under its own date', (tester) async {
      final container = await _container(tester);
      await _unlock(tester, container);
      final series = await _seed(tester, container);
      final repository = container.read(photoSeriesRepositoryProvider);
      final checkIns = (await tester.runAsync(repository.listCheckIns))!;
      final latest = checkIns.reduce(
        (a, b) => a.takenOn.isAfter(b.takenOn) ? a : b,
      );
      final images = (await tester.runAsync(repository.listImages))!;
      await damage(
        tester,
        container,
        images.singleWhere((image) => image.checkInId == latest.id),
      );
      await _pumpDetail(tester, container, series.id);
      await tester.tap(find.text('Playback'));
      await _drain(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await _drain(tester);

      expect(find.textContaining('2 / 2'), findsOneWidget);
      expect(find.text("Can't be opened"), findsOneWidget);
      final date = DateFormat.yMMMd().format(_today());
      expect(find.textContaining('$date  +'), findsOneWidget);

      container.read(secureVaultSessionProvider.notifier).lock();
      await tester.pump();
    });

    testWidgets("BUG-301: a photo that isn't here says why", (tester) async {
      final files = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('voyager_photo_page'),
      ))!;
      addTearDown(() => files.delete(recursive: true));
      final container = await _container(
        tester,
        files: files,
        settings: const AppSettings().copyWith(
          mediaRemoteUploadsEnabled: false,
          mediaRemoteDownloadsEnabled: false,
        ),
      );
      await _unlock(tester, container);
      final series = await _seed(tester, container, daysAgo: [0]);
      final repository = container.read(photoSeriesRepositoryProvider);
      final blobId = (await tester.runAsync(
        repository.listImages,
      ))!.single.blobId;
      // Another device's, in Storage, and not fetched here.
      await tester.runAsync(() async {
        await for (final file in files.list()) {
          await file.delete();
        }
        await repository.updateBlobTransferState(
          blobId,
          uploadState: MediaUploadState.uploaded,
          downloadState: MediaDownloadState.missing,
          thumbDownloadState: MediaDownloadState.missing,
        );
      });
      await _pumpDetail(tester, container, series.id);
      await _drain(tester);
      expect(find.text('Download disabled'), findsOneWidget);
      // Not under the blur, which would make it unreadable.
      expect(
        find.ancestor(
          of: find.text('Download disabled'),
          matching: find.byType(ImageFiltered),
        ),
        findsNothing,
      );

      // Never uploaded by the device that has it.
      await tester.runAsync(
        () => repository.updateBlobTransferState(
          blobId,
          uploadState: MediaUploadState.localOnly,
        ),
      );
      container.read(vaultMediaServiceProvider).notifyChanged();
      await _drain(tester);
      expect(find.text('On another device'), findsOneWidget);

      container.read(secureVaultSessionProvider.notifier).lock();
      await tester.pump();
    });

    testWidgets('BUG-302: leaving Playback of a series with no photos throws '
        'nothing', (tester) async {
      final container = await _container(tester);
      await _unlock(tester, container);
      final series = await _seed(tester, container, daysAgo: []);
      await _pumpDetail(tester, container, series.id);
      await tester.tap(find.text('Playback'));
      await _settle(tester);
      expect(find.text('No photos to play yet.'), findsOneWidget);

      await tester.tap(find.text('Grid'));
      await _settle(tester);
      expect(tester.takeException(), isNull);

      container.read(secureVaultSessionProvider.notifier).lock();
      await tester.pump();
    });

    testWidgets('BUG-303: in a short window the alignment editor fits, and '
        "Compare's photos sit side by side", (tester) async {
      final container = await _container(tester);
      await _unlock(tester, container);
      final series = await _seed(tester, container);
      await _pumpDetail(tester, container, series.id);
      tester.view.physicalSize = const Size(720, 520);
      await _settle(tester);

      // The newer photo, so the editor has a reference and an Opacity row.
      await tester.tap(
        find.byType(VaultPhoto).first,
        buttons: kSecondaryButton,
        warnIfMissed: false,
      );
      await _settle(tester);
      await tester.tap(find.text('Align'));
      await _drain(tester);
      expect(find.text('Opacity'), findsOneWidget);
      expect(tester.takeException(), isNull);
      final rotation = tester.getRect(find.text('Rotation'));
      final done = tester.getRect(find.widgetWithText(GlassButton, 'Done'));
      expect(done.top, greaterThan(rotation.bottom));
      await tester.tap(find.widgetWithText(GlassButton, 'Cancel'));
      await _settle(tester);

      await tester.tap(find.text('Compare'));
      await _drain(tester);
      final frames = find.byType(AlignedPhotoFrame);
      expect(
        tester.getCenter(frames.first).dy,
        tester.getCenter(frames.last).dy,
      );

      container.read(secureVaultSessionProvider.notifier).lock();
      await tester.pump();
    });

    testWidgets('BUG-304: dragging the scrubber, the caption follows the '
        'playhead', (tester) async {
      final container = await _container(tester);
      await _unlock(tester, container);
      final series = await _seed(tester, container, daysAgo: [14, 7, 0]);
      await _pumpDetail(tester, container, series.id);
      await tester.tap(find.text('Playback'));
      await _drain(tester);

      final caption = find.textContaining('1 / 3');
      final scrubber = tester.getRect(
        find.ancestor(of: caption, matching: find.byType(Column)).first,
      );
      final y = scrubber.bottom - 14;
      final start = Offset(scrubber.left + 9, y);
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: start - const Offset(1, 0));
      addTearDown(mouse.removePointer);
      await mouse.moveTo(start);
      await tester.pump();
      await mouse.down(start);
      for (var i = 1; i <= 4; i++) {
        await mouse.moveTo(start + Offset((scrubber.width - 18) * i / 4, 0));
        await tester.pump();
      }
      await _drain(tester);
      expect(find.textContaining('3 / 3'), findsOneWidget);
      await mouse.up();
      await tester.pump();

      container.read(secureVaultSessionProvider.notifier).lock();
      await tester.pump();
    });
  });

  group('MD-18', () {
    testWidgets('BUG-305: the open viewer takes a new check-in and a '
        'replaced photo', (tester) async {
      final container = await _container(tester);
      await _unlock(tester, container);
      final series = await _seed(tester, container, daysAgo: [7]);
      await _pumpDetail(tester, container, series.id);
      await tester.tap(find.byType(VaultPhoto).first, warnIfMissed: false);
      await _settle(tester);
      await tester.tap(find.byType(VaultPhoto).first);
      await _settle(tester);
      expect(find.text('1 / 1'), findsOneWidget);

      // As a pull writes them: straight to the database.
      final repository = container.read(photoSeriesRepositoryProvider);
      final service = container.read(photoSeriesServiceProvider);
      final session = container.read(secureVaultSessionProvider)!;
      late PhotoCheckInImage replacement;
      await tester.runAsync(() async {
        final angle = (await repository.listAngles()).single;
        final checkIn = (await repository.listCheckIns()).single;
        await service.createCheckIn(
          session: session,
          series: series,
          takenOn: DateTime.now(),
          photos: {angle.id: _jpeg()},
        );
        await service.setPhoto(
          session: session,
          checkIn: checkIn,
          angleId: angle.id,
          bytes: _jpeg(),
        );
        replacement = (await repository.listImages()).firstWhere(
          (image) => image.checkInId == checkIn.id,
        );
      });
      await _drain(tester);

      expect(find.text('1 / 2'), findsOneWidget);
      expect(
        find.byWidgetPredicate(
          (w) => w is VaultPhoto && !w.thumb && w.blobId == replacement.blobId,
        ),
        findsOneWidget,
      );

      container.read(secureVaultSessionProvider.notifier).lock();
      await _settle(tester);
    });

    testWidgets('BUG-307: an angle removed elsewhere leaves the open '
        'check-in, with its photo', (tester) async {
      final file = File(
        '${Directory.systemTemp.createTempSync('voyager_photo').path}/a.jpg',
      )..writeAsBytesSync(_jpeg());
      addTearDown(() => file.parent.deleteSync(recursive: true));
      FilePicker.platform = _FakeFilePicker(file.path);
      final container = await _container(tester);
      await _unlock(tester, container);
      final repository = container.read(photoSeriesRepositoryProvider);
      late PhotoSeries series;
      await tester.runAsync(() async {
        series = await container
            .read(photoSeriesServiceProvider)
            .createSeries(
              name: 'Progress',
              cadence: TrackerCadence.weekly,
              sortOrder: 0,
              angleNames: ['Front', 'Side'],
            );
      });
      await _pumpDetail(tester, container, series.id);
      await tester.tap(find.text('Check in'));
      await _settle(tester);
      await tester.tap(find.text('Choose file…'));
      await _drain(tester);
      await tester.tap(find.text('Next'));
      await _settle(tester);
      expect(find.text('Side · 2 of 2'), findsOneWidget);

      // As a pull writes it: straight to the database.
      await tester.runAsync(() async {
        final front = (await repository.listAngles()).firstWhere(
          (a) => a.name == 'Front',
        );
        final now = DateTime.now().toUtc();
        await repository.upsertAngle(
          front.copyWith(deletedAt: now, updatedAt: now),
        );
      });
      await _drain(tester);

      expect(find.text('Side · 1 of 1'), findsOneWidget);
      expect(find.text('Front was removed on another device.'), findsOneWidget);
      // Front's photo went with it: nothing left to save.
      expect(find.text('Skip'), findsOneWidget);
      await tester.tap(find.text('Skip'));
      await _settle(tester);
      expect(
        tester
            .widget<GlassButton>(find.widgetWithText(GlassButton, 'Save'))
            .onPressed,
        isNull,
      );

      container.read(secureVaultSessionProvider.notifier).lock();
      await _settle(tester);
    });

    testWidgets('BUG-307: the series deleted elsewhere empties the open '
        'check-in, and says so', (tester) async {
      final file = File(
        '${Directory.systemTemp.createTempSync('voyager_photo').path}/a.jpg',
      )..writeAsBytesSync(_jpeg());
      addTearDown(() => file.parent.deleteSync(recursive: true));
      FilePicker.platform = _FakeFilePicker(file.path);
      final container = await _container(tester);
      await _unlock(tester, container);
      final series = await _seed(tester, container, daysAgo: []);
      await _pumpDetail(tester, container, series.id);
      await tester.tap(find.text('Check in'));
      await _settle(tester);
      await tester.tap(find.text('Choose file…'));
      await _drain(tester);

      await tester.runAsync(
        () => container.read(photoSeriesServiceProvider).deleteSeries(series),
      );
      await _drain(tester);

      expect(
        find.text('This series was deleted on another device.'),
        findsOneWidget,
      );
      expect(find.text('Choose another…'), findsNothing);
      expect(
        tester
            .widget<GlassButton>(find.widgetWithText(GlassButton, 'Save'))
            .onPressed,
        isNull,
      );

      container.read(secureVaultSessionProvider.notifier).lock();
      await _settle(tester);
    });

    testWidgets('BUG-310: the unlock card tells of photos a reset elsewhere '
        "dropped, and unlocking there clears it", (tester) async {
      final container = await _container(tester);
      await _unlock(tester, container);
      final series = await _seed(tester, container, daysAgo: [7]);
      final notes = container.read(notificationRepositoryProvider);
      await tester.runAsync(() => notes.setLostVaultPhotoCount(2));
      container.read(secureVaultSessionProvider.notifier).lock();
      await _pumpDetail(tester, container, series.id);
      await tester.runAsync(
        () => container.read(secureVaultLostProvider.future),
      );
      await _settle(tester);

      const told =
          "The vault was reset on another device, so 2 photos made on this "
          "device weren't kept.";
      expect(find.text(told), findsOneWidget);

      await tester.enterText(find.byType(TextField), _password);
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await _drain(tester);
      expect(await tester.runAsync(notes.lostVaultPhotoCount), 0);

      container.read(secureVaultSessionProvider.notifier).lock();
      await _drain(tester);
      expect(find.text(told), findsNothing);
    });
  });
}

/// Picks [path], whatever is asked for.
class _FakeFilePicker extends FilePicker {
  _FakeFilePicker(this.path);

  final String path;

  @override
  Future<FilePickerResult?> pickFiles({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Function(FilePickerStatus)? onFileLoading,
    bool allowCompression = true,
    int compressionQuality = 30,
    bool allowMultiple = false,
    bool withData = false,
    bool withReadStream = false,
    bool lockParentWindow = false,
    bool readSequential = false,
  }) async => FilePickerResult([
    PlatformFile(name: 'a.jpg', size: File(path).lengthSync(), path: path),
  ]);
}

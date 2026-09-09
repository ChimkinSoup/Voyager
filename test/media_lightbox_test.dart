import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/media/media_service.dart';
import 'package:voyager/core/media/widgets/media_image.dart';
import 'package:voyager/core/media/widgets/media_lightbox.dart';
import 'package:voyager/core/sync/firestore_collections.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/data/repositories/drift_repositories.dart';
import 'package:voyager/data/services/media_file_store.dart';
import 'package:voyager/domain/models/media_models.dart';
import 'package:voyager/domain/models/settings_models.dart';

Uint8List pngOf(int width, int height) {
  final image = img.Image(width: width, height: height, numChannels: 3);
  img.fill(image, color: img.ColorRgb8(200, 30, 60));
  return img.encodePng(image);
}

/// Pumps far enough for the route transition and the image's byte read to
/// land, without waiting for a world with no running animations in it.
Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

/// A mouse flick: eight moves and a release, each stamped so the release
/// carries a velocity.
///
/// A mouse rather than a finger because that is what makes the drag the
/// viewer's own to answer for. `Scrollable` only accepts the drag devices its
/// `ScrollBehavior` lists and Material's list holds no mouse, so a touch drag
/// is caught by the `PageView`'s own recognizer — which sits above the
/// `IgnorePointer` and so keeps working where a real one on the desktop does
/// not.
///
/// Hand-driven rather than [WidgetTester.timedDragFrom] both for that and so
/// the pointer can be lifted without waiting out the settle it starts. The
/// timestamps are the other half: a `TestGesture` stamps every move
/// `Duration.zero` by default, and a velocity tracker fed one instant sees a
/// drag that never moved.
Future<void> mouseFlick(
  WidgetTester tester,
  Offset from,
  double dx, {
  bool release = true,
}) async {
  final gesture = await tester.startGesture(from, kind: PointerDeviceKind.mouse);
  var stamp = Duration.zero;
  for (var i = 0; i < 8; i++) {
    stamp += const Duration(milliseconds: 16);
    await gesture.moveBy(Offset(dx / 8, 0), timeStamp: stamp);
    await tester.pump(const Duration(milliseconds: 16));
  }
  if (release) await gesture.up(timeStamp: stamp);
}

void main() {
  late Directory tempDir;
  late AppDatabase db;
  late MediaFileStore fileStore;
  late MediaService service;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('voyager_lightbox');
    db = AppDatabase.inMemory();
    fileStore = MediaFileStore(root: Directory('${tempDir.path}/media'));
    service = MediaService(
      repository: DriftMediaRepository(db),
      fileStore: fileStore,
      readSettings: () async => const AppSettings(),
    );
  });

  tearDown(() async {
    await db.close();
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  /// A small image, so the picture occupies the middle of the viewport and
  /// leaves real dead space around it for the dismiss taps to land in.
  ///
  /// [WidgetTester.runAsync] because an ingest hands the decode to `compute`,
  /// and an isolate's answer never arrives inside the fake async zone a
  /// widget test otherwise runs in.
  Future<MediaAsset> attach(WidgetTester tester) async {
    late MediaAsset asset;
    await tester.runAsync(() async {
      final reference = await service.attachBytes(
        bytes: pngOf(40, 40),
        collection: FirestoreCollections.todoTasks,
        documentId: 'task-1',
      );
      asset = (await service.asset(reference.mediaId))!;
    });
    return asset;
  }

  /// [count] distinct images on one owner, in the order they were attached.
  ///
  /// A different pixel per call so each is its own asset rather than the same
  /// one deduplicated by content hash.
  Future<List<MediaAsset>> attachMany(WidgetTester tester, int count) async {
    final assets = <MediaAsset>[];
    await tester.runAsync(() async {
      for (var i = 0; i < count; i++) {
        final image = img.Image(width: 40, height: 40, numChannels: 3);
        img.fill(image, color: img.ColorRgb8(20 * (i + 1), 30, 60));
        final reference = await service.attachBytes(
          bytes: img.encodePng(image),
          collection: FirestoreCollections.todoTasks,
          documentId: 'task-many',
        );
        assets.add((await service.asset(reference.mediaId))!);
      }
    });
    return assets;
  }

  Future<void> openMany(WidgetTester tester, List<MediaAsset> assets) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          mediaServiceProvider.overrideWith((ref) => service),
          mediaFileStoreProvider.overrideWithValue(fileStore),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => Center(
                child: ElevatedButton(
                  onPressed: () => showMediaLightbox(context, assets: assets),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await settle(tester);
    // Real time until every page the viewer built has its bytes: a disk read
    // started inside a widget test's fake async zone only completes while
    // `runAsync` is letting the real event loop turn, and the viewer now
    // starts one per page rather than one in total.
    for (var i = 0; i < 20; i++) {
      if (find
          .byType(CircularProgressIndicator, skipOffstage: false)
          .evaluate()
          .isEmpty) {
        return;
      }
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump();
    }
  }

  Future<void> openLightbox(WidgetTester tester, MediaAsset asset) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          mediaServiceProvider.overrideWith((ref) => service),
          mediaFileStoreProvider.overrideWithValue(fileStore),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => Center(
                child: ElevatedButton(
                  onPressed: () =>
                      showMediaLightbox(context, assets: [asset]),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    // The route transition in fake time, then real time for the image's
    // bytes to come off disk — another read the fake zone would never
    // complete. Bounded pumps rather than pumpAndSettle: a MediaImage that is
    // still resolving paints a CircularProgressIndicator, which never
    // settles.
    await settle(tester);
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pump();
    expect(find.byType(InteractiveViewer), findsOneWidget);
  }

  testWidgets('a tap on the dimmed background closes the viewer', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final asset = await attach(tester);
    await openLightbox(tester, asset);

    // Top-left corner: inside the InteractiveViewer, which hit-tests opaquely
    // across the whole screen, but far outside the centred picture. This is
    // the tap that used to be swallowed.
    await tester.tapAt(const Offset(20, 20));
    await settle(tester);

    expect(
      find.byType(InteractiveViewer),
      findsNothing,
      reason: 'the background tap should have dismissed the lightbox',
    );
  });

  testWidgets('a tap on the picture itself keeps the viewer open', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final asset = await attach(tester);
    await openLightbox(tester, asset);

    await tester.tap(find.byType(MediaImage));
    await settle(tester);

    expect(find.byType(InteractiveViewer), findsOneWidget);
  });

  testWidgets('the close button still dismisses it', (tester) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final asset = await attach(tester);
    await openLightbox(tester, asset);

    await tester.tap(find.byTooltip('Close'));
    await settle(tester);

    expect(find.byType(InteractiveViewer), findsNothing);
  });

  testWidgets('the next image is built and resolved before the slide starts', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final assets = await attachMany(tester, 3);
    await openMany(tester, assets);

    // `skipOffstage: false` because the preloaded page is exactly the one a
    // default finder hides: a sliver's cache-region children are laid out but
    // outside the paint extent, and `debugVisitOnstageChildren` walks past
    // them.
    final images = tester.widgetList<MediaImage>(
      find.byType(MediaImage, skipOffstage: false),
    );
    // The page after the current one exists while the viewer is still sitting
    // still. This is the whole preload: without it the incoming page is only
    // created once the animation is under way, and its bytes land after the
    // slide has finished — the picture appearing in an already-arrived frame.
    expect(images.map((it) => it.asset.id), contains(assets[1].id));

    // And every one of them is a picture, not the spinner a page that has not
    // read its bytes yet would be painting.
    expect(
      find.byType(CircularProgressIndicator, skipOffstage: false),
      findsNothing,
    );
    expect(
      find.byType(Image, skipOffstage: false),
      findsNWidgets(images.length),
    );

    // Only the neighbour, not the whole set: a viewer opened on forty images
    // must not read forty files.
    expect(images.map((it) => it.asset.id), isNot(contains(assets[2].id)));
  });

  testWidgets('dragging the image sideways turns the page', (tester) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final assets = await attachMany(tester, 3);
    await openMany(tester, assets);
    expect(find.text('1 / 3'), findsOneWidget);

    // From the middle of the screen, which is the picture itself and so where
    // the InteractiveViewer's own recognizer takes the arena — the drag that
    // used to go nowhere. `timedDragFrom` rather than a finder: once the page
    // has turned, the first InteractiveViewer in the tree is the one that has
    // just slid off-screen, and a drag started on it hits nothing.
    await tester.timedDragFrom(
      const Offset(600, 450),
      const Offset(-400, 0),
      const Duration(milliseconds: 120),
    );
    await settle(tester);

    expect(find.text('2 / 3'), findsOneWidget);

    await tester.timedDragFrom(
      const Offset(600, 450),
      const Offset(400, 0),
      const Duration(milliseconds: 120),
    );
    await settle(tester);

    expect(find.text('1 / 3'), findsOneWidget);
  });

  testWidgets('a page still settling can be grabbed again', (tester) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final assets = await attachMany(tester, 3);
    await openMany(tester, assets);

    await mouseFlick(tester, const Offset(600, 450), -400);

    // Far enough in that the page has turned and the slide is still running:
    // the ballistic runs the better part of half a second, and the picture is
    // under the pointer for all of it.
    await tester.pump();
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(find.text('2 / 3'), findsOneWidget);

    // The grab that used to land on nothing: `Scrollable` wraps its viewport
    // in an `IgnorePointer` for the whole ballistic, so until the image had
    // finished arriving it was not there to be touched.
    await mouseFlick(tester, const Offset(600, 450), 400);
    await settle(tester);

    expect(
      find.text('1 / 3'),
      findsOneWidget,
      reason: 'a drag started mid-settle should turn the page back',
    );
  });

  testWidgets('a drag on a zoomed image pans it instead of turning the page', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final assets = await attachMany(tester, 3);
    await openMany(tester, assets);

    await tester.tap(find.byTooltip('Zoom in'));
    await settle(tester);

    await tester.timedDragFrom(
      const Offset(600, 450),
      const Offset(-400, 0),
      const Duration(milliseconds: 120),
    );
    await settle(tester);

    expect(
      find.text('1 / 3'),
      findsOneWidget,
      reason: 'a magnified page keeps the drag for its own panning',
    );
  });

  testWidgets('a single image does not drag anywhere', (tester) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final asset = await attach(tester);
    await openLightbox(tester, asset);

    await tester.timedDragFrom(
      const Offset(600, 450),
      const Offset(-400, 0),
      const Duration(milliseconds: 120),
    );
    await settle(tester);

    expect(find.byType(InteractiveViewer), findsOneWidget);
  });
}

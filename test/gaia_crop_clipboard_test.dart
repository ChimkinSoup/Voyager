import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/domain/models/gaia_models.dart';
import 'package:voyager/features/gaia/companion/gaia_controller.dart';

import 'fakes/gaia_fakes.dart';

/// A finished crop (GAIA_HLD.md §15.1 C) joins the draft and the clipboard.
void main() {
  late FakeGaiaPipe companion;
  late GaiaController controller;
  late Directory dir;
  late List<Uint8List> copied;
  late String shot;

  /// Gaia on the crop overlay over an 8×4 capture. [copyPng] stands in for
  /// the system clipboard.
  Future<void> startCrop(Future<void> Function(Uint8List png) copyPng) async {
    dir = await Directory.systemTemp.createTemp('gaia_crop_clipboard');
    addTearDown(() => dir.delete(recursive: true));
    final main = FakeGaiaPipe.main();
    main
      ..onLaunch = (end, _) {
        companion = end;
      }
      ..onRequest = (method, params) async => switch (method) {
        'hello' => {
          'aborted': false,
          'accent': 0xFF7C9EFF,
          'deviceId': 'laptop',
          'settings': GaiaSettings.initial().toJson(),
        },
        'chats' || 'drafts' => <Object?>[],
        'ingestImage' => 'media1',
        _ => null,
      };
    await main.startCompanion();
    controller = GaiaController(
      pipe: companion,
      window: FakeGaiaWindow(),
      runners: {kGaiaClaudeCodeAdapter: FakeClaudeRunner()},
      cliVersions: {kGaiaClaudeCodeAdapter: () async => (2, 1, 310)},
      exit: (_) {},
      copyPng: copyPng,
      draftDirectory: dir.path,
    );
    await controller.start();

    final recorder = ui.PictureRecorder();
    ui.Canvas(recorder);
    final image = await recorder.endRecording().toImage(8, 4);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    shot = '${dir.path}/shot.png';
    await File(shot).writeAsBytes(data!.buffer.asUint8List());

    companion.onEvent!('capture', {
      'kind': 'region',
      'path': shot,
      'left': 0,
      'top': 0,
      'width': 8,
      'height': 4,
    });
    for (var i = 0; i < 100 && controller.cropping == null; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }

  setUp(() => copied = []);

  testWidgets('the crop goes on the clipboard as the PNG the draft holds', (
    tester,
  ) async {
    await tester.runAsync(() async {
      await startCrop((png) async => copied.add(png));
      await controller.finishCrop(const ui.Rect.fromLTWH(2, 0, 6, 4));

      final attached = await File(
        controller.draftImages.single.path,
      ).readAsBytes();
      expect(copied.single, attached);
      expect(copied.single.sublist(1, 4), 'PNG'.codeUnits);
      expect(controller.draft.text, '[image 1] ');
    });
  });

  testWidgets('a cancelled crop leaves the clipboard alone', (tester) async {
    await tester.runAsync(() async {
      await startCrop((png) async => copied.add(png));
      await controller.finishCrop(null);

      expect(copied, isEmpty);
      expect(controller.draftImages, isEmpty);
    });
  });

  testWidgets('a clipboard that will not open keeps the crop in the draft, '
      'and says so', (tester) async {
    await tester.runAsync(() async {
      await startCrop((_) async {
        throw PlatformException(code: 'CLIPBRD_E_CANT_OPEN');
      });
      final toasts = <String>[];
      controller.toasts.listen((toast) => toasts.add(toast.title));
      await controller.finishCrop(const ui.Rect.fromLTWH(2, 0, 6, 4));
      await Future<void>.delayed(Duration.zero);

      expect(controller.draftImages, hasLength(1));
      expect(toasts, ['Image not copied']);
    });
  });
}

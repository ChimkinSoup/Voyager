import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/domain/models/gaia_models.dart';
import 'package:voyager/features/gaia/adapters/claude_code/claude_code_runner.dart';
import 'package:voyager/features/gaia/companion/gaia_attachments.dart';
import 'package:voyager/features/gaia/companion/gaia_image_render.dart';

/// Attached images (GAIA_HLD.md §9.3): the part, the draft's numbering, and
/// the content blocks Claude Code gets.
void main() {
  test('an image part round-trips through JSON', () {
    const part = GaiaImagePart(
      mediaId: 'm1',
      label: 3,
      width: 1920,
      height: 1080,
    );
    final back = GaiaPart.fromJson(part.toJson()) as GaiaImagePart;
    expect(
      (back.mediaId, back.label, back.width, back.height),
      ('m1', 3, 1920, 1080),
    );
  });

  test('the next label follows the highest in the chat', () {
    GaiaMessage message(List<GaiaPart> parts) => GaiaMessage(
      id: 'x',
      chatId: 'c',
      seq: 0,
      role: GaiaMessageRole.user,
      parts: parts,
      status: GaiaMessageStatus.complete,
      createdAt: DateTime.utc(2026),
      updatedAt: DateTime.utc(2026),
    );
    expect(gaiaNextImageLabel([]), 1);
    expect(
      gaiaNextImageLabel([
        message([
          const GaiaTextPart('a'),
          const GaiaImagePart(mediaId: 'a', label: 2, width: 1, height: 1),
        ]),
      ]),
      3,
    );
  });

  group('relabelling a draft', () {
    test('numbers on from the chat, rewriting the tokens', () {
      final (text, images) = gaiaRelabelDraft('Is [image 2] like [image 5]?', [
        GaiaDraftImage(label: 2, path: 'a'),
        GaiaDraftImage(label: 5, path: 'b'),
      ], 4);
      expect(text, 'Is [image 4] like [image 5]?');
      expect(images.map((i) => (i.label, i.path)), [(4, 'a'), (5, 'b')]);
    });

    test("leaves a token naming no draft image alone, and adds one an image "
        "lost", () {
      final (text, _) = gaiaRelabelDraft('As in [image 1] earlier', [
        GaiaDraftImage(label: 3, path: 'a'),
      ], 2);
      expect(text, 'As in [image 1] earlier\n\n[image 2]');
    });
  });

  group("Claude Code's content", () {
    late Directory dir;
    late String one;
    late String two;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('gaia_images');
      one = '${dir.path}/one.png';
      two = '${dir.path}/two.jpg';
      await File(one).writeAsBytes([1, 2]);
      await File(two).writeAsBytes([3, 4]);
    });

    tearDown(() => dir.delete(recursive: true));

    test('is the prompt alone without images', () async {
      expect(await claudeUserContent('Hi', const []), 'Hi');
    });

    test('puts each image after the text ending in its token, and one with '
        'no token at the end', () async {
      final content =
          await claudeUserContent('Compare [image 2] with [image 1], please', [
            (label: 1, path: one, mimeType: 'image/png'),
            (label: 2, path: two, mimeType: 'image/jpeg'),
            (label: 3, path: one, mimeType: 'image/png'),
          ]);
      String describe(Object block) => switch (block) {
        {'type': 'text', 'text': final String text} => text,
        {
          'type': 'image',
          'source': {
            'media_type': final String type,
            'data': final String data,
          },
        } =>
          '<$type ${base64Decode(data)}>',
        _ => '?',
      };
      expect((content as List).map((b) => describe(b as Object)), [
        'Compare [image 2]',
        '<image/jpeg [3, 4]>',
        ' with [image 1]',
        '<image/png [1, 2]>',
        ', please',
        '[image 3]',
        '<image/png [1, 2]>',
      ]);
    });
  });

  group('rendering (§9.4)', () {
    late Directory dir;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('gaia_render');
    });

    tearDown(() => dir.delete(recursive: true));

    /// A [width]×[height] capture, as the main instance writes one: a
    /// top-down 32-bit BMP, blue on the left half and red on the right.
    Future<String> capture(int width, int height) async {
      final header = ByteData(54)
        ..setUint8(0, 0x42)
        ..setUint8(1, 0x4D)
        ..setUint32(2, 54 + width * height * 4, Endian.little)
        ..setUint32(10, 54, Endian.little)
        ..setUint32(14, 40, Endian.little)
        ..setInt32(18, width, Endian.little)
        ..setInt32(22, -height, Endian.little)
        ..setUint16(26, 1, Endian.little)
        ..setUint16(28, 32, Endian.little);
      final pixels = Uint32List(width * height);
      for (var y = 0; y < height; y++) {
        for (var x = 0; x < width; x++) {
          // BGRA in memory: 0xAARRGGBB as a little-endian word.
          pixels[y * width + x] = x < width ~/ 2 ? 0xFF0000FF : 0xFFFF0000;
        }
      }
      final path = '${dir.path}/capture.bmp';
      await File(path).writeAsBytes([
        ...header.buffer.asUint8List(),
        ...pixels.buffer.asUint8List(),
      ]);
      return path;
    }

    Future<(int, int, ByteData)> decode(Uint8List png) async {
      final codec = await ui.instantiateImageCodec(png);
      final image = (await codec.getNextFrame()).image;
      final data = (await image.toByteData())!;
      return (image.width, image.height, data);
    }

    /// The pixel at ([x], [y]) as 0xRRGGBBAA.
    int pixel((int, int, ByteData) image, int x, int y) =>
        image.$3.getUint32((y * image.$1 + x) * 4);

    testWidgets('a capture becomes an opaque PNG the media module takes', (
      tester,
    ) async {
      await tester.runAsync(() async {
        final path = await capture(8, 4);
        final upload = await gaiaUploadablePath(path);
        expect(upload, isNot(path));
        final bytes = await File(upload).readAsBytes();
        expect(bytes.sublist(1, 4), 'PNG'.codeUnits);
        final image = await decode(bytes);
        expect((image.$1, image.$2), (8, 4));
        expect(pixel(image, 0, 0), 0x0000FFFF);
        expect(pixel(image, 7, 3), 0xFF0000FF);
      });
    });

    testWidgets('a PNG without edits goes as it is', (tester) async {
      await tester.runAsync(() async {
        final path = '${dir.path}/pasted.png';
        await File(path).writeAsBytes(await gaiaRenderPng(await capture(2, 2)));
        expect(await gaiaUploadablePath(path), path);
      });
    });

    testWidgets('the crop keeps its region and a redaction covers it', (
      tester,
    ) async {
      await tester.runAsync(() async {
        final path = await capture(8, 4);
        final png = await gaiaRenderPng(
          path,
          edits: const GaiaImageEdits(
            crop: Rect.fromLTWH(2, 0, 6, 4),
            marks: [
              GaiaMark(
                tool: GaiaTool.redact,
                points: [Offset(6, 0), Offset(8, 4)],
                color: Color(0xFFFFFFFF),
                width: 1,
              ),
            ],
          ),
        );
        final image = await decode(png);
        expect((image.$1, image.$2), (6, 4));
        expect(pixel(image, 0, 0), 0x0000FFFF);
        expect(pixel(image, 2, 0), 0xFF0000FF);
        expect(pixel(image, 5, 3), 0x000000FF);
      });
    });
  });
}

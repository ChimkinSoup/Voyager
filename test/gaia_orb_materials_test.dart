import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/features/gaia/companion/gaia_orb_materials.dart';
import 'package:voyager/features/gaia/companion/gaia_tier_glyph.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<Uint8List> pixels(void Function(Canvas) paint, double dpr) async {
    final recorder = ui.PictureRecorder();
    paint(Canvas(recorder)..scale(dpr));
    final picture = recorder.endRecording();
    final image = await picture.toImage(
      (160 * dpr).round(),
      (160 * dpr).round(),
    );
    final bytes = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    final result = Uint8List.fromList(bytes!.buffer.asUint8List());
    image.dispose();
    picture.dispose();
    return result;
  }

  Future<Uint8List> frame({double arrival = 4, double done = 0}) => pixels(
    (canvas) => paintGaiaMaterialOrb(
      canvas,
      const Size.square(160),
      material: GaiaOrbMaterial.astral,
      centre: const Offset(80, 80),
      radius: 56,
      clock: GaiaOrbClock(3.7),
      thinking: 0,
      replying: 0,
      done: done,
      revealAge: arrival,
      burstAge: 4,
      accent: const Color(0xFF96B7ED),
      ink: Colors.white,
      surface: const Color(0xFF202632),
      tier: 2,
    ),
    1,
  );

  test(
    'arrival lights the core before any gold orbit or particles exist',
    () async {
      final nothing = await frame(arrival: 0);
      final core = await frame(arrival: 0.18);
      final assembled = await frame();
      int goldPixels(Uint8List bytes) {
        var count = 0;
        for (var i = 0; i < bytes.length; i += 4) {
          if (bytes[i + 3] > 64 &&
              bytes[i] > bytes[i + 2] * 1.1 &&
              bytes[i + 1] > bytes[i + 2] * 1.05) {
            count++;
          }
        }
        return count;
      }

      expect(nothing.every((byte) => byte == 0), isTrue);
      expect(core.any((byte) => byte != 0), isTrue);
      expect(
        goldPixels(core),
        0,
        reason: 'A solitary light is the first visible asset',
      );
      expect(goldPixels(assembled), greaterThan(30));
    },
  );

  test(
    'the luminous orbits remain visible while they align into model arcs',
    () async {
      final folding = await frame(done: 0.55);
      var arcPixels = 0;
      for (var y = 0; y < 160; y++) {
        for (var x = 0; x < 160; x++) {
          final distanceSquared = (x - 80) * (x - 80) + (y - 80) * (y - 80);
          final alpha = folding[(y * 160 + x) * 4 + 3];
          if (distanceSquared > 24 * 24 && alpha > 150) arcPixels++;
        }
      }
      expect(
        arcPixels,
        greaterThan(50),
        reason:
            'The real orbits stay lit during alignment instead of fading into a small glyph',
      );
    },
  );

  test(
    'astral completion hands off to the exact model mark at every size',
    () async {
      const accent = Color(0xFF96B7ED);
      const centre = Offset(80, 80);
      for (final tier in [0, 1, 2]) {
        for (final radius in [24.0, 56.0, 84.0]) {
          for (final dpr in [1.0, 2.0]) {
            final orb = await pixels(
              (canvas) => paintGaiaMaterialOrb(
                canvas,
                const Size.square(160),
                material: GaiaOrbMaterial.astral,
                centre: centre,
                radius: radius,
                clock: GaiaOrbClock(4.7),
                thinking: 0,
                replying: 0,
                done: 1,
                revealAge: 4,
                burstAge: 4,
                accent: accent,
                ink: Colors.white,
                surface: const Color(0xFF202632),
                tier: tier,
              ),
              dpr,
            );
            final glyph = await pixels(
              (canvas) => paintGaiaTierGlyph(
                canvas,
                centre,
                level: tier,
                color: accent,
                phase: gaiaTierGlyphPhase(tier),
                scale: 1.5,
              ),
              dpr,
            );
            expect(
              listEquals(orb, glyph),
              isTrue,
              reason:
                  'No flash or shape jump: tier=$tier radius=$radius dpr=$dpr',
            );
            expect(orb.any((byte) => byte != 0), isTrue);
          }
        }
      }
    },
  );
}

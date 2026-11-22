import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/core/utils/moon.dart';

void main() {
  test('phase matches known new and full moons', () {
    // The 2024-04-08 total solar eclipse, at new moon.
    final newMoon = moonPhaseAt(DateTime.utc(2024, 4, 8, 18, 21));
    expect(newMoon < 0.03 || newMoon > 0.97, isTrue);
    // The 2024-09-18 partial lunar eclipse, at full moon.
    expect(moonPhaseAt(DateTime.utc(2024, 9, 18, 2, 34)), closeTo(0.5, 0.03));
  });
}

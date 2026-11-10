import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/features/gaia/companion/gaia_app.dart';

void main() {
  final now = DateTime(2026, 11, 9, 10, 30);

  test('rounds a message time to its day', () {
    expect(gaiaWhenLabel(DateTime(2026, 11, 9, 8, 5), now), '8:05 AM');
    expect(gaiaWhenLabel(DateTime(2026, 11, 8, 23, 59), now), 'Yesterday');
    expect(gaiaWhenLabel(DateTime(2026, 11, 4, 12), now), 'Wed');
    expect(gaiaWhenLabel(DateTime(2026, 11, 2, 12), now), 'Nov 2');
    expect(gaiaWhenLabel(DateTime(2025, 9, 20, 12), now), 'Sep 20, 2025');
  });
}

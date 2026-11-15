import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/features/gaia/companion/gaia_controller.dart';

void main() {
  test('a toast line loses its markdown marks, not its words', () {
    expect(gaiaPlainLine('**Short command** (Bash):'), 'Short command (Bash):');
    expect(gaiaPlainLine('## Plan for `main.dart`'), 'Plan for main.dart');
    expect(
      gaiaPlainLine('- see [the docs](https://x.dev/a) *now*'),
      'see the docs now',
    );
    expect(gaiaPlainLine('> ~~old~~ __new__'), 'old new');
  });

  test('a toast line keeps what only looks like markdown', () {
    expect(gaiaPlainLine('2 * 3 * 4 = 24'), '2 * 3 * 4 = 24');
    expect(gaiaPlainLine('snake_case_name stays'), 'snake_case_name stays');
    expect(gaiaPlainLine('Done.'), 'Done.');
  });
}

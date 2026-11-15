import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/domain/models/gaia_models.dart';
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

  test('a search snippet is plain, on one line, its matches still marked', () {
    const s = GaiaSearchHit.start, e = GaiaSearchHit.end;
    expect(
      gaiaPlainSnippet('# The ${s}plan$e\n\n- **${s}plan$e** first'),
      'The ${s}plan$e ${s}plan$e first',
    );
    expect(
      gaiaPlainSnippet('Run:\n```bash\nflutter ${s}test$e\n```'),
      'Run: flutter ${s}test$e',
    );
    // Cut mid-emphasis: the stray marks go.
    expect(gaiaPlainSnippet('…old** and `${s}new$e'), '…old and ${s}new$e');
    // A code block's lines stay as written; prose after it is still plain.
    expect(
      gaiaPlainSnippet(
        '…deps\n- run make\nx ** 2 > ${s}out$e\n```\n**Done**',
        inCode: true,
      ),
      '…deps - run make x ** 2 > ${s}out$e Done',
    );
    expect(gaiaPlainSnippet('```bash\n# ${s}step$e\n```'), '# ${s}step$e');
    // Matched only where it's stripped: as it is, so the match still shows.
    expect(
      gaiaPlainSnippet('see [docs](https://${s}github$e.com/x)'),
      'see [docs](https://${s}github$e.com/x)',
    );
    expect(
      gaiaPlainSnippet('Run:\n```${s}bash$e\nls'),
      'Run: ```${s}bash$e ls',
    );
  });
}

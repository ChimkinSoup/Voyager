import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/domain/models/gaia_models.dart';
import 'package:voyager/features/gaia/companion/gaia_commands.dart';

/// Slash commands (GAIA_HLD.md §9.2): templates, built-ins and the palette.
void main() {
  const commands = [
    GaiaCommand(
      name: 'explain',
      template: r'Explain simply: $ARGUMENTS',
      description: 'Plain words',
    ),
    GaiaCommand(name: 'swap', template: r'$2 then $1, not $3'),
    GaiaCommand(
      name: 'tidy',
      template: 'Tidy this (\$DATE):\n\$CLIPBOARD',
      standalone: true,
    ),
  ];
  final now = DateTime(2026, 10, 25, 9);

  String? expand(String draft) =>
      expandGaiaCommand(draft, commands, clipboard: 'copied', now: now);

  test(r'$SELECTION is the text selected where Gaia was summoned', () {
    expect(
      expandGaiaCommand(
        '/fix',
        const [GaiaCommand(name: 'fix', template: r'Fix: $SELECTION')],
        clipboard: '',
        now: now,
        selection: 'teh cat',
      ),
      'Fix: teh cat',
    );
  });

  test('a command expands with its arguments', () {
    expect(expand('/explain how tides work'), 'Explain simply: how tides work');
    expect(expand('/explain'), 'Explain simply: ');
    expect(expand('/swap a b'), 'b then a, not ');
    expect(expand('/tidy'), 'Tidy this (2026-10-25):\ncopied');
    expect(
      expand('/explain line one\nline two'),
      'Explain simply: line one\nline two',
    );
  });

  test('anything else is left alone', () {
    expect(expand('/unknown x'), isNull);
    expect(expand('explain /explain'), isNull);
    expect(expand('/explainer'), isNull);
  });

  test('built-ins, alone', () {
    expect(gaiaBuiltinIn('/new'), GaiaBuiltin.newChat);
    expect(gaiaBuiltinIn('/this'), GaiaBuiltin.thisControl);
    expect(gaiaThisRest('/this what does it do?'), 'what does it do?');
    expect(gaiaThisRest('/this'), isNull);
    expect(gaiaThisRest('about /this one'), isNull);
    expect(gaiaBuiltinIn(' /stop '), GaiaBuiltin.stop);
    expect(gaiaBuiltinIn('/stop now'), isNull);
  });

  test('/remember takes the rest of the draft', () {
    expect(gaiaRememberText('/remember  I like tea \n'), 'I like tea');
    expect(
      gaiaRememberText('/remember line one\nline two'),
      'line one\nline two',
    );
    expect(gaiaRememberText('/remember'), isNull);
    expect(gaiaRememberText('/remembered that'), isNull);
    expect(gaiaRememberText('please /remember this'), isNull);
    expect(gaiaBuiltinIn('/remember'), GaiaBuiltin.remember);
  });

  test('the palette shows for a slash word at the caret', () {
    GaiaPaletteToken? at(String text, [int? caret]) => gaiaPaletteToken(
      TextEditingValue(
        text: text,
        selection: TextSelection.collapsed(offset: caret ?? text.length),
      ),
    );
    expect(at('/'), (query: '', start: 0, end: 1, whole: true));
    expect(at('/ex'), (query: 'ex', start: 0, end: 3, whole: true));
    expect(at('/explain '), isNull);
    expect(at('hi /ne'), (query: 'ne', start: 3, end: 6, whole: false));
    expect(at('/ne hi', 3), (query: 'ne', start: 0, end: 3, whole: false));
    expect(at('/new', 2), isNull);
    expect(at('a/b'), isNull);
    expect(at('`hi /ne'), isNull);
  });

  group('account aliases', () {
    const aliased = GaiaAccount(
      id: 'b',
      label: 'Beta',
      adapter: kGaiaClaudeCodeAdapter,
      dir: '',
      alias: 'q',
    );
    const plain = GaiaAccount(
      id: 'c',
      label: 'Gamma',
      adapter: kGaiaCodexAdapter,
      dir: '',
    );

    test('only an account with one gets a row, switching to it', () {
      final items = gaiaPaletteItems(commands, accounts: [aliased, plain]);
      final rows = items.where((i) => i.account != null);
      expect(rows.single.account, aliased);
      expect(rows.single.description, 'Switch to Beta (Claude Code)');
    });

    test('typed in full, it beats a longer name it starts', () {
      final items = gaiaPaletteItems(commands, accounts: [aliased]);
      expect(filterGaiaPalette(items, 'q').first.account, aliased);
    });

    test('survives a round trip, and is left out when empty', () {
      expect(GaiaAccount.fromJson(aliased.toJson()), aliased);
      expect(plain.toJson().containsKey('alias'), isFalse);
      expect(GaiaAccount.fromJson(plain.toJson()).alias, isEmpty);
    });
  });

  test('palette matches: prefix, then substring, then letters in order', () {
    final items = gaiaPaletteItems(commands);
    expect(items.map((i) => i.name), [
      'new',
      'stop',
      'remember',
      'queue',
      'queue-pop',
      'queue-pop!',
      'drain',
      'this',
      'quick',
      'std',
      'deep',
      'explain',
      'swap',
      'tidy',
    ]);
    expect(filterGaiaPalette(items, 's').map((i) => i.name), [
      'stop',
      'std',
      'swap',
      'this',
    ]);
    expect(filterGaiaPalette(items, 'ee').map((i) => i.name), [
      'deep',
      'remember',
      'queue',
      'queue-pop',
      'queue-pop!',
    ]);
    expect(filterGaiaPalette(items, 'xpl').single.name, 'explain');
    expect(filterGaiaPalette(items, 'tdy').single.name, 'tidy');
    expect(filterGaiaPalette(items, 'zzz'), isEmpty);
    expect(
      filterGaiaPalette(items, 'explain').single.description,
      'Plain words',
    );
  });
}

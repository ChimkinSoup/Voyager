import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/domain/models/gaia_models.dart';
import 'package:voyager/features/gaia/adapters/gaia_agent_runner.dart';
import 'package:voyager/features/gaia/companion/gaia_command_uses.dart';
import 'package:voyager/features/gaia/companion/gaia_commands.dart';
import 'package:voyager/features/gaia/companion/gaia_tier_commands.dart';

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

  test('/clear and /reset are /new', () {
    expect(gaiaBuiltinIn('/clear'), GaiaBuiltin.newChat);
    expect(gaiaBuiltinIn('/reset'), GaiaBuiltin.newChat);
    final items = gaiaPaletteItems(const []);
    expect(
      filterGaiaPalette(items, 'clear').first.builtin,
      GaiaBuiltin.newChat,
    );
    expect(gaiaUnknownCommand('/clear', items), isNull);
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
    // `--global` saves outside the project (GAIA_PROJECTS_HLD.md §6).
    expect(gaiaRememberGlobal('--global I like tea'), 'I like tea');
    expect(gaiaRememberGlobal('--global'), '');
    expect(gaiaRememberGlobal('I like tea'), isNull);
    expect(gaiaRememberGlobal('--globally fine'), isNull);
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
      'btw',
      'usage',
      'control-off',
      'control-ask',
      'control-auto',
      'screen',
      'window',
      'quick',
      'std',
      'deep',
      'explain',
      'swap',
      'tidy',
    ]);
    expect(filterGaiaPalette(items, 's').map((i) => i.name), [
      'stop',
      'screen',
      'std',
      'swap',
      'this',
      'usage',
      'control-ask',
    ]);
    expect(filterGaiaPalette(items, 'ee').map((i) => i.name), [
      'screen',
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

  // GAIA_NATIVE_COMMANDS.md.
  group('native commands', () {
    const natives = <GaiaNativeCommand>[
      (
        name: 'compact',
        description: 'Free up context',
        argumentHint: '[focus]',
      ),
      (name: 'usage', description: 'Show usage', argumentHint: ''),
      // Clashes with Gaia's own /new: Gaia's wins.
      (name: 'new', description: 'Clear the session', argumentHint: ''),
    ];

    test("the palette lists them after Gaia's, which win a clash", () {
      final items = gaiaPaletteItems(commands, natives: natives);
      expect(
        items.where((i) => i.name == 'new').single.builtin,
        GaiaBuiltin.newChat,
      );
      final compact = items.singleWhere((i) => i.name == 'compact');
      expect(compact.native, natives.first);
      expect(compact.description, 'Free up context ([focus])');
    });

    test('a draft starting with one, then a space or the end, is one', () {
      expect(gaiaNativeIn('/compact', natives), natives[0]);
      expect(gaiaNativeIn(' /compact keep the API notes', natives), natives[0]);
      expect(gaiaNativeIn('/compacted', natives), isNull);
      expect(gaiaNativeIn('please /usage', natives), isNull);
    });

    group('an unknown /word', () {
      final items = gaiaPaletteItems(commands, natives: natives);

      test('is caught with the closest command', () {
        expect(gaiaUnknownCommand('/quee fix the tests', items), (
          word: 'quee',
          suggestion: 'queue',
        ));
        // Not a prefix or letters in order: the fewest edits.
        expect(gaiaUnknownCommand('/usgae', items)?.suggestion, 'usage');
      });

      test('says only that when nothing is close', () {
        expect(gaiaUnknownCommand('/zzzzzz', items), (
          word: 'zzzzzz',
          suggestion: null,
        ));
      });

      test("isn't a known command, a path, or a slash later on", () {
        expect(gaiaUnknownCommand('/usage', items), isNull);
        expect(gaiaUnknownCommand('/explain this', items), isNull);
        expect(gaiaUnknownCommand('/usr/bin is missing', items), isNull);
        expect(gaiaUnknownCommand('/etc/hosts', items), isNull);
        expect(gaiaUnknownCommand('look in /etc', items), isNull);
        expect(gaiaUnknownCommand('', items), isNull);
      });
    });
  });

  test('/con offers control-off first, then ask, then auto', () {
    final items = gaiaPaletteItems(const []);
    expect(
      [for (final item in filterGaiaPalette(items, 'con').take(3)) item.name],
      ['control-off', 'control-ask', 'control-auto'],
    );
    // A typo still finds them.
    expect(filterGaiaPalette(items, 'contrlauto').first.name, 'control-auto');
  });

  test('a control command fires inline once completed', () {
    final found = findGaiaInlineBuiltin(
      const TextEditingValue(text: 'open spotify /control-auto and play'),
    )!;
    expect(found.builtin, GaiaBuiltin.controlAuto);
    expect(found.value.text, 'open spotify and play');
    // Joined, as typed quickly.
    expect(
      findGaiaInlineBuiltin(
        const TextEditingValue(text: '/controloff hi'),
      )?.builtin,
      GaiaBuiltin.controlOff,
    );
    expect(
      findGaiaInlineBuiltin(
        const TextEditingValue(text: 'go /control-ask'),
        atEnd: true,
      )?.builtin,
      GaiaBuiltin.controlAsk,
    );
    // Not before it's completed, inside a path, or in code.
    expect(
      findGaiaInlineBuiltin(const TextEditingValue(text: 'a /control-ask')),
      isNull,
    );
    expect(
      findGaiaInlineBuiltin(
        const TextEditingValue(text: 'see /control-off/x now'),
      ),
      isNull,
    );
    expect(
      findGaiaInlineBuiltin(
        const TextEditingValue(text: 'run `/control-off ` ok'),
      ),
      isNull,
    );
    // The toggles never inline, as pasted text would flip them; alone
    // they run.
    for (final text in ['look /screen now', 'see /window ok']) {
      expect(findGaiaInlineBuiltin(TextEditingValue(text: text)), isNull);
    }
    expect(gaiaBuiltinIn('/window'), GaiaBuiltin.window);
    expect(gaiaBuiltinIn('/screen'), GaiaBuiltin.screen);
  });

  test('the most recently used comes first among equal matches', () {
    final items = gaiaPaletteItems(commands);
    final uses = GaiaCommandUses()
      ..use('control-auto')
      ..use('swap')
      ..use('control-auto');
    expect(uses.recent, ['control-auto', 'swap']);
    expect(
      filterGaiaPalette(
        items,
        'con',
        recent: uses.recent,
      ).take(3).map((i) => i.name),
      ['control-auto', 'control-off', 'control-ask'],
    );
    // A recent loose match never beats a prefix.
    expect(
      filterGaiaPalette(items, 's', recent: uses.recent).first.name,
      'swap',
    );
    expect(
      filterGaiaPalette(items, 'ctrl', recent: ['usage']).first.name,
      'control-off',
    );
  });

  test('rows of one recent name keep their order in a long palette', () {
    // Over 32 rows, where the sort isn't stable.
    final items = gaiaPaletteItems([
      const GaiaCommand(name: 'screen', template: 'mine'),
      for (var i = 0; i < 40; i++)
        GaiaCommand(name: 'screen-$i', template: 'x'),
    ]);
    final rows = filterGaiaPalette(items, 'screen', recent: ['screen']);
    expect(rows[0].builtin, GaiaBuiltin.screen);
    expect(rows[1].command?.template, 'mine');
  });
}

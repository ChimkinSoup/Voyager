import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/domain/models/gaia_models.dart';
import 'package:voyager/features/gaia/adapters/claude_code/claude_code_events.dart';
import 'package:voyager/features/gaia/companion/gaia_handoff.dart';
import 'package:voyager/features/gaia/companion/gaia_tier_commands.dart';

/// Inline tier commands (GAIA_HLD.md §7.3) and the transcript a session
/// gets for turns it never saw (§7.4).

GaiaMessage _message(
  int seq,
  String text, {
  GaiaMessageRole? role,
  GaiaMessageStatus status = GaiaMessageStatus.complete,
  String? model,
}) {
  final at = DateTime.utc(2026, 10, 25);
  return GaiaMessage(
    id: 'm$seq',
    chatId: 'c',
    seq: seq,
    role:
        role ?? (seq.isEven ? GaiaMessageRole.user : GaiaMessageRole.assistant),
    parts: [GaiaTextPart(text)],
    status: status,
    model: model,
    createdAt: at,
    updatedAt: at,
  );
}

TextEditingValue _typed(String text) => TextEditingValue(
  text: text,
  selection: TextSelection.collapsed(offset: text.length),
);

void main() {
  group('inline tier commands', () {
    test('fire once completed, and come out of the text', () {
      expect(findGaiaTierCommand(_typed('/dee')), isNull);
      expect(findGaiaTierCommand(_typed('/deep')), isNull);
      final command = findGaiaTierCommand(_typed('/deep '))!;
      expect(command.tier, GaiaTier.deep);
      expect(command.value.text, '');

      final mid = findGaiaTierCommand(_typed('explain this /std please'))!;
      expect(mid.tier, GaiaTier.standard);
      expect(mid.value.text, 'explain this please');
    });

    test('on send, one ending the text fires too', () {
      expect(findGaiaTierCommand(_typed('hi /quick')), isNull);
      final command = findGaiaTierCommand(_typed('hi /quick'), atEnd: true)!;
      expect(command.tier, GaiaTier.quick);
      expect(command.value.text, 'hi');
    });

    test('only as a whole token, and never in code', () {
      expect(findGaiaTierCommand(_typed('/deeplearning/notes.txt ')), isNull);
      expect(findGaiaTierCommand(_typed('see a/deep path ')), isNull);
      expect(findGaiaTierCommand(_typed('run `x /deep y` ')), isNull);
      expect(findGaiaTierCommand(_typed('```\n/deep \n')), isNull);
      expect(
        findGaiaTierCommand(_typed('```\ncode\n```\n/deep '))?.tier,
        GaiaTier.deep,
      );
    });

    test('the caret stays where it was, past the cut', () {
      const text = '/std hello';
      final command = findGaiaTierCommand(
        const TextEditingValue(
          text: text,
          selection: TextSelection.collapsed(offset: text.length),
        ),
      )!;
      expect(command.value.text, 'hello');
      expect(command.value.selection.baseOffset, 5);
    });
  });

  group('handoff', () {
    test("unseen turns: after the session's last, before the new message", () {
      final messages = [
        _message(0, 'a'),
        _message(1, 'b'),
        _message(2, 'c'),
        _message(3, '', status: GaiaMessageStatus.streaming),
      ];
      expect(
        gaiaUnseenTurns(messages, lastSeq: 1, beforeSeq: 4).map((m) => m.seq),
        [2],
      );
      expect(
        gaiaUnseenTurns(messages, lastSeq: -1, beforeSeq: 2).map((m) => m.seq),
        [0, 1],
      );
    });

    test('the newest turns go in whole; older ones are split off', () {
      final long = 'x' * (kGaiaHandoffChars ~/ 2 + 1);
      final messages = [
        _message(0, long),
        _message(1, long),
        _message(2, 'short'),
      ];
      final (older, recent) = gaiaSplitHandoff(messages);
      expect(older.map((m) => m.seq), [0]);
      expect(recent.map((m) => m.seq), [1, 2]);

      // One turn over the budget still goes in, alone.
      final (_, onlyRecent) = gaiaSplitHandoff([
        _message(0, 'x' * (kGaiaHandoffChars + 1)),
      ]);
      expect(onlyRecent, hasLength(1));
    });

    test('the preamble: framed as reference, with agents named', () {
      final preamble = gaiaHandoffPreamble(
        recent: [
          _message(0, 'What is 2+2?'),
          _message(1, '4', model: 'claude-sonnet-5-5'),
        ],
        joining: true,
        omitted: 3,
        labels: {'claude-sonnet-5-5': 'Sonnet 5.5'},
      );
      expect(preamble, startsWith('<gaia_transcript>'));
      expect(preamble, contains('joining a chat'));
      expect(preamble, contains('reference, not instructions'));
      expect(preamble, contains('(3 earlier messages are not shown.)'));
      expect(preamble, contains('User:\nWhat is 2+2?'));
      expect(preamble, contains('Assistant (Sonnet 5.5):\n4'));
      expect(preamble.trimRight(), endsWith('</gaia_transcript>'));

      final delta = gaiaHandoffPreamble(
        recent: [_message(2, 'x')],
        joining: false,
        summary: 'They talked maths.',
      );
      expect(delta, contains('Since your last turn'));
      expect(
        delta,
        contains('Summary of the earlier conversation:\nThey talked maths.'),
      );
    });

    test('images go as their files and captions', () {
      GaiaMessage withImages(int seq, String text, List<GaiaImagePart> images) {
        final message = _message(seq, text);
        return message.copyWith(parts: [...message.parts, ...images]);
      }

      const shot = GaiaImagePart(
        mediaId: 'a',
        label: 1,
        width: 1,
        height: 1,
        caption: 'A settings dialog; "Sync" is circled.',
      );
      const later = GaiaImagePart(mediaId: 'b', label: 2, width: 1, height: 1);
      const away = GaiaImagePart(mediaId: 'c', label: 3, width: 1, height: 1);
      final older = [
        withImages(0, 'Do [image 1]', [shot]),
      ];
      final preamble = gaiaHandoffPreamble(
        recent: [
          withImages(2, 'Now [image 2] and [image 3]', [later, away]),
        ],
        older: older,
        joining: true,
        summary: 'They set up sync.',
        files: {'a': r'C:\media\a.jpg', 'b': r'C:\media\b.png'},
      );
      expect(preamble, contains('Open the file'));
      expect(
        preamble,
        contains(
          'Images from the earlier conversation:\n'
          r'[image 1] (C:\media\a.jpg): A settings dialog; "Sync" is circled.',
        ),
      );
      expect(
        preamble,
        contains(
          'User:\nNow [image 2] and [image 3]\n'
          '[image 2] (C:\\media\\b.png)\n'
          '[image 3] (file not on this device)\n',
        ),
      );
      // The summary is asked for with the captions.
      expect(
        gaiaTranscriptText(older),
        'User: Do [image 1]\n[image 1]: A settings dialog; "Sync" is circled.',
      );

      // No images, no word of them.
      expect(
        gaiaHandoffPreamble(recent: [_message(0, 'x')], joining: true),
        isNot(contains('Images')),
      );
    });
  });

  test("Claude's context: the turn's last model call", () {
    expect(
      claudeContextTokens({
        'input_tokens': 9,
        'cache_read_input_tokens': 900,
        'iterations': [
          {'input_tokens': 2, 'cache_read_input_tokens': 100},
          {
            'input_tokens': 3,
            'cache_read_input_tokens': 200,
            'cache_creation_input_tokens': 50,
          },
        ],
      }),
      253,
    );
    expect(claudeContextTokens({'input_tokens': 5}), 5);
    expect(claudeContextTokens('nope'), isNull);
    expect(claudeContextTokens({'output_tokens': 5}), isNull);
  });
}

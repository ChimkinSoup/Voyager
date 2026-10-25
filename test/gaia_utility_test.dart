import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:voyager/domain/models/gaia_models.dart';
import 'package:voyager/features/gaia/gaia_secrets.dart';
import 'package:voyager/features/gaia/utility/gaia_utility.dart';
import 'package:voyager/features/gaia/utility/gemini_api.dart';

/// The utility model (GAIA_HLD.md §5.1): the Gemini API's documented
/// `generateContent` shapes, the router and titles on top of it, and the
/// device-only key store.

/// A `generateContent` reply with [text], as the API documents it.
String _reply(String text, {bool withThought = false}) => jsonEncode({
  'candidates': [
    {
      'content': {
        'role': 'model',
        'parts': [
          if (withThought) {'text': 'Let me think.', 'thought': true},
          {'text': text},
        ],
      },
      'finishReason': 'STOP',
    },
  ],
  'usageMetadata': {'promptTokenCount': 12, 'candidatesTokenCount': 1},
});

String _error(int code, String status, String message) => jsonEncode({
  'error': {'code': code, 'message': message, 'status': status},
});

void main() {
  group('generateContent', () {
    test("a reply's text, past thought parts", () {
      expect(
        parseGeminiResponse(200, _reply('deep', withThought: true)),
        'deep',
      );
    });

    test('errors by status', () {
      GeminiFailure failure(int status, String body) {
        try {
          parseGeminiResponse(status, body);
        } on GeminiApiException catch (error) {
          return error.failure;
        }
        fail('no failure');
      }

      expect(
        failure(400, _error(400, 'INVALID_ARGUMENT', 'API key not valid.')),
        GeminiFailure.badKey,
      );
      expect(
        failure(429, _error(429, 'RESOURCE_EXHAUSTED', 'Quota exceeded.')),
        GeminiFailure.exhausted,
      );
      expect(failure(503, 'Service Unavailable'), GeminiFailure.other);
      expect(failure(200, '{"candidates":[]}'), GeminiFailure.other);
    });

    test(
      'the request: model in the path, key in a header, never the URL',
      () async {
        late http.Request sent;
        final api = GeminiApi(
          key: 'k-123',
          model: 'gemini-3.6-flash',
          client: MockClient((request) async {
            sent = request;
            return http.Response(_reply('ok'), 200);
          }),
        );
        expect(await api.generate(system: 'Be brief.', prompt: 'Hi'), 'ok');
        expect(
          sent.url.path,
          endsWith('/models/gemini-3.6-flash:generateContent'),
        );
        expect(sent.url.query, isEmpty);
        expect(sent.headers['x-goog-api-key'], 'k-123');
        final body = jsonDecode(sent.body) as Map;
        expect(body['systemInstruction'], {
          'parts': [
            {'text': 'Be brief.'},
          ],
        });
      },
    );
  });

  group('router and titles', () {
    GaiaUtility utility({
      String? key = 'k',
      bool acknowledged = true,
      required String Function(String system) answer,
    }) {
      final utility = GaiaUtility(
        readKey: () async => key,
        client: () => MockClient((request) async {
          final body = jsonDecode(request.body) as Map;
          final system =
              ((body['systemInstruction'] as Map)['parts'] as List).single
                  as Map;
          return http.Response(_reply(answer(system['text'] as String)), 200);
        }),
      );
      utility.apply({
        ...GaiaSettings.initial().toJson(),
        'utilityAcknowledged': acknowledged,
      });
      return utility;
    }

    test('the router names a tier, with the default rubric', () async {
      String? system;
      final tier = await utility(
        answer: (s) {
          system = s;
          return 'Deep.';
        },
      ).route('Prove this theorem');
      expect(tier, GaiaTier.deep);
      expect(system, contains(kGaiaDefaultRouterRubric));
    });

    test('off without the terms acknowledged, or a key', () async {
      expect(
        await utility(acknowledged: false, answer: (_) => 'quick').route('x'),
        isNull,
      );
      expect(
        await utility(key: null, answer: (_) => 'quick').route('x'),
        isNull,
      );
    });

    test('auto-route off leaves the router out, titles on', () async {
      final u = utility(answer: (_) => 'quick')
        ..apply({
          ...GaiaSettings.initial().toJson(),
          'utilityAcknowledged': true,
          'autoRoute': false,
        });
      expect(await u.route('x'), isNull);
      expect(await u.title('x', 'y'), 'quick');
    });

    test('a failed call is a null, never an error', () async {
      final u =
          GaiaUtility(
            readKey: () async => 'k',
            client: () => MockClient((_) async => http.Response('nope', 500)),
          )..apply({
            ...GaiaSettings.initial().toJson(),
            'utilityAcknowledged': true,
          });
      expect(await u.route('x'), isNull);
      expect(await u.title('x', 'y'), isNull);
    });

    test('answers', () {
      expect(parseRoute('standard'), GaiaTier.standard);
      expect(parseRoute('**quick**'), GaiaTier.quick);
      expect(parseRoute('I think medium'), isNull);
      expect(cleanTitle('"Fixing the sync bug."\nmore'), 'Fixing the sync bug');
      expect(cleanTitle('# Trip plan'), 'Trip plan');
      expect(cleanTitle('  '), isNull);
    });
  });

  test(
    'the key round-trips through DPAPI and is not stored in the clear',
    skip: !Platform.isWindows,
    () async {
      final dir = Directory.systemTemp.createTempSync('gaia_secrets_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final file = File('${dir.path}/key.bin');
      final secrets = GaiaSecrets(file: () async => file);

      expect(await secrets.readUtilityKey(), isNull);
      await secrets.writeUtilityKey('  AIza-secret  ');
      expect(await secrets.readUtilityKey(), 'AIza-secret');
      expect(
        utf8.decode(file.readAsBytesSync(), allowMalformed: true),
        isNot(contains('AIza-secret')),
      );
      await secrets.writeUtilityKey(null);
      expect(file.existsSync(), isFalse);
    },
  );
}

import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/domain/models/gaia_models.dart';
import 'package:voyager/features/gaia/page/gaia_providers.dart';

/// The action log's "stopped" on a step list (BUG-348).
void main() {
  GaiaCardPart card(GaiaCardState state, {required int ran, String? stopped}) =>
      GaiaCardPart(
        id: 'card',
        kind: GaiaCardKind.control,
        state: state,
        tool: 'os_steps',
        input: const {
          'steps': [
            {'label': 'one'},
            {'label': 'two'},
          ],
        },
        answer: {'ran': ran, 'stopped': ?stopped},
      );

  test('every step sent is not stopped', () {
    expect(gaiaControlStopped(card(GaiaCardState.accepted, ran: 2)), isFalse);
  });

  test('a run that stopped says so', () {
    expect(
      gaiaControlStopped(
        card(GaiaCardState.accepted, ran: 1, stopped: 'The user pressed Esc.'),
      ),
      isTrue,
    );
  });

  test('a card still waiting on its next step is not stopped', () {
    expect(gaiaControlStopped(card(GaiaCardState.open, ran: 1)), isFalse);
  });

  test(
    'the rest denied, cancelled or unanswered after Next step is stopped',
    () {
      for (final state in [
        GaiaCardState.rejected,
        GaiaCardState.voided,
        GaiaCardState.expired,
      ]) {
        expect(gaiaControlStopped(card(state, ran: 1)), isTrue);
      }
    },
  );
}

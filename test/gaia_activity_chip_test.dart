import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/domain/models/gaia_models.dart';
import 'package:voyager/features/gaia/companion/gaia_activity_chip.dart';
import 'package:voyager/features/gaia/companion/gaia_card_view.dart';

void main() {
  group('gaiaWithoutControls', () {
    test('drops os_* actions, keeping reads with their details and ids', () {
      const part = GaiaActivityPart(
        ['os_key', 'os_screenshot', 'os_type', 'Bash'],
        details: ['ctrl+l', null, 'hello', 'ls'],
        failures: [null, null, 'Declined', null],
        ids: [null, 'shot', null, null],
      );
      final left = gaiaWithoutControls(part)!;
      expect(left.tools, ['os_screenshot', 'Bash']);
      expect(left.details, [null, 'ls']);
      expect(left.failures, [null, null]);
      expect(left.ids, ['shot', null]);
      expect(gaiaActivityLabel(left.tools), 'Used os_screenshot, Bash');
    });

    test('keeps an os_clipboard read, told by its kept id', () {
      const part = GaiaActivityPart(
        ['os_clipboard', 'os_clipboard'],
        ids: [null, 'clip'],
      );
      expect(gaiaWithoutControls(part)!.tools, ['os_clipboard']);
      expect(gaiaWithoutControls(part)!.ids, ['clip']);
    });

    test('is null when only actions ran', () {
      expect(gaiaWithoutControls(const GaiaActivityPart(['os_focus'])), null);
    });

    test('returns the part itself when nothing is dropped', () {
      const part = GaiaActivityPart(['os_screenshot', 'Read']);
      expect(identical(gaiaWithoutControls(part), part), isTrue);
    });
  });

  test("an activity card that dropped its first actions doesn't take the "
      "chips' place", () {
    GaiaCardPart card(int total, {bool activity = true}) => GaiaCardPart(
      id: 'c',
      kind: GaiaCardKind.control,
      tool: 'activity',
      input: {
        'activity': activity,
        'total': total,
        'steps': [
          {'label': 'Press A'},
          {'label': 'Press B'},
        ],
      },
    );
    expect(gaiaListsEveryAction(card(2)), isTrue);
    expect(gaiaListsEveryAction(card(3)), isFalse);
    expect(gaiaListsEveryAction(card(2, activity: false)), isFalse);
  });
}

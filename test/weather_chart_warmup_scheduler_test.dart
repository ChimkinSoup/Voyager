import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/domain/models/settings_models.dart';
import 'package:voyager/features/shell/weather_chart_transition_warmup.dart';

class _FixedSettings extends SettingsNotifier {
  @override
  Future<AppSettings> build() async => const AppSettings();
}

/// Stands in for the live-workout island's pulse: an animation that never
/// stops, running from the first frame.
class _EndlessPulse extends StatefulWidget {
  const _EndlessPulse();

  @override
  State<_EndlessPulse> createState() => _EndlessPulseState();
}

class _EndlessPulseState extends State<_EndlessPulse>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1600),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FadeTransition(
    opacity: _pulse,
    child: const SizedBox(width: 10, height: 10),
  );
}

void main() {
  // BUG-198: a scheduler task below Priority.animation is held back for as
  // long as any animation ticks, and the scheduler spins on a zero timer
  // meanwhile. With a workout restored at launch the island pulses forever,
  // so the warm-up's plot-cache task never ran and the spin starved Windows
  // input for as long as the workout lasted.
  testWidgets('BUG-198 the warm-up task runs while an endless animation ticks', (
    tester,
  ) async {
    var forecastReads = 0;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          settingsProvider.overrideWith(_FixedSettings.new),
          weatherForecastProvider.overrideWith((ref) async {
            forecastReads++;
            return null;
          }),
        ],
        child: const MaterialApp(
          home: Scaffold(
            body: Column(
              children: [_EndlessPulse(), WeatherChartTransitionWarmup()],
            ),
          ),
        ),
      ),
    );

    // Past the 800 ms start delay and the three warm-up frames.
    for (var i = 0; i < 120; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }

    // The task's only read of the forecast is what shows it ran.
    expect(forecastReads, greaterThan(0));
    expect(tester.binding.transientCallbackCount, greaterThan(0));
  });
}

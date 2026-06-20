import 'package:flutter/material.dart';
import 'package:voyager/domain/models/enums.dart';
import 'package:voyager/domain/services/periodic_prompt_service.dart';

class RankingPromptBanner extends StatefulWidget {
  const RankingPromptBanner({
    super.key,
    required this.cadence,
    required this.maxValue,
    required this.onSubmit,
    this.lastCompleted,
    this.weekStartsMonday = true,
  });

  final TrackerCadence cadence;
  final int maxValue;
  final DateTime? lastCompleted;
  final bool weekStartsMonday;
  final ValueChanged<int> onSubmit;

  @override
  State<RankingPromptBanner> createState() => _RankingPromptBannerState();
}

class _RankingPromptBannerState extends State<RankingPromptBanner> {
  double _value = 1;

  @override
  Widget build(BuildContext context) {
    final service = PeriodicPromptService();
    final now = DateTime.now();
    final due = service.isDue(
      cadence: widget.cadence,
      now: now,
      lastCompleted: widget.lastCompleted,
      weekStartsMonday: widget.weekStartsMonday,
    );
    if (!due) return const SizedBox.shrink();

    final missed = service.missedPeriods(
      cadence: widget.cadence,
      now: now,
      lastCompleted: widget.lastCompleted,
      weekStartsMonday: widget.weekStartsMonday,
    );

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Rate previous ${widget.cadence.name} period (${missed.length} pending)',
            ),
            Slider(
              value: _value,
              min: 1,
              max: widget.maxValue.toDouble(),
              divisions: widget.maxValue - 1,
              label: '${_value.round()}/${widget.maxValue}',
              onChanged: (v) => setState(() => _value = v),
              onChangeEnd: (v) => widget.onSubmit(v.round()),
            ),
          ],
        ),
      ),
    );
  }
}

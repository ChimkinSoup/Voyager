import 'dart:async';
import 'dart:io' show FileSystemException;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:voyager/core/utils/keyboard_focus_utils.dart';
import 'package:voyager/features/settings/services/heat_watch_log.dart';
import 'package:voyager/features/settings/settings_reveal.dart';
import 'package:voyager/features/shell/reveal_request.dart';

const _maxSpikesShown = 5;

/// Settings → About: whether the HeatWatch logger is recording, and the heat
/// spikes it caught lately. Shows nothing on a PC without the logger.
class HeatWatchSection extends ConsumerStatefulWidget {
  const HeatWatchSection({super.key});

  @override
  ConsumerState<HeatWatchSection> createState() => _HeatWatchSectionState();
}

class _HeatWatchSectionState extends ConsumerState<HeatWatchSection> {
  HeatWatchStatus? _status;
  DateTime _checkedAt = DateTime.now();
  late final Timer _timer;

  @override
  void initState() {
    super.initState();
    _load();
    _timer = Timer.periodic(const Duration(minutes: 1), (_) {
      if (subtreeIsVisible(context)) _load();
    });
  }

  @override
  void dispose() {
    _timer.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    final now = DateTime.now();
    try {
      final status = await readHeatWatchStatus(heatWatchLogDir(), now);
      if (!mounted) return;
      setState(() {
        _status = status;
        _checkedAt = now;
      });
      // After the load: until then this section has no height to scroll to.
      if (ref.read(revealHeatWatchRequestProvider)) _reveal();
    } on FileSystemException {
      // The logger had a file busy; the next tick reads it.
    }
  }

  /// Answers a click on the "not recording" notification.
  void _reveal() => revealSettingsSection(
    context,
    clearRequest: () =>
        ref.read(revealHeatWatchRequestProvider.notifier).state = false,
  );

  static String _ago(Duration age) {
    if (age.inDays > 0) return '${age.inDays} d ago';
    if (age.inHours > 0) return '${age.inHours} h ago';
    if (age.inMinutes > 0) return '${age.inMinutes} min ago';
    return '${age.inSeconds} s ago';
  }

  static String _spikeLength(HeatSpike spike) {
    final length = spike.end.difference(spike.start);
    if (length.inSeconds == 0) return 'Brief';
    if (length.inMinutes == 0) return '${length.inSeconds} s';
    return '${length.inMinutes} min';
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<bool>(revealHeatWatchRequestProvider, (_, next) {
      if (next) _reveal();
    });
    final status = _status;
    if (status == null) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final healthy = status.isHealthy(_checkedAt);
    final last = status.lastReading;
    final spikes = status.spikes;

    return Column(
      children: [
        ListTile(
          leading: const Icon(PhosphorIconsRegular.thermometer),
          title: const Text('Heat logger'),
          subtitle: Text(
            [
              if (!healthy)
                last == null
                    ? 'No readings yet. Is Core Temp running?'
                    : 'Last reading ${_ago(_checkedAt.difference(last))}. '
                          'Are the logger and Core Temp running?',
              spikes.isEmpty
                  ? 'No spikes in the last 7 days'
                  : '${spikes.length} '
                        '${spikes.length == 1 ? 'spike' : 'spikes'} in the '
                        'last 7 days',
            ].join(' · '),
          ),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.circle,
                size: 10,
                color: healthy ? Colors.green : theme.colorScheme.error,
              ),
              const SizedBox(width: 6),
              Text(
                healthy ? 'Healthy' : 'Not recording',
                style: theme.textTheme.labelMedium,
              ),
            ],
          ),
        ),
        for (final spike in spikes.take(_maxSpikesShown))
          ListTile(
            dense: true,
            title: Text(
              '${DateFormat('d MMM, h:mm a').format(spike.start)} · '
              '${spike.peakCelsius.round()}°C · '
              '${spike.peakWatts.round()} W · ${_spikeLength(spike)}',
            ),
            subtitle: Text(
              spike.topProcesses
                  .map(
                    (process) =>
                        '${process.name} ${process.percent.toStringAsFixed(1)}%',
                  )
                  .join(', '),
            ),
          ),
      ],
    );
  }
}

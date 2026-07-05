import 'package:flutter/material.dart';
import 'package:voyager/core/widgets/voyager_time_picker_spinner.dart';

// Generates times in 15 minute increments
List<TimeOfDay> _generateTimes() {
  final times = <TimeOfDay>[];
  for (var h = 0; h < 24; h++) {
    for (var m = 0; m < 60; m += 15) {
      times.add(TimeOfDay(hour: h, minute: m));
    }
  }
  return times;
}

class TimeRangeResult {
  final TimeOfDay start;
  final TimeOfDay end;
  const TimeRangeResult(this.start, this.end);
}

class TimeRangePopover extends StatefulWidget {
  const TimeRangePopover({
    super.key,
    required this.initialStart,
    required this.initialEnd,
  });

  final TimeOfDay initialStart;
  final TimeOfDay initialEnd;

  @override
  State<TimeRangePopover> createState() => _TimeRangePopoverState();
}

class _TimeRangePopoverState extends State<TimeRangePopover> {
  late TimeOfDay _start;
  late TimeOfDay _end;

  late final TextEditingController _startController;
  late final TextEditingController _endController;
  late final TextEditingController _durationController;

  late final FocusNode _startFocus;
  late final FocusNode _endFocus;
  late final FocusNode _durationFocus;

  @override
  void initState() {
    super.initState();
    _start = widget.initialStart;
    _end = widget.initialEnd;
    
    _startController = TextEditingController();
    _endController = TextEditingController();
    _durationController = TextEditingController();

    _startFocus = FocusNode();
    _endFocus = FocusNode();
    _durationFocus = FocusNode();

    _startController.addListener(_onStartTextChanged);
    _endController.addListener(_onEndTextChanged);
    _durationController.addListener(_onDurationTextChanged);

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _startController.text = _start.format(context);
        _endController.text = _end.format(context);
        _startFocus.requestFocus();
      }
    });
  }

  @override
  void dispose() {
    _startController.dispose();
    _endController.dispose();
    _durationController.dispose();
    _startFocus.dispose();
    _endFocus.dispose();
    _durationFocus.dispose();
    super.dispose();
  }

  TimeOfDay? _parseTime(String query) {
    query = query.toLowerCase().trim();
    if (query.isEmpty) return null;
    final allTimes = _generateTimes();
    for (var t in allTimes) {
      final formatted = t.format(context).toLowerCase();
      final relaxedFormatted = formatted.replaceAll(RegExp(r'[\s:]'), '');
      final relaxedQuery = query.replaceAll(RegExp(r'[\s:]'), '');
      if (relaxedFormatted.startsWith(relaxedQuery) || formatted.startsWith(query)) {
        return t;
      }
    }
    return null;
  }

  Duration? _parseDuration(String query) {
    query = query.toLowerCase().trim();
    if (query.isEmpty) return null;
    int totalMinutes = 0;
    
    final hMatch = RegExp(r'(\d+)\s*h').firstMatch(query);
    if (hMatch != null) {
      totalMinutes += int.parse(hMatch.group(1)!) * 60;
    }
    final mMatch = RegExp(r'(\d+)\s*m').firstMatch(query);
    if (mMatch != null) {
      totalMinutes += int.parse(mMatch.group(1)!);
    }
    
    if (totalMinutes == 0) {
      final numMatch = RegExp(r'^(\d+)$').firstMatch(query);
      if (numMatch != null) {
        totalMinutes = int.parse(numMatch.group(1)!);
      }
    }
    
    if (totalMinutes > 0) return Duration(minutes: totalMinutes);
    return null;
  }

  void _onStartTextChanged() {
    if (!_startFocus.hasFocus) return;
    final parsed = _parseTime(_startController.text);
    if (parsed != null && parsed != _start) {
      _updateStartMaintainDuration(parsed, updateText: false);
    }
  }

  void _onEndTextChanged() {
    if (!_endFocus.hasFocus) return;
    final parsed = _parseTime(_endController.text);
    if (parsed != null && parsed != _end) {
      setState(() {
        _end = parsed;
      });
    }
  }

  void _onDurationTextChanged() {
    if (!_durationFocus.hasFocus) return;
    final parsed = _parseDuration(_durationController.text);
    if (parsed != null) {
      _applyDuration(parsed);
    }
  }

  void _updateStartMaintainDuration(TimeOfDay newStart, {bool updateText = true}) {
    final startDt = DateTime(2000, 1, 1, _start.hour, _start.minute);
    final endDt = DateTime(2000, 1, 1, _end.hour, _end.minute);
    var endDtAdjusted = endDt;
    if (endDt.isBefore(startDt)) {
      endDtAdjusted = endDt.add(const Duration(days: 1));
    }
    final duration = endDtAdjusted.difference(startDt);

    setState(() {
      _start = newStart;
      final newStartDt = DateTime(2000, 1, 1, newStart.hour, newStart.minute);
      final newEndDt = newStartDt.add(duration);
      _end = TimeOfDay.fromDateTime(newEndDt);
      
      if (updateText) {
        _startController.text = _start.format(context);
      }
      if (!_endFocus.hasFocus) {
        _endController.text = _end.format(context);
      }
    });
  }

  void _applyDuration(Duration dur) {
    final startDt = DateTime(2000, 1, 1, _start.hour, _start.minute);
    final newEndDt = startDt.add(dur);
    setState(() {
      _end = TimeOfDay.fromDateTime(newEndDt);
      if (!_endFocus.hasFocus) {
        _endController.text = _end.format(context);
      }
    });
  }

  void _submit() {
    Navigator.of(context).pop(TimeRangeResult(_start, _end));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final durations = [
      {'label': '15m', 'duration': const Duration(minutes: 15)},
      {'label': '30m', 'duration': const Duration(minutes: 30)},
      {'label': '45m', 'duration': const Duration(minutes: 45)},
      {'label': '1h', 'duration': const Duration(hours: 1)},
      {'label': '1.5h', 'duration': const Duration(hours: 1, minutes: 30)},
      {'label': '2h', 'duration': const Duration(hours: 2)},
    ];

    final normalTextStyle = theme.textTheme.titleLarge?.copyWith(
      color: Color.lerp(theme.colorScheme.primary, Colors.grey, 0.7)?.withValues(alpha: 0.4),
    );
    final highlightTextStyle = theme.textTheme.titleLarge?.copyWith(
      color: theme.colorScheme.primary,
      fontWeight: FontWeight.bold,
    );

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Zone A: Smart Inputs
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _startController,
                  focusNode: _startFocus,
                  style: theme.textTheme.titleMedium,
                  decoration: InputDecoration(
                    hintText: 'Start...',
                    hintStyle: theme.textTheme.titleMedium?.copyWith(
                      color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
                    ),
                    border: InputBorder.none,
                    isDense: true,
                  ),
                  onSubmitted: (_) {
                    _endFocus.requestFocus();
                  },
                ),
              ),
              Icon(Icons.arrow_forward, size: 16, color: theme.colorScheme.onSurface.withValues(alpha: 0.5)),
              const SizedBox(width: 8),
              Expanded(
                child: TextField(
                  controller: _endController,
                  focusNode: _endFocus,
                  style: theme.textTheme.titleMedium,
                  decoration: InputDecoration(
                    hintText: 'End...',
                    hintStyle: theme.textTheme.titleMedium?.copyWith(
                      color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
                    ),
                    border: InputBorder.none,
                    isDense: true,
                  ),
                  onSubmitted: (_) {
                    _submit();
                  },
                ),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        // Zone B: Scrollable Wheels side-by-side
        FittedBox(
          fit: BoxFit.scaleDown,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              VoyagerTimePickerSpinner(
                time: _start,
                minutesInterval: 5,
                normalTextStyle: normalTextStyle,
                highlightedTextStyle: highlightTextStyle,
                spacing: 12, // slightly tighter
                itemHeight: 40,
                onTimeChange: (time) {
                  _updateStartMaintainDuration(time, updateText: !_startFocus.hasFocus);
                },
              ),
              const SizedBox(width: 8),
              Icon(Icons.arrow_forward, size: 20, color: theme.colorScheme.onSurface.withValues(alpha: 0.3)),
              const SizedBox(width: 8),
              VoyagerTimePickerSpinner(
                time: _end,
                minutesInterval: 5,
                normalTextStyle: normalTextStyle,
                highlightedTextStyle: highlightTextStyle,
                spacing: 12,
                itemHeight: 40,
                onTimeChange: (time) {
                  setState(() {
                    _end = time;
                    if (!_endFocus.hasFocus) {
                      _endController.text = _end.format(context);
                    }
                  });
                },
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        // Zone C: Durations
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            children: [
              Expanded(
                child: Wrap(
                  spacing: 4,
                  runSpacing: 4,
                  children: durations.map((d) {
                    return ActionChip(
                      label: Text(d['label'] as String, style: const TextStyle(fontSize: 12)),
                      padding: EdgeInsets.zero,
                      visualDensity: VisualDensity.compact,
                      onPressed: () {
                        _applyDuration(d['duration'] as Duration);
                      },
                    );
                  }).toList(),
                ),
              ),
              const SizedBox(width: 12),
              SizedBox(
                width: 60,
                child: TextField(
                  controller: _durationController,
                  focusNode: _durationFocus,
                  style: theme.textTheme.bodyMedium,
                  textAlign: TextAlign.center,
                  decoration: InputDecoration(
                    hintText: 'e.g. 45m',
                    hintStyle: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
                    ),
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(vertical: 8),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: BorderSide(color: theme.colorScheme.onSurface.withValues(alpha: 0.2)),
                    ),
                  ),
                  onSubmitted: (_) {
                    _submit();
                  },
                ),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        InkWell(
          onTap: _submit,
          child: Container(
            height: 48,
            alignment: Alignment.center,
            child: Text('Done', style: theme.textTheme.titleMedium?.copyWith(color: theme.colorScheme.primary, fontWeight: FontWeight.bold)),
          ),
        ),
      ],
    );
  }
}

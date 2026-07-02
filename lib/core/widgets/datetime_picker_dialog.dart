import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:voyager/core/widgets/enter_to_submit_scope.dart';

/// Shows a combined calendar + clock picker dialog.
Future<DateTime?> showDateTimePickerDialog(
  BuildContext context, {
  required DateTime initialDateTime,
}) {
  return showDialog<DateTime>(
    context: context,
    builder: (_) => DateTimePickerDialog(initialDateTime: initialDateTime),
  );
}

class DateTimePickerDialog extends StatefulWidget {
  const DateTimePickerDialog({super.key, required this.initialDateTime});

  final DateTime initialDateTime;

  @override
  State<DateTimePickerDialog> createState() => _DateTimePickerDialogState();
}

class _DateTimePickerDialogState extends State<DateTimePickerDialog> {
  late DateTime _date;
  late int _hour;
  late int _minute;

  @override
  void initState() {
    super.initState();
    final local = widget.initialDateTime.toLocal();
    _date = local;
    _hour = local.hour;
    _minute = local.minute;
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return EnterToSubmitScope(
      onSubmit: () => Navigator.of(context).pop(
        DateTime(
          _date.year,
          _date.month,
          _date.day,
          _hour,
          _minute,
        ),
      ),
      child: Dialog(
      child: SizedBox(
        width: 680,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              height: 420,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(
                    child: CalendarDatePicker(
                      initialDate: _date,
                      firstDate: DateTime(1900),
                      lastDate: DateTime(2100),
                      onDateChanged: (d) => setState(() => _date = d),
                    ),
                  ),
                  VerticalDivider(width: 1, color: colorScheme.outlineVariant),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(24, 12, 24, 12),
                    child: _ClockTimePicker(
                      hour: _hour,
                      minute: _minute,
                      onChanged: (time) => setState(() {
                        _hour = time.hour;
                        _minute = time.minute;
                      }),
                    ),
                  ),
                ],
              ),
            ),
            Divider(height: 1, color: colorScheme.outlineVariant),
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
              child: Row(
                children: [
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(
                      DateTime(_date.year, _date.month, _date.day),
                    ),
                    child: const Text('Add date'),
                  ),
                  const Spacer(),
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('Cancel'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: () => Navigator.of(context).pop(
                      DateTime(
                        _date.year,
                        _date.month,
                        _date.day,
                        _hour,
                        _minute,
                      ),
                    ),
                    child: const Text('OK'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
      ),
    );
  }
}

enum _ClockTimeMode { hour, minute }

class _ClockTimePicker extends StatefulWidget {
  const _ClockTimePicker({
    required this.hour,
    required this.minute,
    required this.onChanged,
  });

  final int hour;
  final int minute;
  final ValueChanged<TimeOfDay> onChanged;

  @override
  State<_ClockTimePicker> createState() => _ClockTimePickerState();
}

class _ClockTimePickerState extends State<_ClockTimePicker> {
  var _mode = _ClockTimeMode.hour;

  bool get _isPm => widget.hour >= 12;

  int get _displayHour {
    final hour = widget.hour % 12;
    return hour == 0 ? 12 : hour;
  }

  void _setHour(int hour12) {
    final normalizedHour = hour12 == 12 ? 0 : hour12;
    widget.onChanged(
      TimeOfDay(hour: normalizedHour + (_isPm ? 12 : 0), minute: widget.minute),
    );
  }

  void _setMinute(int minute) {
    widget.onChanged(TimeOfDay(hour: widget.hour, minute: minute));
  }

  void _setPeriod({required bool isPm}) {
    var hour = widget.hour;
    if (isPm && hour < 12) hour += 12;
    if (!isPm && hour >= 12) hour -= 12;
    widget.onChanged(TimeOfDay(hour: hour, minute: widget.minute));
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Text('Time', style: Theme.of(context).textTheme.labelMedium),
        const SizedBox(height: 8),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _TimeHeaderButton(
              label: _displayHour.toString().padLeft(2, '0'),
              selected: _mode == _ClockTimeMode.hour,
              onTap: () => setState(() => _mode = _ClockTimeMode.hour),
            ),
            Text(':', style: Theme.of(context).textTheme.headlineSmall),
            _TimeHeaderButton(
              label: widget.minute.toString().padLeft(2, '0'),
              selected: _mode == _ClockTimeMode.minute,
              onTap: () => setState(() => _mode = _ClockTimeMode.minute),
            ),
          ],
        ),
        const SizedBox(height: 8),
        SegmentedButton<bool>(
          segments: const [
            ButtonSegment(value: false, label: Text('AM')),
            ButtonSegment(value: true, label: Text('PM')),
          ],
          selected: {_isPm},
          showSelectedIcon: false,
          onSelectionChanged: (selection) {
            _setPeriod(isPm: selection.first);
          },
        ),
        const SizedBox(height: 12),
        Expanded(
          child: _ClockDial(
            mode: _mode,
            hour: _displayHour,
            minute: widget.minute,
            onHourChanged: _setHour,
            onMinuteChanged: _setMinute,
          ),
        ),
      ],
    );
  }
}

class _TimeHeaderButton extends StatelessWidget {
  const _TimeHeaderButton({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: onTap,
      child: Container(
        width: 56,
        padding: const EdgeInsets.symmetric(vertical: 8),
        decoration: BoxDecoration(
          color: selected
              ? colorScheme.primaryContainer
              : colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(
          label,
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.headlineSmall?.copyWith(
            color: selected
                ? colorScheme.onPrimaryContainer
                : colorScheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}

class _ClockDial extends StatelessWidget {
  const _ClockDial({
    required this.mode,
    required this.hour,
    required this.minute,
    required this.onHourChanged,
    required this.onMinuteChanged,
  });

  final _ClockTimeMode mode;
  final int hour;
  final int minute;
  final ValueChanged<int> onHourChanged;
  final ValueChanged<int> onMinuteChanged;

  void _handlePosition(Offset position, Size size) {
    final center = size.center(Offset.zero);
    final vector = position - center;
    final angle = math.atan2(vector.dy, vector.dx) + math.pi / 2;
    final normalized = angle < 0 ? angle + math.pi * 2 : angle;
    if (mode == _ClockTimeMode.hour) {
      final value = ((normalized / (math.pi * 2) * 12).round() % 12);
      onHourChanged(value == 0 ? 12 : value);
    } else {
      final value = ((normalized / (math.pi * 2) * 60).round() % 60);
      onMinuteChanged(value);
    }
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = math.min(constraints.maxWidth, constraints.maxHeight);
        return SizedBox(
          width: size,
          height: size,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapDown: (details) {
              _handlePosition(details.localPosition, Size(size, size));
            },
            onPanUpdate: (details) {
              _handlePosition(details.localPosition, Size(size, size));
            },
            child: CustomPaint(
              painter: _ClockDialPainter(
                mode: mode,
                hour: hour,
                minute: minute,
                colorScheme: Theme.of(context).colorScheme,
                textStyle: Theme.of(context).textTheme.bodyMedium,
              ),
            ),
          ),
        );
      },
    );
  }
}

class _ClockDialPainter extends CustomPainter {
  _ClockDialPainter({
    required this.mode,
    required this.hour,
    required this.minute,
    required this.colorScheme,
    required this.textStyle,
  });

  final _ClockTimeMode mode;
  final int hour;
  final int minute;
  final ColorScheme colorScheme;
  final TextStyle? textStyle;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final radius = math.min(size.width, size.height) / 2;
    final labelRadius = radius - 28;
    final selectedValue = mode == _ClockTimeMode.hour ? hour : minute;
    final steps = mode == _ClockTimeMode.hour ? 12 : 60;
    final selectedAngle =
        (mode == _ClockTimeMode.hour ? hour % 12 : minute) /
            steps *
            math.pi *
            2 -
        math.pi / 2;
    final selectedOffset = Offset(
      center.dx + math.cos(selectedAngle) * labelRadius,
      center.dy + math.sin(selectedAngle) * labelRadius,
    );

    canvas.drawCircle(
      center,
      radius,
      Paint()..color = colorScheme.surfaceContainerHighest,
    );
    canvas.drawLine(
      center,
      selectedOffset,
      Paint()
        ..color = colorScheme.primary
        ..strokeWidth = 2,
    );
    canvas.drawCircle(center, 4, Paint()..color = colorScheme.primary);
    canvas.drawCircle(selectedOffset, 20, Paint()..color = colorScheme.primary);

    if (mode == _ClockTimeMode.hour) {
      for (var i = 1; i <= 12; i++) {
        _paintLabel(canvas, center, labelRadius, i, i, selectedValue);
      }
    } else {
      for (var i = 0; i < 60; i += 5) {
        _paintLabel(canvas, center, labelRadius, i, i, selectedValue);
      }
    }
  }

  void _paintLabel(
    Canvas canvas,
    Offset center,
    double radius,
    int position,
    int value,
    int selectedValue,
  ) {
    final steps = mode == _ClockTimeMode.hour ? 12 : 60;
    final angle = (position % steps) / steps * math.pi * 2 - math.pi / 2;
    final labelOffset = Offset(
      center.dx + math.cos(angle) * radius,
      center.dy + math.sin(angle) * radius,
    );
    final selected = value == selectedValue;
    final painter = TextPainter(
      text: TextSpan(
        text: mode == _ClockTimeMode.hour
            ? value.toString()
            : value.toString().padLeft(2, '0'),
        style: textStyle?.copyWith(
          color: selected ? colorScheme.onPrimary : colorScheme.onSurface,
        ),
      ),
      textAlign: TextAlign.center,
      textDirection: TextDirection.ltr,
    )..layout();
    painter.paint(
      canvas,
      labelOffset - Offset(painter.width / 2, painter.height / 2),
    );
  }

  @override
  bool shouldRepaint(covariant _ClockDialPainter oldDelegate) {
    return oldDelegate.mode != mode ||
        oldDelegate.hour != hour ||
        oldDelegate.minute != minute ||
        oldDelegate.colorScheme != colorScheme ||
        oldDelegate.textStyle != textStyle;
  }
}

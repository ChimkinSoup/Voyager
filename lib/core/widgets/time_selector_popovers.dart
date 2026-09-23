import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:voyager/core/theme/voyager_theme.dart';
import 'package:voyager/core/utils/time_format.dart';
import 'package:voyager/core/widgets/field_scroll_padding.dart';
import 'package:voyager/core/widgets/select_all_on_click.dart';
import 'package:voyager/core/widgets/time_text_input_formatter.dart';
import 'voyager_time_picker_spinner.dart';

class TimeRangePopover extends StatefulWidget {
  final DateTime initialStart;
  final DateTime initialEnd;
  final ValueChanged<DateTimeRange>? onChanged;

  const TimeRangePopover({
    super.key,
    required this.initialStart,
    required this.initialEnd,
    this.onChanged,
  });

  @override
  State<TimeRangePopover> createState() => _TimeRangePopoverState();
}

class _TimeRangePopoverState extends State<TimeRangePopover> {
  late DateTime _startDt;
  late DateTime _endDt;
  late Duration _duration;

  late final TextEditingController _startController;
  late final TextEditingController _endController;

  late final FocusNode _startFocus;
  late final FocusNode _endFocus;

  bool _activeIsStart = true;
  bool _startSelectAllNextTap = false;
  bool _endSelectAllNextTap = false;

  bool _canPop = false;
  Duration? _selectedDuration;

  static const _presetDurations = [
    Duration(minutes: 15),
    Duration(minutes: 30),
    Duration(minutes: 45),
    Duration(hours: 1),
    Duration(hours: 2),
  ];

  Duration? _matchingPresetDuration(Duration duration) {
    for (final preset in _presetDurations) {
      if (preset == duration) return preset;
    }
    return null;
  }

  @override
  void initState() {
    super.initState();
    _startDt = widget.initialStart;
    _endDt = widget.initialEnd;
    _duration = _endDt.difference(_startDt);
    if (_duration.isNegative) _duration = const Duration(hours: 1);
    _selectedDuration = _matchingPresetDuration(_duration);

    _startController = TextEditingController();
    _endController = TextEditingController();

    _startFocus = FocusNode();
    _endFocus = FocusNode();

    _startFocus.addListener(() {
      if (_startFocus.hasFocus) {
        setState(() => _activeIsStart = true);
        _startSelectAllNextTap = true;
        selectAllTimeText(_startController);
      } else {
        _startController.text = _formatTime(_startDt);
      }
    });
    _endFocus.addListener(() {
      if (_endFocus.hasFocus) {
        setState(() => _activeIsStart = false);
        _endSelectAllNextTap = true;
        selectAllTimeText(_endController);
      } else {
        _endController.text = _formatTime(_endDt);
      }
    });

    _startController.addListener(_onStartTextChanged);
    _endController.addListener(_onEndTextChanged);

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _startController.text = _formatTime(_startDt);
        _endController.text = _formatTime(_endDt);
        _startFocus.requestFocus();
        selectAllTimeText(_startController);
      }
    });
  }

  @override
  void dispose() {
    _startController.dispose();
    _endController.dispose();
    _startFocus.dispose();
    _endFocus.dispose();
    super.dispose();
  }

  String _formatTime(DateTime dt) {
    return TimeOfDay.fromDateTime(dt).format(context);
  }

  void _onStartTextChanged() {
    if (!_startFocus.hasFocus) return;
    final parsed = parseTimeQuery(_startController.text, _startDt);
    if (parsed != null && parsed != _startDt) {
      _applyStartDt(parsed, updateText: false);
    }
  }

  void _onEndTextChanged() {
    if (!_endFocus.hasFocus) return;
    final parsed = parseTimeQuery(_endController.text, _endDt);
    if (parsed != null && parsed != _endDt) {
      _applyEndDt(parsed, updateText: false);
    }
  }

  void _applyStartDt(DateTime newStartDt, {bool updateText = true}) {
    setState(() {
      _startDt = newStartDt;
      _endDt = _startDt.add(_duration);

      if (updateText) {
        _startController.text = _formatTime(_startDt);
      }
      if (!_endFocus.hasFocus) {
        _endController.text = _formatTime(_endDt);
      }
      _selectedDuration = _matchingPresetDuration(_duration);
    });
    widget.onChanged?.call(DateTimeRange(start: _startDt, end: _endDt));
  }

  void _applyEndDt(DateTime newEndDt, {bool updateText = true}) {
    setState(() {
      _endDt = newEndDt;

      // Failsafe: if end is pushed to or before start, push start backwards to maintain a minimum 1-hour duration
      if (!_endDt.isAfter(_startDt)) {
        _startDt = _endDt.subtract(const Duration(hours: 1));
      }
      _duration = _endDt.difference(_startDt);
      _selectedDuration = _matchingPresetDuration(_duration);

      if (updateText) {
        _endController.text = _formatTime(_endDt);
      }
      if (!_startFocus.hasFocus) {
        _startController.text = _formatTime(_startDt);
      }
    });
    widget.onChanged?.call(DateTimeRange(start: _startDt, end: _endDt));
  }

  void _onStartSpinnerChanged(DateTime newTime) {
    _startFocus.requestFocus();
    setState(() => _activeIsStart = true);
    _applyStartDt(newTime, updateText: true);
  }

  void _onEndSpinnerChanged(DateTime newTime) {
    _endFocus.requestFocus();
    setState(() => _activeIsStart = false);
    _applyEndDt(newTime, updateText: true);
  }

  void _applyDuration(Duration dur) {
    setState(() {
      _selectedDuration = dur;
      _activeIsStart = false;
      _applyEndDt(_startDt.add(dur), updateText: true);
      _endFocus.requestFocus();
    });
  }

  void _submit() {
    if (!mounted) return;
    setState(() => _canPop = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted)
        Navigator.of(context).pop(DateTimeRange(start: _startDt, end: _endDt));
    });
  }

  Widget _timeField({
    required ThemeData theme,
    required TextEditingController controller,
    required FocusNode focusNode,
    required bool isActive,
    required String hintText,
    required VoidCallback onTap,
    required bool Function() selectAllPending,
    required ValueChanged<String> onSubmitted,
  }) {
    final accent = theme.colorScheme.primary;
    final fieldTheme = theme.copyWith(
      inputDecorationTheme: const InputDecorationTheme(
        filled: false,
        isDense: true,
        border: InputBorder.none,
        enabledBorder: InputBorder.none,
        focusedBorder: InputBorder.none,
        disabledBorder: InputBorder.none,
        errorBorder: InputBorder.none,
        focusedErrorBorder: InputBorder.none,
      ),
      splashFactory: NoSplash.splashFactory,
      highlightColor: Colors.transparent,
    );
    return AnimatedContainer(
      duration: const Duration(milliseconds: 150),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(VoyagerTheme.fieldRadius),
        border: Border.all(
          color: isActive
              ? accent
              : theme.colorScheme.onSurface.withValues(alpha: 0.2),
          width: isActive ? 2 : 1,
        ),
      ),
      child: Theme(
        data: fieldTheme,
        child: Material(
          type: MaterialType.transparency,
          child: SelectAllOnClick(
            controller: controller,
            focusNode: focusNode,
            selectAllPending: selectAllPending,
            child: TextField(
              contextMenuBuilder: (context, editableTextState) =>
                  const SizedBox.shrink(),
              textAlign: TextAlign.center,
              controller: controller,
              focusNode: focusNode,
              scrollPadding: kVoyagerFieldScrollPadding,
              style: theme.textTheme.titleMedium?.copyWith(
                color: isActive
                    ? accent
                    : theme.colorScheme.onSurface.withValues(alpha: 0.5),
              ),
              decoration: InputDecoration(
                hintText: hintText,
                hintStyle: theme.textTheme.titleMedium?.copyWith(
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.3),
                ),
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
                disabledBorder: InputBorder.none,
                errorBorder: InputBorder.none,
                focusedErrorBorder: InputBorder.none,
                isCollapsed: true,
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 8,
                  vertical: 8,
                ),
              ),
              onTap: onTap,
              onSubmitted: onSubmitted,
              textInputAction: TextInputAction.done,
              inputFormatters: [TimeTextInputFormatter()],
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final durations = [
      {'label': '15 m', 'duration': const Duration(minutes: 15)},
      {'label': '30 m', 'duration': const Duration(minutes: 30)},
      {'label': '45 m', 'duration': const Duration(minutes: 45)},
      {'label': '1 h', 'duration': const Duration(hours: 1)},
      {'label': '2h', 'duration': const Duration(hours: 2)},
    ];

    final activeNormalTextStyle = theme.textTheme.titleLarge?.copyWith(
      color: Color.lerp(
        theme.colorScheme.primary,
        theme.colorScheme.onSurface,
        0.7,
      )?.withValues(alpha: 0.4),
    );
    final activeHighlightTextStyle = theme.textTheme.titleLarge?.copyWith(
      color: theme.colorScheme.primary,
      fontWeight: FontWeight.bold,
    );
    final inactiveNormalTextStyle = theme.textTheme.titleLarge?.copyWith(
      color: theme.colorScheme.onSurface.withValues(alpha: 0.15),
    );
    final inactiveHighlightTextStyle = theme.textTheme.titleLarge?.copyWith(
      color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
      fontWeight: FontWeight.bold,
    );

    return PopScope(
      canPop: _canPop,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        if (mounted) {
          setState(() => _canPop = true);
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted)
              Navigator.of(
                context,
              ).pop(DateTimeRange(start: _startDt, end: _endDt));
          });
        }
      },
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              children: [
                Expanded(
                  child: AnimatedOpacity(
                    duration: const Duration(milliseconds: 150),
                    opacity: _activeIsStart ? 1.0 : 0.25,
                    child: _timeField(
                      theme: theme,
                      controller: _startController,
                      focusNode: _startFocus,
                      isActive: _activeIsStart,
                      hintText: 'Start...',
                      onTap: () {
                        if (_startSelectAllNextTap) {
                          _startController.selection = TextSelection(
                            baseOffset: 0,
                            extentOffset: _startController.text.length,
                          );
                          _startSelectAllNextTap = false;
                        }
                      },
                      selectAllPending: () => _startSelectAllNextTap,
                      onSubmitted: (_) => _endFocus.requestFocus(),
                    ),
                  ),
                ),
                const SizedBox(width: 4),
                Icon(
                  Icons.arrow_forward,
                  size: 16,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(width: 4),
                Expanded(
                  child: AnimatedOpacity(
                    duration: const Duration(milliseconds: 150),
                    opacity: !_activeIsStart ? 1.0 : 0.25,
                    child: _timeField(
                      theme: theme,
                      controller: _endController,
                      focusNode: _endFocus,
                      isActive: !_activeIsStart,
                      hintText: 'End...',
                      onTap: () {
                        if (_endSelectAllNextTap) {
                          _endController.selection = TextSelection(
                            baseOffset: 0,
                            extentOffset: _endController.text.length,
                          );
                          _endSelectAllNextTap = false;
                        }
                      },
                      selectAllPending: () => _endSelectAllNextTap,
                      onSubmitted: (_) => _submit(),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                AnimatedOpacity(
                  duration: const Duration(milliseconds: 150),
                  opacity: _activeIsStart ? 1.0 : 0.25,
                  child: VoyagerTimePickerSpinner(
                    time: _startDt,
                    isActive: _activeIsStart,
                    normalTextStyle: _activeIsStart
                        ? activeNormalTextStyle
                        : inactiveNormalTextStyle,
                    highlightedTextStyle: _activeIsStart
                        ? activeHighlightTextStyle
                        : inactiveHighlightTextStyle,
                    spacing: 4,
                    itemHeight: 40,
                    onInteraction: () {
                      if (!_activeIsStart) {
                        setState(() => _activeIsStart = true);
                        _startFocus.requestFocus();
                      }
                    },
                    onTimeChange: _onStartSpinnerChanged,
                  ),
                ),
                const SizedBox(width: 10),
                Icon(
                  Icons.arrow_forward,
                  size: 20,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(width: 2),
                AnimatedOpacity(
                  duration: const Duration(milliseconds: 150),
                  opacity: !_activeIsStart ? 1.0 : 0.25,
                  child: VoyagerTimePickerSpinner(
                    time: _endDt,
                    isActive: !_activeIsStart,
                    normalTextStyle: !_activeIsStart
                        ? activeNormalTextStyle
                        : inactiveNormalTextStyle,
                    highlightedTextStyle: !_activeIsStart
                        ? activeHighlightTextStyle
                        : inactiveHighlightTextStyle,
                    spacing: 4,
                    itemHeight: 40,
                    onInteraction: () {
                      if (_activeIsStart) {
                        setState(() => _activeIsStart = false);
                        _endFocus.requestFocus();
                      }
                    },
                    onTimeChange: _onEndSpinnerChanged,
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              alignment: WrapAlignment.center,
              children: durations.map((d) {
                final duration = d['duration'] as Duration;
                final isSelected = _selectedDuration == duration;
                return ActionChip(
                  label: Text(
                    d['label'] as String,
                    style: TextStyle(
                      fontSize: 13,
                      color: isSelected
                          ? theme.colorScheme.onPrimary
                          : theme.colorScheme.onSurface,
                    ),
                  ),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 4,
                    vertical: 0,
                  ),
                  visualDensity: VisualDensity.compact,
                  backgroundColor: isSelected
                      ? theme.colorScheme.primary
                      : Colors.transparent,
                  side: isSelected
                      ? BorderSide(color: theme.colorScheme.primary, width: 1)
                      : BorderSide(
                          color: theme.colorScheme.onSurface.withValues(
                            alpha: 0.2,
                          ),
                          width: 1,
                        ),
                  onPressed: () {
                    _applyDuration(duration);
                  },
                );
              }).toList(),
            ),
          ),
          const Divider(height: 1),
          InkWell(
            onTap: _submit,
            child: Container(
              height: 48,
              alignment: Alignment.center,
              child: Text(
                'Done',
                style: theme.textTheme.titleMedium?.copyWith(
                  color: theme.colorScheme.primary,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class TimeSelectorPopover extends StatefulWidget {
  final DateTime initialTime;
  final ValueChanged<DateTime>? onChanged;

  const TimeSelectorPopover({
    super.key,
    required this.initialTime,
    this.onChanged,
  });

  @override
  State<TimeSelectorPopover> createState() => _TimeSelectorPopoverState();
}

class _TimeSelectorPopoverState extends State<TimeSelectorPopover> {
  late DateTime _timeDt;
  late final TextEditingController _timeController;
  late final FocusNode _timeFocus;
  bool _selectAllNextTap = false;
  bool _canPop = false;

  @override
  void initState() {
    super.initState();
    _timeDt = widget.initialTime;
    _timeController = TextEditingController();
    _timeFocus = FocusNode();

    _timeFocus.addListener(() {
      if (_timeFocus.hasFocus) {
        _selectAllNextTap = true;
        selectAllTimeText(_timeController);
      } else {
        _timeController.text = _formatTime(_timeDt);
      }
    });

    _timeController.addListener(_onTimeTextChanged);

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _timeController.text = _formatTime(_timeDt);
        _timeFocus.requestFocus();
        selectAllTimeText(_timeController);
      }
    });
  }

  @override
  void dispose() {
    _timeController.dispose();
    _timeFocus.dispose();
    super.dispose();
  }

  String _formatTime(DateTime dt) {
    return TimeOfDay.fromDateTime(dt).format(context);
  }

  void _onTimeTextChanged() {
    if (!_timeFocus.hasFocus) return;
    final parsed = parseTimeQuery(_timeController.text, _timeDt);
    if (parsed != null && parsed != _timeDt) {
      _applyTimeDt(parsed, updateText: false);
    }
  }

  void _applyTimeDt(DateTime newTimeDt, {bool updateText = true}) {
    setState(() {
      _timeDt = newTimeDt;
      if (updateText) {
        _timeController.text = _formatTime(_timeDt);
      }
    });
    widget.onChanged?.call(_timeDt);
  }

  void _onSpinnerChanged(DateTime newTime) {
    _timeFocus.requestFocus();
    _applyTimeDt(newTime, updateText: true);
  }

  void _submit() {
    if (!mounted) return;
    setState(() => _canPop = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) Navigator.of(context).pop(_timeDt);
    });
  }

  Widget _timeField({
    required ThemeData theme,
    required TextEditingController controller,
    required FocusNode focusNode,
    required String hintText,
    required VoidCallback onTap,
    required bool Function() selectAllPending,
    required ValueChanged<String> onSubmitted,
  }) {
    final accent = theme.colorScheme.primary;
    final fieldTheme = theme.copyWith(
      inputDecorationTheme: const InputDecorationTheme(
        filled: false,
        isDense: true,
        border: InputBorder.none,
        enabledBorder: InputBorder.none,
        focusedBorder: InputBorder.none,
        disabledBorder: InputBorder.none,
        errorBorder: InputBorder.none,
        focusedErrorBorder: InputBorder.none,
      ),
      splashFactory: NoSplash.splashFactory,
      highlightColor: Colors.transparent,
    );
    return AnimatedContainer(
      duration: const Duration(milliseconds: 150),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(VoyagerTheme.fieldRadius),
        border: Border.all(color: accent, width: 2),
      ),
      child: Theme(
        data: fieldTheme,
        child: Material(
          type: MaterialType.transparency,
          child: SelectAllOnClick(
            controller: controller,
            focusNode: focusNode,
            selectAllPending: selectAllPending,
            child: TextField(
              contextMenuBuilder: (context, editableTextState) =>
                  const SizedBox.shrink(),
              textAlign: TextAlign.center,
              controller: controller,
              focusNode: focusNode,
              scrollPadding: kVoyagerFieldScrollPadding,
              style: theme.textTheme.titleMedium?.copyWith(color: accent),
              decoration: InputDecoration(
                hintText: hintText,
                hintStyle: theme.textTheme.titleMedium?.copyWith(
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.3),
                ),
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
                disabledBorder: InputBorder.none,
                errorBorder: InputBorder.none,
                focusedErrorBorder: InputBorder.none,
                isCollapsed: true,
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 8,
                  vertical: 8,
                ),
              ),
              onTap: onTap,
              onSubmitted: onSubmitted,
              textInputAction: TextInputAction.done,
              inputFormatters: [TimeTextInputFormatter()],
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    final activeNormalTextStyle = theme.textTheme.titleLarge?.copyWith(
      color: Color.lerp(
        theme.colorScheme.primary,
        theme.colorScheme.onSurface,
        0.7,
      )?.withValues(alpha: 0.4),
    );
    final activeHighlightTextStyle = theme.textTheme.titleLarge?.copyWith(
      color: theme.colorScheme.primary,
      fontWeight: FontWeight.bold,
    );

    return PopScope(
      canPop: _canPop,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        if (mounted) {
          setState(() => _canPop = true);
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) Navigator.of(context).pop(_timeDt);
          });
        }
      },
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              children: [
                Expanded(
                  child: _timeField(
                    theme: theme,
                    controller: _timeController,
                    focusNode: _timeFocus,
                    hintText: 'Time...',
                    onTap: () {
                      if (_selectAllNextTap) {
                        _timeController.selection = TextSelection(
                          baseOffset: 0,
                          extentOffset: _timeController.text.length,
                        );
                        _selectAllNextTap = false;
                      }
                    },
                    selectAllPending: () => _selectAllNextTap,
                    onSubmitted: (_) => _submit(),
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                VoyagerTimePickerSpinner(
                  time: _timeDt,
                  isActive: true,
                  normalTextStyle: activeNormalTextStyle,
                  highlightedTextStyle: activeHighlightTextStyle,
                  spacing: 4,
                  itemHeight: 40,
                  onTimeChange: _onSpinnerChanged,
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
              child: Text(
                'Done',
                style: theme.textTheme.titleMedium?.copyWith(
                  color: theme.colorScheme.primary,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

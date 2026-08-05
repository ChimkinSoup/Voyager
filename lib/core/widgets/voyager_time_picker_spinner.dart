import 'package:flutter/material.dart';
import 'package:voyager/core/dev/dev_flags.dart';
import 'package:voyager/core/motion/motion.dart';
import 'package:voyager/core/theme/voyager_theme.dart';

class VoyagerTimePickerSpinner extends StatefulWidget {
  const VoyagerTimePickerSpinner({
    super.key,
    required this.time,
    required this.onTimeChange,
    this.onInteraction,
    this.minutesInterval = 5,
    this.itemHeight = 40.0,
    this.spacing = 20.0,
    this.isActive = true,
    this.normalTextStyle,
    this.highlightedTextStyle,
  });

  final DateTime time;
  final ValueChanged<DateTime> onTimeChange;
  final VoidCallback? onInteraction;
  final int minutesInterval;
  final double itemHeight;
  final double spacing;
  final bool isActive;
  final TextStyle? normalTextStyle;
  final TextStyle? highlightedTextStyle;

  @override
  State<VoyagerTimePickerSpinner> createState() => _VoyagerTimePickerSpinnerState();
}

class _VoyagerTimePickerSpinnerState extends State<VoyagerTimePickerSpinner> {
  bool _isProgrammaticScroll = false;
  late FixedExtentScrollController _hourController;
  late FixedExtentScrollController _minuteController;
  late FixedExtentScrollController _amPmController;

  late int _currentHourIndex;
  late int _currentMinuteIndex;
  late int _currentAmPmIndex;
  late int _minuteItemsCount;
  late DateTime _currentDate;

  // Tracks the snapped item index for each wheel — used to highlight the
  // selected row without subscribing every item to the scroll animation.
  late int _displayHourItem;
  late int _displayMinuteItem;
  late int _displayAmPmItem;

  @override
  void initState() {
    super.initState();
    _currentDate = widget.time;
    _minuteItemsCount = 60 ~/ widget.minutesInterval;

    int hour12 = _currentDate.hour % 12;
    if (hour12 == 0) hour12 = 12;
    _currentHourIndex = hour12 - 1;

    int initialMinute = _currentDate.minute;
    _currentMinuteIndex = (initialMinute / widget.minutesInterval).round() % _minuteItemsCount;

    _currentAmPmIndex = _currentDate.hour >= 12 ? 1 : 0;

    final initialHourOffset = 12000 + _currentHourIndex;
    final initialMinuteOffset = (_minuteItemsCount * 1000) + _currentMinuteIndex;

    _hourController = FixedExtentScrollController(initialItem: initialHourOffset);
    _minuteController = FixedExtentScrollController(initialItem: initialMinuteOffset);
    _amPmController = FixedExtentScrollController(initialItem: _currentAmPmIndex);

    _displayHourItem = initialHourOffset;
    _displayMinuteItem = initialMinuteOffset;
    _displayAmPmItem = _currentAmPmIndex;
  }

  @override
  void didUpdateWidget(covariant VoyagerTimePickerSpinner oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.time != widget.time) {
      _currentDate = widget.time;
      int h = (_hourController.hasClients ? _hourController.selectedItem % 12 : _currentHourIndex) + 1;
      int m = (_minuteController.hasClients ? _minuteController.selectedItem % _minuteItemsCount : _currentMinuteIndex) * widget.minutesInterval;
      int ap = _amPmController.hasClients ? _amPmController.selectedItem.clamp(0, 1) : _currentAmPmIndex;
      int currentHour24 = h % 12;
      if (ap == 1) currentHour24 += 12;

      if (currentHour24 != widget.time.hour || m != widget.time.minute) {
        int targetHour12 = widget.time.hour % 12;
        if (targetHour12 == 0) targetHour12 = 12;
        int targetHourIndex = targetHour12 - 1;
        int targetMinuteIndex = (widget.time.minute / widget.minutesInterval).round() % _minuteItemsCount;
        int targetAmPmIndex = widget.time.hour >= 12 ? 1 : 0;

        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          _isProgrammaticScroll = true;
          if (_hourController.hasClients) {
            int current = _hourController.selectedItem;
            int diff = targetHourIndex - (current % 12);
            if (diff > 6) diff -= 12;
            if (diff < -6) diff += 12;
            final next = current + diff;
            _hourController.jumpToItem(next);
            _displayHourItem = next;
          }
          if (_minuteController.hasClients) {
            int current = _minuteController.selectedItem;
            int diff = targetMinuteIndex - (current % _minuteItemsCount);
            if (diff > (_minuteItemsCount ~/ 2)) diff -= _minuteItemsCount;
            if (diff < -(_minuteItemsCount ~/ 2)) diff += _minuteItemsCount;
            final next = current + diff;
            _minuteController.jumpToItem(next);
            _displayMinuteItem = next;
          }
          if (_amPmController.hasClients && _amPmController.selectedItem != targetAmPmIndex) {
            _amPmController.jumpToItem(targetAmPmIndex);
            _displayAmPmItem = targetAmPmIndex;
          }
          _isProgrammaticScroll = false;
        });
      }
    }
  }

  @override
  void dispose() {
    _hourController.dispose();
    _minuteController.dispose();
    _amPmController.dispose();
    super.dispose();
  }

  void _onTimeChanged() {
    if (_isProgrammaticScroll) return;
    int h = (_hourController.selectedItem % 12) + 1;
    int m = (_minuteController.selectedItem % _minuteItemsCount) * widget.minutesInterval;
    int ap = _amPmController.selectedItem.clamp(0, 1);

    int hour24 = h % 12;
    if (ap == 1) hour24 += 12;

    _currentDate = DateTime(_currentDate.year, _currentDate.month, _currentDate.day, hour24, m);
    widget.onTimeChange(_currentDate);
  }

  int _lastMinuteItem = 0;
  bool _isMinuteInitialized = false;

  void _onMinuteSelectedItemChanged(int index) {
    if (_isProgrammaticScroll) {
      _lastMinuteItem = index;
      return;
    }

    if (!_isMinuteInitialized) {
      _lastMinuteItem = index;
      _isMinuteInitialized = true;
    } else {
      int oldCycle = _lastMinuteItem ~/ _minuteItemsCount;
      if (_lastMinuteItem < 0 && _lastMinuteItem % _minuteItemsCount != 0) oldCycle -= 1;

      int newCycle = index ~/ _minuteItemsCount;
      if (index < 0 && index % _minuteItemsCount != 0) newCycle -= 1;

      int cycleDiff = newCycle - oldCycle;
      if (cycleDiff != 0) {
        _jumpHourBy(cycleDiff);
      }

      _lastMinuteItem = index;
    }
    _onTimeChanged();
  }

  int _lastHourItem = 0;
  bool _isHourInitialized = false;

  void _onHourSelectedItemChanged(int index) {
    if (_isProgrammaticScroll) {
      _lastHourItem = index;
      return;
    }

    if (!_isHourInitialized) {
      _lastHourItem = index;
      _isHourInitialized = true;
    } else {
      int oldAdjusted = _lastHourItem + 1;
      int oldCycle = oldAdjusted ~/ 12;
      if (oldAdjusted < 0 && oldAdjusted % 12 != 0) oldCycle -= 1;

      int newAdjusted = index + 1;
      int newCycle = newAdjusted ~/ 12;
      if (newAdjusted < 0 && newAdjusted % 12 != 0) newCycle -= 1;

      int cycleDiff = newCycle - oldCycle;
      if (cycleDiff != 0) {
        _currentDate = _currentDate.add(Duration(hours: 12 * cycleDiff));
        _toggleAmPm(cycleDiff);
      }
      _lastHourItem = index;
    }
    _onTimeChanged();
  }

  void _jumpHourBy(int amount) {
    if (amount == 0) return;
    _hourController.animateToItem(
      _hourController.selectedItem + amount,
      duration: const Duration(milliseconds: 300),
      curve: VoyagerSpring.moveCurve,
    );
  }

  void _toggleAmPm(int amount) {
    if (amount.abs() % 2 != 0) {
      int current = _amPmController.selectedItem;
      int next = current == 0 ? 1 : 0;
      _amPmController.animateToItem(
        next,
        duration: const Duration(milliseconds: 300),
        curve: VoyagerSpring.moveCurve,
      );
    }
  }

  // Each item is built once per snap change — no per-frame AnimatedBuilder.
  Widget _buildWheel({
    required FixedExtentScrollController controller,
    required int selectedItem,
    required Widget Function(BuildContext, int, bool) builder,
    required ValueChanged<int> onSelectedItemChanged,
    int? itemCount,
    double width = 40,
  }) {
    Widget wheel = SizedBox(
      width: width,
      child: NotificationListener<ScrollNotification>(
        onNotification: (n) {
          if ((n is ScrollStartNotification || n is ScrollUpdateNotification) &&
              !_isProgrammaticScroll) {
            widget.onInteraction?.call();
          }
          return false;
        },
        child: ListWheelScrollView.useDelegate(
          controller: controller,
          itemExtent: widget.itemHeight,
          physics: const _HighFrictionFixedExtentScrollPhysics(),
          perspective: 0.005,
          onSelectedItemChanged: onSelectedItemChanged,
          childDelegate: ListWheelChildBuilderDelegate(
            builder: (ctx, index) => builder(ctx, index, index == selectedItem),
            childCount: itemCount,
          ),
        ),
      ),
    );

    if (DevFlags.showTimeSelectorHitboxes) {
      return Container(color: Colors.red.withValues(alpha: 0.5), child: wheel);
    }
    return wheel;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final normalStyle = widget.normalTextStyle ??
        theme.textTheme.titleLarge?.copyWith(
          color: theme.colorScheme.onSurface.withValues(alpha: 0.3),
        );
    final highlightStyle = widget.highlightedTextStyle ??
        theme.textTheme.titleLarge?.copyWith(
          color: theme.colorScheme.primary,
          fontWeight: FontWeight.bold,
        );

    return SizedBox(
      height: widget.itemHeight * 4,
      child: ShaderMask(
        shaderCallback: (Rect bounds) {
          return const LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Colors.transparent, Colors.black, Colors.black, Colors.transparent],
            stops: [0.0, 0.25, 0.75, 1.0],
          ).createShader(bounds);
        },
        blendMode: BlendMode.dstIn,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          mainAxisSize: MainAxisSize.min,
          children: [
            Stack(
              alignment: Alignment.center,
              children: [
                Text(':', style: widget.isActive ? highlightStyle : normalStyle),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _buildWheel(
                      width: 50,
                      controller: _hourController,
                      selectedItem: _displayHourItem,
                      onSelectedItemChanged: (index) {
                        if (!_isProgrammaticScroll) setState(() => _displayHourItem = index);
                        _onHourSelectedItemChanged(index);
                      },
                      builder: (ctx, index, isSelected) {
                        int h = (index % 12) + 1;
                        return Center(
                          child: Text(
                            h.toString().padLeft(2, '0'),
                            style: isSelected ? highlightStyle : normalStyle,
                          ),
                        );
                      },
                    ),
                    _buildWheel(
                      width: 50,
                      controller: _minuteController,
                      selectedItem: _displayMinuteItem,
                      onSelectedItemChanged: (index) {
                        if (!_isProgrammaticScroll) setState(() => _displayMinuteItem = index);
                        _onMinuteSelectedItemChanged(index);
                      },
                      builder: (ctx, index, isSelected) {
                        int m = (index % _minuteItemsCount) * widget.minutesInterval;
                        TextStyle? style = isSelected ? highlightStyle : normalStyle;
                        if (widget.isActive && m % 30 == 0 && highlightStyle != null) {
                          final wash = VoyagerColors.of(ctx).highlightWash;
                          Color base = highlightStyle.color ?? wash;
                          Color lighter = Color.lerp(base, wash, 0.4) ?? wash;
                          style = highlightStyle.copyWith(
                            color: isSelected ? lighter : lighter.withValues(alpha: 0.7),
                          );
                        }
                        return Center(
                          child: Text(
                            m.toString().padLeft(2, '0'),
                            style: style,
                          ),
                        );
                      },
                    ),
                  ],
                ),
              ],
            ),
            SizedBox(width: widget.spacing),
            _buildWheel(
              controller: _amPmController,
              selectedItem: _displayAmPmItem,
              itemCount: 2,
              onSelectedItemChanged: (index) {
                if (!_isProgrammaticScroll) {
                  setState(() => _displayAmPmItem = index.clamp(0, 1));
                  _onTimeChanged();
                }
              },
              builder: (ctx, index, isSelected) {
                return Center(
                  child: Text(
                    index == 0 ? 'AM' : 'PM',
                    style: isSelected ? highlightStyle : normalStyle,
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _HighFrictionFixedExtentScrollPhysics extends FixedExtentScrollPhysics {
  const _HighFrictionFixedExtentScrollPhysics({super.parent});

  @override
  _HighFrictionFixedExtentScrollPhysics applyTo(ScrollPhysics? ancestor) {
    return _HighFrictionFixedExtentScrollPhysics(parent: buildParent(ancestor));
  }

  @override
  Simulation? createBallisticSimulation(ScrollMetrics position, double velocity) {
    return super.createBallisticSimulation(position, velocity * 0.4);
  }
}

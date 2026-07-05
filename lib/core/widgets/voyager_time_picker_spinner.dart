import 'package:flutter/material.dart';

class VoyagerTimePickerSpinner extends StatefulWidget {
  const VoyagerTimePickerSpinner({
    super.key,
    required this.time,
    required this.onTimeChange,
    this.minutesInterval = 5,
    this.itemHeight = 40.0,
    this.spacing = 20.0,
    this.normalTextStyle,
    this.highlightedTextStyle,
  });

  final TimeOfDay time;
  final ValueChanged<TimeOfDay> onTimeChange;
  final int minutesInterval;
  final double itemHeight;
  final double spacing;
  final TextStyle? normalTextStyle;
  final TextStyle? highlightedTextStyle;

  @override
  State<VoyagerTimePickerSpinner> createState() => _VoyagerTimePickerSpinnerState();
}

class _VoyagerTimePickerSpinnerState extends State<VoyagerTimePickerSpinner> {
  late FixedExtentScrollController _hourController;
  late FixedExtentScrollController _minuteController;
  late FixedExtentScrollController _amPmController;

  late int _currentHourIndex; // 0-11
  late int _currentMinuteIndex; // e.g. 0-11 for 5 min intervals
  late int _currentAmPmIndex; // 0 for AM, 1 for PM

  late int _minuteItemsCount;

  @override
  void initState() {
    super.initState();
    _minuteItemsCount = 60 ~/ widget.minutesInterval;
    
    int hour12 = widget.time.hour % 12;
    if (hour12 == 0) hour12 = 12;
    _currentHourIndex = hour12 - 1; 
    
    int initialMinute = widget.time.minute;
    _currentMinuteIndex = (initialMinute / widget.minutesInterval).round() % _minuteItemsCount;
    
    _currentAmPmIndex = widget.time.hour >= 12 ? 1 : 0;

    final initialHourOffset = 12000 + _currentHourIndex;
    final initialMinuteOffset = (_minuteItemsCount * 1000) + _currentMinuteIndex;
    
    _hourController = FixedExtentScrollController(initialItem: initialHourOffset);
    _minuteController = FixedExtentScrollController(initialItem: initialMinuteOffset);
    _amPmController = FixedExtentScrollController(initialItem: _currentAmPmIndex);
  }

  @override
  void didUpdateWidget(covariant VoyagerTimePickerSpinner oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.time != widget.time) {
      // only update if we aren't currently scrolling to avoid fighting the user
      // Actually, a simpler way is to jump the controllers if the time differs from the currently selected time.
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
          if (_hourController.hasClients) {
            int currentHourItem = _hourController.selectedItem;
            int diff = targetHourIndex - (currentHourItem % 12);
            if (diff > 6) diff -= 12;
            if (diff < -6) diff += 12;
            _hourController.jumpToItem(currentHourItem + diff);
          }
          if (_minuteController.hasClients) {
            int currentMinItem = _minuteController.selectedItem;
            int diff = targetMinuteIndex - (currentMinItem % _minuteItemsCount);
            if (diff > (_minuteItemsCount~/2)) diff -= _minuteItemsCount;
            if (diff < -(_minuteItemsCount~/2)) diff += _minuteItemsCount;
            _minuteController.jumpToItem(currentMinItem + diff);
          }
          if (_amPmController.hasClients && _amPmController.selectedItem != targetAmPmIndex) {
            _amPmController.jumpToItem(targetAmPmIndex);
          }
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
    // Determine the actual selected values
    int h = (_hourController.selectedItem % 12) + 1; // 1-12
    int m = (_minuteController.selectedItem % _minuteItemsCount) * widget.minutesInterval;
    
    // For AM/PM, it's not infinite, just 0 or 1
    int ap = _amPmController.selectedItem.clamp(0, 1);
    
    int hour24 = h % 12;
    if (ap == 1) {
      hour24 += 12; // PM
    }

    widget.onTimeChange(TimeOfDay(hour: hour24, minute: m));
  }


  // To handle the minute roll-over to hour, we need to compare the new selected item with the old one
  // and see if we crossed a full cycle.
  int _lastMinuteItem = 0;
  bool _isMinuteInitialized = false;

  void _onMinuteSelectedItemChanged(int index) {
    if (!_isMinuteInitialized) {
      _lastMinuteItem = index;
      _isMinuteInitialized = true;
    } else {
      // If user scrolls up by 1 (e.g. 55 -> 0), index increases
      // Wait, scrolling down (finger moves up, list moves down) -> index increases.
      // 55 is index 11, 0 is index 12. So diff is +1.
      
      // We only care about crossing a boundary.
      // Every time we cross a multiple of _minuteItemsCount, we add or subtract to the hour.
      int oldCycle = _lastMinuteItem ~/ _minuteItemsCount;
      if (_lastMinuteItem < 0 && _lastMinuteItem % _minuteItemsCount != 0) oldCycle -= 1;
      
      int newCycle = index ~/ _minuteItemsCount;
      if (index < 0 && index % _minuteItemsCount != 0) newCycle -= 1;

      int cycleDiff = newCycle - oldCycle;
      if (cycleDiff != 0) {
        // We crossed a full hour boundary!
        _jumpHourBy(cycleDiff);
      }
      
      _lastMinuteItem = index;
    }
    _onTimeChanged();
  }

  int _lastHourItem = 0;
  bool _isHourInitialized = false;

  void _onHourSelectedItemChanged(int index) {
    if (!_isHourInitialized) {
      _lastHourItem = index;
      _isHourInitialized = true;
    } else {
      int oldCycle = _lastHourItem ~/ 12;
      if (_lastHourItem < 0 && _lastHourItem % 12 != 0) oldCycle -= 1;
      
      int newCycle = index ~/ 12;
      if (index < 0 && index % 12 != 0) newCycle -= 1;

      int cycleDiff = newCycle - oldCycle;
      if (cycleDiff != 0) {
        // We crossed a 12-hour boundary! Toggle AM/PM
        _toggleAmPm(cycleDiff);
      }
      _lastHourItem = index;
    }
    _onTimeChanged();
  }

  void _jumpHourBy(int amount) {
    if (amount == 0) return;
    int currentHourItem = _hourController.selectedItem;
    int nextHourItem = currentHourItem + amount;
    
    // We use animateToItem so it's smooth
    _hourController.animateToItem(
      nextHourItem,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOutCubic,
    );
  }

  void _toggleAmPm(int amount) {
    // amount is how many 12-hour cycles we crossed.
    // If odd, toggle AM/PM.
    if (amount.abs() % 2 != 0) {
      int current = _amPmController.selectedItem;
      int next = current == 0 ? 1 : 0;
      _amPmController.animateToItem(
        next,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOutCubic,
      );
    }
  }

  Widget _buildWheel({
    required FixedExtentScrollController controller,
    required Widget Function(BuildContext, int, bool) builder,
    required ValueChanged<int> onSelectedItemChanged,
    int? itemCount,
  }) {
    // FixedExtentScrollPhysics allows smooth scrolling and interrupting snaps natively
    // Using a physics that doesn't block interactions.
    return SizedBox(
      width: 60,
      child: ListWheelScrollView.useDelegate(
        controller: controller,
        itemExtent: widget.itemHeight,
        physics: const _HighFrictionFixedExtentScrollPhysics(),
        perspective: 0.005,
        onSelectedItemChanged: onSelectedItemChanged,
        childDelegate: itemCount != null
            ? ListWheelChildBuilderDelegate(
                builder: (context, index) {
                  return AnimatedBuilder(
                    animation: controller,
                    builder: (context, child) {
                      int selected = controller.hasClients ? (controller.offset / widget.itemHeight).round() : controller.initialItem;
                      return builder(context, index, index == selected);
                    }
                  );
                },
                childCount: itemCount,
              )
            : ListWheelChildBuilderDelegate(
                builder: (context, index) {
                  return AnimatedBuilder(
                    animation: controller,
                    builder: (context, child) {
                      int selected = controller.hasClients ? (controller.offset / widget.itemHeight).round() : controller.initialItem;
                      return builder(context, index, index == selected);
                    }
                  );
                },
              ), // infinite
      ),
    );
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
      height: widget.itemHeight * 4, // 1 center + 1.5 top + 1.5 bottom
      child: ShaderMask(
        shaderCallback: (Rect bounds) {
          return const LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              Colors.transparent,
              Colors.black,
              Colors.black,
              Colors.transparent,
            ],
            stops: [0.0, 0.25, 0.75, 1.0],
          ).createShader(bounds);
        },
        blendMode: BlendMode.dstIn,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            // Hours
            _buildWheel(
              controller: _hourController,
              onSelectedItemChanged: _onHourSelectedItemChanged,
              builder: (context, index, isSelected) {
                int h = (index % 12) + 1;
                return Center(
                  child: Text(
                    h.toString().padLeft(2, '0'),
                    style: isSelected ? highlightStyle : normalStyle,
                  ),
                );
              },
            ),
            SizedBox(width: widget.spacing),
            // Minutes
            _buildWheel(
              controller: _minuteController,
              onSelectedItemChanged: _onMinuteSelectedItemChanged,
              builder: (context, index, isSelected) {
                int m = (index % _minuteItemsCount) * widget.minutesInterval;
                TextStyle? style = isSelected ? highlightStyle : normalStyle;
                if (m % 30 == 0 && highlightStyle != null) {
                  Color baseColor = highlightStyle.color ?? Colors.white;
                  Color whiteMixed = Color.lerp(baseColor, Colors.white, 0.8) ?? Colors.white;
                  style = highlightStyle.copyWith(
                    color: isSelected ? whiteMixed : whiteMixed.withValues(alpha: 0.7),
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
            SizedBox(width: widget.spacing),
            // AM/PM (not infinite)
            _buildWheel(
              controller: _amPmController,
              itemCount: 2,
              onSelectedItemChanged: (index) {
                _onTimeChanged();
              },
              builder: (context, index, isSelected) {
                String label = index == 0 ? 'AM' : 'PM';
                return Center(
                  child: Text(
                    label,
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
    // Reduce the velocity to simulate much higher friction, causing it to stop spinning faster.
    return super.createBallisticSimulation(position, velocity * 0.4);
  }
}

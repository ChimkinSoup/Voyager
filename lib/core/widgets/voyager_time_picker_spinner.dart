import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:voyager/core/dev/dev_flags.dart';

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

  late int _currentHourIndex; // 0-11
  late int _currentMinuteIndex; // e.g. 0-11 for 5 min intervals
  late int _currentAmPmIndex; // 0 for AM, 1 for PM

  late int _minuteItemsCount;

  late DateTime _currentDate;

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
  }

  @override
  void didUpdateWidget(covariant VoyagerTimePickerSpinner oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.time != widget.time) {
      _currentDate = widget.time; // Sync internal date
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
    if (ap == 1) {
      hour24 += 12;
    }

    _currentDate = DateTime(_currentDate.year, _currentDate.month, _currentDate.day, hour24, m);
    widget.onTimeChange(_currentDate);
  }


  // To handle the minute roll-over to hour, we need to compare the new selected item with the old one
  // and see if we crossed a full cycle.
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
      // The hour wheel shows 1-12. Index 0 is 1:00, index 10 is 11:00, index 11 is 12:00.
      // A 12-hour cycle boundary happens between 11:00 and 12:00 (index 10 and 11).
      // We shift the index by 1 so that index 11 becomes 12, making it a clean multiple of 12.
      int oldAdjusted = _lastHourItem + 1;
      int oldCycle = oldAdjusted ~/ 12;
      if (oldAdjusted < 0 && oldAdjusted % 12 != 0) oldCycle -= 1;
      
      int newAdjusted = index + 1;
      int newCycle = newAdjusted ~/ 12;
      if (newAdjusted < 0 && newAdjusted % 12 != 0) newCycle -= 1;

      int cycleDiff = newCycle - oldCycle;
      if (cycleDiff != 0) {
        // We crossed a 12-hour boundary! Add 12 hours to our tracked date.
        _currentDate = _currentDate.add(Duration(hours: 12 * cycleDiff));
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
    double width = 40,
  }) {
    Widget wheel = SizedBox(
      width: width,
      child: NotificationListener<ScrollNotification>(
        onNotification: (scrollNotification) {
          if (scrollNotification is ScrollStartNotification || scrollNotification is ScrollUpdateNotification) {
            if (!_isProgrammaticScroll) {
              widget.onInteraction?.call();
            }
          }
          return false; // let the notification bubble up
        },
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
                  childCount: null,
                ),
        ),
      ),
    );

    if (DevFlags.showTimeSelectorHitboxes) {
      return Container(
        color: Colors.red.withValues(alpha: 0.5),
        child: wheel,
      );
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
          mainAxisSize: MainAxisSize.min,
          children: [
            Stack(
              alignment: Alignment.center,
              children: [
                Text(
                  ':',
                  style: widget.isActive ? highlightStyle : normalStyle,
                ),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Hours
                    _buildWheel(
                      width: 50,
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
                    // Minutes
                    _buildWheel(
                      width: 50,
                      controller: _minuteController,
                      onSelectedItemChanged: _onMinuteSelectedItemChanged,
                      builder: (context, index, isSelected) {
                        int m = (index % _minuteItemsCount) * widget.minutesInterval;
                        TextStyle? style = isSelected ? highlightStyle : normalStyle;
                        if (widget.isActive && m % 30 == 0 && highlightStyle != null) {
                          Color baseColor = highlightStyle.color ?? Colors.white;
                          Color lighterAccent = Color.lerp(baseColor, Colors.white, 0.4) ?? Colors.white;
                          style = highlightStyle.copyWith(
                            color: isSelected ? lighterAccent : lighterAccent.withValues(alpha: 0.7),
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
            // AM/PM (not infinite)
            _buildWheel(
              controller: _amPmController,
              itemCount: 2,
              onSelectedItemChanged: (index) {
                if (_isProgrammaticScroll) return;
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

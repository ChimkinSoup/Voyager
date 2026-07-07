import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';

class DateSelectorPopover extends StatefulWidget {
  const DateSelectorPopover({
    super.key,
    required this.initialStartDate,
    required this.initialEndDate,
  });

  final DateTime initialStartDate;
  final DateTime initialEndDate;

  @override
  State<DateSelectorPopover> createState() => _DateSelectorPopoverState();
}

class _DateSelectorPopoverState extends State<DateSelectorPopover> {
  late DateTime _focusedMonth;
  late DateTime _hoveredDate; // Used for VIM navigation focus
  DateTime? _firstSelected;
  DateTime? _secondSelected;
  late final FocusNode _focusNode;
  bool _canPop = false;
  bool _showHoverRing = false;

  @override
  void initState() {
    super.initState();
    _hoveredDate = widget.initialStartDate;
    _focusedMonth = DateTime(_hoveredDate.year, _hoveredDate.month, 1);
    
    _firstSelected = widget.initialStartDate;
    if (widget.initialStartDate.year != widget.initialEndDate.year ||
        widget.initialStartDate.month != widget.initialEndDate.month ||
        widget.initialStartDate.day != widget.initialEndDate.day) {
      _secondSelected = widget.initialEndDate;
    }

    _focusNode = FocusNode();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focusNode.requestFocus();
    });
  }

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  void _previousMonth() {
    setState(() {
      _focusedMonth = DateTime(_focusedMonth.year, _focusedMonth.month - 1, 1);
    });
  }

  void _nextMonth() {
    setState(() {
      _focusedMonth = DateTime(_focusedMonth.year, _focusedMonth.month + 1, 1);
    });
  }

  void _handleDateTap(DateTime date) {
    setState(() {
      _hoveredDate = date;
      if (_firstSelected == null) {
        _firstSelected = date;
      } else if (_secondSelected == null) {
        _secondSelected = date;
        _submit();
      } else {
        // Reset selection
        _firstSelected = date;
        _secondSelected = null;
      }
    });
  }

  void _submitQuickAction(DateTime date) {
    setState(() {
      _firstSelected = date;
      _secondSelected = date;
    });
    _submit();
  }

  void _submit() {
    if (!mounted) return;
    setState(() => _canPop = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        DateTime start = _firstSelected ?? _hoveredDate;
        DateTime end = _secondSelected ?? start;
        if (end.isBefore(start)) {
          final temp = start;
          start = end;
          end = temp;
        }
        Navigator.of(context).pop(DateTimeRange(start: start, end: end));
      }
    });
  }

  void _handleKeyEvent(KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) return;

    final key = event.logicalKey;
    int dayDelta = 0;

    if (key == LogicalKeyboardKey.arrowLeft) {
      _previousMonth();
      return;
    } else if (key == LogicalKeyboardKey.arrowRight) {
      _nextMonth();
      return;
    } else if (key == LogicalKeyboardKey.keyH) {
      dayDelta = -1;
    } else if (key == LogicalKeyboardKey.keyL) {
      dayDelta = 1;
    } else if (key == LogicalKeyboardKey.keyJ) {
      dayDelta = 7;
    } else if (key == LogicalKeyboardKey.keyK) {
      dayDelta = -7;
    } else if (key == LogicalKeyboardKey.enter || key == LogicalKeyboardKey.numpadEnter) {
      setState(() { _showHoverRing = true; });
      _handleDateTap(_hoveredDate);
      return;
    }

    if (dayDelta != 0) {
      setState(() {
        _showHoverRing = true;
        _hoveredDate = _hoveredDate.add(Duration(days: dayDelta));
        if (_hoveredDate.year != _focusedMonth.year || _hoveredDate.month != _focusedMonth.month) {
          _focusedMonth = DateTime(_hoveredDate.year, _hoveredDate.month, 1);
        }
      });
    }
  }

  bool _isSameDay(DateTime a, DateTime b) {
    return a.year == b.year && a.month == b.month && a.day == b.day;
  }

  bool _isQuickChipSelected(DateTime chipDate) {
    if (_firstSelected == null) return false;
    final end = _secondSelected ?? _firstSelected!;
    if (!_isSameDay(_firstSelected!, end)) return false;
    return _isSameDay(_firstSelected!, chipDate);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);

    final chips = [
      {'label': 'Today', 'date': today},
      {'label': 'Tomorrow', 'date': today.add(const Duration(days: 1))},
      {'label': 'Next Week', 'date': today.add(const Duration(days: 7))},
    ];

    final firstDayOfMonth = _focusedMonth;
    final firstWeekday = firstDayOfMonth.weekday; // 1 = Monday, 7 = Sunday
    final startOffset = (firstWeekday == 7) ? 0 : firstWeekday;
    final startDate = firstDayOfMonth.subtract(Duration(days: startOffset));

    DateTime? minDate;
    DateTime? maxDate;
    if (_firstSelected != null) {
      minDate = _firstSelected;
      maxDate = _secondSelected ?? _firstSelected;
      if (maxDate!.isBefore(minDate!)) {
        final temp = minDate;
        minDate = maxDate;
        maxDate = temp;
      }
    }

    return PopScope(
      canPop: _canPop,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        if (mounted) {
          setState(() => _canPop = true);
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) {
              DateTime start = _firstSelected ?? _hoveredDate;
              DateTime end = _secondSelected ?? start;
              if (end.isBefore(start)) {
                final temp = start;
                start = end;
                end = temp;
              }
              Navigator.of(context).pop(DateTimeRange(start: start, end: end));
            }
          });
        }
      },
      child: Focus(
        focusNode: _focusNode,
        onKeyEvent: (node, event) {
          _handleKeyEvent(event);
          return KeyEventResult.handled;
        },
        child: Container(
          decoration: BoxDecoration(
            color: theme.colorScheme.surface,
            border: Border.all(color: theme.colorScheme.primary, width: 2),
            borderRadius: BorderRadius.circular(12),
            boxShadow: [
              BoxShadow(
                color: theme.colorScheme.primary.withValues(alpha: 0.6),
                blurRadius: 16,
                spreadRadius: 4,
              ),
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: 8),
              // Zone A: Quick Actions
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Row(
                  children: chips.map((c) {
                    final chipDate = c['date'] as DateTime;
                    final isSelected = _isQuickChipSelected(chipDate);
                    return Padding(
                      padding: const EdgeInsets.only(right: 6.0),
                      child: ActionChip(
                        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 0),
                        label: Text(
                          c['label'] as String,
                          style: TextStyle(
                            color: isSelected
                                ? theme.colorScheme.onPrimary
                                : theme.colorScheme.onSurface,
                          ),
                        ),
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
                        onPressed: () => _submitQuickAction(chipDate),
                      ),
                    );
                  }).toList(),
                ),
              ),
              const SizedBox(height: 8),
              const Divider(height: 1),
              // Zone B: The Micro-Grid
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    IconButton(
                      icon: const Icon(PhosphorIconsRegular.caretLeft, size: 16),
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(),
                      onPressed: _previousMonth,
                    ),
                    Text(
                      DateFormat.yMMMM().format(_focusedMonth),
                      style: theme.textTheme.labelLarge?.copyWith(fontWeight: FontWeight.bold),
                    ),
                    IconButton(
                      icon: const Icon(PhosphorIconsRegular.caretRight, size: 16),
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(),
                      onPressed: _nextMonth,
                    ),
                  ],
                ),
              ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.only(left: 12, right: 12, bottom: 16),
                  child: GridView.builder(
                    physics: const NeverScrollableScrollPhysics(),
                    gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: 7,
                      mainAxisSpacing: 0,
                      crossAxisSpacing: 0,
                      childAspectRatio: 1.0,
                    ),
                    itemCount: 42, // 7x6 matrix
                    itemBuilder: (context, index) {
                      final date = startDate.add(Duration(days: index));
                      final isCurrentMonth = date.month == _focusedMonth.month;
                      final isToday = _isSameDay(date, today);
                      
                      bool isSelected = false;
                      bool isInRange = false;
                      bool isRangeStart = false;
                      bool isRangeEnd = false;

                      if (minDate != null && maxDate != null) {
                        if (_isSameDay(date, minDate)) {
                          isSelected = true;
                          isRangeStart = !_isSameDay(minDate, maxDate);
                        }
                        if (_isSameDay(date, maxDate)) {
                          isSelected = true;
                          isRangeEnd = !_isSameDay(minDate, maxDate);
                        }
                        if (date.isAfter(minDate) && date.isBefore(maxDate)) {
                          isInRange = true;
                        }
                      }

                      final isHovered = _isSameDay(date, _hoveredDate);

                      Color textColor = theme.colorScheme.onSurface;
                      if (!isCurrentMonth) {
                        textColor = textColor.withValues(alpha: 0.3);
                      }
                      if (isSelected) {
                        textColor = theme.colorScheme.onPrimary;
                      }

                      final highlightColor = Color.alphaBlend(
                        theme.colorScheme.primary.withValues(alpha: 0.7),
                        theme.colorScheme.surface,
                      );

                      final bool isFirstDayOfWeek = index % 7 == 0;
                      final bool isLastDayOfWeek = index % 7 == 6;

                      return Center(
                        child: SizedBox(
                          height: 36,
                          width: double.infinity,
                          child: Stack(
                            clipBehavior: Clip.none,
                            alignment: Alignment.center,
                            children: [
                              // 1. Bridging Layer (Row with Expanded)
                              if (isInRange || isRangeStart || isRangeEnd)
                                Positioned.fill(
                                  child: Row(
                                    crossAxisAlignment: CrossAxisAlignment.stretch,
                                    children: [
                                      // Left Zone
                                      Expanded(
                                        child: Stack(
                                          clipBehavior: Clip.none,
                                          children: [
                                            if ((isInRange || isRangeEnd) && !isRangeStart)
                                              Positioned(
                                                top: 0,
                                                bottom: 0,
                                                left: 0, // NEVER extend left! Prevents painting over previous cell
                                                right: -1, // overlap center slightly
                                                child: Container(
                                                  decoration: BoxDecoration(
                                                    color: highlightColor,
                                                    borderRadius: BorderRadius.only(
                                                      topLeft: Radius.circular(isFirstDayOfWeek ? 100 : 0),
                                                      bottomLeft: Radius.circular(isFirstDayOfWeek ? 100 : 0),
                                                    ),
                                                  ),
                                                ),
                                              ),
                                          ],
                                        ),
                                      ),
                                      // Right Zone
                                      Expanded(
                                        child: Stack(
                                          clipBehavior: Clip.none,
                                          children: [
                                            if ((isInRange || isRangeStart) && !isRangeEnd)
                                              Positioned(
                                                top: 0,
                                                bottom: 0,
                                                left: -1, // overlap center slightly
                                                right: isLastDayOfWeek ? 0 : -16, // Bridge securely to next cell
                                                child: Container(
                                                  decoration: BoxDecoration(
                                                    color: highlightColor,
                                                    borderRadius: BorderRadius.only(
                                                      topRight: Radius.circular(isLastDayOfWeek ? 100 : 0),
                                                      bottomRight: Radius.circular(isLastDayOfWeek ? 100 : 0),
                                                    ),
                                                  ),
                                                ),
                                              ),
                                          ],
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              
                              // 2. Uniform Background for Translucent Circle
                              if (isInRange || isRangeStart || isRangeEnd)
                                Container(
                                  width: 36,
                                  height: 36,
                                  decoration: BoxDecoration(
                                    color: highlightColor,
                                    shape: BoxShape.circle,
                                  ),
                                ),

                              // 3. The actual day circle (Button & Text)
                              Container(
                                width: 36,
                                height: 36,
                                decoration: BoxDecoration(
                                  color: isSelected 
                                      ? theme.colorScheme.primary 
                                      : Colors.transparent,
                                  border: (isHovered && _showHoverRing) 
                                      ? Border.all(color: theme.colorScheme.onSurface, width: 2) 
                                      : null,
                                  shape: BoxShape.circle,
                                ),
                                clipBehavior: Clip.antiAlias,
                                child: Material(
                                  color: Colors.transparent, // Let Container handle the background color securely
                                  child: InkWell(
                                    onTap: () {
                                      setState(() { _showHoverRing = false; });
                                      _handleDateTap(date);
                                    },
                                    child: Center(
                                      child: Column(
                                        mainAxisAlignment: MainAxisAlignment.center,
                                        children: [
                                          Text(
                                            '${date.day}',
                                            style: theme.textTheme.bodyMedium?.copyWith(
                                              color: textColor,
                                              fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                                            ),
                                          ),
                                          if (isToday && !isSelected)
                                            Container(
                                              width: 4,
                                              height: 4,
                                              margin: const EdgeInsets.only(top: 1),
                                              decoration: BoxDecoration(
                                                color: theme.colorScheme.primary,
                                                shape: BoxShape.circle,
                                              ),
                                            ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

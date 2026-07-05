import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';

class DateSelectorPopover extends StatefulWidget {
  const DateSelectorPopover({
    super.key,
    required this.initialDate,
    this.onAddEndDate,
  });

  final DateTime initialDate;
  final VoidCallback? onAddEndDate;

  @override
  State<DateSelectorPopover> createState() => _DateSelectorPopoverState();
}

class _DateSelectorPopoverState extends State<DateSelectorPopover> {
  late DateTime _focusedMonth;
  late final TextEditingController _controller;
  late final FocusNode _focusNode;

  @override
  void initState() {
    super.initState();
    _focusedMonth = DateTime(
        widget.initialDate.year, widget.initialDate.month, 1);
    _controller = TextEditingController();
    _focusNode = FocusNode();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focusNode.requestFocus();
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _previousMonth() {
    setState(() {
      _focusedMonth =
          DateTime(_focusedMonth.year, _focusedMonth.month - 1, 1);
    });
  }

  void _nextMonth() {
    setState(() {
      _focusedMonth =
          DateTime(_focusedMonth.year, _focusedMonth.month + 1, 1);
    });
  }

  void _selectDate(DateTime date) {
    Navigator.of(context).pop(date);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);

    final chips = [
      {
        'label': 'Today',
        'date': today,
      },
      {
        'label': 'Tomorrow',
        'date': today.add(const Duration(days: 1)),
      },
      {
        'label': 'Next Week',
        'date': today.add(const Duration(days: 7)),
      },
    ];

    // Build the month grid
    final firstDayOfMonth = _focusedMonth;
    final firstWeekday = firstDayOfMonth.weekday; // 1 = Monday, 7 = Sunday
    // Flutter default weekday is Monday = 1, Sunday = 7. Let's start week on Sunday (0).
    final startOffset = (firstWeekday == 7) ? 0 : firstWeekday;
    final startDate = firstDayOfMonth.subtract(Duration(days: startOffset));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Zone A: Smart Input & Quick Actions
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: TextField(
            controller: _controller,
            focusNode: _focusNode,
            style: theme.textTheme.titleMedium,
            decoration: InputDecoration(
              hintText: 'Type a date...',
              hintStyle: theme.textTheme.titleMedium?.copyWith(
                color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
              ),
              border: InputBorder.none,
              isDense: true,
            ),
            onSubmitted: (_) {
              // Extremely naive parsing for demo
              if (_controller.text.toLowerCase().contains('tom')) {
                _selectDate(today.add(const Duration(days: 1)));
              } else if (_controller.text.toLowerCase().contains('tod')) {
                _selectDate(today);
              } else {
                // Ignore for now, or use actual parser
              }
            },
          ),
        ),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: chips.map((c) {
              return Padding(
                padding: const EdgeInsets.only(right: 8.0),
                child: ActionChip(
                  label: Text(c['label'] as String),
                  onPressed: () => _selectDate(c['date'] as DateTime),
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
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: GridView.builder(
              physics: const NeverScrollableScrollPhysics(),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 7,
                mainAxisSpacing: 2,
                crossAxisSpacing: 2,
                childAspectRatio: 1.0,
              ),
              itemCount: 42, // 7x6 matrix
              itemBuilder: (context, index) {
                final date = startDate.add(Duration(days: index));
                final isCurrentMonth = date.month == _focusedMonth.month;
                final isToday = date.year == today.year &&
                    date.month == today.month &&
                    date.day == today.day;
                final isSelected = date.year == widget.initialDate.year &&
                    date.month == widget.initialDate.month &&
                    date.day == widget.initialDate.day;

                Color textColor = theme.colorScheme.onSurface;
                if (!isCurrentMonth) {
                  textColor = textColor.withValues(alpha: 0.3);
                }
                if (isSelected) {
                  textColor = theme.colorScheme.onPrimary;
                }

                return Material(
                  color: isSelected ? theme.colorScheme.primary : Colors.transparent,
                  borderRadius: BorderRadius.circular(20),
                  clipBehavior: Clip.antiAlias,
                  child: InkWell(
                    onTap: () => _selectDate(date),
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
                );
              },
            ),
          ),
        ),
        // Bottom: Add End Date Toggle
        if (widget.onAddEndDate != null) ...[
          const Divider(height: 1),
          InkWell(
            onTap: widget.onAddEndDate,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Center(
                child: Text(
                  '+ Multi-day event',
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: theme.colorScheme.primary,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ),
          ),
        ],
      ],
    );
  }
}

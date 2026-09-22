import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:voyager/core/theme/voyager_theme.dart';
import 'package:voyager/core/utils/time_format.dart';
import 'package:voyager/core/widgets/date_selector_popover.dart';
import 'package:voyager/core/widgets/select_all_on_click.dart';
import 'package:voyager/core/widgets/field_scroll_padding.dart';
import 'package:voyager/core/widgets/time_text_input_formatter.dart';
import 'package:voyager/core/widgets/voyager_time_picker_spinner.dart';

class DateTimeSelectorPopover extends StatefulWidget {
  final DateTime initialDateTime;
  final Color? accentColor;
  final bool optionalTime;
  final bool initialHasTime;

  const DateTimeSelectorPopover({
    super.key,
    required this.initialDateTime,
    this.accentColor,
    this.optionalTime = false,
    this.initialHasTime = true,
  });

  @override
  State<DateTimeSelectorPopover> createState() =>
      _DateTimeSelectorPopoverState();
}

class _DateTimeSelectorPopoverState extends State<DateTimeSelectorPopover> {
  late DateTime _currentDateTime;
  bool _timeSelected = true;
  bool _canPop = false;
  late final TextEditingController _timeController;
  late final FocusNode _timeFocus;
  late final FocusNode _mainFocus;
  bool _focusRequested = false;
  bool _selectAllNextTap = false;

  @override
  void initState() {
    super.initState();
    _currentDateTime = widget.initialDateTime;
    _timeSelected = !widget.optionalTime || widget.initialHasTime;

    if (widget.optionalTime && !widget.initialHasTime) {
      final now = DateTime.now();
      int m = now.minute;
      int roundedMinute = m < 15 ? 0 : (m < 45 ? 30 : 0);
      int roundedHour = now.hour + (m >= 45 ? 1 : 0);
      _currentDateTime = DateTime(
        _currentDateTime.year,
        _currentDateTime.month,
        _currentDateTime.day,
        roundedHour,
        roundedMinute,
      );
    }

    _timeController = TextEditingController();
    _timeFocus = FocusNode();
    _mainFocus = FocusNode();

    _timeFocus.addListener(() {
      if (mounted) {
        setState(() {
          if (!_timeFocus.hasFocus) {
            _timeController.text = _timeSelected
                ? _formatTime(_currentDateTime)
                : '';
          } else {
            // When focusing, if time wasn't selected, select it now.
            if (!_timeSelected && widget.optionalTime) {
              _timeSelected = true;
            }
            _timeController.text = _formatTime(_currentDateTime);
            _selectAllNextTap = true;
            selectAllTimeText(_timeController);
          }
        });
      }
    });

    _timeController.addListener(_onTimeTextChanged);
  }

  bool _isInit = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_isInit) {
      _timeController.text = _timeSelected ? _formatTime(_currentDateTime) : '';
      _isInit = true;
    }

    if (!_focusRequested) {
      final route = ModalRoute.of(context);
      if (route != null) {
        void onAnimationStatusChanged(AnimationStatus status) {
          if (status == AnimationStatus.completed &&
              mounted &&
              !_focusRequested) {
            _focusRequested = true;
            route.animation!.removeStatusListener(onAnimationStatusChanged);
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) {
                if (_timeSelected) {
                  _timeFocus.requestFocus();
                  selectAllTimeText(_timeController);
                } else {
                  _mainFocus.requestFocus();
                }
              }
            });
          }
        }

        if (route.animation?.status == AnimationStatus.completed) {
          _focusRequested = true;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) {
              if (_timeSelected) {
                _timeFocus.requestFocus();
                selectAllTimeText(_timeController);
              } else {
                _mainFocus.requestFocus();
              }
            }
          });
        } else {
          route.animation?.addStatusListener(onAnimationStatusChanged);
        }
      }
    }
  }

  @override
  void dispose() {
    _timeController.dispose();
    _timeFocus.dispose();
    _mainFocus.dispose();
    super.dispose();
  }

  String _formatTime(DateTime dt) {
    return TimeOfDay.fromDateTime(dt).format(context);
  }

  void _onTimeTextChanged() {
    if (!_timeFocus.hasFocus) return;
    final parsed = parseTimeQuery(_timeController.text, _currentDateTime);
    if (parsed != null && parsed != _currentDateTime) {
      setState(() {
        _currentDateTime = parsed;
      });
    }
  }

  Widget _timeField({
    required ThemeData theme,
    required Color focusColor,
    required TextEditingController controller,
    required FocusNode focusNode,
    required String hintText,
    required VoidCallback onTap,
    required bool Function() selectAllPending,
    required ValueChanged<String> onSubmitted,
  }) {
    final accent = focusColor;
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
          color: focusNode.hasFocus
              ? accent
              : theme.colorScheme.onSurface.withValues(alpha: 0.2),
          width: focusNode.hasFocus ? 2 : 1,
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
                color: focusNode.hasFocus
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

  void _submit() {
    if (!mounted) return;
    setState(() => _canPop = true);
    if (widget.optionalTime && !_timeSelected) {
      Navigator.of(context).maybePop(
        DateTime(
          _currentDateTime.year,
          _currentDateTime.month,
          _currentDateTime.day,
        ),
      );
    } else {
      Navigator.of(context).maybePop(_currentDateTime);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent = widget.accentColor ?? theme.colorScheme.primary;
    final activeNormalTextStyle = theme.textTheme.titleLarge?.copyWith(
      color: Color.lerp(
        accent,
        theme.colorScheme.onSurface,
        0.7,
      )?.withValues(alpha: 0.4),
    );
    final activeHighlightTextStyle = theme.textTheme.titleLarge?.copyWith(
      color: accent,
      fontWeight: FontWeight.bold,
    );
    final inactiveNormalTextStyle = theme.textTheme.titleLarge?.copyWith(
      color: theme.colorScheme.onSurface.withValues(alpha: 0.15),
    );
    final inactiveHighlightTextStyle = theme.textTheme.titleLarge?.copyWith(
      color: theme.colorScheme.onSurface.withValues(alpha: 0.3),
    );

    return PopScope(
      canPop: _canPop,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        if (mounted) {
          setState(() => _canPop = true);
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) {
              if (widget.optionalTime && !_timeSelected) {
                Navigator.of(context).pop(
                  DateTime(
                    _currentDateTime.year,
                    _currentDateTime.month,
                    _currentDateTime.day,
                  ),
                );
              } else {
                Navigator.of(context).pop(_currentDateTime);
              }
            }
          });
        }
      },
      child: Focus(
        focusNode: _mainFocus,
        onKeyEvent: (node, event) {
          if (event is KeyDownEvent &&
              event.logicalKey == LogicalKeyboardKey.enter) {
            if (!_timeFocus.hasFocus) {
              _submit();
              return KeyEventResult.handled;
            }
          }
          return KeyEventResult.ignored;
        },
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(
                    flex: 3,
                    child: Padding(
                      padding: const EdgeInsets.only(top: 8.0),
                      child: DateSelectorPopover(
                        initialStartDate: _currentDateTime,
                        initialEndDate: _currentDateTime,
                        singleDateMode: true,
                        inlineMode: true,
                        onDateSelected: (newDate) {
                          setState(() {
                            _currentDateTime = DateTime(
                              newDate.year,
                              newDate.month,
                              newDate.day,
                              _currentDateTime.hour,
                              _currentDateTime.minute,
                            );
                          });
                          _mainFocus.requestFocus();
                        },
                      ),
                    ),
                  ),
                  const VerticalDivider(width: 1),
                  Expanded(
                    flex: 2,
                    child: Padding(
                      padding: const EdgeInsets.only(top: 16.0),
                      child: Stack(
                        children: [
                          Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              AnimatedOpacity(
                                duration: const Duration(milliseconds: 150),
                                opacity: _timeSelected ? 1.0 : 0.25,
                                child: Listener(
                                  onPointerDown: (_) {
                                    if (_timeFocus.hasFocus) {
                                      _mainFocus.requestFocus();
                                    }
                                  },
                                  child: VoyagerTimePickerSpinner(
                                    time: _currentDateTime,
                                    minutesInterval: 5,
                                    isActive: _timeSelected,
                                    normalTextStyle: _timeSelected
                                        ? activeNormalTextStyle
                                        : inactiveNormalTextStyle,
                                    highlightedTextStyle: _timeSelected
                                        ? activeHighlightTextStyle
                                        : inactiveHighlightTextStyle,
                                    spacing: 4,
                                    itemHeight: 40,
                                    onTimeChange: (newTime) {
                                      setState(() {
                                        if (!_timeSelected &&
                                            widget.optionalTime) {
                                          _timeSelected = true;
                                        }
                                        _currentDateTime = newTime;
                                        _timeController.text = _formatTime(
                                          _currentDateTime,
                                        );
                                      });
                                    },
                                  ),
                                ),
                              ),
                              const SizedBox(height: 16),
                              AnimatedOpacity(
                                duration: const Duration(milliseconds: 150),
                                opacity: _timeSelected ? 1.0 : 0.25,
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 32.0,
                                  ),
                                  child: _timeField(
                                    theme: theme,
                                    focusColor: accent,
                                    controller: _timeController,
                                    focusNode: _timeFocus,
                                    hintText: 'Time',
                                    onTap: () {
                                      // The tap that lands focus here selects
                                      // the whole time; a later tap places the
                                      // cursor instead of fighting the user.
                                      if (_selectAllNextTap) {
                                        selectAllTimeText(_timeController);
                                        _selectAllNextTap = false;
                                      }
                                    },
                                    selectAllPending: () => _selectAllNextTap,
                                    onSubmitted: (_) {
                                      _mainFocus.requestFocus();
                                    },
                                  ),
                                ),
                              ),
                            ],
                          ),
                          if (widget.optionalTime && _timeSelected)
                            Positioned(
                              top: 8,
                              right: 8,
                              child: IconButton(
                                icon: Icon(PhosphorIconsRegular.x, size: 16),
                                onPressed: () {
                                  setState(() {
                                    _timeSelected = false;
                                    _timeController.text = '';
                                    if (_timeFocus.hasFocus) {
                                      _mainFocus.requestFocus();
                                    }
                                  });
                                },
                              ),
                            ),
                        ],
                      ),
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
                child: Text(
                  'Done',
                  style: theme.textTheme.titleMedium?.copyWith(
                    color: accent,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

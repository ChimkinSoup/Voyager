import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:voyager/core/widgets/date_selector_popover.dart';
import 'package:voyager/core/widgets/voyager_time_picker_spinner.dart';

class TimeTextInputFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(TextEditingValue oldValue, TextEditingValue newValue) {
    if (newValue.text.isEmpty) return newValue;

    String workingText = newValue.text.toUpperCase();
    bool isDeletion = oldValue.text.length > newValue.text.length;
    
    if (isDeletion) {
      String oldUpper = oldValue.text.toUpperCase();
      if (oldUpper.endsWith('AM') || oldUpper.endsWith('PM')) {
        // If they deleted the 'M', strip the remaining 'A' or 'P' and spaces
        if (workingText.endsWith('A') || workingText.endsWith('P')) {
          workingText = workingText.replaceAll(RegExp(r'[AP ]+$'), '');
        }
      }

      bool isSingleCharBackspace = (oldValue.text.length - newValue.text.length == 1) && oldValue.selection.isCollapsed;
      if (isSingleCharBackspace) {
        int oldOffset = oldValue.selection.baseOffset;
        if (oldOffset > 0 && oldOffset <= oldValue.text.length) {
          if (oldValue.text[oldOffset - 1] == ':') {
            int newOffset = newValue.selection.baseOffset;
            if (newOffset > 0 && newOffset <= workingText.length) {
              workingText = workingText.substring(0, newOffset - 1) + workingText.substring(newOffset);
            }
          }
        }
      }
    }

    String text = workingText.replaceAll(RegExp(r'[^0-9:AMP ]'), '');
    text = text.replaceFirst(RegExp(r'^[^0-9]+'), '');
    text = text.replaceAll(RegExp(r' +'), ' ');
    text = text.replaceAll(RegExp(r':+'), ':');

    String timePart = text.replaceAll(RegExp(r'[AMP ]'), '');
    String letters = text.replaceAll(RegExp(r'[^APM]'), '');
    if (letters.isNotEmpty) {
      if (letters.startsWith('A')) letters = 'AM';
      else if (letters.startsWith('P')) letters = 'PM';
      else letters = '';
    }

    if (!text.contains(':') && timePart.length >= 3) {
      if (timePart.length == 3) {
        timePart = '${timePart.substring(0, 1)}:${timePart.substring(1)}';
      } else if (timePart.length >= 4) {
        timePart = timePart.substring(0, 4);
        timePart = '${timePart.substring(0, 2)}:${timePart.substring(2)}';
      }
    } else if (text.contains(':')) {
      timePart = text.replaceAll(RegExp(r'[AMP ]'), '');
      List<String> parts = timePart.split(':');
      if (parts.length > 2) parts = parts.sublist(0, 2);
      
      String before = parts[0];
      String after = parts.length > 1 ? parts[1] : '';
      
      if (before.length > 2) before = before.substring(0, 2);
      if (after.length > 2) after = after.substring(0, 2);
      
      timePart = '$before:${after}';
      if (text.endsWith(':') && after.isEmpty) {
        // preserve trailing colon
      } else if (after.isEmpty && !text.contains(':')) {
        timePart = before;
      }
    }

    List<String> parts = timePart.split(':');
    if (parts.isNotEmpty && parts[0].isNotEmpty) {
      int? h = int.tryParse(parts[0]);
      if (h != null) {
        if (h > 23 && !timePart.contains(':') && timePart.length == 2) {
           timePart = '${timePart.substring(0, 1)}:${timePart.substring(1)}';
           parts = timePart.split(':');
           h = int.tryParse(parts[0]);
        }
        if (h != null && h > 23) return oldValue;
      }
    }
    
    if (parts.length > 1 && parts[1].isNotEmpty) {
      if (parts[1].length == 1) {
        int? m1 = int.tryParse(parts[1]);
        if (m1 != null && m1 > 5) {
          parts[1] = '0$m1';
          timePart = '${parts[0]}:${parts[1]}';
        }
      }
      int? m = int.tryParse(parts[1]);
      if (m != null && m > 59) return oldValue;
    }

    String finalText = timePart;
    if (letters.isNotEmpty) {
      finalText += ' $letters';
    } 
    
    if (text.endsWith(' ') && letters.isEmpty) {
      finalText += ' ';
    }
    if (text.endsWith(':') && !finalText.contains(':')) {
      finalText += ':';
    }

    int newOffset = newValue.selection.baseOffset;
    if (finalText != newValue.text) {
       if (oldValue.text.length > newValue.text.length) {
         newOffset = newValue.selection.baseOffset;
         if (newOffset > finalText.length) newOffset = finalText.length;
       } else {
         newOffset = finalText.length;
       }
    }

    return TextEditingValue(
      text: finalText,
      selection: TextSelection.collapsed(offset: newOffset.clamp(0, finalText.length)),
    );
  }
}

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
  State<DateTimeSelectorPopover> createState() => _DateTimeSelectorPopoverState();
}

class _DateTimeSelectorPopoverState extends State<DateTimeSelectorPopover> {
  late DateTime _currentDateTime;
  bool _timeSelected = true;
  bool _canPop = false;
  late final TextEditingController _timeController;
  late final FocusNode _timeFocus;
  late final FocusNode _mainFocus;
  bool _focusRequested = false;

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
            _timeController.text = _timeSelected ? _formatTime(_currentDateTime) : '';
          } else {
            // When focusing, if time wasn't selected, select it now.
            if (!_timeSelected && widget.optionalTime) {
              _timeSelected = true;
            }
            _timeController.text = _formatTime(_currentDateTime);
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
          if (status == AnimationStatus.completed && mounted && !_focusRequested) {
            _focusRequested = true;
            route.animation!.removeStatusListener(onAnimationStatusChanged);
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) {
                if (_timeSelected) {
                  _timeFocus.requestFocus();
                  _timeController.selection = TextSelection(
                    baseOffset: 0,
                    extentOffset: _timeController.text.length,
                  );
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
                _timeController.selection = TextSelection(
                  baseOffset: 0,
                  extentOffset: _timeController.text.length,
                );
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

  DateTime? _parseTime(String query, DateTime referenceTime) {
    query = query.toLowerCase().trim();
    if (query.isEmpty) return null;

    final clean = query.replaceAll(RegExp(r'[^a-z0-9]'), '');
    if (clean.isEmpty) return null;

    bool? isPM;
    if (clean.endsWith('pm') || clean.endsWith('p')) {
      isPM = true;
    } else if (clean.endsWith('am') || clean.endsWith('a')) {
      isPM = false;
    }

    String numPart = clean.replaceAll(RegExp(r'[a-z]'), '');
    if (numPart.isEmpty) return null;

    int hour = 0;
    int minute = 0;

    if (numPart.length <= 2) {
      hour = int.parse(numPart);
      minute = 0;
    } else if (numPart.length == 3) {
      hour = int.parse(numPart.substring(0, 1));
      minute = int.parse(numPart.substring(1, 3));
    } else if (numPart.length == 4) {
      hour = int.parse(numPart.substring(0, 2));
      minute = int.parse(numPart.substring(2, 4));
    } else {
      return null;
    }

    if (minute > 59) return null;

    if (hour > 12 && isPM == null) {
       if (hour > 23) return null;
       return DateTime(referenceTime.year, referenceTime.month, referenceTime.day, hour, minute);
    }
    
    if (hour > 12) return null;

    if (isPM != null) {
       int h24 = hour % 12;
       if (isPM) h24 += 12;
       return DateTime(referenceTime.year, referenceTime.month, referenceTime.day, h24, minute);
    } else {
       int h24 = hour % 12;
       int t1 = h24; 
       int t2 = h24 + 12; 
       
       double refH = referenceTime.hour + referenceTime.minute / 60.0;
       double t1Diff = (t1 + (minute/60.0) - refH + 24) % 24;
       double t2Diff = (t2 + (minute/60.0) - refH + 24) % 24;
       
       if (t1Diff < t2Diff) {
         return DateTime(referenceTime.year, referenceTime.month, referenceTime.day, t1, minute);
       } else {
         return DateTime(referenceTime.year, referenceTime.month, referenceTime.day, t2, minute);
       }
    }
  }

  void _onTimeTextChanged() {
    if (!_timeFocus.hasFocus) return;
    final parsed = _parseTime(_timeController.text, _currentDateTime);
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
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: focusNode.hasFocus ? accent : theme.colorScheme.onSurface.withValues(alpha: 0.2),
          width: focusNode.hasFocus ? 2 : 1,
        ),
      ),
      child: Theme(
        data: fieldTheme,
        child: Material(
          type: MaterialType.transparency,
          child: TextField(
            contextMenuBuilder: (context, editableTextState) => const SizedBox.shrink(),
            textAlign: TextAlign.center,
            controller: controller,
            focusNode: focusNode,
            style: theme.textTheme.titleMedium?.copyWith(
              color: focusNode.hasFocus ? accent : theme.colorScheme.onSurface.withValues(alpha: 0.5),
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
            inputFormatters: [
              TimeTextInputFormatter(),
            ],
          ),
        ),
      ),
    );
  }

  void _submit() {
    if (!mounted) return;
    setState(() => _canPop = true);
    if (widget.optionalTime && !_timeSelected) {
      Navigator.of(context).maybePop(DateTime(
        _currentDateTime.year,
        _currentDateTime.month,
        _currentDateTime.day,
      ));
    } else {
      Navigator.of(context).maybePop(_currentDateTime);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent = widget.accentColor ?? theme.colorScheme.primary;
    final activeNormalTextStyle = theme.textTheme.titleLarge?.copyWith(
      color: Color.lerp(accent, Colors.grey, 0.7)?.withValues(alpha: 0.4),
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
                Navigator.of(context).pop(DateTime(
                  _currentDateTime.year,
                  _currentDateTime.month,
                  _currentDateTime.day,
                ));
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
          if (event is KeyDownEvent && event.logicalKey == LogicalKeyboardKey.enter) {
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
                                  normalTextStyle: _timeSelected ? activeNormalTextStyle : inactiveNormalTextStyle,
                                  highlightedTextStyle: _timeSelected ? activeHighlightTextStyle : inactiveHighlightTextStyle,
                                  spacing: 4,
                                  itemHeight: 40,
                                  onTimeChange: (newTime) {
                                    setState(() {
                                      if (!_timeSelected && widget.optionalTime) {
                                        _timeSelected = true;
                                      }
                                      _currentDateTime = newTime;
                                      _timeController.text = _formatTime(_currentDateTime);
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
                                padding: const EdgeInsets.symmetric(horizontal: 32.0),
                                child: _timeField(
                                  theme: theme,
                                  focusColor: accent,
                                  controller: _timeController,
                                  focusNode: _timeFocus,
                                  hintText: 'Time',
                                  onTap: () {
                                    _timeController.selection = TextSelection(baseOffset: 0, extentOffset: _timeController.text.length);
                                  },
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

import 'package:flutter/material.dart';
import 'package:voyager/core/theme/voyager_theme.dart';
import 'package:voyager/core/widgets/field_scroll_padding.dart';
import 'package:voyager/core/widgets/select_all_on_click.dart';
import 'package:voyager/core/widgets/time_text_input_formatter.dart';

/// The typed time box of the time and date-time pickers: centred, outlined
/// in [accent] while [active], and greyed otherwise.
class TimeEntryField extends StatelessWidget {
  const TimeEntryField({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.active,
    this.accent,
    required this.hintText,
    required this.onTap,
    required this.selectAllPending,
    required this.onSubmitted,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final bool active;

  /// Defaults to the theme's primary colour.
  final Color? accent;
  final String hintText;
  final VoidCallback onTap;
  final bool Function() selectAllPending;
  final ValueChanged<String> onSubmitted;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent = this.accent ?? theme.colorScheme.primary;
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
          color: active
              ? accent
              : theme.colorScheme.onSurface.withValues(alpha: 0.2),
          width: active ? 2 : 1,
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
                color: active
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
}

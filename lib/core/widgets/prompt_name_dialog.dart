import 'package:flutter/material.dart';
import 'package:voyager/core/widgets/ctrl_enter_to_submit_scope.dart';
import 'package:voyager/core/widgets/enter_to_submit_scope.dart';
import 'package:voyager/core/widgets/glass_button.dart';
import 'package:voyager/core/widgets/labeled_text_field.dart';
import 'package:voyager/core/widgets/voyager_dialog.dart';

/// Single-field name prompt. Owns its [TextEditingController] in State so
/// Enter-to-submit cannot dispose the controller while the dismiss animation
/// still holds the field.
Future<String?> showPromptNameDialog(
  BuildContext context, {
  required String title,
  String? initial,
  String label = 'Name',
  double? contentWidth,
  bool enterToSubmit = true,
  String? Function(String name)? validate,
}) {
  return showVoyagerDialog<String>(
    context: context,
    builder: (context) => _PromptNameDialog(
      title: title,
      initial: initial,
      label: label,
      contentWidth: contentWidth,
      enterToSubmit: enterToSubmit,
      validate: validate,
    ),
  );
}

class _PromptNameDialog extends StatefulWidget {
  const _PromptNameDialog({
    required this.title,
    required this.initial,
    required this.label,
    required this.contentWidth,
    required this.enterToSubmit,
    required this.validate,
  });

  final String title;
  final String? initial;
  final String label;
  final double? contentWidth;
  final bool enterToSubmit;

  /// A message when the name can't be used, shown under the field with the
  /// dialog kept open and the name kept; null when it can.
  final String? Function(String name)? validate;

  @override
  State<_PromptNameDialog> createState() => _PromptNameDialogState();
}

class _PromptNameDialogState extends State<_PromptNameDialog> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initial ?? '',
  );
  final _focusNode = FocusNode();
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _submit() {
    final error = widget.validate?.call(_controller.text);
    if (error != null) {
      setState(() => _error = error);
      // The field's own submit unfocuses it; hand focus back so the name can
      // be corrected straight away.
      _focusNode.requestFocus();
      return;
    }
    Navigator.pop(context, _controller.text);
  }

  @override
  Widget build(BuildContext context) {
    final error = _error;
    final input = LabeledTextField(
      label: widget.label,
      controller: _controller,
      focusNode: _focusNode,
      autofocus: true,
      textInputAction: TextInputAction.done,
      onSubmitted: (_) => _submit(),
      onChanged: (_) {
        if (_error != null) setState(() => _error = null);
      },
    );
    // One shape with or without the message: swapping the field into a
    // Column remounts it and loses its text input connection.
    final field = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        input,
        if (error != null) ...[
          const SizedBox(height: 6),
          Text(
            error,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.error,
            ),
          ),
        ],
      ],
    );
    final content = widget.contentWidth == null
        ? field
        : SizedBox(width: widget.contentWidth, child: field);

    final dialog = AlertDialog(
      title: Text(widget.title),
      content: content,
      actions: [
        GlassButton(
          dense: true,
          onPressed: () => Navigator.pop(context),
          label: 'Cancel',
        ),
        GlassButton(dense: true, onPressed: _submit, label: 'OK'),
      ],
    );

    final chord = CtrlEnterToSubmitScope(onSubmit: _submit, child: dialog);
    if (!widget.enterToSubmit) return chord;
    return EnterToSubmitScope(onSubmit: _submit, child: chord);
  }
}

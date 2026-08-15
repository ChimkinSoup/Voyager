import 'package:flutter/material.dart';
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
}) {
  return showVoyagerDialog<String>(
    context: context,
    builder: (context) => _PromptNameDialog(
      title: title,
      initial: initial,
      label: label,
      contentWidth: contentWidth,
      enterToSubmit: enterToSubmit,
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
  });

  final String title;
  final String? initial;
  final String label;
  final double? contentWidth;
  final bool enterToSubmit;

  @override
  State<_PromptNameDialog> createState() => _PromptNameDialogState();
}

class _PromptNameDialogState extends State<_PromptNameDialog> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initial ?? '',
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() => Navigator.pop(context, _controller.text);

  @override
  Widget build(BuildContext context) {
    final field = LabeledTextField(
      label: widget.label,
      controller: _controller,
      autofocus: true,
      textInputAction: TextInputAction.done,
      onSubmitted: (_) => _submit(),
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

    if (!widget.enterToSubmit) return dialog;
    return EnterToSubmitScope(onSubmit: _submit, child: dialog);
  }
}

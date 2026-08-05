import 'package:flutter/material.dart';
import 'package:voyager/core/layout/touch_target.dart';
import 'package:voyager/core/widgets/glass_button.dart';
import 'package:voyager/core/widgets/voyager_text_field.dart';

/// Small bottom sheet asking for a single name — used for creating/renaming
/// a Study folder or deck. Returns the trimmed name, or null if cancelled.
Future<String?> showStudyNameModal(
  BuildContext context, {
  required String title,
  String? initialValue,
  String hintText = 'Name',
}) {
  return showModalBottomSheet<String>(
    context: context,
    useRootNavigator: true,
    isScrollControlled: true,
    useSafeArea: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (ctx) => _StudyNameModal(
      title: title,
      initialValue: initialValue,
      hintText: hintText,
    ),
  );
}

class _StudyNameModal extends StatefulWidget {
  const _StudyNameModal({
    required this.title,
    this.initialValue,
    required this.hintText,
  });

  final String title;
  final String? initialValue;
  final String hintText;

  @override
  State<_StudyNameModal> createState() => _StudyNameModalState();
}

class _StudyNameModalState extends State<_StudyNameModal> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initialValue ?? '',
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final name = _controller.text.trim();
    if (name.isEmpty) return;
    Navigator.of(context).pop(name);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final viewInsets = MediaQuery.of(context).viewInsets.bottom;

    return Padding(
      padding: EdgeInsets.only(bottom: viewInsets),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 10, 20, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Container(
                width: 36,
                height: 4,
                margin: const EdgeInsets.only(bottom: 16),
                decoration: BoxDecoration(
                  color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.3),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            Row(
              children: [
                Text(widget.title, style: theme.textTheme.titleMedium),
                const Spacer(),
                IconButton(
                  onPressed: Navigator.of(context).pop,
                  icon: const Icon(Icons.close, size: 18),
                  tooltip: 'Cancel',
                  padding: EdgeInsets.zero,
                  constraints: kMinTouchTarget,
                ),
              ],
            ),
            const SizedBox(height: 12),
            VoyagerTextField(
              controller: _controller,
              autofocus: true,
              onSubmitted: (_) => _submit(),
              decoration: InputDecoration(hintText: widget.hintText),
            ),
            const SizedBox(height: 18),
            GlassButton(
              onPressed: _submit,
              label: 'Save',
              padding: const EdgeInsets.symmetric(vertical: 14),
            ),
          ],
        ),
      ),
    );
  }
}

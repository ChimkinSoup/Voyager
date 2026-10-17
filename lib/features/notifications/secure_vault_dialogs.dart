import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/secure_vault/secure_vault_service.dart';
import 'package:voyager/core/widgets/glass_button.dart';
import 'package:voyager/core/widgets/voyager_dialog.dart';
import 'package:voyager/features/notifications/secure_vault_session.dart';

/// What holding the inbox title does: locks an unlocked vault, and otherwise
/// asks for the password — or for a new one, when there is no vault yet.
Future<void> toggleSecureVault(BuildContext context, WidgetRef ref) async {
  if (ref.read(secureVaultSessionProvider) != null) {
    ref.read(secureVaultSessionProvider.notifier).lock();
    return;
  }
  final header = await ref.read(secureVaultServiceProvider).refreshHeader();
  if (!context.mounted) return;
  ref.invalidate(secureVaultHeaderProvider);
  if (header == null) {
    await _showSetup(context, ref);
  } else {
    await _showUnlock(context, ref);
  }
}

Future<void> showChangeVaultPasswordDialog(
  BuildContext context,
  WidgetRef ref,
) {
  final service = ref.read(secureVaultServiceProvider);
  return _show(
    context,
    title: 'Change password',
    fields: const [
      _Field('Current password'),
      _Field('New password'),
      _Field('Confirm new password'),
    ],
    confirmLabel: 'Change',
    submit: (values) async {
      final error = _checkNewPassword(values[1], values[2]);
      if (error != null) return error;
      if (!await service.changePassword(values[0], values[1])) {
        return 'Wrong password.';
      }
      ref.invalidate(secureVaultHeaderProvider);
      return null;
    },
  );
}

Future<void> _showSetup(BuildContext context, WidgetRef ref) {
  final service = ref.read(secureVaultServiceProvider);
  return _show(
    context,
    title: 'Create secure vault',
    message:
        'Secure notes are encrypted with this password. If you forget it, '
        'the notes are gone — there is no way to recover them.',
    fields: const [_Field('Password'), _Field('Confirm password')],
    confirmLabel: 'Create',
    submit: (values) async {
      final error = _checkNewPassword(values[0], values[1]);
      if (error != null) return error;
      final key = await service.create(values[0]);
      final header = await service.localHeader();
      ref
          .read(secureVaultSessionProvider.notifier)
          .unlock(key, header!.vaultId);
      ref.invalidate(secureVaultHeaderProvider);
      return null;
    },
  );
}

Future<void> _showUnlock(BuildContext context, WidgetRef ref) async {
  final service = ref.read(secureVaultServiceProvider);
  final repository = ref.read(notificationRepositoryProvider);
  // Told here rather than when it happened: the vault is hidden, and anyone
  // could be looking at the screen when a reset arrives.
  final lost = await repository.lostSecureNoteCount();
  if (!context.mounted) return;
  var reset = false;
  await _show(
    context,
    title: 'Unlock',
    message: lost == 0 ? null : _lostNotesMessage(lost),
    fields: const [_Field('Password')],
    confirmLabel: 'Unlock',
    submit: (values) async {
      final key = await service.unlock(values[0]);
      if (key == null) return 'Wrong password.';
      final header = await service.localHeader();
      ref
          .read(secureVaultSessionProvider.notifier)
          .unlock(key, header!.vaultId);
      await repository.setLostSecureNoteCount(0);
      return null;
    },
    secondaryLabel: 'Reset vault',
    onSecondary: () => reset = true,
  );
  if (reset && context.mounted) await _showReset(context, ref);
}

Future<void> _showReset(BuildContext context, WidgetRef ref) {
  final service = ref.read(secureVaultServiceProvider);
  return _show(
    context,
    title: 'Reset vault',
    message:
        'This permanently deletes every secure note, on every device, and '
        'starts a new vault. Type RESET to confirm.',
    fields: const [
      _Field('Type RESET', obscure: false),
      _Field('New password'),
      _Field('Confirm new password'),
    ],
    confirmLabel: 'Reset',
    destructive: true,
    submit: (values) async {
      if (values[0] != 'RESET') return 'Type RESET to confirm.';
      final error = _checkNewPassword(values[1], values[2]);
      if (error != null) return error;
      final key = await service.reset(values[1]);
      await ref.read(notificationRepositoryProvider).setLostSecureNoteCount(0);
      final header = await service.localHeader();
      ref
          .read(secureVaultSessionProvider.notifier)
          .unlock(key, header!.vaultId);
      ref.invalidate(secureVaultHeaderProvider);
      ref.invalidate(secureNotesProvider);
      return null;
    },
  );
}

String _lostNotesMessage(int count) =>
    'The vault was reset on another device, so '
    '${count == 1 ? '1 note' : '$count notes'} made on this device '
    "${count == 1 ? "wasn't" : "weren't"} kept.";

String? _checkNewPassword(String password, String confirmation) {
  if (password.length < SecureVaultService.minPasswordLength) {
    return 'Use at least ${SecureVaultService.minPasswordLength} characters.';
  }
  if (password != confirmation) return "The passwords don't match.";
  return null;
}

class _Field {
  const _Field(this.label, {this.obscure = true});

  final String label;
  final bool obscure;
}

/// Runs [submit] with the fields' values. A returned message is shown under
/// the fields; null closes the dialog. A [SecureVaultException] shows its
/// message the same way.
Future<void> _show(
  BuildContext context, {
  required String title,
  String? message,
  required List<_Field> fields,
  required String confirmLabel,
  required Future<String?> Function(List<String> values) submit,
  bool destructive = false,
  String? secondaryLabel,
  VoidCallback? onSecondary,
}) {
  return showVoyagerDialog<void>(
    context: context,
    builder: (context) => _VaultDialog(
      title: title,
      message: message,
      fields: fields,
      confirmLabel: confirmLabel,
      submit: submit,
      destructive: destructive,
      secondaryLabel: secondaryLabel,
      onSecondary: onSecondary,
    ),
  );
}

class _VaultDialog extends StatefulWidget {
  const _VaultDialog({
    required this.title,
    required this.message,
    required this.fields,
    required this.confirmLabel,
    required this.submit,
    required this.destructive,
    required this.secondaryLabel,
    required this.onSecondary,
  });

  final String title;
  final String? message;
  final List<_Field> fields;
  final String confirmLabel;
  final Future<String?> Function(List<String> values) submit;
  final bool destructive;
  final String? secondaryLabel;
  final VoidCallback? onSecondary;

  @override
  State<_VaultDialog> createState() => _VaultDialogState();
}

class _VaultDialogState extends State<_VaultDialog> {
  late final _controllers = [
    for (final _ in widget.fields) TextEditingController(),
  ];
  String? _error;
  bool _busy = false;

  @override
  void dispose() {
    for (final controller in _controllers) {
      controller.dispose();
    }
    super.dispose();
  }

  Future<void> _submit() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    String? error;
    try {
      error = await widget.submit([for (final c in _controllers) c.text]);
    } on SecureVaultException catch (e) {
      error = e.message;
    }
    if (!mounted) return;
    if (error == null) {
      Navigator.pop(context);
      return;
    }
    setState(() {
      _busy = false;
      _error = error;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: 360,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (widget.message case final message?)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Text(message),
              ),
            for (var i = 0; i < widget.fields.length; i++)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                // A plain field: no Vim, snippets, autocorrect or
                // spellcheck, and nothing the keyboard may learn from.
                child: TextField(
                  controller: _controllers[i],
                  autofocus: i == 0,
                  obscureText: widget.fields[i].obscure,
                  enableSuggestions: false,
                  autocorrect: false,
                  enableIMEPersonalizedLearning: false,
                  keyboardType: widget.fields[i].obscure
                      ? TextInputType.visiblePassword
                      : TextInputType.text,
                  textInputAction: i == widget.fields.length - 1
                      ? TextInputAction.done
                      : TextInputAction.next,
                  decoration: InputDecoration(
                    labelText: widget.fields[i].label,
                    isDense: true,
                  ),
                  onSubmitted: i == widget.fields.length - 1
                      ? (_) => _submit()
                      : null,
                ),
              ),
            if (_error case final error?)
              Text(
                error,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
          ],
        ),
      ),
      actions: [
        if (widget.secondaryLabel case final label?)
          TextButton(
            onPressed: _busy
                ? null
                : () {
                    widget.onSecondary?.call();
                    Navigator.pop(context);
                  },
            child: Text(label),
          ),
        GlassButton(
          onPressed: () => Navigator.pop(context),
          label: 'Cancel',
          dense: true,
        ),
        GlassButton(
          onPressed: _busy ? null : _submit,
          label: widget.confirmLabel,
          color: widget.destructive ? theme.colorScheme.error : null,
          dense: true,
        ),
      ],
    );
  }
}

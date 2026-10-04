import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/theme/app_fonts.dart';
import 'package:voyager/core/widgets/glass_button.dart';
import 'package:voyager/core/widgets/labeled_text_field.dart';
import 'package:voyager/core/widgets/voyager_dialog.dart';

/// Settings → Account: who is signed in, changing the password, signing out.
///
/// Reads the account once per build rather than watching it: signing out
/// routes to `/login` and tears the shell down, so a different account always
/// arrives with a fresh Settings.
class AccountSettingsSection extends ConsumerWidget {
  const AccountSettingsSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final auth = ref.read(authRepositoryProvider);
    final hasPassword = auth.hasPasswordSignIn;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Account', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 4),
        ListTile(
          leading: const Icon(PhosphorIconsRegular.userCircle),
          title: Text(auth.currentUserEmail ?? 'Signed in'),
          subtitle: Text(
            hasPassword
                ? 'Signed in with email and password'
                : 'Signed in with Google',
          ),
        ),
        if (hasPassword)
          ListTile(
            leading: const Icon(PhosphorIconsRegular.password),
            title: const Text('Change password'),
            onTap: () => showVoyagerDialog<void>(
              context: context,
              builder: (_) => const _ChangePasswordDialog(),
            ),
          ),
        ListTile(
          leading: const Icon(PhosphorIconsRegular.signOut),
          title: const Text('Sign out'),
          onTap: () => auth.signOut(),
        ),
      ],
    );
  }
}

class _ChangePasswordDialog extends ConsumerStatefulWidget {
  const _ChangePasswordDialog();

  @override
  ConsumerState<_ChangePasswordDialog> createState() =>
      _ChangePasswordDialogState();
}

class _ChangePasswordDialogState extends ConsumerState<_ChangePasswordDialog> {
  final _current = TextEditingController();
  final _next = TextEditingController();
  final _confirm = TextEditingController();
  var _loading = false;
  String? _error;

  @override
  void dispose() {
    _current.dispose();
    _next.dispose();
    _confirm.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_loading) return;
    if (_current.text.isEmpty || _next.text.isEmpty) {
      setState(() => _error = 'Fill in both passwords.');
      return;
    }
    if (_next.text != _confirm.text) {
      setState(() => _error = 'New passwords do not match.');
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await ref
          .read(authRepositoryProvider)
          .changePassword(_current.text, _next.text);
      if (!mounted) return;
      final messenger = ScaffoldMessenger.of(context);
      Navigator.pop(context);
      messenger.showSnackBar(const SnackBar(content: Text('Password changed')));
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.toString().replaceFirst('Exception: ', '');
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Change password'),
      content: SizedBox(
        width: 360,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            LabeledTextField(
              label: 'Current password',
              controller: _current,
              obscureText: true,
              autofocus: true,
              enabled: !_loading,
              onSubmitted: (_) => _submit(),
            ),
            const SizedBox(height: 12),
            LabeledTextField(
              label: 'New password',
              controller: _next,
              obscureText: true,
              enabled: !_loading,
              onSubmitted: (_) => _submit(),
            ),
            const SizedBox(height: 12),
            LabeledTextField(
              label: 'Confirm new password',
              controller: _confirm,
              obscureText: true,
              enabled: !_loading,
              onSubmitted: (_) => _submit(),
            ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(
                _error!,
                style: AppFonts.style(
                  color: Theme.of(context).colorScheme.error,
                ),
              ),
            ],
          ],
        ),
      ),
      actions: [
        GlassButton(
          dense: true,
          onPressed: _loading ? null : () => Navigator.pop(context),
          label: 'Cancel',
        ),
        GlassButton(
          dense: true,
          onPressed: _loading ? null : _submit,
          icon: _loading
              ? const SizedBox.square(
                  dimension: 14,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : null,
          label: 'Change',
        ),
      ],
    );
  }
}

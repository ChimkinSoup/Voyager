import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:voyager/app/providers.dart';

/// Forces automatic backups to fail, so the "Backups failing" Inbox alert
/// and the Attention status appear through the real failure path.
class DevBackupFailureSection extends ConsumerStatefulWidget {
  const DevBackupFailureSection({super.key});

  @override
  ConsumerState<DevBackupFailureSection> createState() =>
      _DevBackupFailureSectionState();
}

class _DevBackupFailureSectionState
    extends ConsumerState<DevBackupFailureSection> {
  bool? _value;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    unawaited(
      ref.read(autoBackupServiceProvider).simulatesFailure().then((value) {
        if (mounted) setState(() => _value = value);
      }),
    );
  }

  Future<void> _set(bool value) async {
    setState(() {
      _value = value;
      _busy = true;
    });
    await ref.read(autoBackupServiceProvider).setSimulateFailure(value);
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    return SwitchListTile(
      title: const Text('Simulate failing backups'),
      subtitle: const Text(
        'Every automatic backup run fails with a simulated error, recorded '
        'like a real one: Settings shows Attention and the Inbox shows '
        '"Backups failing" straight away instead of after two days. Turning '
        'it off takes a real backup, which clears both.',
      ),
      value: _value ?? false,
      onChanged: _value == null || _busy ? null : _set,
    );
  }
}

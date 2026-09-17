import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:voyager/features/finance/finance_transaction_modal.dart';
import 'package:voyager/features/hotkeys/floaters/floater_controller.dart';
import 'package:voyager/features/hotkeys/quick_capture.dart';

/// The finance hotkey's floater: the whole transaction form, drafts kept
/// across dismissals.
class FinanceFloater extends ConsumerStatefulWidget {
  const FinanceFloater({super.key});

  @override
  ConsumerState<FinanceFloater> createState() => _FinanceFloaterState();
}

class _FinanceFloaterState extends ConsumerState<FinanceFloater> {
  var _saved = false;

  @override
  Widget build(BuildContext context) {
    final container = ProviderScope.containerOf(context, listen: false);
    return financeTransactionForm(
      container: container,
      draft: ref.read(financeCaptureDraftProvider),
      onSaved: () async => _saved = true,
      onClose: () {
        final floaters = container.read(floaterControllerProvider);
        unawaited(
          _saved
              ? floaters.completeWith('Transaction added')
              : floaters.dismiss(),
        );
      },
      onDraft: (draft) => storeFinanceCaptureDraft(container, draft),
    );
  }
}

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:voyager/features/finance/finance_transaction_modal.dart';

/// What a global hotkey captures.
enum QuickCaptureKind {
  todo('/todo'),
  journal('/journal'),
  finance('/finance');

  const QuickCaptureKind(this.path);

  /// The shell page the in-app path navigates to.
  final String path;
}

/// The quick-add bar's unsaved state. Session memory only: nothing here is
/// written anywhere until Enter creates the task.
class TodoCaptureDraft {
  const TodoCaptureDraft({
    this.title = '',
    this.dueDate,
    this.listId,
    this.listIdBasis,
  });

  final String title;

  /// Local midnight of the picked day.
  final DateTime? dueDate;

  /// A list picked in the bar, or null for the last-touched list.
  final String? listId;

  /// The last-touched list at the moment [listId] was picked. A pick only
  /// stands until the user touches a list somewhere else.
  final String? listIdBasis;

  TodoCaptureDraft copyWith({
    String? title,
    DateTime? dueDate,
    bool clearDueDate = false,
  }) {
    return TodoCaptureDraft(
      title: title ?? this.title,
      dueDate: clearDueDate ? null : (dueDate ?? this.dueDate),
      listId: listId,
      listIdBasis: listIdBasis,
    );
  }
}

final todoCaptureDraftProvider = StateProvider<TodoCaptureDraft>(
  (_) => const TodoCaptureDraft(),
);

/// The transaction form's unsaved fields, kept across dismissals until a save
/// clears them. Session memory only.
final financeCaptureDraftProvider = StateProvider<FinanceTransactionDraft?>(
  (_) => null,
);

/// Stores a transaction draft handed back by a closing form. Deferred: the
/// form hands it over from `dispose`, mid tree teardown.
void storeFinanceCaptureDraft(
  ProviderContainer container,
  FinanceTransactionDraft? draft,
) {
  scheduleMicrotask(
    () => container.read(financeCaptureDraftProvider.notifier).state = draft,
  );
}

/// A hotkey pressed while the main window was focused, for the page it names
/// to act on.
///
/// Deliberately not const and without `==`: pressing the same hotkey twice is
/// two requests, and the provider only notifies on a change.
class QuickCaptureRequest {
  QuickCaptureRequest(this.kind);

  final QuickCaptureKind kind;
}

final quickCaptureRequestProvider = StateProvider<QuickCaptureRequest?>(
  (_) => null,
);

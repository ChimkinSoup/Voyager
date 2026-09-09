import 'package:flutter/widgets.dart';
import 'package:voyager/core/spellcheck/voyager_spell_check_service.dart';

/// Publishes the user's autocorrect setting, and the dictionary it corrects
/// against, to every text field below.
///
/// Installed once at the app root beside `VimEnabledScope` and
/// `SnippetEnabledScope` (see `voyager_app.dart`) and read the same way —
/// through an inherited dependency, so flipping the setting re-applies to
/// every mounted field without any of them holding a Riverpod ref.
///
/// The [service] travels with the flag rather than being looked up separately
/// because `VimTextScope`, which creates the sessions, is a plain widget in
/// `core/vim` with no provider access of its own. It is a single long-lived
/// instance, so this compares by identity and the scope never notifies for it.
@immutable
class AutocorrectScopeData {
  const AutocorrectScopeData({required this.enabled, required this.service});

  static const AutocorrectScopeData disabled = AutocorrectScopeData(
    enabled: false,
    service: null,
  );

  final bool enabled;

  /// The dictionary autocorrect reads. Null only before the app root has
  /// installed a real scope — in tests that build a field on its own, which
  /// is also exactly when autocorrect should stay out of the way.
  final VoyagerSpellCheckService? service;

  @override
  bool operator ==(Object other) =>
      other is AutocorrectScopeData &&
      other.enabled == enabled &&
      identical(other.service, service);

  @override
  int get hashCode => Object.hash(enabled, identityHashCode(service));
}

class AutocorrectEnabledScope extends InheritedWidget {
  const AutocorrectEnabledScope({
    super.key,
    required this.data,
    required super.child,
  });

  final AutocorrectScopeData data;

  static AutocorrectScopeData of(BuildContext context) {
    final scope = context
        .dependOnInheritedWidgetOfExactType<AutocorrectEnabledScope>();
    return scope?.data ?? AutocorrectScopeData.disabled;
  }

  @override
  bool updateShouldNotify(AutocorrectEnabledScope oldWidget) =>
      oldWidget.data != data;
}

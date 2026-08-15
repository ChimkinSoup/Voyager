import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Publishes the user's "Vim keybindings" setting to every text field below.
///
/// Installed once at the app root (see `voyager_app.dart`). Fields read it
/// with [VimEnabledScope.of], which registers an inherited dependency, so
/// flipping the switch in Settings re-applies to every mounted field without
/// any of them needing a Riverpod ref.
class VimEnabledScope extends InheritedWidget {
  const VimEnabledScope({
    super.key,
    required this.enabled,
    required super.child,
  });

  final bool enabled;

  static bool of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<VimEnabledScope>();
    return scope?.enabled ?? false;
  }

  @override
  bool updateShouldNotify(VimEnabledScope oldWidget) =>
      oldWidget.enabled != enabled;
}

/// Whether a field's configuration makes Vim editing meaningful.
///
/// The user asked for Vim in every text box *except* structured inputs, and
/// this is the single rule that draws that line — no per-call-site opt-outs to
/// keep in sync:
///
/// - **Obscured** fields (passwords, the dev API key) have no visible text to
///   navigate, and a mode indicator over a password box is noise.
/// - **Numeric and other non-text keyboards** (amounts, counts, the time
///   pickers) are single-token inputs where `w`/`b`/`ciw` have nothing to act
///   on.
/// - **Formatter-constrained** fields (the hex colour box, currency amounts)
///   reject most of what an operator would write back, so a Vim edit there
///   would silently half-apply.
/// - **Read-only** fields cannot be edited at all.
bool vimSuitsField({
  bool obscureText = false,
  TextInputType? keyboardType,
  List<TextInputFormatter>? inputFormatters,
  bool readOnly = false,
}) {
  if (obscureText || readOnly) return false;
  if (inputFormatters != null && inputFormatters.isNotEmpty) return false;
  if (keyboardType != null && !_isFreeTextKeyboard(keyboardType)) return false;
  return true;
}

/// Whether a keyboard type still denotes free text. Anything else (number,
/// phone, datetime, url…) is a structured input.
///
/// Written as comparisons rather than a `Set` lookup because [TextInputType]
/// overrides `==`, which Dart forbids in a const set.
bool _isFreeTextKeyboard(TextInputType type) =>
    type == TextInputType.text ||
    type == TextInputType.multiline ||
    type == TextInputType.name ||
    type == TextInputType.emailAddress;

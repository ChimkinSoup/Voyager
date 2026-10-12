import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/domain/models/settings_models.dart';

/// The date picker reads the week-start setting; this supplies it without
/// opening the real database.
Widget datePickerSettingsScope(
  Widget child, {
  bool weekStartsOnMonday = false,
}) => ProviderScope(
  overrides: [
    settingsProvider.overrideWith(() => _FixedSettings(weekStartsOnMonday)),
  ],
  child: child,
);

class _FixedSettings extends SettingsNotifier {
  _FixedSettings(this.weekStartsOnMonday);

  final bool weekStartsOnMonday;

  @override
  Future<AppSettings> build() async =>
      AppSettings(weekStartsOnMonday: weekStartsOnMonday);
}

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/widgets/labeled_text_field.dart';
import 'package:voyager/domain/models/settings_models.dart';

/// Debug-only control for calling OpenWeather directly instead of Cloud Functions.
class DevWeatherApiTile extends ConsumerStatefulWidget {
  const DevWeatherApiTile({super.key, required this.settings});

  final AppSettings settings;

  @override
  ConsumerState<DevWeatherApiTile> createState() => _DevWeatherApiTileState();
}

class _DevWeatherApiTileState extends ConsumerState<DevWeatherApiTile> {
  late final TextEditingController _apiKeyController;

  @override
  void initState() {
    super.initState();
    _apiKeyController = TextEditingController(
      text: widget.settings.devOpenWeatherApiKey ?? '',
    );
  }

  @override
  void didUpdateWidget(covariant DevWeatherApiTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.settings.devOpenWeatherApiKey !=
        widget.settings.devOpenWeatherApiKey) {
      _apiKeyController.text = widget.settings.devOpenWeatherApiKey ?? '';
    }
  }

  @override
  void dispose() {
    _apiKeyController.dispose();
    super.dispose();
  }

  Future<void> _save(AppSettings settings) async {
    await ref.read(settingsRepositoryProvider).saveSettings(settings);
    ref.invalidate(settingsProvider);
    ref.invalidate(weatherApiClientProvider);
    ref.invalidate(currentWeatherProvider);
  }

  @override
  Widget build(BuildContext context) {
    if (!kDebugMode) return const SizedBox.shrink();

    final settings = widget.settings;
    final hasKey = _apiKeyController.text.trim().isNotEmpty;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SwitchListTile(
          title: const Text('Direct OpenWeather API'),
          subtitle: const Text(
            'Skip Cloud Functions. API key is stored locally on this device only.',
          ),
          value: settings.devUseDirectOpenWeather,
          onChanged: (enabled) async {
            await _save(settings.copyWith(devUseDirectOpenWeather: enabled));
          },
        ),
        if (settings.devUseDirectOpenWeather) ...[
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: LabeledTextField(
              label: 'OpenWeather API key',
              controller: _apiKeyController,
              obscureText: true,
              onSubmitted: (_) => _saveApiKey(settings),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Align(
              alignment: Alignment.centerRight,
              child: FilledButton(
                onPressed: hasKey ? () => _saveApiKey(settings) : null,
                child: const Text('Save API key'),
              ),
            ),
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Text(
              'Not synced to Firestore. Release builds always use Cloud Functions.',
              style: TextStyle(fontSize: 12),
            ),
          ),
        ],
      ],
    );
  }

  Future<void> _saveApiKey(AppSettings settings) async {
    final key = _apiKeyController.text.trim();
    await _save(
      settings.copyWith(
        devOpenWeatherApiKey: key.isEmpty ? null : key,
        clearDevOpenWeatherApiKey: key.isEmpty,
      ),
    );
  }
}

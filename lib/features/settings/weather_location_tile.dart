import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/widgets/labeled_text_field.dart';
import 'package:voyager/core/widgets/weather_icon.dart';
import 'package:voyager/domain/models/settings_models.dart';

class WeatherLocationTile extends ConsumerStatefulWidget {
  const WeatherLocationTile({super.key, required this.settings});

  final AppSettings settings;

  @override
  ConsumerState<WeatherLocationTile> createState() =>
      _WeatherLocationTileState();
}

class _WeatherLocationTileState extends ConsumerState<WeatherLocationTile> {
  late final TextEditingController _controller;
  var _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(
      text: widget.settings.weatherLocationLabel,
    );
  }

  @override
  void didUpdateWidget(covariant WeatherLocationTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.settings.weatherLocationLabel !=
        widget.settings.weatherLocationLabel) {
      _controller.text = widget.settings.weatherLocationLabel ?? '';
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _saveLocation() async {
    final query = _controller.text.trim();
    if (query.isEmpty) {
      setState(() => _error = 'Enter a city, such as Chicago, US');
      return;
    }

    setState(() {
      _saving = true;
      _error = null;
    });

    try {
      await ref.read(weatherServiceProvider).saveLocation(query);
      ref.invalidate(settingsProvider);
      ref.invalidate(currentWeatherProvider);
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  String? _lastUpdatedLabel() {
    final fetchedAt = widget.settings.weatherFetchedAt;
    if (fetchedAt == null) return null;
    return 'Updated ${DateFormat.MMMd().add_jm().format(fetchedAt.toLocal())}';
  }

  @override
  Widget build(BuildContext context) {
    final lastUpdated = _lastUpdatedLabel();

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(weatherIconData(widget.settings.weatherIcon), size: 28),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'Weather location',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            LabeledTextField(
              label: 'City (e.g. Chicago, US)',
              controller: _controller,
              onSubmitted: (_) => _saveLocation(),
            ),
            if (lastUpdated != null) ...[
              const SizedBox(height: 8),
              Text(lastUpdated, style: Theme.of(context).textTheme.bodySmall),
            ],
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(
                _error!,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.error,
                ),
              ),
            ],
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton(
                onPressed: _saving ? null : _saveLocation,
                child: _saving
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('Save location'),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Weather data provided by OpenWeather',
              style: Theme.of(context).textTheme.labelSmall,
            ),
          ],
        ),
      ),
    );
  }
}

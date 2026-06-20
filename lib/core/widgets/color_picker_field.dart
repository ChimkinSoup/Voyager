import 'package:flutter/material.dart';

const voyagerColorPalette = <int>[
  0xFF7C9EFF,
  0xFF4CAF50,
  0xFFFF9800,
  0xFFE91E63,
  0xFF00BCD4,
  0xFFFFC107,
  0xFF9C27B0,
  0xFFEF5350,
];

class ColorPickerField extends StatefulWidget {
  const ColorPickerField({
    super.key,
    required this.label,
    required this.value,
    required this.onChanged,
    this.palette = voyagerColorPalette,
  });

  final String label;
  final int value;
  final ValueChanged<int> onChanged;
  final List<int> palette;

  @override
  State<ColorPickerField> createState() => _ColorPickerFieldState();
}

class _ColorPickerFieldState extends State<ColorPickerField> {
  late final TextEditingController _hexController;
  String? _error;

  @override
  void initState() {
    super.initState();
    _hexController = TextEditingController(text: _formatHex(widget.value));
  }

  @override
  void didUpdateWidget(ColorPickerField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.value != widget.value && _parseHex(_hexController.text) != widget.value) {
      _hexController.text = _formatHex(widget.value);
    }
  }

  @override
  void dispose() {
    _hexController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(widget.label, style: Theme.of(context).textTheme.labelMedium),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final colorValue in widget.palette)
              _ColorSwatch(
                colorValue: colorValue,
                selected: colorValue == widget.value,
                onTap: () => _setColor(colorValue),
              ),
          ],
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _hexController,
          decoration: InputDecoration(
            labelText: 'Custom hex color',
            hintText: '#7C9EFF',
            errorText: _error,
            prefixIcon: Padding(
              padding: const EdgeInsets.all(12),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: Color(widget.value),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: const SizedBox(width: 16, height: 16),
              ),
            ),
          ),
          onChanged: _applyHex,
          onSubmitted: _applyHex,
        ),
      ],
    );
  }

  void _setColor(int colorValue) {
    setState(() {
      _error = null;
      _hexController.text = _formatHex(colorValue);
    });
    widget.onChanged(colorValue);
  }

  void _applyHex(String input) {
    final parsed = _parseHex(input);
    setState(() => _error = parsed == null ? 'Use #RRGGBB or #AARRGGBB' : null);
    if (parsed != null) widget.onChanged(parsed);
  }

  int? _parseHex(String input) {
    final normalized = input.trim().replaceFirst('#', '').toUpperCase();
    if (!RegExp(r'^[0-9A-F]{6}([0-9A-F]{2})?$').hasMatch(normalized)) return null;
    final withAlpha = normalized.length == 6 ? 'FF$normalized' : normalized;
    return int.tryParse(withAlpha, radix: 16);
  }

  String _formatHex(int colorValue) {
    return '#${colorValue.toRadixString(16).padLeft(8, '0').toUpperCase()}';
  }
}

class _ColorSwatch extends StatelessWidget {
  const _ColorSwatch({
    required this.colorValue,
    required this.selected,
    required this.onTap,
  });

  final int colorValue;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(18),
      child: CircleAvatar(
        radius: 18,
        backgroundColor: Color(colorValue),
        child: selected ? const Icon(Icons.check, size: 18, color: Colors.white) : null,
      ),
    );
  }
}

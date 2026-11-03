import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:voyager/domain/models/gaia_models.dart';
import 'package:voyager/features/gaia/companion/gaia_button.dart';
import 'package:voyager/features/gaia/companion/gaia_card_view.dart';
import 'package:voyager/features/gaia/host/gaia_flash.dart';

/// One step of the preview card: [marker] is what hovering it shows, [flash]
/// what running it does. Both null for a control not on screen.
typedef _ShowcaseStep = ({
  String label,
  Map<String, Object?>? marker,
  Map<String, Object?>? flash,
});

enum _EffectSet {
  classic('Current', 'The original rings, chevrons and illuminated outlines.'),
  astral(
    'Astral',
    'Tracing halos, soft core light, flowing scroll arrows and adaptive corner frames.',
  ),
  echo(
    'Echo',
    'Clean circular pulses, soft outlines and bold travelling wavefronts.',
  ),
  glide(
    'Glide',
    'Rounded square pulses, clean rails and clear directional chevrons.',
  );

  const _EffectSet(this.label, this.description);
  final String label, description;
}

enum _ClickStudy {
  trace('Trace', 'White and gold strokes draw the halos. No orbiting light.'),
  bloom(
    'Bloom',
    'The core softly brightens between steady halos. No orbiting light.',
  ),
  traceBloom(
    'Trace + Bloom',
    'White and gold halos draw themselves as the core softly brightens.',
  );

  const _ClickStudy(this.label, this.description);
  final String label, description;
}

/// Everything Gaia plays on screen while in control, for real, aimed at a mock
/// window: each flash (GAIA_AUTONOMY_HLD.md §6.2), the border, and an Ask card
/// with its step preview (§6.4). Nothing is clicked or typed.
class GaiaControlShowcase extends StatefulWidget {
  const GaiaControlShowcase({super.key, required this.clientOrigin});

  /// Where Gaia's client area starts on screen, in physical pixels: flashes
  /// are aimed in screen coordinates.
  final ({int x, int y}) Function() clientOrigin;

  @override
  State<GaiaControlShowcase> createState() => _GaiaControlShowcaseState();
}

class _GaiaControlShowcaseState extends State<GaiaControlShowcase> {
  static const _borderChannel = MethodChannel('voyager/gaia_border');

  final _window = GlobalKey();
  final _button = GlobalKey();
  final _field = GlobalKey();

  final _timers = <Timer>[];
  var _border = false;
  var _set = _EffectSet.astral;
  var _clickStudy = _ClickStudy.traceBloom;

  Map<String, Object?> _styled(Map<String, Object?> flash) => {
    ...flash,
    'style': _set.name,
    if (_set == _EffectSet.astral && flash['kind'] == 'click')
      'click_variant': _clickStudy.name,
  };

  void _selectSet(_EffectSet value) {
    if (value == _set) return;
    _cancelTimers();
    setState(() {
      _set = value;
      _opens = 0;
    });
    if (_border) unawaited(_setBorderNative(true));
  }

  ScrollPosition? _scroll;

  /// Bumped to open the card afresh, which pulses its markers. 0 until first
  /// opened: the mock window may be off screen before that.
  var _opens = 0;

  /// Each opening's card id, new across showcases too: a card pulses only the
  /// first time its id builds.
  static var _cardIds = 0;
  var _cardId = 0;
  var _unresolved = false;
  var _ran = 0;
  var _state = GaiaCardState.open;

  int get _accent => Theme.of(context).colorScheme.primary.toARGB32();

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final scroll = Scrollable.maybeOf(context)?.position;
    if (scroll == _scroll) return;
    _scroll?.removeListener(_onScroll);
    _scroll = scroll?..addListener(_onScroll);
  }

  @override
  void dispose() {
    _cancelTimers();
    _scroll?.removeListener(_onScroll);
    if (_border) unawaited(_setBorderNative(false));
    super.dispose();
  }

  /// The open card's markers move with the mock window, so are worked out
  /// again once it's laid out where it scrolled to.
  void _onScroll() {
    if (_opens == 0) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() {});
    });
  }

  void _cancelTimers() {
    for (final timer in _timers) {
      timer.cancel();
    }
    _timers.clear();
  }

  /// [key]'s widget on screen, as the flash channel takes a rect.
  Map<String, int> _rect(GlobalKey key) {
    final box = key.currentContext!.findRenderObject()! as RenderBox;
    final scale = View.of(context).devicePixelRatio;
    final origin = widget.clientOrigin();
    final rect = box.localToGlobal(Offset.zero) & box.size;
    return {
      'left': origin.x + (rect.left * scale).round(),
      'top': origin.y + (rect.top * scale).round(),
      'right': origin.x + (rect.right * scale).round(),
      'bottom': origin.y + (rect.bottom * scale).round(),
    };
  }

  Map<String, int> _centre(Map<String, int> rect) => {
    'x': (rect['left']! + rect['right']!) ~/ 2,
    'y': (rect['top']! + rect['bottom']!) ~/ 2,
  };

  /// An empty spot in the mock window, for what's aimed by coordinates.
  Map<String, int> _spot() {
    final window = _rect(_window);
    return {
      'x': window['left']! + (window['right']! - window['left']!) * 3 ~/ 4,
      'y': window['top']! + (window['bottom']! - window['top']!) * 3 ~/ 5,
    };
  }

  Map<String, Object?> _scrollFlash(String direction, [int amount = 3]) => {
    'kind': 'scroll',
    ..._spot(),
    'direction': direction,
    'amount': amount,
  };

  /// Every effect, by name, worked out when it plays. Each is as
  /// `gaia_os_control.dart` asks for it.
  late final Map<String, Map<String, Object?> Function()> _effects = {
    for (final kind in const {
      'Click': 'click',
      'Double click': 'double',
      'Right click': 'right',
    }.entries)
      kind.key: () => {
        'kind': kind.value,
        ..._centre(_rect(_button)),
        'label': 'Mark as read',
      },
    'Click, no name': () => {'kind': 'click', ..._spot()},
    for (final direction in const ['up', 'down', 'left', 'right'])
      'Scroll $direction': () => _scrollFlash(direction),
    'Scroll far': () => _scrollFlash('down', 15),
    'Type': () => {
      'kind': 'type',
      ..._rect(_field),
      'ms': 2000,
      'label': 'Subject',
    },
    'Key': () => {'kind': 'key', ..._rect(_window), 'label': 'Ctrl+S'},
    'Typing, nothing aimed': () => {
      'kind': 'key',
      ..._rect(_window),
      'label': 'Typing',
    },
    'Open, focus, adopt': () => {
      'kind': 'window',
      ..._rect(_window),
      'label': 'Notepad',
    },
    'Marker on a control': () => {
      'kind': 'mark',
      ..._centre(_rect(_button)),
      ..._rect(_button),
      'label': 'Mark as read',
    },
    'Marker at a point': () => {'kind': 'mark', ..._spot()},
  };

  void _play(String effect) => gaiaFlash(_styled(_effects[effect]!()), _accent);

  void _playClickStudies() {
    _cancelTimers();
    for (final (index, study) in _ClickStudy.values.indexed) {
      _timers.add(
        Timer(Duration(milliseconds: index * 1000), () {
          gaiaFlash({
            ..._effects['Click']!(),
            'style': 'astral',
            'click_variant': study.name,
            'label': study.label,
          }, _accent);
        }),
      );
    }
  }

  /// Each effect in turn, once the last has about finished.
  void _playAll() {
    _cancelTimers();
    var at = 0;
    for (final MapEntry(key: name, value: effect) in _effects.entries) {
      _timers.add(Timer(Duration(milliseconds: at), () => _play(name)));
      at += math.max(1000, (effect()['ms'] as int? ?? 0) + 500);
    }
  }

  Future<void> _setBorderNative(bool on) async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.windows) return;
    // The real one's button goes to the main instance, which never hears of
    // this one, so it only turns this one off.
    _borderChannel.setMethodCallHandler(
      on
          ? (call) async {
              if (call.method == 'revoke' && mounted) _setBorder(false);
            }
          : null,
    );
    try {
      await _borderChannel.invokeMethod<void>(
        'show',
        on
            ? {
                'label': 'Gaia is in control: Debug',
                'accent': _accent & 0xFFFFFF,
                'style': _set.name,
              }
            : null,
      );
    } catch (error) {
      debugPrint('[gaia] border not shown: $error');
    }
  }

  void _setBorder(bool on) {
    setState(() => _border = on);
    unawaited(_setBorderNative(on));
  }

  void _open({required bool unresolved}) {
    _cancelTimers();
    setState(() {
      _opens++;
      _cardId = ++_cardIds;
      _unresolved = unresolved;
      _ran = 0;
      _state = GaiaCardState.open;
    });
  }

  /// The steps, against where the mock window is now, labelled as a real card
  /// labels them.
  List<_ShowcaseStep> _steps() {
    final button = _rect(_button);
    final field = _rect(_field);
    final window = _rect(_window);
    final spot = _spot();
    final buttonAt = _centre(button);
    String bounds(Map<String, int> rect) =>
        '[${rect['left']},${rect['top']} '
        '${rect['right']! - rect['left']!}x${rect['bottom']! - rect['top']!}]';
    return [
      (
        label: 'Click Button "Mark as read" ${bounds(button)}',
        marker: {
          'kind': 'mark',
          ...buttonAt,
          ...button,
          'label': 'Mark as read',
        },
        flash: {'kind': 'click', ...buttonAt, 'label': 'Mark as read'},
      ),
      (
        label: 'Click at ${spot['x']}, ${spot['y']}',
        marker: {'kind': 'mark', ...spot},
        flash: {'kind': 'click', ...spot},
      ),
      if (_unresolved)
        (label: 'Click "Save" (not on screen yet)', marker: null, flash: null),
      (
        label: 'Type "Hello" into Edit "Subject" ${bounds(field)}',
        marker: {'kind': 'mark', ...field, 'ms': 0, 'label': 'Subject'},
        flash: {'kind': 'type', ...field, 'ms': 600, 'label': 'Subject'},
      ),
      (
        label: 'Scroll down 3',
        marker: _scrollFlash('down'),
        flash: _scrollFlash('down'),
      ),
      (
        label: 'Press Ctrl+S',
        marker: {'kind': 'key', ...window, 'label': 'Ctrl+S'},
        flash: {'kind': 'key', ...window, 'label': 'Ctrl+S'},
      ),
    ];
  }

  void _runNext() {
    final steps = _steps();
    if (_ran >= steps.length) return;
    if (steps[_ran].flash case final flash?) gaiaFlash(_styled(flash), _accent);
    setState(() {
      _ran++;
      if (_ran == steps.length) _state = GaiaCardState.accepted;
    });
  }

  void _runAll() {
    _cancelTimers();
    final left = _steps().length - _ran;
    for (var i = 0; i < left; i++) {
      _timers.add(Timer(Duration(milliseconds: 500 * i), _runNext));
    }
  }

  void _deny() {
    _cancelTimers();
    setState(() => _state = GaiaCardState.rejected);
  }

  Widget _card() {
    final steps = _steps();
    return GaiaCardView(
      card: GaiaCardPart(
        id: 'showcase-$_cardId',
        kind: GaiaCardKind.control,
        state: _state,
        tool: 'os_steps',
        input: {
          'window': 'Notepad: "notes.txt"',
          'app': 'Notepad',
          'steps': [
            for (final step in steps)
              {
                'label': step.label,
                'resolved': step.marker != null,
                'flash': ?(step.marker == null ? null : _styled(step.marker!)),
              },
          ],
        },
        answer: {'ran': _ran},
      ),
      waiting: true,
      sendKey: 'Ctrl+Enter',
      onRunAll: _runAll,
      onRunNext: _runNext,
      onReject: _deny,
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'The real effects, drawn over this mock window as they are over '
          "another app. Nothing is clicked or typed. They're native, so Slow "
          "animations doesn't slow them and screenshots leave them out.",
          style: muted,
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final set in _EffectSet.values)
              ChoiceChip(
                label: Text(set.label),
                selected: _set == set,
                onSelected: (_) => _selectSet(set),
              ),
          ],
        ),
        const SizedBox(height: 8),
        Text(_set.description, style: muted),
        if (_set == _EffectSet.astral) ...[
          const SizedBox(height: 16),
          Text('Single-click studies', style: theme.textTheme.titleSmall),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final study in _ClickStudy.values)
                ChoiceChip(
                  label: Text(study.label),
                  selected: _clickStudy == study,
                  onSelected: (_) {
                    _cancelTimers();
                    setState(() => _clickStudy = study);
                  },
                ),
            ],
          ),
          const SizedBox(height: 8),
          Text(_clickStudy.description, style: muted),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerLeft,
            child: GaiaButton(
              label: 'Play click studies',
              icon: Icons.play_arrow,
              onPressed: _playClickStudies,
            ),
          ),
        ],
        const SizedBox(height: 8),
        Container(
          key: _window,
          height: 220,
          padding: const EdgeInsets.all(16),
          alignment: Alignment.topLeft,
          decoration: BoxDecoration(
            color: theme.scaffoldBackgroundColor,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('notes.txt - Notepad', style: theme.textTheme.titleSmall),
              const SizedBox(height: 16),
              Container(
                key: _button,
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: const Text('Mark as read'),
              ),
              const SizedBox(height: 16),
              Container(
                key: _field,
                width: 200,
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
                decoration: BoxDecoration(
                  border: Border.all(color: theme.colorScheme.outlineVariant),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text('Subject', style: muted),
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final name in _effects.keys)
              GaiaButton(label: name, onPressed: () => _play(name)),
            GaiaButton(
              icon: Icons.play_arrow,
              label: 'Play all',
              onPressed: _playAll,
            ),
          ],
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Control border'),
          subtitle: const Text(
            'Round every monitor, with its notch on the primary one. The '
            "notch's button only turns this off: no chat is touched.",
          ),
          value: _border,
          onChanged: _setBorder,
        ),
        const SizedBox(height: 8),
        Text("Ask's step preview", style: theme.textTheme.bodySmall),
        const SizedBox(height: 4),
        Text(
          "Opening a card pulses each step's marker in turn, and hovering a "
          'step shows its marker again. Its buttons play the steps here and '
          'run nothing.',
          style: muted,
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            GaiaButton(
              label: 'Open the card',
              onPressed: () => _open(unresolved: false),
            ),
            GaiaButton(
              label: 'Open with a step not on screen',
              onPressed: () => _open(unresolved: true),
            ),
          ],
        ),
        if (_opens > 0) _card(),
      ],
    );
  }
}

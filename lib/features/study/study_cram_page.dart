import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/theme/voyager_theme.dart';
import 'package:voyager/core/widgets/glass_button.dart';
import 'package:voyager/domain/models/study_models.dart';
import 'package:voyager/core/utils/keyboard_focus_utils.dart';
import 'package:voyager/features/study/study_flip_card.dart';
import 'package:voyager/features/study/study_keyboard_shortcuts.dart';
import 'package:voyager/features/study/study_rich_text.dart';

const _kBucketFailColor = Color(0xFFE0714A);
const _kBucketMidColor = Color(0xFFE0A63A);
const _kBucketDoneColor = Color(0xFF4CAF7D);

/// Cram mode: every card starts in bucket 0 (unseen/failed), passing moves
/// it up a bucket, failing drops it back to bucket 0, and the session ends
/// once every card reaches bucket 2. Purely in-memory — never touches the
/// cards' persisted SRS state (STUDY.md is explicit about this).
class StudyCramPage extends ConsumerStatefulWidget {
  const StudyCramPage({super.key, required this.deckId});

  final String deckId;

  @override
  ConsumerState<StudyCramPage> createState() => _StudyCramPageState();
}

class _StudyCramPageState extends ConsumerState<StudyCramPage> {
  final _flipController = StudyFlipController();
  Map<String, StudyCard>? _cardsById;
  List<String> _bucket0 = [];
  final List<String> _bucket1 = [];
  final List<String> _bucket2 = [];
  bool _showingBack = false;

  double _dragDx = 0;
  bool _dragging = false;
  bool _exiting = false;
  double _exitDx = 0;

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_handleArrowKey);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_handleArrowKey);
    super.dispose();
  }

  void _ensureBuckets(List<StudyCard> cards) {
    if (_cardsById != null) return;
    _cardsById = {for (final c in cards) c.id: c};
    _bucket0 = cards.map((c) => c.id).toList();
  }

  StudyCard? get _current {
    final id = _bucket0.isNotEmpty
        ? _bucket0.first
        : (_bucket1.isNotEmpty ? _bucket1.first : null);
    return id == null ? null : _cardsById![id];
  }

  bool get _complete => _bucket0.isEmpty && _bucket1.isEmpty && _cardsById != null;

  bool _handleArrowKey(KeyEvent event) {
    if (!mounted) return false;
    final route = ModalRoute.of(context);
    if (route?.isCurrent != true) return false;
    if (isTextInputFocused() || !subtreeIsVisible(context)) return false;
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) return false;

    if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
      _decide(true);
      return true;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
      _decide(false);
      return true;
    }
    return false;
  }

  void _applyDecision(bool passed) {
    final card = _current;
    if (card == null) return;
    final id = card.id;
    if (_bucket0.remove(id)) {
      (passed ? _bucket1 : _bucket0).add(id);
    } else if (_bucket1.remove(id)) {
      (passed ? _bucket2 : _bucket0).add(id);
    }
  }

  void _decide(bool passed) {
    if (_current == null || _exiting) return;
    setState(() {
      _dragging = false;
      _exiting = true;
      _exitDx = passed ? 700 : -700;
    });
    Future.delayed(const Duration(milliseconds: 220), () {
      if (!mounted) return;
      setState(() {
        _applyDecision(passed);
        _exiting = false;
        _exitDx = 0;
        _dragDx = 0;
        _showingBack = false;
      });
      _flipController.showFront();
    });
  }

  void _handleFlip() => _flipController.flip();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cardsAsync = ref.watch(studyCardsProvider(widget.deckId));
    final cards = cardsAsync.valueOrNull;
    if (cards != null) _ensureBuckets(cards);

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: SafeArea(
        child: _cardsById == null
            ? const Center(child: CircularProgressIndicator())
            : _complete
            ? _CramComplete(onDone: () => Navigator.of(context).pop())
            : StudyKeyboardShortcuts(
                onSpace: _handleFlip,
                showingBack: _showingBack,
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    children: [
                      Row(
                        children: [
                          IconButton(
                            onPressed: () => Navigator.of(context).pop(),
                            icon: const Icon(PhosphorIconsRegular.x),
                          ),
                          const Spacer(),
                          Text('Cram mode', style: theme.textTheme.titleMedium),
                          const Spacer(),
                          const SizedBox(width: 48),
                        ],
                      ),
                      const SizedBox(height: 12),
                      _BucketProgressBar(
                        bucket0: _bucket0.length,
                        bucket1: _bucket1.length,
                        bucket2: _bucket2.length,
                      ),
                      Expanded(
                        child: Center(
                          child: GestureDetector(
                            onHorizontalDragStart: (_) => setState(() => _dragging = true),
                            onHorizontalDragUpdate: (details) =>
                                setState(() => _dragDx += details.delta.dx),
                            onHorizontalDragEnd: (details) {
                              if (_dragDx.abs() > 120) {
                                _decide(_dragDx > 0);
                              } else {
                                setState(() {
                                  _dragging = false;
                                  _dragDx = 0;
                                });
                              }
                            },
                            child: AnimatedScale(
                              scale: _exiting ? 0.8 : 1.0,
                              duration: const Duration(milliseconds: 220),
                              curve: Curves.easeOut,
                              child: AnimatedOpacity(
                                opacity: _exiting ? 0.0 : 1.0,
                                duration: const Duration(milliseconds: 220),
                                child: _dragging
                                    ? Transform.translate(
                                        offset: Offset(_dragDx, 0),
                                        child: _cramCard(theme),
                                      )
                                    : AnimatedContainer(
                                        duration: const Duration(milliseconds: 220),
                                        curve: Curves.easeOut,
                                        transform: Matrix4.translationValues(
                                          _exiting ? _exitDx : 0,
                                          0,
                                          0,
                                        ),
                                        child: _cramCard(theme),
                                      ),
                              ),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 16),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          GlassButton(
                            width: 56,
                            height: 56,
                            borderRadius: BorderRadius.circular(28),
                            color: theme.colorScheme.error,
                            icon: const Icon(PhosphorIconsRegular.arrowLeft),
                            onPressed: () => _decide(false),
                          ),
                          const SizedBox(width: 24),
                          GlassButton(
                            width: 56,
                            height: 56,
                            borderRadius: BorderRadius.circular(28),
                            color: const Color(0xFF4CAF7D),
                            icon: const Icon(PhosphorIconsRegular.arrowRight),
                            onPressed: () => _decide(true),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
      ),
    );
  }

  Widget _cramCard(ThemeData theme) {
    final card = _current!;
    final vc = VoyagerColors.of(context);
    Widget face(String text, {bool accent = false}) => Container(
      width: 480,
      constraints: const BoxConstraints(minHeight: 280),
      padding: const EdgeInsets.all(28),
      decoration: BoxDecoration(
        color: theme.cardTheme.color ?? theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: vc.strongHairline),
        boxShadow: vc.surfaceShadow(),
      ),
      child: Center(
        child: StudyRichText(
          text,
          textAlign: TextAlign.center,
          style: theme.textTheme.headlineSmall?.copyWith(
            color: accent ? theme.colorScheme.primary : theme.colorScheme.onSurface,
          ),
        ),
      ),
    );

    return StudyFlipCard(
      controller: _flipController,
      onFlipChanged: (back) => setState(() => _showingBack = back),
      front: face(card.frontText),
      back: face(card.backText, accent: true),
    );
  }
}

class _BucketProgressBar extends StatelessWidget {
  const _BucketProgressBar({
    required this.bucket0,
    required this.bucket1,
    required this.bucket2,
  });

  final int bucket0;
  final int bucket1;
  final int bucket2;

  @override
  Widget build(BuildContext context) {
    final total = bucket0 + bucket1 + bucket2;
    return ClipRRect(
      borderRadius: BorderRadius.circular(4),
      child: SizedBox(
        height: 8,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final w = constraints.maxWidth;
            double widthFor(int n) => total == 0 ? 0 : w * n / total;
            return Row(
              children: [
                Container(width: widthFor(bucket0), color: _kBucketFailColor),
                Container(width: widthFor(bucket1), color: _kBucketMidColor),
                Container(width: widthFor(bucket2), color: _kBucketDoneColor),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _CramComplete extends StatelessWidget {
  const _CramComplete({required this.onDone});

  final VoidCallback onDone;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(PhosphorIconsRegular.checkCircle, size: 48, color: theme.colorScheme.primary),
          const SizedBox(height: 16),
          Text('All cards mastered', style: theme.textTheme.titleLarge),
          const SizedBox(height: 20),
          GlassButton(onPressed: onDone, label: 'Back to deck'),
        ],
      ),
    );
  }
}

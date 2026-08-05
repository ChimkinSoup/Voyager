import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/theme/voyager_theme.dart';
import 'package:voyager/core/utils/ids.dart';
import 'package:voyager/core/widgets/glass_button.dart';
import 'package:voyager/domain/models/study_models.dart';
import 'package:voyager/domain/services/study_srs_engine.dart';
import 'package:voyager/features/study/study_flip_card.dart';
import 'package:voyager/features/study/study_keyboard_shortcuts.dart';
import 'package:voyager/features/study/study_rich_text.dart';

/// Distraction-free full-screen SRS review: only the active flashcard and
/// its grading buttons — no roster, no admin chrome. Grading a card
/// persists its new interval/ease and logs a real review event; a card
/// re-graded back to a same-day interval (Fail, or Hard while still new)
/// re-queues to the end of this session so it can be tried again before
/// the session ends.
class StudySessionPage extends ConsumerStatefulWidget {
  const StudySessionPage({super.key, required this.deckId});

  final String deckId;

  @override
  ConsumerState<StudySessionPage> createState() => _StudySessionPageState();
}

class _StudySessionPageState extends ConsumerState<StudySessionPage> {
  final _flipController = StudyFlipController();
  List<StudyCard>? _queue;
  bool _showingBack = false;
  bool _grading = false;

  void _ensureQueue(List<StudyCard> allCards) {
    if (_queue != null) return;
    final now = DateTime.now().toUtc();
    _queue = allCards.where((c) => !c.dueAt.isAfter(now)).toList()
      ..sort((a, b) => a.dueAt.compareTo(b.dueAt));
  }

  void _handleFlip() {
    _flipController.flip();
  }

  Future<void> _grade(StudyGrade grade) async {
    final queue = _queue;
    if (queue == null || queue.isEmpty || _grading) return;
    setState(() => _grading = true);

    final current = queue.first;
    final graded = gradeStudyCard(current, grade);
    final repo = ref.read(studyRepositoryProvider);
    final remoteSync = ref.read(remoteSyncServiceProvider);
    await repo.upsertCard(graded);
    remoteSync.pushStudyCard(graded);
    final log = StudyReviewLog(
      id: newId(),
      cardId: graded.id,
      grade: grade,
      reviewedAt: DateTime.now().toUtc(),
    );
    await repo.logReview(log);
    remoteSync.pushStudyReviewLog(log);

    setState(() {
      final next = [...queue]..removeAt(0);
      if (graded.interval <= 0) next.add(graded);
      _queue = next;
      _showingBack = false;
      _grading = false;
    });
    _flipController.showFront();

    ref.invalidate(studyCardsProvider(widget.deckId));
    ref.invalidate(studyDeckStatsProvider(widget.deckId));
    ref.invalidate(studyStatsProvider);
  }

  @override
  Widget build(BuildContext context) {
    final cardsAsync = ref.watch(studyCardsProvider(widget.deckId));
    final cards = cardsAsync.valueOrNull;
    if (cards != null) _ensureQueue(cards);
    final queue = _queue;

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: SafeArea(
        child: queue == null
            ? const Center(child: CircularProgressIndicator())
            : queue.isEmpty
            ? _SessionComplete(onDone: () => Navigator.of(context).pop())
            : StudyKeyboardShortcuts(
                onSpace: _handleFlip,
                showingBack: _showingBack,
                onGrade: _grade,
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
                          _SessionCounter(queue: queue),
                          const Spacer(),
                          const SizedBox(width: 48),
                        ],
                      ),
                      Expanded(
                        child: Center(
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 520, maxHeight: 340),
                            child: StudyFlipCard(
                              controller: _flipController,
                              onFlipChanged: (back) => setState(() => _showingBack = back),
                              front: _SessionCardFace(
                                text: queue.first.frontText,
                                onTap: _handleFlip,
                              ),
                              back: _SessionCardFace(
                                text: queue.first.backText,
                                accent: true,
                                onTap: _handleFlip,
                              ),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 24),
                      _GradingRow(
                        card: queue.first,
                        enabled: _showingBack && !_grading,
                        onGrade: _grade,
                      ),
                    ],
                  ),
                ),
              ),
      ),
    );
  }
}

class _SessionCardFace extends StatelessWidget {
  const _SessionCardFace({required this.text, required this.onTap, this.accent = false});

  final String text;
  final VoidCallback onTap;
  final bool accent;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final vc = VoyagerColors.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(28),
      decoration: BoxDecoration(
        color: theme.cardTheme.color ?? theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: vc.strongHairline),
        boxShadow: vc.surfaceShadow(),
      ),
      child: Center(
        child: SingleChildScrollView(
          child: StudyRichText(
            text,
            textAlign: TextAlign.center,
            style: theme.textTheme.headlineSmall?.copyWith(
              color: accent ? theme.colorScheme.primary : theme.colorScheme.onSurface,
            ),
          ),
        ),
      ),
    );
  }
}

class _SessionCounter extends StatelessWidget {
  const _SessionCounter({required this.queue});

  final List<StudyCard> queue;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final newCount = queue.where((c) => c.isNew).length;
    final learning = queue.where((c) => !c.isNew && c.isLearning).length;
    final review = queue.length - newCount - learning;

    Widget chip(String label, int count, Color color) => Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6),
      child: Text(
        '$label $count',
        style: theme.textTheme.labelMedium?.copyWith(color: color, fontWeight: FontWeight.w600),
      ),
    );

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        chip('New', newCount, theme.colorScheme.onSurface.withValues(alpha: 0.5)),
        chip('Learning', learning, const Color(0xFFE0A63A)),
        chip('Review', review, const Color(0xFF5C8BE0)),
      ],
    );
  }
}

class _GradingRow extends StatelessWidget {
  const _GradingRow({required this.card, required this.enabled, required this.onGrade});

  final StudyCard card;
  final bool enabled;
  final ValueChanged<StudyGrade> onGrade;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    Widget button(String label, StudyGrade grade, Color color) {
      final result = applyStudyGrade(interval: card.interval, ease: card.ease, grade: grade);
      return Expanded(
        child: Column(
          children: [
            Text(
              formatStudyInterval(result.interval),
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
              ),
            ),
            const SizedBox(height: 4),
            GlassButton(
              onPressed: enabled ? () => onGrade(grade) : null,
              label: label,
              color: color,
              padding: const EdgeInsets.symmetric(vertical: 12),
            ),
          ],
        ),
      );
    }

    return Row(
      children: [
        button('Fail', StudyGrade.fail, theme.colorScheme.error),
        const SizedBox(width: 10),
        button('Hard', StudyGrade.hard, const Color(0xFFE0A63A)),
        const SizedBox(width: 10),
        button('Good', StudyGrade.good, const Color(0xFF5C8BE0)),
        const SizedBox(width: 10),
        button('Easy', StudyGrade.easy, const Color(0xFF4CAF7D)),
      ],
    );
  }
}

class _SessionComplete extends StatelessWidget {
  const _SessionComplete({required this.onDone});

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
          Text('Session complete', style: theme.textTheme.titleLarge),
          const SizedBox(height: 20),
          GlassButton(onPressed: onDone, label: 'Back to deck'),
        ],
      ),
    );
  }
}

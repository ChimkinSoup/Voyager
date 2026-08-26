import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/constants/leetcode_constants.dart';
import 'package:voyager/core/motion/motion.dart';
import 'package:voyager/core/widgets/contextual_popover.dart';
import 'package:voyager/core/widgets/glass_button.dart';
import 'package:voyager/core/widgets/selector_pill.dart';
import 'package:voyager/core/widgets/voyager_text_field.dart';
import 'package:voyager/domain/models/enums.dart';
import 'package:voyager/domain/models/leetcode_models.dart';
import 'package:voyager/domain/models/settings_models.dart';
import 'package:voyager/domain/services/leetcode_srs_engine.dart';
import 'package:voyager/features/leetcode/leetcode_actions.dart';
import 'package:voyager/features/leetcode/leetcode_cram_page.dart';
import 'package:voyager/features/leetcode/leetcode_mini_flashcard.dart';
import 'package:voyager/features/leetcode/leetcode_providers.dart';
import 'package:voyager/features/leetcode/leetcode_session_page.dart';

const _kDeckGrid = SliverGridDelegateWithMaxCrossAxisExtent(
  maxCrossAxisExtent: 220,
  mainAxisSpacing: 12,
  crossAxisSpacing: 12,
  childAspectRatio: 0.95,
);

/// The Review Deck: the administrative view over every tracked problem —
/// counts, Study/Cram entry points, a search + filter control bar, and the
/// scrollable grid of miniature flashcards. The full-size card lives inside a
/// session; this page is where you browse and pick.
class LeetCodeReviewDeck extends ConsumerStatefulWidget {
  const LeetCodeReviewDeck({super.key});

  @override
  ConsumerState<LeetCodeReviewDeck> createState() => _LeetCodeReviewDeckState();
}

class _LeetCodeReviewDeckState extends ConsumerState<LeetCodeReviewDeck> {
  /// Problems the user turned over by hand, mapped to the baseline face that
  /// was in force when they did it — normally the front, or the back for a
  /// problem the search only matched there.
  ///
  /// Turning cards over is a browsing gesture, not a mode: flips pile up as
  /// the user works through the grid and are only dropped when the page goes
  /// away. Recording *which* baseline the override was made against is what
  /// retires it once the search moves that baseline: an override only stands
  /// while the question it answered is still the one being asked.
  final Map<String, bool> _flipped = {};

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final problemsAsync = ref.watch(leetcodeProblemsProvider);
    final problems = problemsAsync.valueOrNull ?? const <LeetCodeProblem>[];
    // Distinct from "tracked nothing yet": before the query resolves the deck
    // knows nothing about the library, and saying it is empty is a claim it
    // cannot support.
    final loading = problemsAsync.isLoading && !problemsAsync.hasValue;
    final query = ref.watch(leetCodeDeckSearchQueryProvider);
    final difficulties = ref.watch(leetCodeDeckDifficultyFilterProvider);
    final tagFilter = ref.watch(leetCodeDeckTagFilterProvider);

    // Matched as one phrase, so the tiles highlight it as one phrase too.
    final keywords = query.trim().isEmpty ? const <String>[] : [query.trim()];
    final needle = query.trim().toLowerCase();
    // Folded once per library revision rather than per problem per keystroke.
    final searchIndex = ref.watch(leetCodeDeckSearchIndexProvider);
    LeetCodeSearchText textFor(LeetCodeProblem p) =>
        searchIndex[p.id] ?? leetCodeSearchTextFor(p);
    final filtered = problems.where((p) {
      if (difficulties.isNotEmpty && !difficulties.contains(p.difficulty)) {
        return false;
      }
      if (!tagFilter.every(p.tags.contains)) return false;
      if (needle.isEmpty) return true;
      final text = textFor(p);
      return text.front.contains(needle) || text.back.contains(needle);
    }).toList();
    final ordered = sortLeetCodeProblemsByMastery(filtered);

    // The counts describe what a session would actually work through, so they
    // follow the filter rather than the whole library.
    final dueCount = filtered.where((p) => p.isDue()).length;
    final filtering =
        needle.isNotEmpty || difficulties.isNotEmpty || tagFilter.isNotEmpty;
    final visibleIds = {for (final p in filtered) p.id};

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AnimatedOpacity(
            opacity: loading ? 0 : 1,
            duration: VoyagerMotion.crossfade,
            child: Text(
              '${filtered.length} problem${filtered.length == 1 ? '' : 's'}'
              '${filtering ? ' of ${problems.length}' : ''} · $dueCount due',
              style: theme.textTheme.bodyMedium?.copyWith(
                // Legible by contrast and weight rather than a pale grey —
                // this sits over the app's live background.
                color: theme.colorScheme.onSurface.withValues(alpha: 0.75),
                fontWeight: FontWeight.w500,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: GlassButton(
                  tooltip: dueCount == 0
                      ? 'Nothing due for review'
                      : 'Review what is due, scheduled by SRS',
                  onPressed: dueCount == 0
                      ? null
                      : () => Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) =>
                                LeetCodeSessionPage(problemIds: visibleIds),
                          ),
                        ),
                  icon: const Icon(PhosphorIconsRegular.playCircle),
                  label: 'Study',
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: GlassButton(
                  tooltip: 'Drill every problem shown, ignoring the schedule',
                  onPressed: filtered.isEmpty
                      ? null
                      : () => Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) =>
                                LeetCodeCramPage(problemIds: visibleIds),
                          ),
                        ),
                  icon: const Icon(PhosphorIconsRegular.lightning),
                  label: 'Cram',
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          _ControlBar(problems: problems),
          const SizedBox(height: 4),
          Expanded(
            child: loading
                ? const _DeckSkeleton()
                : ordered.isEmpty
                ? _EmptyDeck(
                    filtering: problems.isNotEmpty,
                    onClearFilters: () {
                      ref.read(leetCodeDeckSearchQueryProvider.notifier).state =
                          '';
                      ref
                              .read(leetCodeDeckDifficultyFilterProvider.notifier)
                              .state =
                          {};
                      ref.read(leetCodeDeckTagFilterProvider.notifier).state =
                          {};
                    },
                  )
                : GridView.builder(
                    padding: const EdgeInsets.only(top: 8, bottom: 96),
                    gridDelegate: _kDeckGrid,
                    itemCount: ordered.length,
                    itemBuilder: (context, index) {
                      final problem = ordered[index];
                      // A back-only search hit turns its tile around, so
                      // _flipped records the difference from that baseline
                      // rather than the face itself — otherwise flipping such
                      // a tile to the front would immediately snap it back.
                      //
                      // The override only counts while the baseline it was
                      // made against still holds. Once the search moves that
                      // baseline it has re-answered the question the flip was
                      // answering, and the search wins.
                      final backOnly = leetCodeMatchesBackOnly(
                        textFor(problem),
                        keywords,
                      );
                      final baseline = _flipped[problem.id];
                      final overridden =
                          baseline != null && baseline == backOnly;
                      return LeetCodeMiniFlashcard(
                        key: ValueKey(problem.id),
                        problem: problem,
                        keywords: keywords,
                        showBack: backOnly != overridden,
                        onFlipped: (showingBack) => setState(() {
                          if (showingBack == backOnly) {
                            _flipped.remove(problem.id);
                          } else {
                            _flipped[problem.id] = backOnly;
                          }
                        }),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

/// Card-shaped stand-ins for the grid while the library loads, so the deck
/// does not claim to be empty before it has looked. Deliberately static — a
/// looping shimmer is the slow oscillation reduced-motion guidance asks
/// interfaces to keep off screen.
class _DeckSkeleton extends StatelessWidget {
  const _DeckSkeleton();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final wash = theme.colorScheme.onSurface.withValues(alpha: 0.06);
    return IgnorePointer(
      child: GridView.builder(
        padding: const EdgeInsets.only(top: 8, bottom: 96),
        gridDelegate: _kDeckGrid,
        itemCount: 6,
        itemBuilder: (context, index) => Card(
          margin: EdgeInsets.zero,
          clipBehavior: Clip.antiAlias,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(18),
            side: BorderSide(color: wash, width: 1.5),
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Container(height: 10, width: 40, color: wash),
                Container(height: 12, color: wash),
                Container(height: 10, width: 64, color: wash),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Offers the action instead of naming the control that performs it.
class _EmptyDeck extends ConsumerWidget {
  const _EmptyDeck({required this.filtering, required this.onClearFilters});

  /// True when problems exist but the active filters hide all of them — a
  /// different problem from having tracked nothing, with a different way out.
  final bool filtering;
  final VoidCallback onClearFilters;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            filtering ? 'No matches' : 'Nothing tracked yet',
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            filtering
                ? 'No problems match the current filters.'
                : 'Track a problem to start reviewing it on a schedule.',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurface.withValues(alpha: 0.7),
            ),
          ),
          const SizedBox(height: 20),
          filtering
              ? GlassButton(
                  onPressed: onClearFilters,
                  icon: const Icon(PhosphorIconsRegular.x),
                  label: 'Clear filters',
                )
              : GlassButton(
                  onPressed: () => startLeetCodeTrackFlow(context, ref),
                  icon: const Icon(PhosphorIconsRegular.plus),
                  label: 'Track a problem',
                ),
        ],
      ),
    );
  }
}

/// Search field plus the two LeetCode-native narrowings: difficulty and tag.
/// No import button — problems come from the Track flow, not a JSON blob —
/// and no reverse/multi-select, which a deck of one-sided problems has no
/// use for.
class _ControlBar extends ConsumerStatefulWidget {
  const _ControlBar({required this.problems});

  final List<LeetCodeProblem> problems;

  @override
  ConsumerState<_ControlBar> createState() => _ControlBarState();
}

class _ControlBarState extends ConsumerState<_ControlBar> {
  /// The field is a view of the query provider rather than a one-way writer
  /// into it. Uncontrolled, it could push text out but nothing could push text
  /// back in — so "Clear filters" un-filtered the grid while the box went on
  /// displaying the query that had emptied it, and the next keystroke appended
  /// to that invisible-but-live text.
  late final TextEditingController _search = TextEditingController(
    text: ref.read(leetCodeDeckSearchQueryProvider),
  );

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final difficulties = ref.watch(leetCodeDeckDifficultyFilterProvider);
    final tagFilter = ref.watch(leetCodeDeckTagFilterProvider);

    // Adopt any change made from outside the field — "Clear filters" is the
    // only one today. The inequality guard is what keeps the field's own
    // onChanged from bouncing back through here and resetting the caret
    // mid-word.
    ref.listen<String>(leetCodeDeckSearchQueryProvider, (_, next) {
      if (_search.text != next) _search.text = next;
    });

    void toggleDifficulty(LeetCodeDifficulty difficulty) {
      final next = {...difficulties};
      if (!next.remove(difficulty)) next.add(difficulty);
      ref.read(leetCodeDeckDifficultyFilterProvider.notifier).state = next;
    }

    return Row(
      children: [
        Expanded(
          child: VoyagerTextField(
            controller: _search,
            onChanged: (v) =>
                ref.read(leetCodeDeckSearchQueryProvider.notifier).state = v,
            decoration: const InputDecoration(
              hintText: 'Search problems',
              prefixIcon: Icon(PhosphorIconsRegular.magnifyingGlass, size: 18),
              isDense: true,
            ),
          ),
        ),
        const SizedBox(width: 8),
        for (final difficulty in LeetCodeDifficulty.values) ...[
          SelectorPill(
            dense: true,
            label: labelForLeetCodeDifficulty(difficulty),
            isActive: difficulties.contains(difficulty),
            accentColor: colorForLeetCodeDifficulty(difficulty),
            fillWhenActive: true,
            onTap: () => toggleDifficulty(difficulty),
          ),
          const SizedBox(width: 6),
        ],
        _TagFilterButton(problems: widget.problems, selected: tagFilter),
        if (tagFilter.isNotEmpty) ...[
          const SizedBox(width: 6),
          Text(
            '${tagFilter.length}',
            style: theme.textTheme.labelMedium?.copyWith(
              color: theme.colorScheme.primary,
            ),
          ),
        ],
        const SizedBox(width: 6),
        const _SessionDisplayButton(),
      ],
    );
  }
}

class _TagFilterButton extends ConsumerWidget {
  const _TagFilterButton({required this.problems, required this.selected});

  final List<LeetCodeProblem> problems;
  final Set<String> selected;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    // Only tags that are actually on a tracked problem — a filter that can
    // only ever return nothing isn't worth offering.
    final tags = {for (final p in problems) ...p.tags}.toList()..sort();

    return Builder(
      builder: (buttonContext) => GlassButton(
        dense: true,
        tooltip: 'Filter by tag',
        icon: const Icon(PhosphorIconsRegular.tag),
        color: selected.isEmpty ? null : theme.colorScheme.primary,
        onPressed: tags.isEmpty
            ? null
            : () => showContextualPopover<void>(
                context: context,
                buttonContext: buttonContext,
                width: 240,
                height: 320,
                builder: (_) => _TagFilterList(tags: tags),
              ),
      ),
    );
  }
}

/// One hide toggle: what it is called, whether it is on, and how to flip it.
/// The list of them is the menu, so adding a hideable part of the card is a
/// row here rather than another widget.
typedef _HideToggle = ({
  String label,
  bool value,
  AppSettings Function(AppSettings settings, bool value) apply,
});

List<_HideToggle> _hideToggles(AppSettings s) => [
  (
    label: 'Hide difficulty',
    value: s.leetCodeHideDifficulty,
    apply: (settings, v) => settings.copyWith(leetCodeHideDifficulty: v),
  ),
  (
    label: 'Hide tags',
    value: s.leetCodeHideTags,
    apply: (settings, v) => settings.copyWith(leetCodeHideTags: v),
  ),
  (
    label: 'Hide question name',
    value: s.leetCodeHideQuestionName,
    apply: (settings, v) => settings.copyWith(leetCodeHideQuestionName: v),
  ),
  (
    label: 'Hide description',
    value: s.leetCodeHideDescription,
    apply: (settings, v) => settings.copyWith(leetCodeHideDescription: v),
  ),
  (
    label: 'Hide examples',
    value: s.leetCodeHideExamples,
    apply: (settings, v) => settings.copyWith(leetCodeHideExamples: v),
  ),
  (
    label: 'Hide complexity',
    value: s.leetCodeHideComplexity,
    apply: (settings, v) => settings.copyWith(leetCodeHideComplexity: v),
  ),
  (
    label: 'Hide solution code',
    value: s.leetCodeHideCode,
    apply: (settings, v) => settings.copyWith(leetCodeHideCode: v),
  ),
];

/// Opens the session display menu — what a Study or Cram run leaves off the
/// card. Unlike the filters beside it these are settings rather than page
/// state: they persist, and they follow the account to another device.
class _SessionDisplayButton extends ConsumerWidget {
  const _SessionDisplayButton();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final settings = ref.watch(settingsProvider).valueOrNull;
    final hiding =
        settings != null && _hideToggles(settings).any((t) => t.value);

    return Builder(
      builder: (buttonContext) => GlassButton(
        dense: true,
        tooltip: 'What Study and Cram show on the card',
        icon: const Icon(PhosphorIconsRegular.gear),
        color: hiding ? theme.colorScheme.primary : null,
        onPressed: settings == null
            ? null
            : () => showContextualPopover<void>(
                context: context,
                buttonContext: buttonContext,
                width: 240,
                builder: (_) => const _SessionDisplayList(),
              ),
      ),
    );
  }
}

class _SessionDisplayList extends ConsumerWidget {
  const _SessionDisplayList();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final settings = ref.watch(settingsProvider).valueOrNull;
    if (settings == null) return const SizedBox.shrink();
    final toggles = _hideToggles(settings);

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
          child: Text(
            'Study & Cram',
            style: theme.textTheme.labelMedium?.copyWith(
              color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
            ),
          ),
        ),
        for (final toggle in toggles)
          InkWell(
            // Computed against the notifier's value at tap time rather than
            // against the settings captured when this menu was built: a second
            // tap that lands before the first has published would otherwise
            // write a delta against a base the first tap has already moved,
            // and silently undo it.
            onTap: () {
              final live = ref.read(settingsProvider).valueOrNull;
              if (live == null) return;
              // The captured `toggle.value` is exactly as stale as the
              // settings it came from, so the flag is re-read too.
              final current = _hideToggles(
                live,
              ).firstWhere((t) => t.label == toggle.label);
              ref
                  .read(settingsProvider.notifier)
                  .saveSettings(current.apply(live, !current.value));
            },
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(
                children: [
                  Icon(
                    toggle.value
                        ? PhosphorIconsFill.checkSquare
                        : PhosphorIconsRegular.square,
                    size: 16,
                    color: toggle.value
                        ? theme.colorScheme.primary
                        : theme.colorScheme.onSurface.withValues(alpha: 0.4),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      toggle.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyMedium,
                    ),
                  ),
                ],
              ),
            ),
          ),
        const SizedBox(height: 4),
      ],
    );
  }
}

class _TagFilterList extends ConsumerWidget {
  const _TagFilterList({required this.tags});

  final List<String> tags;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final selected = ref.watch(leetCodeDeckTagFilterProvider);

    void toggle(String tag) {
      final next = {...selected};
      if (!next.remove(tag)) next.add(tag);
      ref.read(leetCodeDeckTagFilterProvider.notifier).state = next;
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (selected.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
            child: GlassButton(
              dense: true,
              label: 'Clear ${selected.length}',
              icon: const Icon(PhosphorIconsRegular.x),
              onPressed: () =>
                  ref.read(leetCodeDeckTagFilterProvider.notifier).state = {},
            ),
          ),
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.symmetric(vertical: 4),
            itemCount: tags.length,
            itemBuilder: (context, index) {
              final tag = tags[index];
              final isOn = selected.contains(tag);
              return InkWell(
                onTap: () => toggle(tag),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 8,
                  ),
                  child: Row(
                    children: [
                      Icon(
                        isOn
                            ? PhosphorIconsFill.checkSquare
                            : PhosphorIconsRegular.square,
                        size: 16,
                        color: isOn
                            ? theme.colorScheme.primary
                            : theme.colorScheme.onSurface.withValues(
                                alpha: 0.4,
                              ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          tag,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodyMedium,
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

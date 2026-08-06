import 'package:flutter/material.dart';
import 'package:flutter_code_editor/flutter_code_editor.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/constants/leetcode_constants.dart';
import 'package:voyager/core/utils/ids.dart';
import 'package:voyager/core/widgets/glass_button.dart';
import 'package:voyager/core/widgets/glass_surface.dart';
import 'package:voyager/core/widgets/selector_pill.dart';
import 'package:voyager/core/widgets/voyager_text_field.dart';
import 'package:voyager/domain/models/enums.dart';
import 'package:voyager/domain/models/leetcode_api_models.dart';
import 'package:voyager/domain/models/leetcode_models.dart';
import 'package:voyager/features/leetcode/leetcode_code_field.dart';
import 'package:voyager/features/leetcode/leetcode_search_popover.dart';

/// Opens the "track a problem" modal. When [prefill] is given, the form
/// starts populated with that API result (e.g. the user's most recently
/// accepted submission) but every field stays manually editable. When
/// [existing] is given, the modal edits that problem in place instead of
/// creating a new one.
Future<bool> showLeetCodeTrackModal(
  BuildContext context,
  WidgetRef ref, {
  LeetCodeApiQuestion? prefill,
  LeetCodeProblem? existing,
}) async {
  // Modal bottom sheets cap out at 640px wide by default (Material 3's
  // BottomSheetThemeData default), which reads as a narrow drawer on a
  // desktop-sized window. This form has a lot of fields plus a code editor,
  // so it gets almost the full screen instead.
  final screenSize = MediaQuery.sizeOf(context);
  final saved = await showVoyagerSheet<bool>(
    context: context,
    constraints: BoxConstraints(
      maxWidth: screenSize.width * 0.96,
      maxHeight: screenSize.height * 0.96,
    ),
    builder: (ctx) => ProviderScope(
      parent: ProviderScope.containerOf(context),
      child: _TrackModal(prefill: prefill, existing: existing),
    ),
  );
  return saved ?? false;
}

class _TrackModal extends ConsumerStatefulWidget {
  const _TrackModal({this.prefill, this.existing});

  final LeetCodeApiQuestion? prefill;
  final LeetCodeProblem? existing;

  @override
  ConsumerState<_TrackModal> createState() => _TrackModalState();
}

class _TrackModalState extends ConsumerState<_TrackModal> {
  late final TextEditingController _titleController;
  late final TextEditingController _questionFrontendIdController;
  late final TextEditingController _tagsController;
  late final TextEditingController _algorithmController;
  late final TextEditingController _timeComplexityController;
  late final TextEditingController _spaceComplexityController;
  late final TextEditingController _explanationController;
  late final TextEditingController _notesController;
  late final CodeController _codeController;
  late LeetCodeDifficulty _difficulty;
  late String _codeLanguage;
  String? _titleSlug;
  String? _questionId;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final existing = widget.existing;
    final prefill = widget.prefill;

    _titleController = TextEditingController(
      text: existing?.title ?? prefill?.title ?? '',
    );
    _questionFrontendIdController = TextEditingController(
      text: existing?.questionFrontendId ?? prefill?.questionFrontendId ?? '',
    );
    _tagsController = TextEditingController(
      text: (existing?.tags ?? prefill?.topicTags ?? const [])
          .map((t) => '#$t')
          .join(' '),
    );
    _algorithmController = TextEditingController(
      text: existing?.algorithm ?? '',
    );
    _timeComplexityController = TextEditingController(
      text: existing?.timeComplexity ?? '',
    );
    _spaceComplexityController = TextEditingController(
      text: existing?.spaceComplexity ?? '',
    );
    _explanationController = TextEditingController(
      text: existing?.explanation ?? '',
    );
    _notesController = TextEditingController(text: existing?.notes ?? '');
    _codeLanguage = existing?.codeLanguage ?? 'python';
    _codeController = CodeController(text: existing?.code ?? '');
    _difficulty =
        existing?.difficulty ??
        prefill?.difficulty ??
        LeetCodeDifficulty.medium;
    _titleSlug = existing?.titleSlug ?? prefill?.titleSlug;
    _questionId = existing?.questionId ?? prefill?.questionId;
  }

  @override
  void dispose() {
    _titleController.dispose();
    _questionFrontendIdController.dispose();
    _tagsController.dispose();
    _algorithmController.dispose();
    _timeComplexityController.dispose();
    _spaceComplexityController.dispose();
    _explanationController.dispose();
    _notesController.dispose();
    _codeController.dispose();
    super.dispose();
  }

  List<String> get _parsedTags {
    final raw = _tagsController.text.split(RegExp(r'[\s,]+'));
    final seen = <String>{};
    for (final token in raw) {
      final tag = token.replaceAll('#', '').trim();
      if (tag.isNotEmpty) seen.add(tag);
    }
    return seen.toList();
  }

  Future<void> _openSearch(BuildContext buttonContext) async {
    final picked = await showLeetCodeSearchPopover(context, buttonContext, ref);
    if (picked == null || !mounted) return;
    setState(() {
      _titleController.text = picked.title;
      _questionFrontendIdController.text = picked.questionFrontendId;
      _tagsController.text = picked.topicTags.map((t) => '#$t').join(' ');
      _difficulty = picked.difficulty;
      _titleSlug = picked.titleSlug;
      _questionId = picked.questionId;
    });
  }

  Future<void> _save() async {
    final title = _titleController.text.trim();
    if (title.isEmpty || _saving) return;
    setState(() => _saving = true);

    final now = utcNow();
    final existing = widget.existing;
    final problem = LeetCodeProblem(
      id: existing?.id ?? newId(),
      createdAt: existing?.createdAt ?? now,
      updatedAt: now,
      version: existing == null ? 0 : existing.version + 1,
      title: title,
      questionId: _questionId,
      questionFrontendId: _questionFrontendIdController.text.trim().isEmpty
          ? null
          : _questionFrontendIdController.text.trim(),
      titleSlug: _titleSlug,
      difficulty: _difficulty,
      tags: _parsedTags,
      algorithm: _algorithmController.text.trim(),
      timeComplexity: _timeComplexityController.text.trim().isEmpty
          ? null
          : _timeComplexityController.text.trim(),
      spaceComplexity: _spaceComplexityController.text.trim().isEmpty
          ? null
          : _spaceComplexityController.text.trim(),
      explanation: _explanationController.text.trim(),
      codeLanguage: _codeLanguage,
      code: _codeController.text,
      notes: _notesController.text.trim().isEmpty
          ? null
          : _notesController.text.trim(),
      solvedAt: existing?.solvedAt ?? DateTime.now(),
    );

    final repo = ref.read(leetCodeRepositoryProvider);
    await repo.upsertProblem(problem);
    ref.read(remoteSyncServiceProvider).pushLeetCodeProblem(problem);
    ref.invalidate(leetcodeProblemsProvider);

    if (mounted) Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent = theme.colorScheme.primary;
    final canSave = _titleController.text.trim().isNotEmpty && !_saving;
    final viewInsets = MediaQuery.of(context).viewInsets.bottom;
    final screenHeight = MediaQuery.sizeOf(context).height;

    return SizedBox(
      height: screenHeight * 0.94,
      child: Padding(
        padding: EdgeInsets.only(bottom: viewInsets),
        child: SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 6, 20, 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Center(
                  child: Container(
                    width: 36,
                    height: 4,
                    margin: const EdgeInsets.only(bottom: 6),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.onSurfaceVariant.withValues(
                        alpha: 0.3,
                      ),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                Row(
                  children: [
                    Text(
                      widget.existing == null
                          ? 'Track a problem'
                          : 'Edit problem',
                      style: theme.textTheme.titleMedium,
                    ),
                    const Spacer(),
                    IconButton(
                      onPressed: Navigator.of(context).pop,
                      icon: const Icon(PhosphorIconsRegular.x, size: 18),
                      tooltip: 'Close',
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      flex: 3,
                      child: VoyagerTextField(
                        controller: _titleController,
                        accentColor: accent,
                        onChanged: (_) => setState(() {}),
                        decoration: const InputDecoration(
                          labelText: 'Problem name',
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: VoyagerTextField(
                        controller: _questionFrontendIdController,
                        accentColor: accent,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(labelText: 'ID'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Builder(
                      builder: (buttonContext) => IconButton(
                        onPressed: () => _openSearch(buttonContext),
                        icon: const Icon(
                          PhosphorIconsRegular.magnifyingGlass,
                          size: 20,
                        ),
                        tooltip: 'Search LeetCode',
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  children: [
                    for (final d in LeetCodeDifficulty.values)
                      SelectorPill(
                        dense: true,
                        label: labelForLeetCodeDifficulty(d),
                        isActive: _difficulty == d,
                        accentColor: colorForLeetCodeDifficulty(d),
                        fillWhenActive: true,
                        onTap: () => setState(() => _difficulty = d),
                      ),
                  ],
                ),
                const SizedBox(height: 16),
                VoyagerTextField(
                  controller: _tagsController,
                  accentColor: accent,
                  decoration: const InputDecoration(
                    labelText: 'Tags',
                    hintText: '#array #hash-table',
                  ),
                ),
                const SizedBox(height: 16),
                VoyagerTextField(
                  controller: _algorithmController,
                  accentColor: accent,
                  maxLines: 2,
                  decoration: const InputDecoration(
                    labelText: 'Algorithm',
                    hintText: 'Core approach in a sentence or two',
                  ),
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Expanded(
                      child: VoyagerTextField(
                        controller: _timeComplexityController,
                        accentColor: accent,
                        decoration: const InputDecoration(
                          labelText: 'Time',
                          hintText: 'O(n)',
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: VoyagerTextField(
                        controller: _spaceComplexityController,
                        accentColor: accent,
                        decoration: const InputDecoration(
                          labelText: 'Space',
                          hintText: 'O(1)',
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                VoyagerTextField(
                  controller: _explanationController,
                  accentColor: accent,
                  maxLines: 6,
                  minLines: 3,
                  decoration: const InputDecoration(
                    labelText: 'Explanation',
                    hintText: 'Walk through the logic in plain language',
                  ),
                ),
                const SizedBox(height: 16),
                Text('Code', style: theme.textTheme.labelLarge),
                const SizedBox(height: 8),
                LeetCodeCodeInput(
                  controller: _codeController,
                  language: _codeLanguage,
                  onLanguageChanged: (lang) =>
                      setState(() => _codeLanguage = lang),
                ),
                const SizedBox(height: 16),
                VoyagerTextField(
                  controller: _notesController,
                  accentColor: accent,
                  maxLines: 2,
                  decoration: const InputDecoration(
                    labelText: 'Notes',
                    hintText: 'Anything to remember for next time',
                  ),
                ),
                const SizedBox(height: 24),
                GlassButton(
                  onPressed: canSave ? _save : null,
                  label: widget.existing == null ? 'Save' : 'Save changes',
                  color: accent,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/constants/leetcode_constants.dart';
import 'package:voyager/core/widgets/contextual_popover.dart';
import 'package:voyager/core/widgets/voyager_text_field.dart';
import 'package:voyager/domain/models/leetcode_api_models.dart';

/// Opens a small popover with a title search field. Returns the picked
/// [LeetCodeApiQuestion], or `null` if dismissed without a pick.
Future<LeetCodeApiQuestion?> showLeetCodeSearchPopover(
  BuildContext context,
  BuildContext buttonContext,
  WidgetRef ref,
) {
  final accent = Theme.of(context).colorScheme.primary;
  return showContextualPopover<LeetCodeApiQuestion>(
    context: context,
    buttonContext: buttonContext,
    width: 320,
    height: 320,
    accentColor: accent,
    builder: (_) => ProviderScope(
      parent: ProviderScope.containerOf(context),
      child: const _SearchPopoverContent(),
    ),
  );
}

class _SearchPopoverContent extends ConsumerStatefulWidget {
  const _SearchPopoverContent();

  @override
  ConsumerState<_SearchPopoverContent> createState() => _SearchPopoverContentState();
}

class _SearchPopoverContentState extends ConsumerState<_SearchPopoverContent> {
  final _controller = TextEditingController();
  List<LeetCodeApiQuestion>? _results;
  bool _searching = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    final query = _controller.text.trim();
    if (query.isEmpty || _searching) return;
    setState(() => _searching = true);
    final results = await ref
        .read(leetCodeApiClientProvider)
        .searchByTitle(query);
    if (!mounted) return;
    setState(() {
      _results = results;
      _searching = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent = theme.colorScheme.primary;
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          VoyagerTextField(
            controller: _controller,
            autofocus: true,
            accentColor: accent,
            decoration: const InputDecoration(
              labelText: 'Search problems',
              hintText: 'Two Sum',
            ),
            onSubmitted: (_) => _search(),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: _searching
                ? const Center(
                    child: SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  )
                : _buildResults(theme),
          ),
        ],
      ),
    );
  }

  Widget _buildResults(ThemeData theme) {
    final results = _results;
    if (results == null) {
      return Center(
        child: Text(
          'Search by title',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      );
    }
    if (results.isEmpty) {
      return Center(
        child: Text(
          'No matches',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      );
    }
    return ListView.separated(
      itemCount: results.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (context, index) {
        final q = results[index];
        return ListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          title: Text(
            '${q.questionFrontendId}. ${q.title}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          trailing: Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: colorForLeetCodeDifficulty(q.difficulty)
                  .withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text(
              labelForLeetCodeDifficulty(q.difficulty),
              style: theme.textTheme.labelSmall?.copyWith(
                color: colorForLeetCodeDifficulty(q.difficulty),
              ),
            ),
          ),
          onTap: () => Navigator.of(context).pop(q),
        );
      },
    );
  }
}

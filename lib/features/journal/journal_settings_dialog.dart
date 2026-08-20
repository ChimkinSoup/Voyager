import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/widgets/glass_button.dart';
import 'package:voyager/core/widgets/voyager_dialog.dart';
import 'package:voyager/core/widgets/voyager_scroll_view.dart';
import 'package:voyager/domain/models/journal_models.dart';

/// Per-journal settings: which editor controls the journal shows, whether its
/// entries join the combined list, and whether the journal page opens into it.
///
/// Every toggle writes straight through — there is no Save button, matching
/// rename and change-colour, which also commit as soon as the user picks.
Future<void> showJournalSettingsDialog(
  BuildContext context,
  WidgetRef ref,
  Journal journal,
) {
  return showVoyagerDialog<void>(
    context: context,
    builder: (context) => _JournalSettingsDialog(journalId: journal.id),
  );
}

class _JournalSettingsDialog extends ConsumerWidget {
  const _JournalSettingsDialog({required this.journalId});

  final String journalId;

  Future<void> _saveJournal(WidgetRef ref, Journal updated) async {
    await ref.read(journalRepositoryProvider).upsertJournal(updated);
    ref.read(remoteSyncServiceProvider).pushJournal(updated);
    ref.invalidate(journalsProvider);
    await ref.read(journalsProvider.future);
  }

  /// Setting a default clears whichever journal held it before, because
  /// [AppSettings.defaultJournalId] is a single field — the exclusivity is
  /// structural rather than something the UI has to police.
  Future<void> _saveDefaultJournal(
    WidgetRef ref, {
    required bool isDefault,
  }) async {
    final settingsRepo = ref.read(settingsRepositoryProvider);
    final settings = await settingsRepo.getSettings();
    await settingsRepo.saveSettings(
      isDefault
          ? settings.copyWith(defaultJournalId: journalId)
          : settings.copyWith(clearDefaultJournalId: true),
    );
    ref.invalidate(settingsProvider);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final journal = ref
        .watch(journalsProvider)
        .valueOrNull
        ?.cast<Journal?>()
        .firstWhere((j) => j!.id == journalId, orElse: () => null);
    final settings = ref.watch(settingsProvider).valueOrNull;
    final theme = Theme.of(context);

    if (journal == null) {
      return AlertDialog(
        title: const Text('Journal settings'),
        content: const SizedBox(
          height: 96,
          child: Center(child: CircularProgressIndicator()),
        ),
        actions: [
          GlassButton(
            onPressed: () => Navigator.pop(context),
            label: 'Close',
            dense: true,
          ),
        ],
      );
    }

    final accent = Color(
      journal.colorValue ?? theme.colorScheme.primary.toARGB32(),
    );
    final defaultJournalId = settings?.defaultJournalId;
    final isDefault = defaultJournalId == journal.id;
    final currentDefault = defaultJournalId == null
        ? null
        : ref
              .watch(journalsProvider)
              .valueOrNull
              ?.cast<Journal?>()
              .firstWhere((j) => j!.id == defaultJournalId, orElse: () => null);
    final globalQuotesOff = settings?.showQuotes == false;

    return AlertDialog(
      title: Text('${journal.name} settings'),
      content: SizedBox(
        width: 420,
        // Scrollable rather than a bare Column: five switch rows plus their
        // explanatory subtitles outgrow a short window, and AlertDialog hands
        // its content whatever height is left over.
        child: VoyagerScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _toggle(
                context,
                accent: accent,
                title: 'Mood bar',
                subtitle:
                    'Hiding it leaves the mood on each entry untouched — turn it '
                    'back on and every value is still there.',
                value: journal.showMood,
                onChanged: (v) =>
                    _saveJournal(ref, journal.copyWith(showMood: v)),
              ),
              _toggle(
                context,
                accent: accent,
                title: 'Weather',
                value: journal.showWeather,
                onChanged: (v) =>
                    _saveJournal(ref, journal.copyWith(showWeather: v)),
              ),
              _toggle(
                context,
                accent: accent,
                title: 'Quotes',
                subtitle: globalQuotesOff
                    ? 'Quotes are off for every journal in Settings, so this has '
                          'no effect until you turn that back on.'
                    : null,
                value: journal.showQuotes,
                onChanged: (v) =>
                    _saveJournal(ref, journal.copyWith(showQuotes: v)),
              ),
              const Divider(height: 24),
              _toggle(
                context,
                accent: accent,
                title: 'Include in "All journals"',
                subtitle:
                    'Off keeps these entries out of the combined list. They stay '
                    'in search and analytics.',
                value: journal.includeInAllView,
                onChanged: (v) =>
                    _saveJournal(ref, journal.copyWith(includeInAllView: v)),
              ),
              _toggle(
                context,
                accent: accent,
                title: 'Default view',
                subtitle: isDefault
                    ? 'The journal page always opens here.'
                    : currentDefault != null
                    ? 'Currently: ${currentDefault.name}'
                    : 'No journal is the default — the page reopens wherever you '
                          'left it.',
                value: isDefault,
                onChanged: (v) => _saveDefaultJournal(ref, isDefault: v),
              ),
            ],
          ),
        ),
      ),
      actions: [
        GlassButton(
          onPressed: () => Navigator.pop(context),
          label: 'Close',
          dense: true,
        ),
      ],
    );
  }

  Widget _toggle(
    BuildContext context, {
    required Color accent,
    required String title,
    required bool value,
    required ValueChanged<bool> onChanged,
    String? subtitle,
  }) {
    return SwitchListTile(
      contentPadding: EdgeInsets.zero,
      activeThumbColor: accent,
      title: Text(title),
      subtitle: subtitle == null
          ? null
          : Text(subtitle, style: Theme.of(context).textTheme.bodySmall),
      value: value,
      onChanged: onChanged,
    );
  }
}

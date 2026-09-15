// Every dialog and sheet has to fit the smallest window the desktop build
// allows — the companion to narrow_window_overflow_test.dart, which does
// pages. Modals open over the whole 720x520 window rather than the page
// area. Each is opened through its public show function, its segmented
// views pressed, and every overflow collected.
//
// Openers that edit an existing row take the first one from the database;
// on the empty database they are skipped, so sweep real data too (see
// narrow_window_harness.dart).

import 'dart:async';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/theme/voyager_theme.dart';
import 'package:voyager/core/widgets/confirm_dialog.dart';
import 'package:voyager/core/widgets/create_name_color_dialog.dart';
import 'package:voyager/core/widgets/datetime_picker_dialog.dart';
import 'package:voyager/core/widgets/prompt_name_dialog.dart';
import 'package:voyager/domain/models/contribution_room_models.dart';
import 'package:voyager/domain/models/enums.dart';
import 'package:voyager/features/calendar/calendar_manage_sheet.dart';
import 'package:voyager/features/finance/finance_allocate_modal.dart';
import 'package:voyager/features/finance/finance_asset_modal.dart';
import 'package:voyager/features/finance/finance_budget_modal.dart';
import 'package:voyager/features/finance/finance_category_modal.dart';
import 'package:voyager/features/finance/finance_contribution_room_modal.dart';
import 'package:voyager/features/finance/finance_goal_modal.dart';
import 'package:voyager/features/finance/finance_room_event_modal.dart';
import 'package:voyager/features/finance/finance_subscription_modal.dart';
import 'package:voyager/features/finance/finance_transaction_modal.dart';
import 'package:voyager/features/jobs/jobs_manage_sheet.dart';
import 'package:voyager/features/jobs/jobs_track_modal.dart';
import 'package:voyager/features/journal/journal_entry_actions.dart';
import 'package:voyager/features/journal/journal_manage_sheet.dart';
import 'package:voyager/features/journal/journal_settings_dialog.dart';
import 'package:voyager/features/leetcode/leetcode_track_modal.dart';
import 'package:voyager/features/rankings/rankings_category_dialog.dart';
import 'package:voyager/features/rankings/rankings_child_list.dart';
import 'package:voyager/features/rankings/rankings_manage_sheet.dart';
import 'package:voyager/features/rankings/rankings_media_grid.dart';
import 'package:voyager/features/settings/custom_quotes_dialog.dart';
import 'package:voyager/features/settings/dictionary_dialog.dart';
import 'package:voyager/features/settings/job_experience_snippets_dialog.dart';
import 'package:voyager/features/settings/key_binding_dialog.dart';
import 'package:voyager/features/settings/media_storage_dialog.dart';
import 'package:voyager/features/settings/snippets_dialog.dart';
import 'package:voyager/features/shell/weather_forecast_sheet.dart';
import 'package:voyager/features/study/study_card_editor_modal.dart';
import 'package:voyager/features/study/study_import_text_modal.dart';
import 'package:voyager/features/study/study_link_deck_modal.dart';
import 'package:voyager/features/study/study_linked_deck.dart';
import 'package:voyager/features/study/study_move_destination_modal.dart';
import 'package:voyager/features/study/study_move_modal.dart';
import 'package:voyager/features/study/study_name_modal.dart';
import 'package:voyager/features/todo/todo_manage_sheet.dart';
import 'package:voyager/features/todo/todo_settings_dialog.dart';
import 'package:voyager/features/workout/workout_name_modal.dart';
import 'package:voyager/features/workout/workout_target_editor.dart';

import 'narrow_window_harness.dart';

const _windowWidths = <double>[720, 1000];

/// Opens one modal and returns its future without awaiting it — in a record,
/// since an async function would flatten it and wait for the modal to close —
/// or null when the database has nothing for it to edit.
typedef _Opener =
    Future<(Future<Object?>,)?> Function(BuildContext context, WidgetRef ref);

Future<T?> _first<T>(Future<List<T>> list) async {
  final items = await list;
  return items.isEmpty ? null : items.first;
}

final _openers = <String, _Opener>{
  'confirm': (c, r) async => (
    showConfirmDialog(
      c,
      title: 'Delete this journal?',
      message: 'Its entries go with it. This cannot be undone.',
    ),
  ),
  'delete container': (c, r) async => (
    showDeleteContainerDialog(
      c,
      title: 'Delete this list?',
      message: 'Move its tasks to another list first?',
    ),
  ),
  'recurrence scope': (c, r) async => (
    showRecurrenceScopeDialog(
      c,
      title: 'Delete recurring event',
      isDelete: true,
    ),
  ),
  'name and color': (c, r) async => (
    showCreateNameColorDialog(
      c,
      title: 'New calendar',
      palette: r.read(colorPaletteProvider),
      initialColor: r.read(colorPaletteProvider).first,
    ),
  ),
  'date and time': (c, r) async => (
    showDateTimePickerDialog(c, initialDateTime: DateTime(2026, 9, 30, 12, 59)),
  ),
  'time range': (c, r) async => (
    showTimeRangePickerDialog(
      c,
      initialStart: const TimeOfDay(hour: 9, minute: 0),
      initialEnd: const TimeOfDay(hour: 17, minute: 30),
    ),
  ),
  'prompt name': (c, r) async => (showPromptNameDialog(c, title: 'Rename'),),
  'calendar manage': (c, r) async => (showCalendarManageSheet(c, r),),
  'finance asset': (c, r) async => (showAssetModal(c, r),),
  'finance budget': (c, r) async => (showBudgetModal(c, r),),
  'finance category': (c, r) async => (showCategoryModal(c, r),),
  'finance goal': (c, r) async => (showGoalModal(c, r),),
  'finance subscription': (c, r) async => (showSubscriptionModal(c, r),),
  'finance transaction': (c, r) async => (showFinanceTransactionModal(c, r),),
  'finance allocate': (c, r) async {
    final goal = await _first(r.read(savingsGoalsProvider.future));
    return goal == null ? null : (showAllocateModal(c, r, goal: goal),);
  },
  'finance contribution room': (c, r) async {
    final asset = await _first(r.read(assetsProvider.future));
    return asset == null
        ? null
        : (showContributionRoomModal(c, r, asset: asset),);
  },
  'finance room contribution': (c, r) async {
    final asset = await _first(r.read(assetsProvider.future));
    return asset == null
        ? null
        : (
            showRoomCashEventModal(
              c,
              r,
              asset: asset,
              kind: RoomEventKind.contribution,
            ),
          );
  },
  'finance room transfer': (c, r) async {
    final asset = await _first(r.read(assetsProvider.future));
    return asset == null ? null : (showRoomTransferModal(c, r, from: asset),);
  },
  'jobs manage': (c, r) async => (showJobsManageSheet(c, r),),
  'jobs track': (c, r) async => (showJobsTrackModal(c, r),),
  'journal manage': (c, r) async => (showJournalManageSheet(c, r),),
  'journal settings': (c, r) async {
    final journal = await _first(r.read(journalsProvider.future));
    return journal == null ? null : (showJournalSettingsDialog(c, r, journal),);
  },
  'journal move entry': (c, r) async {
    final journals = await r.read(journalsProvider.future);
    return journals.isEmpty
        ? null
        : (
            showMoveToJournalDialog(
              c,
              journals: journals,
              currentJournalId: journals.first.id,
            ),
          );
  },
  'leetcode track': (c, r) async => (showLeetCodeTrackModal(c, r),),
  'rankings category': (c, r) async => (showRankingCategoryDialog(c),),
  'rankings manage': (c, r) async => (showRankingsManageSheet(c, r),),
  'rankings child editor': (c, r) async {
    final repo = r.read(rankingRepositoryProvider);
    final category = await _first(repo.listCategories());
    if (category == null) return null;
    final child = await _first(repo.listChildrenOfCategory(category.id));
    return child == null
        ? null
        : (showRankingChildEditor(c, child: child, category: category),);
  },
  'rankings media grid': (c, r) async {
    final repo = r.read(rankingRepositoryProvider);
    final category = await _first(repo.listCategories());
    if (category == null) return null;
    final parent = await _first(repo.listParents(category.id));
    return parent == null
        ? null
        : (
            showRankingsMediaGrid(
              c,
              r,
              documentId: parent.id,
              title: parent.title,
            ),
          );
  },
  'custom quotes': (c, r) async => (showCustomQuotesDialog(c),),
  'dictionary': (c, r) async => (showDictionaryDialog(c),),
  'experience snippets': (c, r) async => (showJobExperienceSnippetsDialog(c),),
  'experience editor': (c, r) async => (showJobExperienceEditor(c),),
  'key binding': (c, r) async =>
      (showKeyBindingDialog(c, title: 'Calendar: navigate left'),),
  'media storage': (c, r) async => (showMediaStorageDialog(c),),
  'snippets': (c, r) async => (showSnippetsDialog(c),),
  'weather forecast': (c, r) async => (showWeatherForecastSheet(c),),
  'study name': (c, r) async => (showStudyNameModal(c, title: 'New deck'),),
  'study move destination': (c, r) async => (
    showStudyMoveDestinationModal(
      c,
      r,
      title: 'Move to…',
      onSelect: (_) async {},
    ),
  ),
  'study card editor': (c, r) async {
    final deck = await _first(r.read(studyRepositoryProvider).listDecks());
    return deck == null
        ? null
        : (showStudyCardEditorModal(c, r, deckId: deck.id),);
  },
  'study import text': (c, r) async {
    final deck = await _first(r.read(studyRepositoryProvider).listDecks());
    return deck == null ? null : (showStudyImportTextModal(c, r, deck.id),);
  },
  'study linked deck': (c, r) async {
    final deck = await _first(r.read(studyRepositoryProvider).listDecks());
    return deck == null
        ? null
        : (showStudyLinkedDeckSheet(c, deckId: deck.id),);
  },
  'study link deck': (c, r) async {
    final deck = await _first(r.read(studyRepositoryProvider).listDecks());
    return deck == null
        ? null
        : (showStudyLinkDeckModal(c, parentDeckId: deck.id),);
  },
  'study move cards': (c, r) async {
    final repo = r.read(studyRepositoryProvider);
    final deck = await _first(repo.listDecks());
    if (deck == null) return null;
    final cards = await repo.listCards(deck.id);
    return cards.isEmpty
        ? null
        : (showStudyMoveModal(c, r, cardIds: [for (final x in cards) x.id]),);
  },
  'todo list manage': (c, r) async => (showTodoListManageSheet(c, r),),
  'todo list settings': (c, r) async {
    final list = await _first(r.read(todoListsProvider.future));
    return list == null ? null : (showTodoListSettingsDialog(c, r, list),);
  },
  'workout name': (c, r) async => (showWorkoutNameModal(c, title: 'New plan'),),
  'exercise target': (c, r) async {
    final exercise = await _first(r.read(exercisesProvider.future));
    return exercise == null
        ? null
        : (
            showExerciseTargetEditor(
              c,
              exercise: exercise,
              unit: WeightUnit.lb,
            ),
          );
  },
};

class _Host extends ConsumerWidget {
  const _Host();

  @override
  Widget build(BuildContext context, WidgetRef ref) => const SizedBox.expand();
}

void main() {
  setUpAll(() => driftRuntimeOptions.dontWarnAboutMultipleDatabases = true);

  for (final MapEntry(key: name, value: open) in _openers.entries) {
    testWidgets(
      'the $name modal fits the minimum window',
      variant: TargetPlatformVariant.only(TargetPlatform.windows),
      semanticsEnabled: false,
      (tester) async {
        addTearDown(tester.view.reset);
        await loadRealFonts(tester);

        final found = <String>[];
        var skipped = false;
        for (final width in _windowWidths) {
          tester.view.physicalSize = Size(width, minWindowSize.height);
          tester.view.devicePixelRatio = 1.0;
          final (db, container) = await openHarnessContainer();
          try {
            final overflows = await collectOverflows(() async {
              await tester.pumpWidget(
                UncontrolledProviderScope(
                  container: container,
                  child: MaterialApp(
                    theme: VoyagerTheme.forMode(AppThemeMode.dark),
                    home: const Scaffold(body: _Host()),
                  ),
                ),
              );
              await settle(tester);
              final element = tester.element(find.byType(_Host));
              final modal = await tester.runAsync(
                () => open(element, element as WidgetRef),
              );
              if (modal == null) {
                skipped = true;
                return;
              }
              unawaited(modal.$1);
              await settle(tester);
              await visitSegments(tester);
              Navigator.of(
                element,
                rootNavigator: true,
              ).popUntil((route) => route.isFirst);
              await settle(tester);
              // Openers run on the real event loop (runAsync), so what they
              // do after the modal closes — invalidating providers through
              // the host's ref — only runs here. Let it, before unmounting.
              await tester.runAsync(() => modal.$1);
              await tester.pumpWidget(const SizedBox.shrink());
              await tester.pump(const Duration(seconds: 1));
            });
            for (final overflow in overflows) {
              found.add('${width.toInt()}px: $overflow');
            }
          } finally {
            container.dispose();
            await db.close();
          }
          if (skipped) break;
        }
        if (skipped) {
          markTestSkipped('nothing in the database for "$name" to edit');
          return;
        }
        expect(found, isEmpty);
      },
    );
  }
}

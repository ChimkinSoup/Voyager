import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Search box contents (§6.1). Page-local: applications are deliberately not
/// in the global Search page's corpora.
final jobSearchQueryProvider = StateProvider<String>((ref) => '');

/// Statuses the table is narrowed to. Empty means no narrowing — the same
/// result as selecting every status, but it keeps "no filter" as the state the
/// page opens in rather than something the user has to restore.
final jobStatusFilterProvider = StateProvider<Set<String>>((ref) => const {});

/// The application whose editor panel is open, by id. Null closes the panel.
final jobSelectedApplicationProvider = StateProvider<String?>((ref) => null);

/// Columns the table can show, in fixed left-to-right order.
///
/// The id is what persists in settings, so renaming a label is safe but
/// renaming an id would silently re-show a column the user had switched off.
enum JobColumn {
  color('color', 'Color'),
  company('company', 'Company'),
  title('title', 'Title'),
  status('status', 'Status'),
  dateApplied('dateApplied', 'Date applied'),
  notes('notes', 'Notes');

  const JobColumn(this.id, this.label);

  final String id;
  final String label;
}

/// Columns that cannot be switched off. Hiding both of the fields an
/// application is required to have would leave rows with nothing to identify
/// them by, and nothing to click.
const jobRequiredColumns = {JobColumn.company, JobColumn.title};

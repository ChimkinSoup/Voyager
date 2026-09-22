import 'package:voyager/core/utils/ids.dart';
import 'package:voyager/domain/models/soft_deletable.dart';

/// One tab of the LeetCode cheat sheet.
///
/// [languageKey] is a `leetCodeCodeLanguages` key or null — null means "no
/// highlighting", which is what makes a "Patterns" or "Big-O" tab legal. A key
/// this build no longer offers reads the same as null rather than erroring;
/// the record is left alone.
class LeetCodeCheatTab extends SoftDeletable {
  const LeetCodeCheatTab({
    required super.id,
    required super.createdAt,
    required super.updatedAt,
    super.version,
    super.deletedAt,
    required this.name,
    this.languageKey,
    required this.position,
  });

  final String name;
  final String? languageKey;
  final double position;

  /// [touch] off leaves [updatedAt] where it was, for a cascade that stamps
  /// every row it writes with one instant — see `softDeleteCheatTab`.
  LeetCodeCheatTab copyWith({
    String? name,
    String? languageKey,
    bool clearLanguageKey = false,
    double? position,
    DateTime? deletedAt,
    bool clearDeletedAt = false,
    int? version,
    bool bumpVersion = true,
    bool touch = true,
  }) {
    return LeetCodeCheatTab(
      id: id,
      createdAt: createdAt,
      updatedAt: touch ? utcNow() : updatedAt,
      version: version ?? (bumpVersion ? this.version + 1 : this.version),
      deletedAt: clearDeletedAt ? null : (deletedAt ?? this.deletedAt),
      name: name ?? this.name,
      languageKey: clearLanguageKey ? null : (languageKey ?? this.languageKey),
      position: position ?? this.position,
    );
  }
}

/// One section heading inside a tab. There is exactly one level of these.
class LeetCodeCheatSection extends SoftDeletable {
  const LeetCodeCheatSection({
    required super.id,
    required super.createdAt,
    required super.updatedAt,
    super.version,
    super.deletedAt,
    required this.tabId,
    required this.name,
    required this.position,
  });

  final String tabId;
  final String name;
  final double position;

  /// [touch] as on [LeetCodeCheatTab.copyWith].
  LeetCodeCheatSection copyWith({
    String? name,
    double? position,
    DateTime? deletedAt,
    bool clearDeletedAt = false,
    int? version,
    bool bumpVersion = true,
    bool touch = true,
  }) {
    return LeetCodeCheatSection(
      id: id,
      createdAt: createdAt,
      updatedAt: touch ? utcNow() : updatedAt,
      version: version ?? (bumpVersion ? this.version + 1 : this.version),
      deletedAt: clearDeletedAt ? null : (deletedAt ?? this.deletedAt),
      tabId: tabId,
      name: name ?? this.name,
      position: position ?? this.position,
    );
  }
}

/// One command, what it does, and optionally a label and its complexity.
///
/// [complexity] is null rather than empty when unset — the badge's presence in
/// Viewing mode is the flag, and an empty string would draw an empty badge.
/// [label] follows the same rule: null is what collapses the row's label
/// column, so rows without one are not indented past the ones with.
class LeetCodeCheatEntry extends SoftDeletable {
  const LeetCodeCheatEntry({
    required super.id,
    required super.createdAt,
    required super.updatedAt,
    super.version,
    super.deletedAt,
    required this.sectionId,
    required this.command,
    this.label,
    this.description = '',
    this.complexity,
    required this.position,
  });

  final String sectionId;
  final String command;

  /// A short name for the row, shown in its own column to the left of the
  /// code. Null when unset — see the class doc.
  final String? label;

  /// Markdown-ish prose: `` `inline code` `` and triple-backtick fenced blocks
  /// render, nothing else is parsed.
  final String description;

  /// One per line of [command], newline-separated, since a block's lines
  /// rarely cost the same — the loop and the lookup inside it are two
  /// different numbers, and only one badge each says which.
  ///
  /// A blank line is a line with no badge, and the list may be shorter than
  /// the command (the lines past it have none) or longer (the surplus is not
  /// drawn). [complexityByLine] is what pairs the two up.
  final String? complexity;

  final double position;

  /// [complexity] lined up against [command]: exactly one entry per line of
  /// the command, trimmed, and empty where that line carries no cost.
  List<String> get complexityByLine {
    final costs = (complexity ?? '').split('\n');
    return [
      for (var i = 0; i < commandLines.length; i++)
        i < costs.length ? costs[i].trim() : '',
    ];
  }

  /// [command] split into the lines the sheet draws it as. Always at least
  /// one, so an empty command is still a line that can hold a badge.
  List<String> get commandLines => command.split('\n');

  /// [touch] as on [LeetCodeCheatTab.copyWith].
  LeetCodeCheatEntry copyWith({
    String? command,
    String? label,
    bool clearLabel = false,
    String? description,
    String? complexity,
    bool clearComplexity = false,
    double? position,
    DateTime? deletedAt,
    bool clearDeletedAt = false,
    int? version,
    bool bumpVersion = true,
    bool touch = true,
  }) {
    return LeetCodeCheatEntry(
      id: id,
      createdAt: createdAt,
      updatedAt: touch ? utcNow() : updatedAt,
      version: version ?? (bumpVersion ? this.version + 1 : this.version),
      deletedAt: clearDeletedAt ? null : (deletedAt ?? this.deletedAt),
      sectionId: sectionId,
      command: command ?? this.command,
      label: clearLabel ? null : (label ?? this.label),
      description: description ?? this.description,
      complexity: clearComplexity ? null : (complexity ?? this.complexity),
      position: position ?? this.position,
    );
  }
}

/// The gap a fresh row is appended at, and the floor a reorder renormalizes
/// below.
///
/// Appending adds [kCheatPositionStep] to the last position, so the ordinary
/// case never needs a second write. A drop between two neighbours takes their
/// midpoint, which halves the gap each time — after about fifty drops onto the
/// same seam a double can no longer tell the two apart, and
/// [kCheatPositionFloor] is where the list is renumbered instead.
const double kCheatPositionStep = 1024;

/// Below this the midpoint of two neighbours stops being reliably distinct, so
/// the list is renumbered. Generous rather than tight: renumbering is a bulk
/// write, and the user paid for it with a drag either way.
const double kCheatPositionFloor = 0.0001;

/// The position a row dropped between [before] and [after] takes.
///
/// Nulls are the ends of the list: both null is the only row, so it keeps
/// [kCheatPositionStep].
double cheatPositionBetween(double? before, double? after) {
  if (before == null && after == null) return kCheatPositionStep;
  if (before == null) return after! - kCheatPositionStep;
  if (after == null) return before + kCheatPositionStep;
  return (before + after) / 2;
}

/// Whether [positions], in order, still has room for a drop on every seam.
bool cheatPositionsNeedRenormalize(List<double> positions) {
  for (var i = 1; i < positions.length; i++) {
    if (positions[i] - positions[i - 1] < kCheatPositionFloor) return true;
  }
  return false;
}

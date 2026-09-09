import 'package:flutter/material.dart';
import 'package:voyager/domain/models/job_models.dart';

/// The colour a status is drawn in, wherever the page draws one: the header
/// chips, the table's status capsule, and the swatch in the Manage dialog.
///
/// A stage the user has coloured uses that colour. One they have not keeps the
/// original behaviour — a hue spread around the theme's wheel by the stage's
/// position — so the pipeline looks the same until a colour is actually
/// picked. Orphan statuses (no stage by that name any more) all share the
/// muted fallback, which is what marks them apart at a glance.
class JobStageColors {
  JobStageColors({required List<JobStage> stages, required this.fallback})
    : _stageByName = {for (final stage in stages) stage.name: stage},
      _indexByName = {
        for (var i = 0; i < stages.length; i++) stages[i].name: i,
      },
      _count = stages.length;

  final Color fallback;
  final Map<String, JobStage> _stageByName;
  final Map<String, int> _indexByName;
  final int _count;

  Color of(String status) {
    final explicit = _stageByName[status]?.colorValue;
    if (explicit != null) return Color(explicit);
    final index = _indexByName[status];
    if (index == null || _count == 0) return fallback;
    return derivedColor(index, _count, fallback);
  }

  /// What [stage] shows, whether or not it carries a colour of its own.
  Color forStage(JobStage stage) => of(stage.name);

  /// Whether [stage] carries a colour the user chose, as opposed to the one
  /// its position hands it.
  bool isExplicit(JobStage stage) => stage.colorValue != null;

  /// The position-derived colour: [fallback]'s hue, rotated by the stage's
  /// share of the wheel.
  static Color derivedColor(int index, int count, Color fallback) {
    final hsl = HSLColor.fromColor(fallback);
    return hsl.withHue((hsl.hue + (360 / count) * index) % 360).toColor();
  }
}

/// Stable ids for the two plans. There is exactly one of each mode, created
/// on first launch and never deleted, so fixed ids keep both devices pointing
/// at the same plan instead of syncing two rival copies of "the weekly plan".
const String kWeeklyWorkoutPlanId = 'workout_plan_weekly';
const String kCycleWorkoutPlanId = 'workout_plan_cycle';

/// Seeded on first launch so the planner's drag panel isn't empty. Ordinary
/// rows once written — renameable, deletable, and not restored if removed.
const List<String> kStarterExercises = [
  'Bench Press',
  'Incline Dumbbell Press',
  'Overhead Press',
  'Barbell Row',
  'Pull-up',
  'Lat Pulldown',
  'Back Squat',
  'Front Squat',
  'Deadlift',
  'Romanian Deadlift',
  'Leg Press',
  'Lunge',
  'Bicep Curl',
  'Tricep Pushdown',
  'Lateral Raise',
  'Face Pull',
  'Calf Raise',
  'Plank',
];

/// Wheel step for the weight picker, in each display unit. Fine enough for
/// microplates without making a flick to 200 lb feel like a marathon.
const double kWeightStepLb = 2.5;
const double kWeightStepKg = 1.25;

/// Upper bound of the weight wheel in each display unit.
const double kMaxWeightLb = 1000;
const double kMaxWeightKg = 450;

/// Upper bound of the reps wheel.
const int kMaxReps = 60;

/// Upper bound on a movement's planned sets. Shared by the two places a target
/// can be edited — the planner's sheet and the detail view's inline fields —
/// so the same typed number can't be accepted by one and clamped by the other.
const int kMaxSets = 20;

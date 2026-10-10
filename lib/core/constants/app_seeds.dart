import 'package:voyager/core/constants/workout_constants.dart';
import 'package:voyager/core/sync/firestore_collections.dart';

/// The part of a seeded row's id derived from its name: "Phone screen" →
/// "phone-screen". Job stages and companies and the starter exercises all
/// use it, so the same seed is the same document on every device.
String seedSlug(String name) =>
    name.trim().toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '-');

/// Whether [id] in [collection] is a row the app seeds for itself, under a
/// fixed id, on every device: the built-in Weekly / Split plans, and every
/// `seed-` id (job stages and companies, starter exercises).
///
/// An untouched one (version 0) is never uploaded, so the full sync check
/// doesn't count it missing from the cloud, and a restore never counts one
/// as a record it created (BUG-210). The purge, which runs in SQL, keeps
/// their tombstones by the same `seed-` prefix.
bool isAppSeed(String collection, String id) => switch (collection) {
  FirestoreCollections.workoutPlans =>
    id == kWeeklyWorkoutPlanId || id == kCycleWorkoutPlanId,
  _ => id.startsWith('seed-'),
};

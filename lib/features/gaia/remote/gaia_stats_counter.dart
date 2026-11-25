import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:voyager/core/sync/firestore_collections.dart';
import 'package:voyager/features/gaia/usage/gaia_stats_model.dart';

/// Gaia's lifetime stats, every desktop's (GAIA_STATS_HLD.md §4.2): one
/// document at `users/{uid}/gaia_stats/lifetime`, added to with increments as
/// the token count is, so desktops never overwrite each other's.
class GaiaStatsCounter {
  GaiaStatsCounter(this.firestore);

  final FirebaseFirestore firestore;

  /// The stats; null until read, and while signed out.
  final stats = ValueNotifier<GaiaStats?>(null);

  String? _uid;
  StreamSubscription<Object?>? _subscription;

  DocumentReference<Map<String, dynamic>> _doc(String uid) =>
      firestore.doc('users/$uid/${FirestoreCollections.gaiaStats}/lifetime');

  void setUser(String? uid) {
    if (uid == _uid) return;
    _uid = uid;
    unawaited(_subscription?.cancel());
    _subscription = null;
    stats.value = null;
    if (uid == null) return;
    _subscription = _doc(uid).snapshots().listen(
      (snapshot) {
        final read = GaiaStats.fromJson(_plain(snapshot.data() ?? {}));
        stats.value = read;
        unawaited(_backfillFirsts(uid, read));
      },
      onError: (Object error) => debugPrint('[gaia] stats read failed: $error'),
    );
  }

  /// A sighting counted before the stats were read went without its first
  /// date ([_firstUnseen]): it gets now's, as near to it as is known.
  Future<void> _backfillFirsts(String uid, GaiaStats read) async {
    Map<String, Object?> missing(Map<String, GaiaSeen> seen) => {
      for (final MapEntry(:key, :value) in seen.entries)
        if (value.count > 0 && value.first == null)
          key: {'first': Timestamp.now()},
    };
    final satellites = missing(read.satellites);
    final auroras = missing(read.auroras);
    if (satellites.isEmpty && auroras.isEmpty) return;
    try {
      await _doc(uid).set({
        if (satellites.isNotEmpty) 'satellites': satellites,
        if (auroras.isNotEmpty) 'auroras': auroras,
      }, SetOptions(merge: true));
    } catch (error) {
      debugPrint('[gaia] stats write failed: $error');
    }
  }

  /// The document as JSON: its first-seen [Timestamp]s in milliseconds.
  static Map<String, Object?> _plain(Map<String, dynamic> data) => {
    for (final MapEntry(:key, :value) in data.entries)
      key: switch (value) {
        Timestamp() => value.millisecondsSinceEpoch,
        Map() => _plain(value.cast()),
        _ => value,
      },
  };

  /// Adds what the companion saw or did, as its `statsSeen` has it (§4.1).
  /// Signed out, it's dropped: there's no Voyager account to count it under.
  Future<void> add(Map<String, Object?> seen) async {
    final uid = _uid;
    if (uid == null) return;
    final Map<String, Object?>? data = switch (seen) {
      {
        'kind': final String kind && ('satellite' || 'aurora'),
        'id': final String id,
      } =>
        {
          '${kind}s': {
            id: {
              'count': FieldValue.increment(1),
              // Two desktops racing on the first both write it; the later
              // wins, seconds apart.
              if (_firstUnseen(kind, id)) 'first': Timestamp.now(),
            },
          },
        },
      {'kind': 'meteors', 'n': final int n} => {
        'meteors': FieldValue.increment(n),
      },
      {'kind': 'comet'} => {'comets': FieldValue.increment(1)},
      {'kind': 'chat'} => {'chats': FieldValue.increment(1)},
      // A day is set, not counted, so two desktops on one day count it once.
      {'kind': 'day', 'day': final String day} => {
        'days': {day: true},
      },
      _ => null,
    };
    if (data == null) return;
    try {
      await _doc(uid).set(data, SetOptions(merge: true));
    } catch (error) {
      debugPrint('[gaia] stats write failed: $error');
    }
  }

  /// Read, and with no first sighting of [id] yet. Not yet read, it's left
  /// unwritten rather than risk writing over one.
  bool _firstUnseen(String kind, String id) {
    final read = stats.value;
    if (read == null) return false;
    final seen = kind == 'satellite' ? read.satellites : read.auroras;
    return seen[id]?.first == null;
  }
}

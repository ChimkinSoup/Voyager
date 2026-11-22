import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:voyager/core/sync/firestore_collections.dart';
import 'package:voyager/features/gaia/usage/gaia_tokens.dart';

/// Gaia's lifetime token count, every desktop's: a document for each
/// account, source and model at `users/{uid}/gaia_tokens/{id}`, which each
/// model call adds to with increments, so desktops never overwrite each
/// other's.
class GaiaTokenCounter {
  GaiaTokenCounter(this.firestore);

  final FirebaseFirestore firestore;

  /// Every line of the count; null until read, and while signed out.
  final totals = ValueNotifier<List<GaiaTokenRow>?>(null);

  String? _uid;
  StreamSubscription<Object?>? _subscription;

  CollectionReference<Map<String, dynamic>> _collection(String uid) =>
      firestore.collection('users/$uid/${FirestoreCollections.gaiaTokens}');

  void setUser(String? uid) {
    if (uid == _uid) return;
    _uid = uid;
    unawaited(_subscription?.cancel());
    _subscription = null;
    totals.value = null;
    if (uid == null) return;
    _subscription = _collection(uid).snapshots().listen(
      (snapshot) {
        totals.value = [
          for (final doc in snapshot.docs)
            if (doc.data()['source'] is String)
              GaiaTokenRow.fromJson(doc.data()),
        ];
        // The first version's, by model alone, are cleared: their account and
        // source are unknown. Safe to drop once every desktop has run this.
        for (final doc in snapshot.docs) {
          if (doc.data()['source'] is! String) {
            unawaited(doc.reference.delete());
          }
        }
      },
      onError: (Object error) =>
          debugPrint('[gaia] token count read failed: $error'),
    );
  }

  /// Adds [byModel] to [tokensFor]'s count. Signed out, it's dropped: there's
  /// no Voyager account to count it under.
  Future<void> add(
    GaiaTokensFor tokensFor,
    Map<String, GaiaTokenCount> byModel,
  ) async {
    final uid = _uid;
    if (uid == null) return;
    final (:account, :source) = tokensFor;
    try {
      await Future.wait([
        for (final MapEntry(key: model, value: count) in byModel.entries)
          if (count.total > 0)
            // A document id can't hold a slash, which an account key has.
            _collection(
              uid,
            ).doc('$account|$source|$model'.replaceAll('/', '_')).set({
              'account': account,
              'source': source,
              'model': model,
              for (final MapEntry(:key, :value) in count.toJson().entries)
                key: FieldValue.increment(value),
            }, SetOptions(merge: true)),
      ]);
    } catch (error) {
      debugPrint('[gaia] token count write failed: $error');
    }
  }
}

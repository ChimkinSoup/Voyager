import 'dart:io';

import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';

/// The dev profile this process runs as, or null for the normal instance:
/// a second Voyager beside the normal one with its own data, sign-in and
/// device identity. See DEV_PROFILE_HLD.md. Only debug builds read it, as
/// only the runner's debug build does (see windows/runner/utils.cpp).
String? get devProfile => _devProfile;
String? _devProfile = parseDevProfile(
  Platform.environment['VOYAGER_PROFILE'],
  debug: kDebugMode,
);

@visibleForTesting
set devProfileForTesting(String? value) => _devProfile = value;

/// `VOYAGER_PROFILE` read as a profile name. The runner has already refused
/// an invalid one, so the throw is a backstop.
@visibleForTesting
String? parseDevProfile(String? raw, {required bool debug}) {
  if (!debug) return null;
  if (raw == null || raw.isEmpty) return null;
  if (!RegExp(r'^[a-z0-9]{1,16}$').hasMatch(raw) || raw == 'default') {
    throw StateError('VOYAGER_PROFILE must match [a-z0-9]{1,16}: $raw');
  }
  return raw;
}

/// ` [b]` in a profile, empty otherwise: for titles, tooltips, device names.
String get devProfileSuffix => devProfile == null ? '' : ' [$devProfile]';

/// The Firebase app every Firebase service is taken from: `[DEFAULT]`
/// normally, `voyager-<profile>` in a profile. The SDK keys its Firestore
/// cache and persisted sign-in by app name, so a profile shares neither.
late final FirebaseApp voyagerFirebaseApp;

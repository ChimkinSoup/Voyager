import 'dart:async';

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:voyager/features/gaia/remote/gaia_remote_client.dart';

/// Gaia's push notifications on the phone (GAIA_HLD.md §14): asks for the
/// notification permission (Android 13+), keeps this device's FCM token on
/// its `gaia_devices` document for the `gaiaNotify` Cloud Function, and
/// opens the chat a tapped notification is about. Android only.
class GaiaPush {
  GaiaPush._();

  /// Whose device document has the token: the signed-in account's. Null
  /// after a failure, so the next call tries again.
  static GaiaRemoteClient? _client;
  static var _listening = false;

  static Future<void> start(
    GaiaRemoteClient client, {
    required void Function(String chatId) open,
  }) async {
    if (identical(client, _client)) return;
    _client = client;
    final messaging = FirebaseMessaging.instance;
    try {
      // First: writing the token waits for the network, and a tap doesn't.
      if (!_listening) {
        _listening = true;
        void opened(RemoteMessage message) {
          if (message.data['chatId'] case final String chatId
              when chatId.isNotEmpty) {
            open(chatId);
          }
        }

        FirebaseMessaging.onMessageOpenedApp.listen(opened);
        messaging.onTokenRefresh.listen(
          (token) => unawaited(_client?.setFcmToken(token)),
        );
        if (await messaging.getInitialMessage() case final message?) {
          opened(message);
        }
      }
      await messaging.requestPermission();
      if (await messaging.getToken() case final token?) {
        await client.setFcmToken(token);
      }
    } catch (error) {
      if (identical(client, _client)) _client = null;
      // No Play services, say: Gaia works, without pushes.
      debugPrint('[gaia] push notifications unavailable: $error');
    }
  }
}

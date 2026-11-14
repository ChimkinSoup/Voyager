import 'dart:ui' as ui;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/features/gaia/companion/gaia_no_ding.dart';

class _Recording implements BinaryMessenger {
  final sent = <MethodCall>[];

  @override
  Future<ByteData?>? send(String channel, ByteData? message) {
    sent.add(SystemChannels.platform.codec.decodeMethodCall(message));
    return null;
  }

  @override
  void setMessageHandler(String channel, MessageHandler? handler) {}

  @override
  Future<void> handlePlatformMessage(
    String channel,
    ByteData? data,
    ui.PlatformMessageResponseCallback? callback,
  ) async {}
}

void main() {
  test('the alert is answered as played, and anything else goes on', () async {
    final inner = _Recording();
    final messenger = GaiaNoDingMessenger(inner);
    final platform = MethodChannel(
      SystemChannels.platform.name,
      SystemChannels.platform.codec,
      messenger,
    );

    // Completes, as a sound played would: no MissingPluginException.
    await platform.invokeMethod<void>(
      'SystemSound.play',
      SystemSoundType.alert.toString(),
    );
    expect(inner.sent, isEmpty);

    platform
        .invokeMethod<void>(
          'SystemSound.play',
          SystemSoundType.click.toString(),
        )
        .ignore();
    expect(inner.sent.single.arguments, SystemSoundType.click.toString());
  });
}

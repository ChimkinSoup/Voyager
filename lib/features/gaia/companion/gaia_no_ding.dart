import 'dart:ui' as ui;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// Gaia's binding: Flutter's, with the system alert, the Windows ding,
/// never played. Flutter plays it for a click on a barrier that can't be
/// dismissed, such as a page's bare background, and Gaia wants no ding for
/// anything. Made before anything else asks for the binding.
class GaiaNoDingBinding extends WidgetsFlutterBinding {
  @override
  BinaryMessenger createBinaryMessenger() =>
      GaiaNoDingMessenger(super.createBinaryMessenger());
}

/// [inner], answering `SystemSound.play` of the alert itself, as played,
/// without passing it on.
class GaiaNoDingMessenger implements BinaryMessenger {
  GaiaNoDingMessenger(this.inner);

  final BinaryMessenger inner;

  static final _alert = SystemChannels.platform.codec.encodeMethodCall(
    MethodCall('SystemSound.play', SystemSoundType.alert.toString()),
  );

  @override
  Future<ByteData?>? send(String channel, ByteData? message) {
    if (channel == SystemChannels.platform.name &&
        message != null &&
        _same(message, _alert)) {
      return Future.value(
        SystemChannels.platform.codec.encodeSuccessEnvelope(null),
      );
    }
    return inner.send(channel, message);
  }

  static bool _same(ByteData a, ByteData b) {
    if (a.lengthInBytes != b.lengthInBytes) return false;
    for (var i = 0; i < a.lengthInBytes; i++) {
      if (a.getUint8(i) != b.getUint8(i)) return false;
    }
    return true;
  }

  @override
  void setMessageHandler(String channel, MessageHandler? handler) =>
      inner.setMessageHandler(channel, handler);

  @override
  // ignore: deprecated_member_use
  Future<void> handlePlatformMessage(
    String channel,
    ByteData? data,
    ui.PlatformMessageResponseCallback? callback,
  ) =>
      // ignore: deprecated_member_use
      inner.handlePlatformMessage(channel, data, callback);
}

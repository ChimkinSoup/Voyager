import 'dart:async';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:win32/win32.dart';

/// Copies a Secure Note and clears it off the clipboard [clearAfter] later —
/// but only if the clipboard still holds it, so whatever the user copied
/// since is left alone.
///
/// The timer is held here, not by the widget that copied, so it still fires
/// after the vault locks and the row is gone.
///
/// On Windows the text is put on the clipboard directly, with the
/// `ExcludeClipboardContentFromMonitorProcessing` format beside it: without
/// it, Win+V history and cloud clipboard keep the text after the clear.
///
/// On Android it goes through `MainActivity`, which marks the clip sensitive
/// so keyboards and the system's copy preview hide it. An app in the
/// background can't read the clipboard there, so when the clear can't tell
/// whose text is on it, it clears anyway.
abstract final class SecureClipboard {
  static const clearAfter = Duration(seconds: 30);

  static Timer? _clear;

  /// Whether to write through Win32. Tests turn it off to use the platform
  /// channel Flutter's [Clipboard] goes through.
  @visibleForTesting
  static bool useWin32 = Platform.isWindows;

  /// Whether to go through `MainActivity`'s channel. Tests turn it on.
  @visibleForTesting
  static bool useAndroid = Platform.isAndroid;

  static const _android = MethodChannel('voyager/secure_clipboard');

  static Future<void> copy(String text) async {
    if (useWin32) {
      _writeWindows(text);
    } else if (useAndroid) {
      await _android.invokeMethod<void>('copy', text);
    } else {
      await Clipboard.setData(ClipboardData(text: text));
    }
    _clear?.cancel();
    _clear = Timer(clearAfter, () => unawaited(_clearIfStill(text)));
  }

  static Future<void> _clearIfStill(String text) async {
    _clear = null;
    final current = await Clipboard.getData(Clipboard.kTextPlain);
    if (useAndroid) {
      // Null is also what a backgrounded app reads.
      if (current != null && current.text != text) return;
      await _android.invokeMethod<void>('clear');
      return;
    }
    if (current?.text != text) return;
    if (useWin32) {
      // Another process may hold the clipboard open for a moment.
      for (var attempt = 1; ; attempt++) {
        try {
          _writeWindows(null);
          return;
        } on WindowsException {
          if (attempt == 5) rethrow;
          await Future<void>.delayed(const Duration(milliseconds: 200));
        }
      }
    } else {
      await Clipboard.setData(const ClipboardData(text: ''));
    }
  }

  /// Replaces the clipboard with [text], or empties it for null.
  static void _writeWindows(String? text) {
    if (OpenClipboard(NULL) == 0) {
      throw WindowsException(HRESULT_FROM_WIN32(GetLastError()));
    }
    try {
      EmptyClipboard();
      if (text == null) return;
      final units = text.codeUnits;
      final memory = GlobalAlloc(GMEM_MOVEABLE, (units.length + 1) * 2);
      final chars = GlobalLock(memory).cast<Uint16>();
      chars.asTypedList(units.length + 1)
        ..setAll(0, units)
        ..[units.length] = 0;
      GlobalUnlock(memory);
      // The clipboard owns the memory once this succeeds.
      SetClipboardData(CF_UNICODETEXT, memory.address);

      final name = 'ExcludeClipboardContentFromMonitorProcessing'
          .toNativeUtf16();
      try {
        final format = RegisterClipboardFormat(name);
        // The format's presence is the signal; its content is never read.
        final marker = GlobalAlloc(GMEM_MOVEABLE, 4);
        SetClipboardData(format, marker.address);
      } finally {
        malloc.free(name);
      }
    } finally {
      CloseClipboard();
    }
  }
}

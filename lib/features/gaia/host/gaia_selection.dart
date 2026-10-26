import 'dart:ffi';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:win32/win32.dart';
import 'package:voyager/features/gaia/host/gaia_window_context.dart';

/// The selection in [window] the way E reads it (GAIA_HLD.md §15.2) when
/// UI Automation found none: a synthetic Ctrl+C, with the clipboard put
/// back as it was afterwards, every format of it. Never in a console, where
/// Ctrl+C is a SIGINT. Null when nothing was copied.
///
/// The restore carries `ExcludeClipboardContentFromMonitorProcessing`, so
/// putting the user's clipboard back doesn't add it to Win+V history again.
/// The copy itself is the source app's, which marks it as it likes.
Future<String?> gaiaCopySelection(GaiaForegroundWindow window) async {
  if (window.console) return null;
  // The hotkey's own keys are still down: Ctrl+C sent with Alt held is
  // Ctrl+Alt+C to the app.
  final released = Stopwatch()..start();
  while (_modifierDown() && released.elapsed < const Duration(seconds: 1)) {
    await Future<void>.delayed(const Duration(milliseconds: 15));
  }
  if (_modifierDown() || GetForegroundWindow() != window.hwnd) return null;
  final saved = _readClipboard();
  if (saved == null) return null;
  final before = GetClipboardSequenceNumber();
  _sendCtrlC();
  final waited = Stopwatch()..start();
  while (GetClipboardSequenceNumber() == before &&
      waited.elapsed < const Duration(milliseconds: 500)) {
    await Future<void>.delayed(const Duration(milliseconds: 15));
  }
  if (GetClipboardSequenceNumber() == before) return null;
  // The source app may still hold it open, writing its formats.
  await Future<void>.delayed(const Duration(milliseconds: 30));
  final copied = _readText();
  _writeClipboard(saved);
  return copied == null || copied.trim().isEmpty ? null : copied;
}

const _modifiers = [VK_CONTROL, VK_MENU, VK_SHIFT, VK_LWIN, VK_RWIN];

bool _modifierDown() =>
    _modifiers.any((key) => GetAsyncKeyState(key) & 0x8000 != 0);

void _sendCtrlC() {
  const keys = [
    (VK_CONTROL, 0),
    (0x43, 0), // C
    (0x43, KEYEVENTF_KEYUP),
    (VK_CONTROL, KEYEVENTF_KEYUP),
  ];
  final inputs = calloc<INPUT>(keys.length);
  try {
    for (final (i, (key, flags)) in keys.indexed) {
      inputs[i].type = INPUT_KEYBOARD;
      inputs[i].ki
        ..wVk = key
        ..dwFlags = flags;
    }
    SendInput(keys.length, inputs, sizeOf<INPUT>());
  } finally {
    free(inputs);
  }
}

/// Formats whose data is a GDI handle rather than memory, which can't be
/// copied as bytes. Windows synthesises the bitmap ones again from the DIB.
bool _isHandleFormat(int format) =>
    const {
      CF_BITMAP,
      CF_METAFILEPICT,
      CF_PALETTE,
      CF_ENHMETAFILE,
      CF_OWNERDISPLAY,
      CF_DSPBITMAP,
      CF_DSPMETAFILEPICT,
      CF_DSPENHMETAFILE,
    }.contains(format) ||
    (format >= CF_GDIOBJFIRST && format <= CF_GDIOBJFIRST + 0xFF);

/// Every format on the clipboard, as bytes; null when it couldn't be
/// opened, when nothing may touch it.
List<(int, Uint8List)>? _readClipboard() {
  if (!_open()) return null;
  try {
    final formats = <(int, Uint8List)>[];
    for (
      var format = EnumClipboardFormats(0);
      format != 0;
      format = EnumClipboardFormats(format)
    ) {
      if (_isHandleFormat(format)) continue;
      final handle = GetClipboardData(format);
      if (handle == 0) continue;
      final memory = Pointer.fromAddress(handle);
      final size = GlobalSize(memory);
      final data = GlobalLock(memory);
      if (data == nullptr) continue;
      try {
        formats.add((
          format,
          Uint8List.fromList(data.cast<Uint8>().asTypedList(size)),
        ));
      } finally {
        GlobalUnlock(memory);
      }
    }
    return formats;
  } finally {
    CloseClipboard();
  }
}

String? _readText() {
  if (!_open()) return null;
  try {
    final handle = GetClipboardData(CF_UNICODETEXT);
    if (handle == 0) return null;
    final memory = Pointer.fromAddress(handle);
    final text = GlobalLock(memory);
    if (text == nullptr) return null;
    try {
      return text.cast<Utf16>().toDartString();
    } finally {
      GlobalUnlock(memory);
    }
  } finally {
    CloseClipboard();
  }
}

void _writeClipboard(List<(int, Uint8List)> formats) {
  if (!_open()) {
    debugPrint("[gaia] the clipboard couldn't be put back");
    return;
  }
  final marker = 'ExcludeClipboardContentFromMonitorProcessing'.toNativeUtf16();
  try {
    EmptyClipboard();
    for (final (format, bytes) in [
      ...formats,
      // The format's presence is the signal; its content is never read.
      (RegisterClipboardFormat(marker), Uint8List(4)),
    ]) {
      final memory = GlobalAlloc(
        GMEM_MOVEABLE,
        bytes.isEmpty ? 1 : bytes.length,
      );
      final data = GlobalLock(memory).cast<Uint8>();
      data.asTypedList(bytes.length).setAll(0, bytes);
      GlobalUnlock(memory);
      // The clipboard owns the memory once this succeeds.
      if (SetClipboardData(format, memory.address) == 0) GlobalFree(memory);
    }
  } finally {
    free(marker);
    CloseClipboard();
  }
}

/// Another process may hold the clipboard open for a moment.
bool _open() {
  for (var attempt = 0; attempt < 5; attempt++) {
    if (OpenClipboard(NULL) != 0) return true;
    Sleep(10);
  }
  return false;
}

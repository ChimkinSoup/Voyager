import 'dart:ffi';

import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart';

/// What `os_clipboard` read (GAIA_AUTONOMY_HLD.md §8.5): the text, if there is
/// any; whether it was marked private, as password managers mark what they
/// copy; the window that put it there, 0 when none did; and whether it's
/// [ours], Gaia's own last write. Null text with [busy] means another app had
/// the clipboard open.
typedef GaiaClipboard = ({
  String? text,
  bool private,
  int owner,
  bool ours,
  bool busy,
});

/// The clipboard's sequence number just after Gaia's last write: its own
/// text, marked as left out of history, isn't a password manager's.
int? _gaiaWrote;

/// The clipboard's text, unless it was marked private.
Future<GaiaClipboard> gaiaReadClipboard() async {
  if (!await _open()) {
    return (text: null, private: false, owner: 0, ours: false, busy: true);
  }
  try {
    final owner = GetClipboardOwner();
    final ours = GetClipboardSequenceNumber() == _gaiaWrote;
    final private =
        !ours &&
        (_has('ExcludeClipboardContentFromMonitorProcessing') ||
            _has('Clipboard Viewer Ignore') ||
            _dword('CanIncludeInClipboardHistory') == 0);
    if (private) {
      return (text: null, private: true, owner: owner, ours: ours, busy: false);
    }
    final handle = GetClipboardData(CF_UNICODETEXT);
    if (handle == 0) {
      return (
        text: null,
        private: false,
        owner: owner,
        ours: ours,
        busy: false,
      );
    }
    final memory = Pointer.fromAddress(handle);
    final text = GlobalLock(memory);
    if (text == nullptr) {
      return (
        text: null,
        private: false,
        owner: owner,
        ours: ours,
        busy: false,
      );
    }
    try {
      return (
        text: text.cast<Utf16>().toDartString(),
        private: false,
        owner: owner,
        ours: ours,
        busy: false,
      );
    } finally {
      GlobalUnlock(memory);
    }
  } finally {
    CloseClipboard();
  }
}

/// Replaces the clipboard with [text], left out of clipboard history and
/// cloud sync. False when another app had the clipboard open.
Future<bool> gaiaWriteClipboard(String text) async {
  // Filled before the clipboard is emptied, so a failure here leaves the
  // user's copy alone.
  final units = text.codeUnits;
  final memory = GlobalAlloc(GMEM_MOVEABLE, (units.length + 1) * 2);
  if (memory == nullptr) return false;
  final locked = GlobalLock(memory);
  if (locked == nullptr) {
    GlobalFree(memory);
    return false;
  }
  locked.cast<Uint16>().asTypedList(units.length + 1)
    ..setAll(0, units)
    ..[units.length] = 0;
  GlobalUnlock(memory);
  if (!await _open()) {
    GlobalFree(memory);
    return false;
  }
  try {
    EmptyClipboard();
    // The clipboard owns it once set.
    if (SetClipboardData(CF_UNICODETEXT, memory.address) == 0) {
      GlobalFree(memory);
      return false;
    }
    _setDword('CanIncludeInClipboardHistory', 0);
    _setDword('CanUploadToCloudClipboard', 0);
  } finally {
    CloseClipboard();
  }
  _gaiaWrote = GetClipboardSequenceNumber();
  return true;
}

/// [text]'s first [length] code units, one fewer rather than half an emoji's
/// surrogate pair.
String gaiaCut(String text, int length) {
  if (text.length <= length) return text;
  final last = text.codeUnitAt(length - 1);
  return text.substring(
    0,
    last >= 0xD800 && last <= 0xDBFF ? length - 1 : length,
  );
}

/// Another app may hold the clipboard for a moment.
Future<bool> _open() async {
  for (var i = 0; i < 10; i++) {
    if (OpenClipboard(NULL) != 0) return true;
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
  return false;
}

int _format(String name) {
  final native = name.toNativeUtf16();
  try {
    return RegisterClipboardFormat(native);
  } finally {
    free(native);
  }
}

bool _has(String format) => IsClipboardFormatAvailable(_format(format)) != 0;

/// The DWORD in [format], or null when it's absent.
int? _dword(String format) {
  final handle = GetClipboardData(_format(format));
  if (handle == 0) return null;
  final memory = Pointer.fromAddress(handle);
  final value = GlobalLock(memory);
  if (value == nullptr) return null;
  try {
    return value.cast<Uint32>().value;
  } finally {
    GlobalUnlock(memory);
  }
}

void _setDword(String format, int value) {
  final memory = GlobalAlloc(GMEM_MOVEABLE, 4);
  if (memory == nullptr) return;
  GlobalLock(memory).cast<Uint32>().value = value;
  GlobalUnlock(memory);
  if (SetClipboardData(_format(format), memory.address) == 0) {
    GlobalFree(memory);
  }
}

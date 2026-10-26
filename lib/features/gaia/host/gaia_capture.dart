import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart';

/// A screenshot of one monitor (GAIA_HLD.md §15.1, C and D): the file
/// holding it, and the monitor's rectangle in physical pixels.
typedef GaiaScreenCapture = ({
  String path,
  int left,
  int top,
  int width,
  int height,
});

/// Captures the monitor under the cursor to [path], as a 32-bit top-down
/// BMP: no encoding, so the frame is on disk in a few tens of
/// milliseconds, before menus and tooltips close. Gaia's window is
/// excluded from capture (§3.2), so it never shows in the frame. Null when
/// the screen couldn't be read, as on a locked session.
Future<GaiaScreenCapture?> gaiaCaptureScreen(String path) =>
    Isolate.run(() => _capture(path));

GaiaScreenCapture? _capture(String path) {
  final cursor = calloc<POINT>();
  final info = calloc<MONITORINFO>()..ref.cbSize = sizeOf<MONITORINFO>();
  final header = calloc<BITMAPINFO>();
  final screen = GetDC(NULL);
  final memory = CreateCompatibleDC(screen);
  var bitmap = 0;
  Pointer<Uint8>? pixels;
  try {
    GetCursorPos(cursor);
    GetMonitorInfo(
      MonitorFromPoint(cursor.ref, MONITOR_DEFAULTTONEAREST),
      info,
    );
    final rect = info.ref.rcMonitor;
    final width = rect.right - rect.left;
    final height = rect.bottom - rect.top;
    bitmap = CreateCompatibleBitmap(screen, width, height);
    final old = SelectObject(memory, bitmap);
    // CAPTUREBLT takes layered windows too: menus, tooltips, toasts.
    final copied = BitBlt(
      memory,
      0,
      0,
      width,
      height,
      screen,
      rect.left,
      rect.top,
      SRCCOPY | CAPTUREBLT,
    );
    SelectObject(memory, old);
    if (copied == 0) return null;
    header.ref.bmiHeader
      ..biSize = sizeOf<BITMAPINFOHEADER>()
      ..biWidth = width
      // Negative: top-down rows.
      ..biHeight = -height
      ..biPlanes = 1
      ..biBitCount = 32
      ..biCompression = BI_RGB;
    final size = width * height * 4;
    pixels = calloc<Uint8>(size);
    if (GetDIBits(memory, bitmap, 0, height, pixels, header, DIB_RGB_COLORS) ==
        0) {
      return null;
    }
    // GDI leaves the alpha byte 0, which a decoder reads as transparent.
    final words = pixels.cast<Uint32>().asTypedList(width * height);
    for (var i = 0; i < words.length; i++) {
      words[i] |= 0xFF000000;
    }
    File(path).parent.createSync(recursive: true);
    final file = File(path).openSync(mode: FileMode.write);
    try {
      file
        ..writeFromSync(_bmpHeader(width, height))
        ..writeFromSync(pixels.asTypedList(size));
    } finally {
      file.closeSync();
    }
    return (
      path: path,
      left: rect.left,
      top: rect.top,
      width: width,
      height: height,
    );
  } finally {
    if (pixels != null) free(pixels);
    if (bitmap != 0) DeleteObject(bitmap);
    DeleteDC(memory);
    ReleaseDC(NULL, screen);
    free(cursor);
    free(info);
    free(header);
  }
}

/// A BMP's file header and info header for 32-bit top-down pixels.
Uint8List _bmpHeader(int width, int height) {
  const headers = 14 + 40;
  final data = ByteData(headers)
    ..setUint8(0, 0x42) // 'B'
    ..setUint8(1, 0x4D) // 'M'
    ..setUint32(2, headers + width * height * 4, Endian.little)
    ..setUint32(10, headers, Endian.little)
    ..setUint32(14, 40, Endian.little)
    ..setInt32(18, width, Endian.little)
    ..setInt32(22, -height, Endian.little)
    ..setUint16(26, 1, Endian.little)
    ..setUint16(28, 32, Endian.little);
  return data.buffer.asUint8List();
}

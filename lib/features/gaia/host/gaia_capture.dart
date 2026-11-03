import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:image/image.dart' as img;
import 'package:voyager/features/gaia/host/gaia_window_context.dart';
import 'package:win32/win32.dart';

typedef GaiaScreenRect = ({int left, int top, int width, int height});

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
  try {
    GetCursorPos(cursor);
    GetMonitorInfo(
      MonitorFromPoint(cursor.ref, MONITOR_DEFAULTTONEAREST),
      info,
    );
    final rect = info.ref.rcMonitor;
    return _captureRect(
      path,
      rect.left,
      rect.top,
      rect.right - rect.left,
      rect.bottom - rect.top,
    );
  } finally {
    free(cursor);
    free(info);
  }
}

/// The widest and tallest crop `/this` keeps (§15.5), so a control the size
/// of a whole page doesn't attach the whole page, and the room around a
/// control's bounds that shows where it is.
const _elementCropMaxWidth = 1000;
const _elementCropMaxHeight = 700;
const _elementCropPadding = 48;

/// What to crop around a control (§15.5): its bounds with some room around
/// them, kept [within] its window, and, for one too big for that, the part
/// around the cursor. Null when none of it is in there.
GaiaScreenRect? gaiaElementCropRect({
  required GaiaScreenRect element,
  required int cursorX,
  required int cursorY,
  required GaiaScreenRect within,
}) {
  (int, int) span(
    int start,
    int size,
    int cursor,
    int low,
    int high,
    int most,
  ) {
    var from = max(start - _elementCropPadding, low);
    var to = min(start + size + _elementCropPadding, high);
    if (to - from > most) {
      from = (cursor - most ~/ 2).clamp(from, to - most);
      to = from + most;
    }
    return (from, to);
  }

  final (left, right) = span(
    element.left,
    element.width,
    cursorX,
    within.left,
    within.left + within.width,
    _elementCropMaxWidth,
  );
  final (top, bottom) = span(
    element.top,
    element.height,
    cursorY,
    within.top,
    within.top + within.height,
    _elementCropMaxHeight,
  );
  if (right <= left || bottom <= top) return null;
  return (left: left, top: top, width: right - left, height: bottom - top);
}

/// A [gaiaCaptureElement] isolate still running.
var _elementCropping = false;

/// A crop around a control to [path], for `/this` (§15.5), out of [_printWindow]:
/// only the window under the cursor, with its sensitive fields blacked out.
/// Null when it couldn't be printed or scanned, within [kGaiaScreenBudget].
Future<String?> gaiaCaptureElement(
  String path,
  GaiaCursorTarget target,
  GaiaScreenRect element,
) async {
  if (_elementCropping) return null;
  final (:x, :y, :window) = target;
  final hwnd = window.hwnd;
  final browser = gaiaIsBrowser(window.exe);
  _elementCropping = true;
  final crop = Isolate.run(
    () => _cropWindow(path, hwnd, element, x, y, browser: browser),
  );
  crop.whenComplete(() => _elementCropping = false).ignore();
  try {
    return await crop.timeout(kGaiaScreenBudget);
  } on TimeoutException {
    return null;
  }
}

String? _cropWindow(
  String path,
  int hwnd,
  GaiaScreenRect element,
  int cursorX,
  int cursorY, {
  required bool browser,
}) {
  final printed = _printWindow(hwnd, browser: browser);
  final image = printed.image;
  if (image == null) return null;
  final crop = gaiaElementCropRect(
    element: element,
    cursorX: cursorX,
    cursorY: cursorY,
    within: gaiaWindowFrame(hwnd),
  );
  if (crop == null) return null;
  int inPrint(int physical) => (physical * printed.factor).round();
  final shot = img.copyCrop(
    image,
    x: inPrint(crop.left - printed.left),
    y: inPrint(crop.top - printed.top),
    width: inPrint(crop.width),
    height: inPrint(crop.height),
  );
  File(path).parent.createSync(recursive: true);
  final file = File(path).openSync(mode: FileMode.write);
  try {
    file
      ..writeFromSync(_bmpHeader(shot.width, shot.height))
      ..writeFromSync(shot.getBytes(order: img.ChannelOrder.bgra));
  } finally {
    file.closeSync();
  }
  return path;
}

/// The longest side `os_screenshot` sends (§15.6), past which the APIs scale it
/// down themselves and its coordinates stop meaning anything.
const _shotMaxSide = 1568;

/// Above this, a PNG goes as a JPEG instead: the APIs take 5 MB of base64.
const _shotMaxPng = 3500000;

/// What `os_screenshot` got of a window (§15.6): the image, or why not in
/// [refused]. [url] is its address, for the exclusion list. [left] and [top]
/// place it on screen, and [scale] is image pixels per screen pixel.
typedef GaiaWindowShot = ({
  String? refused,
  String? url,
  Uint8List? image,
  String mimeType,
  int left,
  int top,
  int width,
  int height,
  double scale,
  int hidden,
});

GaiaWindowShot _shotRefused(String why) => (
  refused: why,
  url: null,
  image: null,
  mimeType: '',
  left: 0,
  top: 0,
  width: 0,
  height: 0,
  scale: 1,
  hidden: 0,
);

/// [_printWindow] for an agent. Null over budget.
Future<GaiaWindowShot?> gaiaShootWindow(int hwnd, {required bool browser}) =>
    gaiaScreenWork(hwnd, () => _shootWindow(hwnd, browser: browser));

GaiaWindowShot _shootWindow(int hwnd, {required bool browser}) {
  final printed = _printWindow(hwnd, browser: browser);
  final image = printed.image;
  if (image == null) return _shotRefused(printed.refused!);
  int inPrint(int physical) => (physical * printed.factor).round();
  // Without the invisible resize borders, which come out black.
  final frame = gaiaWindowFrame(hwnd);
  var shot = img.copyCrop(
    image,
    x: inPrint(frame.left - printed.left),
    y: inPrint(frame.top - printed.top),
    width: inPrint(frame.width),
    height: inPrint(frame.height),
  );
  final longest = max(shot.width, shot.height);
  final resize = longest > _shotMaxSide ? _shotMaxSide / longest : 1.0;
  if (resize < 1) {
    shot = img.copyResize(
      shot,
      width: (shot.width * resize).round(),
      height: (shot.height * resize).round(),
      interpolation: img.Interpolation.average,
    );
  }
  final png = img.encodePng(shot, level: 3);
  final small = png.length <= _shotMaxPng;
  return (
    refused: null,
    url: printed.url,
    image: small ? png : img.encodeJpg(shot, quality: 85),
    mimeType: small ? 'image/png' : 'image/jpeg',
    left: frame.left,
    top: frame.top,
    width: shot.width,
    height: shot.height,
    scale: printed.factor * resize,
    hidden: printed.hidden,
  );
}

/// What [_printWindow] got: the whole window rect as printed, or why not in
/// [refused]. [left] and [top] place it on screen, and [factor] is print pixels
/// per screen pixel. [url] is its address, and [hidden] the fields blacked out.
typedef _WindowPrint = ({
  String? refused,
  img.Image? image,
  int left,
  int top,
  double factor,
  String? url,
  int hidden,
});

_WindowPrint _printRefused(String why) => (
  refused: why,
  image: null,
  left: 0,
  top: 0,
  factor: 1,
  url: null,
  hidden: 0,
);

/// One window's own pixels, whatever is over it, so nothing of an excluded app
/// on top can get in. Sensitive fields (§15.6), and a page's fields with no name,
/// which could be, are blacked out first. A window
/// that keeps itself out of captures is refused: this way of asking wouldn't
/// honour that.
_WindowPrint _printWindow(int hwnd, {required bool browser}) {
  final affinity = calloc<Uint32>();
  try {
    GetWindowDisplayAffinity(hwnd, affinity);
    if (affinity.value != WDA_NONE) {
      return _printRefused('That window keeps itself out of screen captures.');
    }
  } finally {
    free(affinity);
  }
  if (IsHungAppWindow(hwnd) != 0) {
    return _printRefused("That window isn't responding.");
  }
  // No tree, no knowing where its sensitive fields are.
  final scan = gaiaSettleScan(
    () => gaiaScanWindow(hwnd, browser: browser, text: false),
    web: browser || gaiaHostsChromiumPage(hwnd),
    wait: () => sleep(const Duration(milliseconds: 250)),
  );
  if (scan == null) {
    return _printRefused(
      "That window's controls couldn't be checked, so its sensitive fields "
      "couldn't be hidden. A browser shows Gaia no page while it's covered: "
      'ask the user to bring it up.',
    );
  }
  final rect = calloc<RECT>();
  final fill = calloc<RECT>();
  final header = calloc<BITMAPINFO>();
  final screen = GetDC(NULL);
  final memory = CreateCompatibleDC(screen);
  var bitmap = 0;
  Pointer<Uint8>? pixels;
  try {
    GetWindowRect(hwnd, rect);
    final left = rect.ref.left;
    final top = rect.ref.top;
    final width = rect.ref.right - left;
    final height = rect.ref.bottom - top;
    bitmap = CreateCompatibleBitmap(screen, width, height);
    final old = SelectObject(memory, bitmap);
    final printed = PrintWindow(hwnd, memory, _pwRenderFullContent) != 0;
    // An app that isn't per-monitor aware prints at its own DPI, in the bitmap's
    // top left, while UI Automation's bounds and its window rect are physical.
    final factor = gaiaWindowPrintScale(hwnd);
    int inPrint(int physical) => (physical * factor).round();
    for (final field in [...scan.sensitive, ...scan.unjudged]) {
      fill.ref
        ..left = inPrint(field.left - left) - _shotFieldMargin
        ..top = inPrint(field.top - top) - _shotFieldMargin
        ..right = inPrint(field.right - left) + _shotFieldMargin
        ..bottom = inPrint(field.bottom - top) + _shotFieldMargin;
      FillRect(memory, fill, GetStockObject(BLACK_BRUSH));
    }
    SelectObject(memory, old);
    if (!printed) return _printRefused("That window couldn't be captured.");
    final size = width * height * 4;
    pixels = calloc<Uint8>(size);
    if (!_readPixels(memory, bitmap, width, height, header, pixels)) {
      return _printRefused("That window couldn't be captured.");
    }
    // By color: [_readPixels] has made every pixel opaque.
    final colors = pixels.cast<Uint32>().asTypedList(width * height);
    if (!colors.any((pixel) => pixel & 0x00FFFFFF != 0)) {
      return _printRefused('That window came back blank.');
    }
    return (
      refused: null,
      image: img.Image.fromBytes(
        width: width,
        height: height,
        // A copy: [pixels] is freed on the way out.
        bytes: Uint8List.fromList(pixels.asTypedList(size)).buffer,
        numChannels: 4,
        order: img.ChannelOrder.bgra,
      ),
      left: left,
      top: top,
      factor: factor,
      url: scan.url,
      hidden: scan.sensitive.length + scan.unjudged.length,
    );
  } finally {
    if (pixels != null) free(pixels);
    if (bitmap != 0) DeleteObject(bitmap);
    DeleteDC(memory);
    ReleaseDC(NULL, screen);
    free(rect);
    free(fill);
    free(header);
  }
}

/// What the window's own compositor shows, GPU content included.
const _pwRenderFullContent = 2;

/// Around a blacked-out field, against rounding between the two scales.
const _shotFieldMargin = 2;

/// [bitmap]'s top-down pixels into [pixels], with GDI's alpha of 0 made opaque,
/// which a decoder would read as transparent.
bool _readPixels(
  int memory,
  int bitmap,
  int width,
  int height,
  Pointer<BITMAPINFO> header,
  Pointer<Uint8> pixels,
) {
  header.ref.bmiHeader
    ..biSize = sizeOf<BITMAPINFOHEADER>()
    ..biWidth = width
    // Negative: top-down rows.
    ..biHeight = -height
    ..biPlanes = 1
    ..biBitCount = 32
    ..biCompression = BI_RGB;
  if (GetDIBits(memory, bitmap, 0, height, pixels, header, DIB_RGB_COLORS) ==
      0) {
    return false;
  }
  final words = pixels.cast<Uint32>().asTypedList(width * height);
  for (var i = 0; i < words.length; i++) {
    words[i] |= 0xFF000000;
  }
  return true;
}

GaiaScreenCapture? _captureRect(
  String path,
  int left,
  int top,
  int width,
  int height,
) {
  final header = calloc<BITMAPINFO>();
  final screen = GetDC(NULL);
  final memory = CreateCompatibleDC(screen);
  var bitmap = 0;
  Pointer<Uint8>? pixels;
  try {
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
      left,
      top,
      SRCCOPY | CAPTUREBLT,
    );
    SelectObject(memory, old);
    if (copied == 0) return null;
    final size = width * height * 4;
    pixels = calloc<Uint8>(size);
    if (!_readPixels(memory, bitmap, width, height, header, pixels)) {
      return null;
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
    return (path: path, left: left, top: top, width: width, height: height);
  } finally {
    if (pixels != null) free(pixels);
    if (bitmap != 0) DeleteObject(bitmap);
    DeleteDC(memory);
    ReleaseDC(NULL, screen);
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

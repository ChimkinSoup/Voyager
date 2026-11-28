import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io' show Platform, pid, sleep;
import 'dart:isolate';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart' show debugPrint, kDebugMode;
import 'package:flutter/scheduler.dart' show SchedulerBinding;
import 'package:path/path.dart' as p;
import 'package:voyager/domain/models/gaia_models.dart';
import 'package:voyager/features/gaia/host/gaia_voyager_reads.dart';
import 'package:win32/win32.dart';

/// The window the user was in when they summoned Gaia (GAIA_HLD.md §15.4):
/// its app, title and process, read with plain Win32 the moment the hotkey
/// arrives, so it describes the app under Gaia rather than Gaia.
typedef GaiaForegroundWindow = ({
  int hwnd,
  int pid,
  String exe,
  String app,
  String title,
  bool console,
});

/// What UI Automation adds (§15.2, §15.4): a browser's address, and the
/// selected text of the focused control.
typedef GaiaWindowUia = ({String? url, String? selection});

/// Exe names, without `.exe`, whose address bar is read for the URL.
const _browsers = {'chrome', 'msedge', 'firefox', 'brave', 'vivaldi', 'opera'};

/// Exe names, without `.exe`, of apps hosting a Chromium page whose fields
/// with no name are read as any app's are (§15.6): Obsidian's note editor is one.
const _unnamedFieldsTrusted = {'obsidian'};

/// Window classes of console hosts, where a synthetic Ctrl+C would be a
/// SIGINT (§15.2).
const _consoleClasses = {'ConsoleWindowClass', 'CASCADIA_HOSTING_WINDOW_CLASS'};

/// How long a summon lets UI Automation take (§15.2): cross-process calls
/// can block for seconds against a hung app.
const kGaiaUiaBudget = Duration(milliseconds: 250);

/// The narrowest the Gaia window goes, in logical pixels: its sidebar plus a
/// usable chat.
const kGaiaMinimumWidth = 560.0;

/// The foreground window; null when there's none, as on a locked session.
GaiaForegroundWindow? gaiaForegroundWindow() {
  final hwnd = GetForegroundWindow();
  return hwnd == 0 ? null : _describeWindow(hwnd);
}

/// Where the cursor is, and the top-level window under it: not always the
/// one in front. Null over the control border's button, the only part of the
/// border a point can land on, which hides what's below it.
typedef GaiaCursorTarget = ({int x, int y, GaiaForegroundWindow window});

GaiaCursorTarget? gaiaCursorTarget() {
  final cursor = calloc<POINT>();
  try {
    if (GetCursorPos(cursor) == 0) return null;
    final under = WindowFromPoint(cursor.ref);
    if (under == 0 || _isControlBorder(under)) return null;
    return (
      x: cursor.ref.x,
      y: cursor.ref.y,
      window: _describeWindow(GetAncestor(under, GA_ROOT)),
    );
  } finally {
    free(cursor);
  }
}

/// Whether [hwnd] is a dialog, as the Open dialog a browser shows: no page,
/// so no address, though its folder box reads as one.
bool gaiaIsDialog(int hwnd) {
  final className = wsalloc(256);
  try {
    GetClassName(hwnd, className, 256);
    return className.toDartString() == '#32770';
  } finally {
    free(className);
  }
}

bool _isControlBorder(int hwnd) {
  final className = wsalloc(256);
  try {
    GetClassName(hwnd, className, 256);
    return className.toDartString() == 'VoyagerGaiaControlBorder';
  } finally {
    free(className);
  }
}

GaiaForegroundWindow _describeWindow(int hwnd) {
  final pid = calloc<Uint32>();
  final className = wsalloc(256);
  try {
    GetWindowThreadProcessId(hwnd, pid);
    GetClassName(hwnd, className, 256);
    final exe = _processPath(pid.value);
    return (
      hwnd: hwnd,
      pid: pid.value,
      exe: exe == null ? '' : p.basenameWithoutExtension(exe),
      app:
          (exe == null ? null : _fileDescription(exe)) ??
          (exe == null ? '' : p.basenameWithoutExtension(exe)),
      title: _windowText(hwnd),
      console: _consoleClasses.contains(className.toDartString()),
    );
  } finally {
    free(pid);
    free(className);
  }
}

/// The split hotkey (§15.1): moves the other window to its half of its
/// monitor's work area, and returns Gaia's half. [hwnd] is the foreground
/// window, which is the other window itself, or with [below] Gaia, whose next
/// app window down is. With none, as over the desktop, only Gaia has a half,
/// on the monitor under the cursor. Gaia's half is never narrower than the Gaia
/// window can go.
/// An elevated window refuses to be moved, and stays where it is.
({int left, int top, int width, int height}) gaiaSplitWindows(
  int hwnd, {
  required bool below,
  required bool gaiaRight,
}) {
  final other = below
      ? _appWindowBelow(hwnd)
      : (gaiaIsShellWindow(hwnd) ? 0 : _rootOwner(hwnd));
  final cursor = calloc<POINT>();
  final info = calloc<MONITORINFO>()..ref.cbSize = sizeOf<MONITORINFO>();
  final dpiX = calloc<Uint32>();
  final dpiY = calloc<Uint32>();
  try {
    GetCursorPos(cursor);
    final monitor = other != 0
        ? MonitorFromWindow(other, MONITOR_DEFAULTTONEAREST)
        : MonitorFromPoint(cursor.ref, MONITOR_DEFAULTTONEAREST);
    GetMonitorInfo(monitor, info);
    GetDpiForMonitor(monitor, MDT_EFFECTIVE_DPI, dpiX, dpiY);
    final work = info.ref.rcWork;
    final (:gaia, other: otherHalf) = gaiaSplitHalves(
      left: work.left,
      top: work.top,
      right: work.right,
      bottom: work.bottom,
      gaiaRight: gaiaRight,
      gaiaMinimumWidth: (kGaiaMinimumWidth * dpiX.value / 96).ceil(),
    );
    // Off this isolate: these calls wait on the window's thread, for as long
    // as the app is busy.
    if (other != 0) {
      final moved = Isolate.run(() => _moveWindow(other, otherHalf));
      // Voyager's own window, maximised, is resized twice back to back (out
      // of maximised, then to its half), and the engine can present the frame
      // drawn for the first size into the second: sheared, with its halves
      // swapped. An idle page then never draws over it, so draw once more.
      if (_ownedBy(other, pid)) {
        moved
            .then((_) => SchedulerBinding.instance.scheduleForcedFrame())
            .ignore();
      } else {
        moved.ignore();
      }
    }
    return gaia;
  } finally {
    free(cursor);
    free(info);
    free(dpiX);
    free(dpiY);
  }
}

/// The app window a dialog belongs to. An owner kept hidden isn't one, which
/// leaves the dialog itself.
int _rootOwner(int hwnd) {
  var root = hwnd;
  for (
    var owner = GetWindow(root, GW_OWNER);
    owner != 0;
    owner = GetWindow(root, GW_OWNER)
  ) {
    root = owner;
  }
  return IsWindowVisible(root) != 0 ? root : hwnd;
}

/// A work area's two halves, 50:50, unless that leaves Gaia under
/// [gaiaMinimumWidth]: then Gaia has that, and the other window the rest.
({
  ({int left, int top, int width, int height}) gaia,
  ({int left, int top, int width, int height}) other,
})
gaiaSplitHalves({
  required int left,
  required int top,
  required int right,
  required int bottom,
  required bool gaiaRight,
  required int gaiaMinimumWidth,
}) {
  final height = bottom - top;
  final width = right - left;
  final minimum = gaiaMinimumWidth.clamp(0, width);
  final leftWidth = gaiaRight
      ? (width ~/ 2).clamp(0, width - minimum)
      : (width ~/ 2).clamp(minimum, width);
  final leftHalf = (left: left, top: top, width: leftWidth, height: height);
  final rightHalf = (
    left: left + leftWidth,
    top: top,
    width: width - leftWidth,
    height: height,
  );
  return gaiaRight
      ? (gaia: rightHalf, other: leftHalf)
      : (gaia: leftHalf, other: rightHalf);
}

/// The taskbar, the desktop, or Start or Search, in front on the way to the
/// user's app when they click through it: not an app. (A Store app's own
/// CoreWindow is a child of its frame, never the top-level window here.)
bool gaiaIsShellWindow(int hwnd) {
  final className = wsalloc(64);
  try {
    GetClassName(hwnd, className, 64);
    return const {
      'Shell_TrayWnd',
      'Shell_SecondaryTrayWnd',
      'Progman',
      'WorkerW',
      'Windows.UI.Core.CoreWindow',
    }.contains(className.toDartString());
  } finally {
    free(className);
  }
}

/// The first app window under [hwnd] in the z-order, as Alt+Tab would list
/// it, past any always-on-top ones a floater sits among; 0 for none.
int _appWindowBelow(int hwnd) {
  for (
    var next = GetWindow(hwnd, GW_HWNDNEXT);
    next != 0;
    next = GetWindow(next, GW_HWNDNEXT)
  ) {
    if (_isAppWindow(next)) return next;
  }
  return 0;
}

bool _isAppWindow(int hwnd) {
  if (IsWindowVisible(hwnd) == 0 ||
      IsIconic(hwnd) != 0 ||
      GetWindow(hwnd, GW_OWNER) != 0 ||
      gaiaIsShellWindow(hwnd) ||
      GetWindowTextLength(hwnd) == 0 ||
      GetWindowLongPtr(hwnd, GWL_EXSTYLE) &
              (WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE | WS_EX_TOPMOST) !=
          0) {
    return false;
  }
  // Windows on another virtual desktop, and suspended Store apps, are
  // visible but cloaked.
  final cloaked = calloc<Int32>();
  try {
    DwmGetWindowAttribute(hwnd, DWMWA_CLOAKED, cloaked, sizeOf<Int32>());
    return cloaked.value == 0;
  } finally {
    free(cloaked);
  }
}

/// A window `os_windows` lists (GAIA_AUTONOMY_HLD.md §8.2).
typedef GaiaListedWindow = ({
  GaiaForegroundWindow window,
  bool minimized,
  ({int left, int top, int width, int height}) frame,
});

/// The windows Alt+Tab would show, front first, minimized and always-on-top
/// ones included: visible, titled, owned by no other window, and not a tool
/// window, the shell or the control border. Gaia's own are the caller's to
/// leave out.
List<GaiaListedWindow> gaiaListWindows() {
  // The handles all at once, then each described: a z-order walk describing
  // each as it went missed a window raised meanwhile (BUG-360).
  final handles = _enumerated = [];
  EnumWindows(Pointer.fromFunction<WNDENUMPROC>(_collectWindow, 0), 0);
  return [
    for (final hwnd in handles)
      if (_isListedWindow(hwnd))
        (
          window: _describeWindow(hwnd),
          minimized: IsIconic(hwnd) != 0,
          frame: gaiaWindowFrame(hwnd),
        ),
  ];
}

var _enumerated = <int>[];

int _collectWindow(int hwnd, int _) {
  _enumerated.add(hwnd);
  return 1;
}

/// The app ID [hwnd] was given explicitly, as Store apps' frames and some
/// desktop apps (Chrome) are: what the taskbar groups by. Null for none.
String? gaiaWindowAppId(int hwnd) {
  final initialized = CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
  final iid = GUIDFromString(IID_IPropertyStore);
  final store = calloc<COMObject>();
  final key = calloc<PROPERTYKEY>();
  final value = calloc<PROPVARIANT>();
  try {
    if (FAILED(_shGetPropertyStoreForWindow(hwnd, iid, store.cast())) ||
        store.ref.isNull) {
      return null;
    }
    final properties = _detached(IPropertyStore(store));
    try {
      final format = GUIDFromString('{9F4C2855-9F79-4B39-A8D0-E1D42DE1D5F3}');
      key.ref
        ..fmtid = format.ref
        ..pid = 5;
      free(format);
      if (FAILED(properties.getValue(key, value))) return null;
      // VT_LPWSTR: the string's pointer follows the 8-byte header.
      final vt = value.cast<Uint16>().value;
      final text = vt == 31
          ? Pointer<Utf16>.fromAddress(
              (value.cast<Uint8>() + 8).cast<IntPtr>().value,
            ).toDartString()
          : null;
      PropVariantClear(value);
      return text == null || text.isEmpty ? null : text;
    } finally {
      properties.release();
    }
  } finally {
    free(iid);
    free(store);
    free(key);
    free(value);
    if (SUCCEEDED(initialized)) CoUninitialize();
  }
}

/// The app ID of process [pid]'s package, as a packaged desktop app such as
/// Windows 11's Notepad has, whose windows carry none of their own. Null for an
/// unpackaged process.
String? gaiaProcessAppId(int pid) {
  final process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pid);
  if (process == 0) return null;
  final length = calloc<Uint32>()..value = 256;
  final name = wsalloc(256);
  try {
    if (_getApplicationUserModelId(process, length, name) != 0) return null;
    return name.toDartString();
  } finally {
    CloseHandle(process);
    free(length);
    free(name);
  }
}

/// Whether process [pid] runs as administrator (an elevated token). False
/// when that can't be read.
bool gaiaProcessElevated(int pid) {
  final process = pid == 0
      ? 0
      : OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pid);
  if (process == 0) return false;
  final token = calloc<IntPtr>();
  final elevation = calloc<Uint32>();
  final length = calloc<Uint32>();
  try {
    if (OpenProcessToken(process, TOKEN_QUERY, token) == 0) return false;
    try {
      return GetTokenInformation(
                token.value,
                TokenElevation,
                elevation,
                sizeOf<Uint32>(),
                length,
              ) !=
              0 &&
          elevation.value != 0;
    } finally {
      CloseHandle(token.value);
    }
  } finally {
    CloseHandle(process);
    free(token);
    free(elevation);
    free(length);
  }
}

final _getApplicationUserModelId = DynamicLibrary.open('kernel32.dll')
    .lookupFunction<
      Int32 Function(IntPtr, Pointer<Uint32>, Pointer<Utf16>),
      int Function(int, Pointer<Uint32>, Pointer<Utf16>)
    >('GetApplicationUserModelId');

/// Where the Start menu's app [id] points when it's a shortcut, such as a
/// `Microsoft.AutoGenerated.{…}` one: the target's path or URL. Null when it
/// isn't a shortcut.
String? gaiaStartAppTarget(String id) =>
    gaiaLinkTarget('shell:AppsFolder\\$id');

/// Where the shell item at [parsingPath] points when it's a shortcut, such as
/// a `.lnk` file: the target's path or URL. Null when it isn't one.
String? gaiaLinkTarget(String parsingPath) {
  final initialized = CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
  final path = parsingPath.toNativeUtf16();
  final iid = GUIDFromString(IID_IShellItem2);
  final item = calloc<COMObject>();
  final key = calloc<PROPERTYKEY>();
  final text = calloc<Pointer<Utf16>>();
  try {
    if (FAILED(SHCreateItemFromParsingName(path, nullptr, iid, item.cast())) ||
        item.ref.isNull) {
      return null;
    }
    final shell = _detached(IShellItem2(item));
    try {
      // PKEY_Link_TargetParsingPath.
      final format = GUIDFromString('{B9B4B3FC-2B51-4A42-B5D8-324146AFCF25}');
      key.ref
        ..fmtid = format.ref
        ..pid = 2;
      free(format);
      if (FAILED(shell.getString(key, text))) return null;
      final target = text.value.toDartString().trim();
      CoTaskMemFree(text.value);
      return target.isEmpty ? null : target;
    } finally {
      shell.release();
    }
  } finally {
    free(path);
    free(iid);
    free(item);
    free(key);
    free(text);
    if (SUCCEEDED(initialized)) CoUninitialize();
  }
}

final _shGetPropertyStoreForWindow = DynamicLibrary.open('shell32.dll')
    .lookupFunction<
      Int32 Function(IntPtr, Pointer<GUID>, Pointer<Pointer>),
      int Function(int, Pointer<GUID>, Pointer<Pointer>)
    >('SHGetPropertyStoreForWindow');

/// What opens [assoc], a file extension (".pdf") or with [protocol] a URL
/// scheme ("https"): its exe's name and, for a Store app, its app ID. Null
/// fields when Windows doesn't say.
({String? exe, String? appId}) gaiaHandlerOf(
  String assoc, {
  required bool protocol,
}) {
  // ASSOCF_INIT_IGNOREUNKNOWN, so an unknown type isn't "Open with", and
  // ASSOCF_IS_PROTOCOL; ASSOCSTR_EXECUTABLE and ASSOCSTR_APPID.
  final flags = 0x400 | (protocol ? 0x1000 : 0);
  String? query(int what) {
    final name = assoc.toNativeUtf16();
    final out = wsalloc(MAX_PATH);
    final size = calloc<Uint32>()..value = MAX_PATH;
    try {
      if (FAILED(_assocQueryString(flags, what, name, nullptr, out, size))) {
        return null;
      }
      final text = out.toDartString().trim();
      return text.isEmpty ? null : text;
    } finally {
      free(name);
      free(out);
      free(size);
    }
  }

  final exe = query(2);
  return (
    exe: exe == null ? null : p.windows.basenameWithoutExtension(exe),
    appId: query(21),
  );
}

final _assocQueryString = DynamicLibrary.open('shlwapi.dll')
    .lookupFunction<
      Int32 Function(
        Uint32,
        Int32,
        Pointer<Utf16>,
        Pointer<Utf16>,
        Pointer<Utf16>,
        Pointer<Uint32>,
      ),
      int Function(
        int,
        int,
        Pointer<Utf16>,
        Pointer<Utf16>,
        Pointer<Utf16>,
        Pointer<Uint32>,
      )
    >('AssocQueryStringW');

/// Every running process's parent, by pid.
Map<int, int> gaiaProcessParents() {
  final parents = <int, int>{};
  // TH32CS_SNAPPROCESS.
  final snapshot = _createToolhelp32Snapshot(2, 0);
  if (snapshot == INVALID_HANDLE_VALUE) return parents;
  final entry = calloc<_ProcessEntry>()..ref.size = sizeOf<_ProcessEntry>();
  try {
    for (
      var more = _process32First(snapshot, entry);
      more != 0;
      more = _process32Next(snapshot, entry)
    ) {
      parents[entry.ref.pid] = entry.ref.parent;
    }
    return parents;
  } finally {
    free(entry);
    CloseHandle(snapshot);
  }
}

/// PROCESSENTRY32W.
final class _ProcessEntry extends Struct {
  @Uint32()
  external int size;
  @Uint32()
  external int usage;
  @Uint32()
  external int pid;
  @IntPtr()
  external int heap;
  @Uint32()
  external int module;
  @Uint32()
  external int threads;
  @Uint32()
  external int parent;
  @Int32()
  external int priority;
  @Uint32()
  external int flags;
  @Array(MAX_PATH)
  external Array<Uint16> exe;
}

final _kernel32 = DynamicLibrary.open('kernel32.dll');
final _createToolhelp32Snapshot = _kernel32
    .lookupFunction<IntPtr Function(Uint32, Uint32), int Function(int, int)>(
      'CreateToolhelp32Snapshot',
    );
final _process32First = _kernel32
    .lookupFunction<
      Int32 Function(IntPtr, Pointer<_ProcessEntry>),
      int Function(int, Pointer<_ProcessEntry>)
    >('Process32FirstW');
final _process32Next = _kernel32
    .lookupFunction<
      Int32 Function(IntPtr, Pointer<_ProcessEntry>),
      int Function(int, Pointer<_ProcessEntry>)
    >('Process32NextW');

bool _isListedWindow(int hwnd) {
  if (IsWindowVisible(hwnd) == 0 ||
      GetWindow(hwnd, GW_OWNER) != 0 ||
      gaiaIsShellWindow(hwnd) ||
      _isControlBorder(hwnd) ||
      GetWindowTextLength(hwnd) == 0 ||
      GetWindowLongPtr(hwnd, GWL_EXSTYLE) &
              (WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE) !=
          0) {
    return false;
  }
  final cloaked = calloc<Int32>();
  try {
    DwmGetWindowAttribute(hwnd, DWMWA_CLOAKED, cloaked, sizeOf<Int32>());
    return cloaked.value == 0;
  } finally {
    free(cloaked);
  }
}

/// Fits what the user sees of [hwnd] to [frame]: its window rect also holds
/// invisible resize borders, which would leave gaps at the edges of the half.
void _moveWindow(int hwnd, ({int left, int top, int width, int height}) frame) {
  // These wait on the window's thread, which a hung app never answers.
  if (IsHungAppWindow(hwnd) != 0) return;
  // SetWindowPos doesn't bring a window out of maximised or minimised. Not
  // activating: a busy app gets here after Gaia has taken the foreground.
  if (IsZoomed(hwnd) != 0 || IsIconic(hwnd) != 0) {
    ShowWindow(hwnd, SW_SHOWNOACTIVATE);
  }
  final rect = calloc<RECT>();
  final visible = calloc<RECT>();
  try {
    GetWindowRect(hwnd, rect);
    final read = DwmGetWindowAttribute(
      hwnd,
      DWMWA_EXTENDED_FRAME_BOUNDS,
      visible,
      sizeOf<RECT>(),
    );
    final left = SUCCEEDED(read) ? visible.ref.left - rect.ref.left : 0;
    final top = SUCCEEDED(read) ? visible.ref.top - rect.ref.top : 0;
    final right = SUCCEEDED(read) ? rect.ref.right - visible.ref.right : 0;
    final bottom = SUCCEEDED(read) ? rect.ref.bottom - visible.ref.bottom : 0;
    SetWindowPos(
      hwnd,
      0,
      frame.left - left,
      frame.top - top,
      frame.width + left + right,
      frame.height + top + bottom,
      SWP_NOZORDER | SWP_NOACTIVATE,
    );
  } finally {
    free(rect);
    free(visible);
  }
}

bool gaiaIsBrowser(String exe) => _browsers.contains(exe.toLowerCase());

/// Whether a [web] window of [exe] hides its fields with no name (§15.6).
bool gaiaHidesUnnamedFields(String exe, {required bool web}) =>
    web && !_unnamedFieldsTrusted.contains(exe.toLowerCase());

/// Where a quoted selection came from (§15.2): "Google Chrome — Pull
/// requests", without the app's name the title already ends in.
String gaiaSelectionSource(GaiaForegroundWindow window) {
  final title = gaiaTitleWithoutApp(window.title, window.app);
  if (title.isEmpty || title == window.app) return window.app;
  return '${window.app} — $title';
}

/// Whether [exclusions] (§15.4) leave the window out: an entry naming its
/// exe or app, or the host of its [url] or one it's under.
bool gaiaContextExcluded(
  List<String> exclusions, {
  required String exe,
  required String app,
  String? url,
}) {
  final host = url == null ? null : _host(url);
  for (final raw in exclusions) {
    final entry = raw.trim().toLowerCase();
    if (entry.isEmpty) continue;
    if (entry == exe.toLowerCase() || entry == app.toLowerCase()) return true;
    if (host != null && (host == entry || host.endsWith('.$entry'))) {
      return true;
    }
  }
  return false;
}

/// An address bar's text as a host: it often has no scheme.
String? _host(String url) {
  final withScheme = url.contains('://') ? url : 'https://$url';
  final host = Uri.tryParse(withScheme)?.host.toLowerCase();
  return host == null || host.isEmpty ? null : host;
}

/// Whether a control may never be read or typed into, whatever an agent or
/// a page says: a password, card or one-time code field (§15.6). Enforced
/// here because a prompt isn't a boundary; it goes by the control's name and
/// never its value. A port of nus-desktop's `guide/sensitive.js`.
bool gaiaSensitiveControl({
  required bool isPassword,
  required String type,
  required String name,
  required String automationId,
}) {
  if (isPassword) return true;
  final kind = type.toLowerCase();
  if (kind != 'edit' && kind != 'combobox') return false;
  final text = '$name $automationId'
      .replaceAllMapped(
        RegExp('([a-z])([A-Z])'),
        (match) => '${match[1]} ${match[2]}',
      )
      // An acronym's end and a digit are word breaks too: OTPInput, cvv2.
      .replaceAllMapped(
        RegExp('([A-Z])([A-Z][a-z])'),
        (match) => '${match[1]} ${match[2]}',
      )
      .replaceAll(RegExp('(?<=[a-zA-Z])(?=[0-9])|(?<=[0-9])(?=[a-zA-Z])'), ' ')
      .replaceAll(RegExp('[_-]'), ' ')
      .toLowerCase();
  return _sensitiveWords.hasMatch(text);
}

final _sensitiveWords = RegExp(
  r'\b(password|passcode|passwd|pwd|pin|cvv|cvc|ssn|passport|otp)\b'
  r'|\b(?:card|credit|debit|account|routing|social security|national id'
  r'|government id|tax id|driver.?s? licen[cs]e)\s*(?:number|no|num)?\b'
  r'|\b(?:security|verification|one time)\s*code\b',
);

/// The control under the cursor (§15.5), and the browser's address when its
/// window is one's. A sensitive one has no [value], which was never read.
typedef GaiaPointedControl = ({
  String type,
  String name,
  String? value,
  bool sensitive,
  int left,
  int top,
  int width,
  int height,
  String? url,
});

/// How much of a control's name and value goes on a message, which is synced:
/// a document's value can be all its text.
const _maxControlName = 200;
const _maxControlValue = 500;

String _capped(String text, int most) =>
    text.length > most ? '${text.substring(0, most)}…' : text;

/// A [gaiaReadControl] isolate still running, as [_uiaReading] is for its
/// read.
var _controlReading = false;

/// Reads the control under [target]'s point on a worker isolate. Null from a
/// call over budget, or while an earlier one is still stuck, or where there's
/// no control. The budget is [kGaiaUiaBudget], or for a page, which may have to
/// wake its tree first, [kGaiaScreenBudget].
Future<GaiaPointedControl?> gaiaReadControl(GaiaCursorTarget target) async {
  if (_controlReading) return null;
  final (:x, :y, :window) = target;
  final browser = gaiaIsBrowser(window.exe);
  final hwnd = window.hwnd;
  final web = browser || gaiaHostsChromiumPage(hwnd);
  final hideUnnamed = gaiaHidesUnnamedFields(window.exe, web: web);
  _controlReading = true;
  _noteVoyagerRead(hwnd, 'control under the cursor');
  final read = Isolate.run(() {
    final first = _readControl(
      x,
      y,
      hwnd,
      browser: browser,
      hideUnnamed: hideUnnamed,
    );
    if (first == null ||
        !web ||
        !(gaiaLooksAsleep(first.type, first.name) ||
            (hideUnnamed && gaiaFieldUnjudged(first.type, first.name)) ||
            gaiaNotYetAControl(
              first.type,
              first.name,
              width: first.width,
              height: first.height,
            ))) {
      return first;
    }
    // Asked for, the tree wakes. A page still not in it can't be read, and what's
    // under the cursor could be a sensitive field: no control, and no crop.
    final scan = gaiaSettleScan(
      () => gaiaScanWindow(hwnd, browser: browser, text: false),
      web: true,
      wait: () => sleep(const Duration(milliseconds: 250)),
    );
    if (scan == null) return null;
    final again = _readControl(
      x,
      y,
      hwnd,
      browser: browser,
      hideUnnamed: hideUnnamed,
    );
    return again == null ||
            gaiaNotYetAControl(
              again.type,
              again.name,
              width: again.width,
              height: again.height,
            ) ||
            // A sensitive field's name is withheld too, and it's refused as one.
            (hideUnnamed &&
                !again.sensitive &&
                gaiaFieldUnjudged(again.type, again.name)) ||
            (gaiaLooksAsleep(again.type, again.name) && !scan.hasDocument)
        ? null
        : again;
  });
  read.whenComplete(() => _controlReading = false).ignore();
  try {
    return await read.timeout(web ? kGaiaScreenBudget : kGaiaUiaBudget);
  } on TimeoutException {
    return null;
  }
}

/// What a first read of a sleeping page gives for any control on it.
bool gaiaLooksAsleep(String type, String name) =>
    name.isEmpty && (type == 'Pane' || type == 'Document');

/// What else UI Automation gives for a point on a page that isn't in its tree
/// yet, whatever is really there, which is no control even once it's awake: the
/// browser's window, Chromium's host for the page, or something with no size.
bool gaiaNotYetAControl(
  String type,
  String name, {
  required int width,
  required int height,
}) =>
    type == 'Window' ||
    (type == 'Pane' && name == 'Chrome Legacy Window') ||
    width <= 0 ||
    height <= 0;

/// Whether a field on a page can't be judged, and so can't be read (§15.6). What
/// makes a field sensitive is its name, and a page's fields can be in the tree
/// before their names are, with their values.
bool gaiaFieldUnjudged(String type, String name) =>
    name.isEmpty && (type == 'Edit' || type == 'ComboBox');

GaiaPointedControl? _readControl(
  int x,
  int y,
  int hwnd, {
  required bool browser,
  required bool hideUnnamed,
}) {
  CoInitializeEx(nullptr, COINIT_MULTITHREADED);
  final uia = CUIAutomation.createInstance();
  final point = calloc<POINT>();
  final found = calloc<COMObject>();
  final value = calloc<VARIANT>();
  try {
    point.ref
      ..x = x
      ..y = y;
    if (FAILED(uia.elementFromPoint(point.ref, found.cast())) ||
        found.ref.isNull) {
      return null;
    }
    final element = _detached(IUIAutomationElement(found));
    final type = _controlTypeName(element.currentControlType);
    String text(Pointer<Utf16> bstr) {
      if (bstr == nullptr) return '';
      final read = bstr.toDartString();
      SysFreeString(bstr);
      return read.trim();
    }

    final name = text(element.currentName);
    final bounds = _boundsOf(element);
    // Decided before the value is touched, which a sensitive field never is.
    final sensitive = gaiaSensitiveControl(
      isPassword: element.currentIsPassword != 0,
      type: type,
      name: name,
      automationId: text(element.currentAutomationId),
    );
    String? read;
    if (!sensitive &&
        !(hideUnnamed && gaiaFieldUnjudged(type, name)) &&
        SUCCEEDED(
          element.getCurrentPropertyValue(UIA_ValueValuePropertyId, value),
        ) &&
        value.ref.vt == VT_BSTR) {
      final held = value.ref.bstrVal.toDartString().trim();
      if (held.isNotEmpty) read = _capped(held, _maxControlValue);
    }
    return (
      type: type,
      name: sensitive ? '' : _capped(name, _maxControlName),
      value: read,
      sensitive: sensitive,
      left: bounds.left,
      top: bounds.top,
      width: bounds.right - bounds.left,
      height: bounds.bottom - bounds.top,
      // For the exclusion list, which may name the site.
      url: browser ? _addressBar(uia, hwnd) : null,
    );
  } on WindowsException {
    // The control went away while it was being read.
    return null;
  } finally {
    _releaseFound(found);
    VariantClear(value);
    free(found);
    free(point);
    free(value);
    _release(uia);
    CoUninitialize();
  }
}

/// The window an `os_*` tool works on (§15.6), worked out when it runs: the
/// one in front, or with Gaia or the shell in front, the next app window under
/// it that isn't Gaia's. [gaiaPid] is the companion's. Null with nothing in
/// front, as on a locked session, or nothing under it.
GaiaForegroundWindow? gaiaOsTarget(int gaiaPid) {
  final front = GetForegroundWindow();
  if (front == 0) return null;
  if (!_ownedBy(front, gaiaPid) &&
      !gaiaIsShellWindow(front) &&
      IsWindowVisible(front) != 0 &&
      IsIconic(front) == 0) {
    return _describeWindow(front);
  }
  for (
    var next = GetWindow(front, GW_HWNDNEXT);
    next != 0;
    next = GetWindow(next, GW_HWNDNEXT)
  ) {
    if (_isAppWindow(next) && !_ownedBy(next, gaiaPid)) {
      return _describeWindow(next);
    }
  }
  return null;
}

bool _ownedBy(int hwnd, int pid) {
  final owner = calloc<Uint32>();
  try {
    GetWindowThreadProcessId(hwnd, owner);
    return owner.value == pid;
  } finally {
    free(owner);
  }
}

/// What the user sees of [hwnd], without its invisible resize borders.
({int left, int top, int width, int height}) gaiaWindowFrame(int hwnd) {
  final rect = calloc<RECT>();
  try {
    if (FAILED(
      DwmGetWindowAttribute(
        hwnd,
        DWMWA_EXTENDED_FRAME_BOUNDS,
        rect,
        sizeOf<RECT>(),
      ),
    )) {
      GetWindowRect(hwnd, rect);
    }
    return (
      left: rect.ref.left,
      top: rect.ref.top,
      width: rect.ref.right - rect.ref.left,
      height: rect.ref.bottom - rect.ref.top,
    );
  } finally {
    free(rect);
  }
}

/// Pixels `PrintWindow` draws [hwnd] with per physical pixel: 1 for a
/// per-monitor aware app, under 1 for one Windows scales up to its monitor.
double gaiaWindowPrintScale(int hwnd) {
  final dpiX = calloc<Uint32>();
  final dpiY = calloc<Uint32>();
  try {
    final own = GetDpiForWindow(hwnd);
    if (own == 0 ||
        FAILED(
          GetDpiForMonitor(
            MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST),
            MDT_EFFECTIVE_DPI,
            dpiX,
            dpiY,
          ),
        ) ||
        dpiX.value == 0) {
      return 1;
    }
    return own / dpiX.value;
  } finally {
    free(dpiX);
    free(dpiY);
  }
}

/// How long an agent's read of the screen gets (§15.6): a whole window's tree,
/// from an app that may have to wake its accessibility tree first.
const kGaiaScreenBudget = Duration(seconds: 8);

/// The windows with a [gaiaScreenWork] isolate still running.
final _screenWorking = <int>{};

/// How many windows can have one running at once. Each stuck one holds a thread
/// for as long as its app does.
const kGaiaScreenWorkCap = 4;

/// [work] for [hwnd] on a worker isolate within [kGaiaScreenBudget], since
/// cross-process calls can block for as long as the app does. Null over budget,
/// or while an earlier one for [hwnd] is still stuck, so they don't pile up.
/// Throws a [GaiaReadException] when other windows' are holding every slot.
Future<T?> gaiaScreenWork<T>(int hwnd, T Function() work) async {
  if (_screenWorking.contains(hwnd)) return null;
  if (_screenWorking.length >= kGaiaScreenWorkCap) {
    throw GaiaReadException(
      "Another window's read is stuck, so Gaia can't read this one yet. Try "
      'again shortly.',
    );
  }
  _screenWorking.add(hwnd);
  _noteVoyagerRead(hwnd, 'screen work');
  final run = Isolate.run(work);
  run.whenComplete(() => _screenWorking.remove(hwnd)).ignore();
  try {
    return await run.timeout(kGaiaScreenBudget);
  } on TimeoutException {
    return null;
  }
}

/// A browser's address, for the exclusion list; call within [gaiaScreenWork].
String? gaiaReadAddress(int hwnd) {
  CoInitializeEx(nullptr, COINIT_MULTITHREADED);
  final uia = CUIAutomation.createInstance();
  try {
    return _addressBar(uia, hwnd);
  } on WindowsException {
    // The address bar went away while it was being read.
    return null;
  } finally {
    _release(uia);
    CoUninitialize();
  }
}

/// [gaiaScanWindow] for what the agent is shown; call within [gaiaScreenWork].
/// A page gets a moment to wake its tree first. One that doesn't is read anyway,
/// as far as it's in there, since no value is read without its field's name.
GaiaWindowScan? gaiaReadWindow(
  int hwnd, {
  required bool browser,
  ({int left, int top, int width, int height})? region,
  String? matching,
  Set<String>? types,
  bool offscreen = false,
  bool pageOnly = false,
}) {
  if (browser || gaiaHostsChromiumPage(hwnd)) {
    gaiaSettleScan(
      () => gaiaScanWindow(hwnd, browser: browser, text: false),
      web: true,
      wait: () => sleep(const Duration(milliseconds: 250)),
      tries: 4,
    );
  }
  return gaiaScanWindow(
    hwnd,
    browser: browser,
    text: true,
    region: region,
    matching: matching,
    types: types,
    offscreen: offscreen,
    pageOnly: pageOnly,
  );
}

/// How much of a window's tree goes to the agent, and of one leaf's text: what
/// a terminal or an editor holds.
const _maxTreeText = 60000;
const _maxLeafText = 20000;

/// Containers with nothing to say of their own: their children stand in for
/// them, a level up.
const _silentControls = {'Pane', 'Group', 'Control', 'Image', 'Text'};

/// Controls that say, holding the keyboard focus, only that it's somewhere in
/// them. Firefox's Document does, with a field focused before its tree woke
/// holding it, whichever field that is.
const _focusContainers = {'Document', 'Pane', 'Window', 'Group', 'Control'};

/// Whether a control of [type] holding the keyboard focus says what has it. In a
/// window with no page, a container may be what's typed in, as a text editor's
/// Document is. On a page, nor does a field that can't be judged: it could be any
/// field, so it refuses as not knowing does, if the window has a sensitive field.
bool gaiaFocusNamesControl(String type, String name, {required bool web}) =>
    !web ||
    (!_focusContainers.contains(type) && !gaiaFieldUnjudged(type, name));

/// Types whose value is worth asking for. Each is a call to the app, so not
/// every control's.
const _valueControls = {'Edit', 'ComboBox', 'Document', 'Spinner', 'Slider'};

/// A window's controls (§15.6). [sensitive] are the bounds of the fields no
/// tool may read, whose subtrees aren't looked into and whose values are never
/// asked for. [unjudged] are those of a page's fields with no name, treated the
/// same way, except that they don't count as sensitive fields on the window.
typedef GaiaWindowScan = ({
  String? url,
  String tree,
  bool cut,
  List<({int left, int top, int right, int bottom})> sensitive,
  List<({int left, int top, int right, int bottom})> unjudged,
  List<GaiaControlMatch> matches,
  int controls,
  bool hasDocument,
  bool sensitiveFocused,
  bool anyFocused,
});

/// A control [gaiaScanWindow] was asked to find. A sensitive one's [type] and
/// name stay in the worker's scan: only that it matched comes out. [offscreen]
/// when UI Automation says it's scrolled out of view (GAIA_ROUTINES_HLD.md
/// §15.1). [exact] when it matched by its own name, not by its inferred label
/// (§15.4) or a name cut short (§15.7). [focused] when it holds the keyboard
/// focus. [text] is what it holds, a field's value or else its name, for
/// reading it back (§15.3, §15.5); null for a sensitive one. [label] is the
/// text by it (§15.4), which tells apart matches sharing a name; null for a
/// sensitive one.
typedef GaiaControlMatch = ({
  String type,
  bool sensitive,
  int left,
  int top,
  int right,
  int bottom,
  bool offscreen,
  bool exact,
  bool focused,
  String? text,
  String? label,
});

/// Whether a control's [name] and [type] are what an agent asked for. Names are
/// as `os_read_screen` shows them, where a long one ends in an ellipsis.
bool gaiaControlMatches(
  ({String name, String? type}) find, {
  required String name,
  required String type,
}) {
  if (find.type case final wanted?
      when wanted.toLowerCase() != type.toLowerCase()) {
    return false;
  }
  final shown = _capped(name, _maxControlName).trim().toLowerCase();
  return shown.isNotEmpty && shown == find.name.trim().toLowerCase();
}

/// Whether [find]'s name and a control's [name], one of them cut short with an
/// ellipsis, as UI Automation and `os_read_screen` cut long names, start the
/// same (GAIA_ROUTINES_HLD.md §15.7). A step takes such a match only when it's
/// the only one.
bool gaiaControlMatchesCut(
  ({String name, String? type}) find, {
  required String name,
  required String type,
}) {
  if (find.type case final wanted?
      when wanted.toLowerCase() != type.toLowerCase()) {
    return false;
  }
  String? stem(String text) {
    for (final cut in const ['…', '...']) {
      if (text.endsWith(cut)) {
        final stem = text.substring(0, text.length - cut.length).trim();
        return stem.isEmpty ? null : stem;
      }
    }
    return null;
  }

  final shown = _capped(name, _maxControlName).trim().toLowerCase();
  final asked = find.name.trim().toLowerCase();
  if (stem(shown) case final start? when asked.startsWith(start)) return true;
  if (stem(asked) case final start? when shown.startsWith(start)) return true;
  return false;
}

/// How far from a control its inferred label can be, in physical pixels.
const _labelReach = 200;

/// A label for a control at [field] (GAIA_ROUTINES_HLD.md §15.4): a field with
/// no name, or one sharing its name with others, is named after the nearest of
/// [texts], those read before it, above it or to its left. Not its [own] name.
/// Null when none is within [_labelReach].
String? gaiaInferLabel(
  ({int left, int top, int right, int bottom}) field,
  List<({String text, ({int left, int top, int right, int bottom}) bounds})>
  texts, {
  String own = '',
}) {
  String? label;
  var nearest = _labelReach;
  for (final (:text, :bounds) in texts) {
    if (text.toLowerCase() == own.toLowerCase()) continue;
    final int gap;
    if (bounds.bottom <= field.top + 4 &&
        bounds.right > field.left &&
        bounds.left < field.right) {
      gap = field.top - bounds.bottom;
    } else if (bounds.right <= field.left + 4 &&
        bounds.bottom > field.top &&
        bounds.top < field.bottom) {
      gap = field.left - bounds.right;
    } else {
      continue;
    }
    // At the same distance, the later one, nearer in reading order.
    if (gap <= nearest) {
      nearest = gap;
      label = text;
    }
  }
  return label;
}

/// Where a vertical scroll of [view], showing [shown] percent of what it holds
/// and scrolled [at] percent down, goes to bring [target] a third of the way
/// down it (GAIA_ROUTINES_HLD.md §15.1). Null when it can't scroll.
double? gaiaScrollPercentToward({
  required double at,
  required double shown,
  required ({int left, int top, int right, int bottom}) view,
  required ({int left, int top, int right, int bottom}) target,
}) {
  final height = view.bottom - view.top;
  if (height <= 0 || shown <= 0 || shown >= 100) return null;
  // What it holds past what it shows, in pixels.
  final hidden = height * 100 / shown - height;
  final by = target.top - view.top - height / 3;
  return (at + by / hidden * 100).clamp(0.0, 100.0);
}

/// One look at what has focus. Not [held] when UI Automation answered with
/// something that doesn't hold the keyboard focus, as its first answer about a
/// sleeping page does.
typedef GaiaFocusRead = ({bool held, bool sensitive});

/// Whether what has focus can't be typed into (§15.6). Asking UI Automation what
/// has focus proves little for a [web] page: its first answer is an unnamed Pane
/// whatever has focus, and on Firefox the call can block for as long as the app
/// runs. So a page is asked through its tree, once that shows the page. Elsewhere,
/// and if the tree doesn't say, an answer that doesn't hold focus is asked again,
/// and then the tree is. Not knowing counts as sensitive if the window has a
/// sensitive field. On a page, a container holding the focus is not knowing: see
/// [gaiaFocusNamesControl].
bool gaiaSettleFocus(
  GaiaFocusRead? Function() read,
  GaiaWindowScan? Function() scan, {
  required bool web,
  required void Function() wait,
  int tries = 8,
}) {
  if (web) {
    final seen = gaiaSettleScan(scan, web: true, wait: wait);
    if (seen == null || seen.sensitiveFocused) return true;
    if (seen.anyFocused) return false;
  }
  for (var i = 0; i < tries; i++) {
    final look = read();
    if (look == null || look.sensitive) return true;
    if (look.held) return false;
    wait();
  }
  final seen = scan();
  if (seen == null || seen.sensitiveFocused) return true;
  if (seen.anyFocused) return false;
  return seen.sensitive.isNotEmpty;
}

/// [gaiaSettleFocus] for what has focus in [hwnd], in front; call within
/// [gaiaScreenWork].
bool gaiaFocusSensitive(int hwnd, {required bool browser}) {
  final web = browser || gaiaHostsChromiumPage(hwnd);
  return gaiaSettleFocus(
    () => _readFocus(web: web),
    () => gaiaScanWindow(hwnd, browser: browser, text: false),
    web: web,
    wait: () => sleep(const Duration(milliseconds: 250)),
  );
}

/// Null when it can't be asked.
GaiaFocusRead? _readFocus({required bool web}) {
  CoInitializeEx(nullptr, COINIT_MULTITHREADED);
  final uia = CUIAutomation.createInstance();
  final focused = calloc<COMObject>();
  try {
    if (FAILED(uia.getFocusedElement(focused.cast())) || focused.ref.isNull) {
      return null;
    }
    final element = _detached(IUIAutomationElement(focused));
    final type = _controlTypeName(element.currentControlType);
    final name = _taken(element.currentName);
    return (
      held:
          element.currentHasKeyboardFocus != 0 &&
          gaiaFocusNamesControl(type, name, web: web),
      sensitive: gaiaSensitiveControl(
        isPassword: element.currentIsPassword != 0,
        type: type,
        name: name,
        automationId: _taken(element.currentAutomationId),
      ),
    );
  } on WindowsException {
    return null;
  } finally {
    _releaseFound(focused);
    free(focused);
    _release(uia);
    CoUninitialize();
  }
}

/// [hwnd], described as [gaiaOsTarget] describes a window.
GaiaForegroundWindow gaiaDescribeWindow(int hwnd) => _describeWindow(hwnd);

/// Whether [hwnd] is the shell or one of the process [pid]'s: what can be in
/// front of a window an `os_*` action is about to activate (§15.6).
bool gaiaInFrontOfTarget(int hwnd, int pid) =>
    _ownedBy(hwnd, pid) || gaiaIsShellWindow(hwnd);

/// Whether a Chromium page lives in [hwnd], as in Electron and WebView2 apps.
bool gaiaHostsChromiumPage(int hwnd) {
  final className = wsalloc(64);
  try {
    bool within(int parent) {
      for (
        var child = FindWindowEx(parent, 0, nullptr, nullptr);
        child != 0;
        child = FindWindowEx(parent, child, nullptr, nullptr)
      ) {
        GetClassName(child, className, 64);
        if (className.toDartString() == 'Chrome_RenderWidgetHostHWND' ||
            within(child)) {
          return true;
        }
      }
      return false;
    }

    return within(hwnd);
  } finally {
    free(className);
  }
}

/// The scan a screenshot's sensitive fields can be decided from (§15.6). An app
/// may build its tree only once it's asked for one: a Chromium page isn't in
/// its window's tree until about 300 ms after the first read, or at all while
/// the page is covered. So one read says nothing: it takes two that agree, and
/// with [web] content, one that shows the page. Null when it never does.
GaiaWindowScan? gaiaSettleScan(
  GaiaWindowScan? Function() read, {
  required bool web,
  required void Function() wait,
  int tries = 16,
}) {
  var scan = read();
  for (var i = 0; scan != null && i < tries; i++) {
    wait();
    final next = read();
    final settled =
        next != null &&
        next.controls == scan.controls &&
        (!web || next.hasDocument);
    scan = next;
    if (settled) return scan;
  }
  // An app whose tree never stops changing still has its latest read.
  return scan == null || (web && !scan.hasDocument) ? null : scan;
}

/// Reads [hwnd]'s controls in one fetch of its tree; call within
/// [gaiaScreenWork]. With [text] off, only what [GaiaWindowScan.sensitive]
/// needs. [region] keeps the tree to controls touching it, in physical screen
/// pixels. [matching] and [types] keep it to controls with that text in their
/// name or value, and of those types, each under what it's in; either matches
/// regardless of case. [offscreen] keeps the controls UI Automation says are
/// off screen too, as a page's below the fold, marked so. [pageOnly] matches
/// only controls inside a Document, so not a browser's tabs or address bar. [find] fills [GaiaWindowScan.matches] with the
/// controls of that name. Null when its tree couldn't be read at all. [onMatch] is
/// handed each match's element as it's found, and [onScrollable] each
/// on-screen control that can scroll, neither inside a sensitive field: what
/// [gaiaActOnControl] acts on. A [find] matches off-screen controls too, marked
/// so, and by a control's inferred label or a cut-off name
/// (GAIA_ROUTINES_HLD.md §15.1, §15.4, §15.7). [onListItem] is handed the name
/// of each on-screen list option (§15.3).
GaiaWindowScan? gaiaScanWindow(
  int hwnd, {
  required bool browser,
  required bool text,
  ({int left, int top, int width, int height})? region,
  String? matching,
  Set<String>? types,
  bool offscreen = false,
  bool pageOnly = false,
  ({String name, String? type})? find,
  void Function(
    IUIAutomation uia,
    IUIAutomationElement element,
    GaiaControlMatch match,
  )?
  onMatch,
  void Function(
    IUIAutomationElement element,
    ({int left, int top, int right, int bottom}) bounds,
  )?
  onScrollable,
  void Function(String name)? onListItem,
}) {
  CoInitializeEx(nullptr, COINIT_MULTITHREADED);
  final uia = CUIAutomation.createInstance();
  final root = calloc<COMObject>();
  final request = calloc<COMObject>();
  final cached = calloc<COMObject>();
  try {
    final url = browser ? _addressBar(uia, hwnd) : null;
    final web = browser || gaiaHostsChromiumPage(hwnd);
    final hideUnnamed = gaiaHidesUnnamedFields(_exeOf(hwnd), web: web);
    if (FAILED(uia.elementFromHandle(hwnd, root.cast())) ||
        root.ref.isNull ||
        FAILED(uia.createCacheRequest(request.cast())) ||
        request.ref.isNull) {
      return null;
    }
    final cache = _detached(IUIAutomationCacheRequest(request));
    for (final property in [
      UIA_ControlTypePropertyId,
      UIA_NamePropertyId,
      UIA_AutomationIdPropertyId,
      UIA_IsPasswordPropertyId,
      UIA_IsOffscreenPropertyId,
      UIA_BoundingRectanglePropertyId,
      UIA_IsTextPatternAvailablePropertyId,
      UIA_HasKeyboardFocusPropertyId,
      if (onScrollable != null) UIA_IsScrollPatternAvailablePropertyId,
      if (text) ...[
        UIA_IsTogglePatternAvailablePropertyId,
        UIA_ToggleToggleStatePropertyId,
        UIA_IsSelectionItemPatternAvailablePropertyId,
        UIA_SelectionItemIsSelectedPropertyId,
      ] else if (onListItem != null)
        UIA_IsSelectionItemPatternAvailablePropertyId,
    ]) {
      cache.addProperty(property);
    }
    cache.treeScope = TreeScope_Subtree;
    final hr = _detached(IUIAutomationElement(root)).buildUpdatedCache(
      // The request itself, not the slot holding it.
      request.ref.lpVtbl.cast(),
      cached.cast(),
    );
    if (FAILED(hr) || cached.ref.isNull) return null;
    final lines = <String>[];
    var written = 0;
    // The named text read so far, which labels a control after it (§15.4):
    // a page's text labels only the page's controls, never the browser's own
    // (BUG-440), and the browser's text only its own.
    final pageTexts =
        <
          ({String text, ({int left, int top, int right, int bottom}) bounds})
        >[];
    final otherTexts =
        <
          ({String text, ({int left, int top, int right, int bottom}) bounds})
        >[];
    List<({String text, ({int left, int top, int right, int bottom}) bounds})>
    textsIn(bool page) => page ? pageTexts : otherTexts;
    // Each printed control with a name: its line, where its name ends there,
    // how many texts of its group came before it, whether that's the page,
    // and its type and name, which a control shares with others to be given a
    // label (§15.4).
    final named =
        <
          ({
            int line,
            int head,
            int before,
            bool page,
            String key,
            String name,
            ({int left, int top, int right, int bottom}) bounds,
          })
        >[];
    final sensitive = <({int left, int top, int right, int bottom})>[];
    final unjudged = <({int left, int top, int right, int bottom})>[];
    final matches = <GaiaControlMatch>[];
    var cut = false;
    var controls = 0;
    var hasDocument = false;
    var sensitiveFocused = false;
    var anyFocused = false;

    void matchIf(
      IUIAutomationElement element,
      String type,
      String name,
      ({int left, int top, int right, int bottom}) bounds, {
      required bool isSensitive,
      required bool inPage,
      String? label,
    }) {
      if (find == null ||
          bounds.right <= bounds.left ||
          bounds.bottom <= bounds.top) {
        return;
      }
      final exact = gaiaControlMatches(find, name: name, type: type);
      // By its label: a field's with no name, or one sharing it (§15.4).
      String? by() =>
          label ??
          (type == 'Text' || name.isEmpty
              ? null
              : gaiaInferLabel(bounds, textsIn(inPage), own: name));
      final String? labelled;
      if (!exact && !gaiaControlMatchesCut(find, name: name, type: type)) {
        labelled = by();
        if (labelled == null ||
            !gaiaControlMatches(find, name: labelled, type: type)) {
          return;
        }
      } else {
        labelled = by();
      }
      final match = (
        type: type,
        sensitive: isSensitive,
        left: bounds.left,
        top: bounds.top,
        right: bounds.right,
        bottom: bounds.bottom,
        offscreen: element.cachedIsOffscreen != 0,
        exact: exact,
        focused: element.cachedHasKeyboardFocus != 0,
        text: isSensitive
            ? null
            : _valueControls.contains(type)
            ? _valueOf(element, type, leaf: false) ?? ''
            : name,
        label: isSensitive ? null : labelled,
      );
      matches.add(match);
      onMatch?.call(uia, element, match);
    }

    bool inRegion(({int left, int top, int right, int bottom}) bounds) =>
        region == null ||
        (bounds.left < region.left + region.width &&
            bounds.right > region.left &&
            bounds.top < region.top + region.height &&
            bounds.bottom > region.top);

    // [above] is the name of the printed control this one is under.
    final needle = matching?.toLowerCase();
    final kinds = types?.map((type) => type.toLowerCase()).toSet();
    bool keeps(String type, String name, String? value) =>
        (kinds == null || kinds.contains(type.toLowerCase())) &&
        (needle == null ||
            name.toLowerCase().contains(needle) ||
            (value?.toLowerCase().contains(needle) ?? false));

    // The printed controls being walked under, each null once it's written:
    // with a filter, one is written only above a control that's kept.
    final open = <String?>[];
    void emit(String line, {required bool kept}) {
      if (!kept) return;
      for (var i = 0; i < open.length; i++) {
        if (open[i] case final above?) {
          lines.add(above);
          written += above.length + 1;
          open[i] = null;
        }
      }
      lines.add(line);
      written += line.length + 1;
    }

    // The window itself: its title isn't a match, as a wait's text would
    // otherwise show at once whenever the title has it.
    var atRoot = true;
    void walk(
      IUIAutomationElement element,
      int depth,
      String above, {
      bool inPage = false,
    }) {
      final isRoot = atRoot;
      atRoot = false;
      if (text && written >= _maxTreeText) {
        cut = true;
        return;
      }
      final type = _controlTypeName(element.cachedControlType);
      controls++;
      if (type == 'Document') hasDocument = true;
      final focused = element.cachedHasKeyboardFocus != 0;
      final name = _taken(element.cachedName);
      final bounds = _boundsOf(element, cached: true);
      final sized = bounds.right > bounds.left && bounds.bottom > bounds.top;
      // A page's field with no name goes by the text beside it, which judges
      // it as a name would (GAIA_ROUTINES_HLD.md §15.4). With none, it can't be
      // judged, so isn't read.
      final label = hideUnnamed && gaiaFieldUnjudged(type, name)
          ? gaiaInferLabel(bounds, textsIn(inPage))
          : null;
      if (focused && gaiaFocusNamesControl(type, label ?? name, web: web)) {
        anyFocused = true;
      }
      final place =
          '[${bounds.left},${bounds.top} '
          '${bounds.right - bounds.left}x${bounds.bottom - bounds.top}]';
      // Decided before any value is touched, which a sensitive field's never
      // is. Nor its children: a web field's text can be one.
      if (gaiaSensitiveControl(
        isPassword: element.cachedIsPassword != 0,
        type: type,
        name: label ?? name,
        automationId: _taken(element.cachedAutomationId),
      )) {
        sensitive.add(bounds);
        if (focused) sensitiveFocused = true;
        matchIf(
          element,
          type,
          name,
          bounds,
          isSensitive: true,
          inPage: inPage,
          label: label,
        );
        if (text && inRegion(bounds)) {
          emit(
            '${'  ' * depth}$type (sensitive, not read) $place',
            kept: keeps(type, '', null),
          );
        }
        return;
      }
      matchIf(
        element,
        type,
        name,
        bounds,
        isSensitive: false,
        inPage: inPage,
        label: label,
      );
      if (type == 'Text' && name.isNotEmpty && sized) {
        textsIn(inPage).add((text: name, bounds: bounds));
      }
      if (onListItem != null &&
          type == 'ListItem' &&
          name.isNotEmpty &&
          element.cachedIsOffscreen == 0 &&
          _cachedFlag(element, UIA_IsSelectionItemPatternAvailablePropertyId)) {
        onListItem(name);
      }
      if (onScrollable != null &&
          element.cachedIsOffscreen == 0 &&
          _cachedFlag(element, UIA_IsScrollPatternAvailablePropertyId)) {
        onScrollable(element, bounds);
      }
      // Nor its children, as above.
      if (hideUnnamed && label == null && gaiaFieldUnjudged(type, name)) {
        unjudged.add(bounds);
        if (text &&
            (offscreen || element.cachedIsOffscreen == 0) &&
            inRegion(bounds)) {
          emit(
            '${'  ' * depth}$type (no name, not read)'
            '${element.cachedIsOffscreen == 0 ? '' : ' (off screen)'} $place',
            kept: keeps(type, '', null),
          );
        }
        return;
      }
      final children = calloc<COMObject>();
      var printed = false;
      try {
        element.getCachedChildren(children.cast());
        final leaf = children.ref.isNull;
        if (text &&
            (offscreen || element.cachedIsOffscreen == 0) &&
            inRegion(bounds)) {
          final read = _valueControls.contains(type) || leaf
              ? _valueOf(element, type, leaf: leaf)
              : null;
          if (read != null && read.length >= _maxLeafText) cut = true;
          // A name the same as the one it's under only repeats it, as a
          // list row's checkbox and link repeat the row's.
          final shown = name == above ? '' : name;
          // A name cut short is given whole as the value, so a long option,
          // the statement a click agrees to, is read in full
          // (GAIA_ROUTINES_HLD.md §15.7).
          final value =
              read ??
              (shown.length > _maxControlName
                  ? _capped(shown, _maxLeafText)
                  : null);
          if (shown.isNotEmpty ||
              value != null ||
              (sized && !_silentControls.contains(type))) {
            // As JSON strings, so what a page says can't pass for another line.
            final head =
                '${'  ' * depth}$type'
                '${shown.isEmpty ? '' : ' ${jsonEncode(_capped(shown, _maxControlName))}'}'
                '${label == null ? '' : ', labelled by: ${jsonEncode(_capped(label, _maxControlName))}'}';
            final line =
                '$head'
                '${value == null ? '' : ' = ${jsonEncode(value)}'}'
                '${_stateOf(element)}'
                '${element.cachedIsOffscreen == 0 ? '' : ' (off screen)'}'
                ' $place';
            final kept =
                !isRoot &&
                (!pageOnly || inPage) &&
                keeps(type, label ?? name, value);
            emit(line, kept: kept);
            if (kept && shown.isNotEmpty && type != 'Text') {
              named.add((
                line: lines.length - 1,
                head: head.length,
                before: textsIn(inPage).length,
                page: inPage,
                key: '$type\n${name.toLowerCase()}',
                name: name,
                bounds: bounds,
              ));
            }
            open.add(kept ? null : line);
            printed = true;
            above = name;
          }
        }
        if (leaf) return;
        final array = _detached(IUIAutomationElementArray(children));
        for (var i = 0; i < array.length; i++) {
          final child = calloc<COMObject>();
          try {
            if (SUCCEEDED(array.getElement(i, child.cast())) &&
                !child.ref.isNull) {
              walk(
                _detached(IUIAutomationElement(child)),
                printed ? depth + 1 : depth,
                above,
                inPage: inPage || type == 'Document',
              );
            }
          } finally {
            _releaseFound(child);
            free(child);
          }
        }
      } finally {
        if (printed) open.removeLast();
        _releaseFound(children);
        free(children);
      }
    }

    walk(_detached(IUIAutomationElement(cached)), 0, '');
    // Controls sharing a type and name each get their question (§15.4).
    final sharing = <String, int>{};
    for (final control in named) {
      sharing[control.key] = (sharing[control.key] ?? 0) + 1;
    }
    for (final control in named) {
      if (sharing[control.key]! < 2) continue;
      final label = gaiaInferLabel(
        control.bounds,
        textsIn(control.page).sublist(0, control.before),
        own: control.name,
      );
      if (label == null) continue;
      final line = lines[control.line];
      lines[control.line] =
          '${line.substring(0, control.head)}, labelled by: '
          '${jsonEncode(_capped(label, _maxControlName))}'
          '${line.substring(control.head)}';
    }
    return (
      url: url,
      tree: lines.join('\n').trimRight(),
      cut: cut,
      sensitive: sensitive,
      unjudged: unjudged,
      matches: matches,
      controls: controls,
      hasDocument: hasDocument,
      sensitiveFocused: sensitiveFocused,
      anyFocused: anyFocused,
    );
  } on WindowsException {
    // The window went away while it was being read.
    return null;
  } finally {
    [root, request, cached].forEach(_releaseFound);
    free(root);
    free(request);
    free(cached);
    _release(uia);
    CoUninitialize();
  }
}

/// What a direct call is asked to do (GAIA_AUTONOMY_HLD.md §13.2): a left
/// click, typing [text], scrolling [amount] notches in [direction], or
/// scrolling the control into view (GAIA_ROUTINES_HLD.md §15.1). Typing with
/// [replace] sets the value whatever the field holds (§15.5).
typedef GaiaDirectAct = ({
  GaiaDirectKind kind,
  String? text,
  String? direction,
  int amount,
  bool replace,
});

enum GaiaDirectKind { click, type, scroll, reveal }

/// The pattern a direct call ran.
enum GaiaDirectRan {
  invoke,
  toggle,
  select,
  expand,
  collapse,
  setValue,
  scroll,
}

/// Why a direct call didn't run. [noPattern], [hasText] and [page] leave the
/// step to real input, with the window in front; [busy] is an earlier call
/// into the window still stuck.
enum GaiaDirectMiss {
  notFound,
  sensitive,
  disabled,
  denied,
  noPattern,
  hasText,
  page,
  busy,
}

typedef GaiaDirectResult = ({GaiaDirectRan? ran, GaiaDirectMiss? miss});

/// Whether a [gaiaScreenWork] for [hwnd] is still running.
bool gaiaScreenBusy(int hwnd) => _screenWorking.contains(hwnd);

/// Acts on [hwnd]'s control named [find] at [at] through UI Automation, with no
/// input sent (§13.3): found as `os_read_screen` shows it, by the same walk,
/// and called on the element it matched, so it must run where that walk does,
/// within [gaiaScreenWork]. A scroll with no [find] scrolls the window's
/// largest scrollable control.
GaiaDirectResult gaiaActOnControl(
  int hwnd, {
  required bool browser,
  required ({String name, String? type})? find,
  required ({int x, int y}) at,
  required GaiaDirectAct act,
}) {
  // A page keeps its own copy of a field's text. Chromium sends the page an
  // input event for a set value; Firefox wasn't seen to (§13.11).
  if (act.kind == GaiaDirectKind.type &&
      _exeOf(hwnd).toLowerCase() == 'firefox') {
    return (ran: null, miss: GaiaDirectMiss.page);
  }
  // Held open past the scan's own, for the largest scrollable kept from it.
  CoInitializeEx(nullptr, COINIT_MULTITHREADED);
  final largest = calloc<COMObject>();
  var largestArea = 0;
  GaiaDirectResult? result;
  try {
    gaiaScanWindow(
      hwnd,
      browser: browser,
      text: false,
      find: find,
      onMatch: (uia, element, match) {
        // Only scrolling into view acts on one out of view.
        if (result != null ||
            match.offscreen != (act.kind == GaiaDirectKind.reveal) ||
            at.x < match.left ||
            at.x >= match.right ||
            at.y < match.top ||
            at.y >= match.bottom) {
          return;
        }
        // Clicking one, to focus it for the user, is fine; typing isn't.
        if (match.sensitive && act.kind == GaiaDirectKind.type) {
          result = (ran: null, miss: GaiaDirectMiss.sensitive);
          return;
        }
        // Caught here: the scan's own catch would make it "not found".
        try {
          result = _directCall(uia, element, act);
        } on WindowsException catch (error) {
          result = (
            ran: null,
            miss: _missOf(error.hr) ?? GaiaDirectMiss.notFound,
          );
        }
      },
      onScrollable: find != null || act.kind != GaiaDirectKind.scroll
          ? null
          : (element, bounds) {
              final area =
                  (bounds.right - bounds.left) * (bounds.bottom - bounds.top);
              if (area <= largestArea) return;
              largestArea = area;
              _releaseFound(largest);
              largest.ref.lpVtbl = element.ptr.ref.lpVtbl;
              IUnknown(largest)
                ..detach()
                ..addRef();
            },
    );
    if (result case final done?) return done;
    if (find != null) return (ran: null, miss: GaiaDirectMiss.notFound);
    if (largest.ref.isNull) return (ran: null, miss: GaiaDirectMiss.noPattern);
    return _scroll(_detached(IUIAutomationElement(largest)), act);
  } on WindowsException catch (error) {
    // The window went away, or its app refused the call.
    return (ran: null, miss: _missOf(error.hr) ?? GaiaDirectMiss.notFound);
  } finally {
    _releaseFound(largest);
    free(largest);
    CoUninitialize();
  }
}

/// `BM_CLICK`, which the win32 package has no name for.
const _bmClick = 0x00F5;

/// [element]'s own window, when it's a Win32 push button (a WinForms one's
/// class is `WindowsForms10.BUTTON...`); else null.
int? _win32Button(IUIAutomationElement element) {
  if (element.currentControlType != UIA_ButtonControlTypeId) return null;
  final hwnd = element.currentNativeWindowHandle;
  if (hwnd == 0) return null;
  final className = wsalloc(256);
  try {
    GetClassName(hwnd, className, 256);
    final name = className.toDartString().toUpperCase();
    return name == 'BUTTON' || name.contains('.BUTTON.') ? hwnd : null;
  } finally {
    free(className);
  }
}

/// [act] on [element]: a click as its pattern does it, in §13.2's order.
GaiaDirectResult _directCall(
  IUIAutomation uia,
  IUIAutomationElement element,
  GaiaDirectAct act,
) {
  if (element.currentIsEnabled == 0) {
    return (ran: null, miss: GaiaDirectMiss.disabled);
  }
  switch (act.kind) {
    case GaiaDirectKind.click:
      // A Win32 button's Invoke sends it BM_CLICK and waits for the click to
      // be handled: a modal dialog the click opens holds the call until it
      // closes, and every other UI Automation call from Gaia's process into
      // that app waits behind it (BUG-374). Posted, the same click doesn't.
      // Failing, the patterns below say why.
      if (_win32Button(element) case final button?
          when PostMessage(button, _bmClick, 0, 0) != 0) {
        return (ran: GaiaDirectRan.invoke, miss: null);
      }
      // A click on an item selects it, where Invoke would open it, as a
      // double-click does (§13.11); Invoke is what a button's click does.
      for (final (id, ran) in const [
        (UIA_SelectionItemPatternId, GaiaDirectRan.select),
        (UIA_InvokePatternId, GaiaDirectRan.invoke),
        (UIA_TogglePatternId, GaiaDirectRan.toggle),
        (UIA_ExpandCollapsePatternId, GaiaDirectRan.expand),
      ]) {
        final called = _withPattern(element, id, (pattern) {
          switch (ran) {
            case GaiaDirectRan.invoke:
              return (
                _detached(IUIAutomationInvokePattern(pattern)).invoke(),
                ran,
              );
            case GaiaDirectRan.toggle:
              return (
                _detached(IUIAutomationTogglePattern(pattern)).toggle(),
                ran,
              );
            case GaiaDirectRan.select:
              return (
                _detached(IUIAutomationSelectionItemPattern(pattern)).select(),
                ran,
              );
            default:
              final expander = _detached(
                IUIAutomationExpandCollapsePattern(pattern),
              );
              return switch (expander.currentExpandCollapseState) {
                ExpandCollapseState_LeafNode => null,
                ExpandCollapseState_Collapsed => (
                  expander.expand(),
                  GaiaDirectRan.expand,
                ),
                _ => (expander.collapse(), GaiaDirectRan.collapse),
              };
          }
        });
        if (called == null) continue;
        final (hr, did) = called;
        if (SUCCEEDED(hr)) return (ran: did, miss: null);
        if (_missOf(hr) case final miss?) return (ran: null, miss: miss);
        // Offered and failed: the next pattern may still do it.
      }
      return (ran: null, miss: GaiaDirectMiss.noPattern);
    case GaiaDirectKind.type:
      if (element.currentIsPassword != 0) {
        return (ran: null, miss: GaiaDirectMiss.sensitive);
      }
      final typed = _withPattern(element, UIA_ValuePatternId, (pattern) {
        final value = _detached(IUIAutomationValuePattern(pattern));
        if (value.currentIsReadOnly != 0) return GaiaDirectMiss.noPattern;
        // A set value replaces the whole value, so only into an empty field,
        // unless replacing is what's asked.
        if (!act.replace && _taken(value.currentValue).isNotEmpty) {
          return GaiaDirectMiss.hasText;
        }
        final text = act.text!.toNativeUtf16();
        try {
          final hr = value.setValue(text);
          return SUCCEEDED(hr) ? null : _missOf(hr) ?? GaiaDirectMiss.noPattern;
        } finally {
          free(text);
        }
      }, unsupported: GaiaDirectMiss.noPattern);
      return typed == null
          ? (ran: GaiaDirectRan.setValue, miss: null)
          : (ran: null, miss: typed);
    case GaiaDirectKind.scroll:
      return _nearestScrollable(uia, element, (view) => _scroll(view, act));
    case GaiaDirectKind.reveal:
      final shown = _withPattern(
        element,
        UIA_ScrollItemPatternId,
        (pattern) =>
            _detached(IUIAutomationScrollItemPattern(pattern)).scrollIntoView(),
      );
      if (shown != null && SUCCEEDED(shown)) {
        return (ran: GaiaDirectRan.scroll, miss: null);
      }
      // No pattern: its nearest scrollable ancestor, by its offset (§15.1).
      final target = _boundsOf(element);
      return _nearestScrollable(
        uia,
        element,
        (view) => _scrollToward(view, target),
      );
  }
}

/// [call] on [element]'s nearest scrollable ancestor, itself first: the first
/// that doesn't answer no pattern.
GaiaDirectResult _nearestScrollable(
  IUIAutomation uia,
  IUIAutomationElement element,
  GaiaDirectResult Function(IUIAutomationElement view) call,
) {
  final walker = IUIAutomationTreeWalker(uia.controlViewWalker);
  final at = calloc<COMObject>()..ref.lpVtbl = element.ptr.ref.lpVtbl;
  IUnknown(at)
    ..detach()
    ..addRef();
  var current = at;
  try {
    while (true) {
      final scrolled = call(_detached(IUIAutomationElement(current)));
      if (scrolled.miss != GaiaDirectMiss.noPattern) return scrolled;
      final parent = calloc<COMObject>();
      final hr = walker.getParentElement(
        current.ref.lpVtbl.cast(),
        parent.cast(),
      );
      _releaseFound(current);
      free(current);
      current = parent;
      // Past the window is the desktop, which doesn't scroll.
      if (FAILED(hr) || parent.ref.isNull) {
        return (ran: null, miss: GaiaDirectMiss.noPattern);
      }
    }
  } finally {
    _releaseFound(current);
    free(current);
    _release(walker);
  }
}

/// [view] scrolled down or up to bring [target] into it
/// ([gaiaScrollPercentToward]). No pattern when it can't scroll that way.
GaiaDirectResult _scrollToward(
  IUIAutomationElement view,
  ({int left, int top, int right, int bottom}) target,
) {
  final box = _boundsOf(view);
  final scrolled = _withPattern(view, UIA_ScrollPatternId, (pattern) {
    final scroller = _detached(IUIAutomationScrollPattern(pattern));
    if (scroller.currentVerticallyScrollable == 0) {
      return GaiaDirectMiss.noPattern;
    }
    final to = gaiaScrollPercentToward(
      at: scroller.currentVerticalScrollPercent,
      shown: scroller.currentVerticalViewSize,
      view: box,
      target: target,
    );
    if (to == null) return GaiaDirectMiss.noPattern;
    // UIA_ScrollPatternNoScroll: across stays as it is.
    final hr = scroller.setScrollPercent(-1.0, to);
    return SUCCEEDED(hr) ? null : _missOf(hr) ?? GaiaDirectMiss.noPattern;
  }, unsupported: GaiaDirectMiss.noPattern);
  return scrolled == null
      ? (ran: GaiaDirectRan.scroll, miss: null)
      : (ran: null, miss: scrolled);
}

/// The names of [hwnd]'s list options on screen, as an open dropdown shows
/// them (GAIA_ROUTINES_HLD.md §15.3); null when its tree couldn't be read. Call
/// within [gaiaScreenWork].
List<String>? gaiaListItems(int hwnd, {required bool browser}) {
  final names = <String>[];
  final scan = gaiaScanWindow(
    hwnd,
    browser: browser,
    text: false,
    onListItem: names.add,
  );
  return scan == null ? null : names;
}

/// [element] scrolled [act]'s notches, each a tenth of what it shows, in one
/// call: each call lands about 2 s after it's made (§13.11). No pattern when
/// it can't scroll that way.
GaiaDirectResult _scroll(IUIAutomationElement element, GaiaDirectAct act) {
  final horizontal = act.direction == 'left' || act.direction == 'right';
  final sign = act.direction == 'down' || act.direction == 'right' ? 1 : -1;
  final scrolled = _withPattern(element, UIA_ScrollPatternId, (pattern) {
    final scroller = _detached(IUIAutomationScrollPattern(pattern));
    final can = horizontal
        ? scroller.currentHorizontallyScrollable
        : scroller.currentVerticallyScrollable;
    if (can == 0) return GaiaDirectMiss.noPattern;
    final (at, shown) = horizontal
        ? (
            scroller.currentHorizontalScrollPercent,
            scroller.currentHorizontalViewSize,
          )
        : (
            scroller.currentVerticalScrollPercent,
            scroller.currentVerticalViewSize,
          );
    final to = (at + sign * act.amount * shown / 10).clamp(0.0, 100.0);
    // UIA_ScrollPatternNoScroll: the other axis stays as it is.
    const stay = -1.0;
    final hr = horizontal
        ? scroller.setScrollPercent(to, stay)
        : scroller.setScrollPercent(stay, to);
    return SUCCEEDED(hr) ? null : _missOf(hr) ?? GaiaDirectMiss.noPattern;
  }, unsupported: GaiaDirectMiss.noPattern);
  return scrolled == null
      ? (ran: GaiaDirectRan.scroll, miss: null)
      : (ran: null, miss: scrolled);
}

/// [call] on [element]'s pattern [id]; [unsupported] when it has none.
T? _withPattern<T>(
  IUIAutomationElement element,
  int id,
  T? Function(Pointer<COMObject> pattern) call, {
  T? unsupported,
}) {
  final pattern = calloc<COMObject>();
  try {
    if (FAILED(element.getCurrentPattern(id, pattern.cast())) ||
        pattern.ref.isNull) {
      return unsupported;
    }
    return call(pattern);
  } finally {
    _releaseFound(pattern);
    free(pattern);
  }
}

/// A failed call's reason the agent is told, where it has one.
GaiaDirectMiss? _missOf(int hr) => switch (hr.toUnsigned(32)) {
  0x80070005 => GaiaDirectMiss.denied,
  UIA_E_ELEMENTNOTENABLED => GaiaDirectMiss.disabled,
  // UIA_E_ELEMENTNOTAVAILABLE: it went away.
  0x80040201 => GaiaDirectMiss.notFound,
  _ => null,
};

/// What a checkbox, radio button or list item says of itself, as a read shows
/// it: checked, mixed or selected; nothing for none of them. Each only where
/// its pattern is: a control without one still answers its default, which for
/// a toggle is mixed.
String _stateOf(IUIAutomationElement element) {
  final toggle = calloc<VARIANT>();
  try {
    if (_cachedFlag(element, UIA_IsTogglePatternAvailablePropertyId) &&
        SUCCEEDED(
          element.getCachedPropertyValue(
            UIA_ToggleToggleStatePropertyId,
            toggle,
          ),
        ) &&
        toggle.ref.vt == VT_I4) {
      switch (toggle.ref.lVal) {
        case ToggleState_On:
          return ' (checked)';
        case ToggleState_Indeterminate:
          return ' (mixed)';
      }
    }
  } finally {
    VariantClear(toggle);
    free(toggle);
  }
  return _cachedFlag(element, UIA_IsSelectionItemPatternAvailablePropertyId) &&
          _cachedFlag(element, UIA_SelectionItemIsSelectedPropertyId)
      ? ' (selected)'
      : '';
}

bool _cachedFlag(IUIAutomationElement element, int property) {
  final value = calloc<VARIANT>();
  try {
    return SUCCEEDED(element.getCachedPropertyValue(property, value)) &&
        value.ref.vt == VT_BOOL &&
        value.ref.boolVal;
  } finally {
    VariantClear(value);
    free(value);
  }
}

/// Whether [hwnd] is cloaked: on another virtual desktop, or a suspended Store
/// app's.
bool gaiaWindowCloaked(int hwnd) {
  final cloaked = calloc<Int32>();
  try {
    DwmGetWindowAttribute(hwnd, DWMWA_CLOAKED, cloaked, sizeOf<Int32>());
    return cloaked.value != 0;
  } finally {
    free(cloaked);
  }
}

/// The visible, titled top-level windows of process [pid] or owned by [owner]:
/// a dialog its app opened, maybe behind (GAIA_AUTONOMY_HLD.md §13.5). Not a
/// menu or tooltip, which are untitled tool windows.
List<int> gaiaAppWindows(int pid, int owner) {
  final handles = _enumerated = [];
  EnumWindows(Pointer.fromFunction<WNDENUMPROC>(_collectWindow, 0), 0);
  final process = calloc<Uint32>();
  try {
    return [
      for (final hwnd in handles)
        if (IsWindowVisible(hwnd) != 0 &&
            GetWindowTextLength(hwnd) != 0 &&
            GetWindowLongPtr(hwnd, GWL_EXSTYLE) & WS_EX_TOOLWINDOW == 0 &&
            (GetWindow(hwnd, GW_OWNER) == owner ||
                (GetWindowThreadProcessId(hwnd, process) != 0 &&
                    process.value == pid)) &&
            !gaiaWindowCloaked(hwnd))
          hwnd,
    ];
  } finally {
    free(process);
  }
}

/// What [element] holds: its value, or for a leaf with a TextPattern and no
/// value, all its text, as a terminal's. Only a leaf's: a document with
/// children has its fields among them, sensitive ones too.
String? _valueOf(
  IUIAutomationElement element,
  String type, {
  required bool leaf,
}) {
  final value = calloc<VARIANT>();
  final available = calloc<VARIANT>();
  final pattern = calloc<COMObject>();
  Pointer<COMObject>? range;
  final bstr = calloc<Pointer<Utf16>>();
  try {
    if (_valueControls.contains(type) &&
        SUCCEEDED(
          element.getCurrentPropertyValue(UIA_ValueValuePropertyId, value),
        ) &&
        value.ref.vt == VT_BSTR) {
      final held = value.ref.bstrVal.toDartString().trim();
      if (held.isNotEmpty) return _capped(held, _maxLeafText);
    }
    if (!leaf ||
        FAILED(
          element.getCachedPropertyValue(
            UIA_IsTextPatternAvailablePropertyId,
            available,
          ),
        ) ||
        available.ref.vt != VT_BOOL ||
        !available.ref.boolVal ||
        FAILED(element.getCurrentPattern(UIA_TextPatternId, pattern.cast())) ||
        pattern.ref.isNull) {
      return null;
    }
    range = _detached(IUIAutomationTextPattern(pattern)).documentRange;
    if (FAILED(
          _detached(IUIAutomationTextRange(range)).getText(_maxLeafText, bstr),
        ) ||
        bstr.value == nullptr) {
      return null;
    }
    final read = bstr.value.toDartString().trim();
    SysFreeString(bstr.value);
    return read.isEmpty ? null : read;
  } on WindowsException {
    return null;
  } finally {
    if (range != null) {
      _releaseFound(range);
      free(range);
    }
    _releaseFound(pattern);
    VariantClear(value);
    VariantClear(available);
    free(value);
    free(available);
    free(pattern);
    free(bstr);
  }
}

/// A BSTR the caller owns as text, freed.
String _taken(Pointer<Utf16> bstr) {
  if (bstr == nullptr) return '';
  final read = bstr.toDartString().trim();
  SysFreeString(bstr);
  return read;
}

/// [element]'s bounds, in physical screen pixels, or as [cached]. Not through
/// the package's `currentBoundingRectangle` or `cachedBoundingRectangle`, which
/// hand back a view of memory they've already freed (win32 5.15).
({int left, int top, int right, int bottom}) _boundsOf(
  IUIAutomationElement element, {
  bool cached = false,
}) {
  final rect = calloc<RECT>();
  try {
    final hr = (element.ptr.ref.vtable + (cached ? 75 : 43))
        .cast<Pointer<NativeFunction<Int32 Function(Pointer, Pointer<RECT>)>>>()
        .value
        .asFunction<
          int Function(Pointer, Pointer<RECT>)
        >()(element.ptr.ref.lpVtbl, rect);
    if (FAILED(hr)) throw WindowsException(hr);
    return (
      left: rect.ref.left,
      top: rect.ref.top,
      right: rect.ref.right,
      bottom: rect.ref.bottom,
    );
  } finally {
    free(rect);
  }
}

/// UI Automation's own name for a control type; "Control" for any other.
String _controlTypeName(int id) => switch (id) {
  UIA_ButtonControlTypeId => 'Button',
  UIA_CalendarControlTypeId => 'Calendar',
  UIA_CheckBoxControlTypeId => 'CheckBox',
  UIA_ComboBoxControlTypeId => 'ComboBox',
  UIA_DataGridControlTypeId => 'DataGrid',
  UIA_DataItemControlTypeId => 'DataItem',
  UIA_DocumentControlTypeId => 'Document',
  UIA_EditControlTypeId => 'Edit',
  UIA_GroupControlTypeId => 'Group',
  UIA_HeaderControlTypeId => 'Header',
  UIA_HeaderItemControlTypeId => 'HeaderItem',
  UIA_HyperlinkControlTypeId => 'Link',
  UIA_ImageControlTypeId => 'Image',
  UIA_ListControlTypeId => 'List',
  UIA_ListItemControlTypeId => 'ListItem',
  UIA_MenuControlTypeId => 'Menu',
  UIA_MenuBarControlTypeId => 'MenuBar',
  UIA_MenuItemControlTypeId => 'MenuItem',
  UIA_PaneControlTypeId => 'Pane',
  UIA_ProgressBarControlTypeId => 'ProgressBar',
  UIA_RadioButtonControlTypeId => 'RadioButton',
  UIA_ScrollBarControlTypeId => 'ScrollBar',
  UIA_SliderControlTypeId => 'Slider',
  UIA_SpinnerControlTypeId => 'Spinner',
  UIA_SplitButtonControlTypeId => 'SplitButton',
  UIA_StatusBarControlTypeId => 'StatusBar',
  UIA_TabControlTypeId => 'Tab',
  UIA_TabItemControlTypeId => 'TabItem',
  UIA_TableControlTypeId => 'Table',
  UIA_TextControlTypeId => 'Text',
  UIA_ThumbControlTypeId => 'Thumb',
  UIA_TitleBarControlTypeId => 'TitleBar',
  UIA_ToolBarControlTypeId => 'ToolBar',
  UIA_ToolTipControlTypeId => 'ToolTip',
  UIA_TreeControlTypeId => 'Tree',
  UIA_TreeItemControlTypeId => 'TreeItem',
  UIA_WindowControlTypeId => 'Window',
  _ => 'Control',
};

/// Debug-only: a UI Automation read of one of Voyager's own windows (the app or
/// Gaia's companion) turns on that window's Flutter accessibility tree, which
/// is where the engine's `ui::AXTree` console errors come from. Printed so they
/// can be matched to the `[a11y] ... semantics ON` line that follows.
void _noteVoyagerRead(int hwnd, String what) {
  if (!kDebugMode) return;
  final window = _describeWindow(hwnd);
  if (window.exe.toLowerCase() !=
      p.basenameWithoutExtension(Platform.resolvedExecutable).toLowerCase()) {
    return;
  }
  debugPrint(
    '[a11y] Gaia UIA read ($what) of Voyager window "${window.title}" '
    'pid ${window.pid} at ${DateTime.now().toIso8601String()}',
  );
}

/// A [gaiaReadUia] isolate still running, maybe long after its budget, on
/// a hung app's UI Automation call.
var _uiaReading = false;

/// Reads [window]'s URL, when it's a browser, and the focused control's
/// selection, when [selection] asks, on a worker isolate within
/// [kGaiaUiaBudget]. Nothing comes back from a call over budget, or while
/// an earlier one is still stuck, so they don't pile up.
Future<GaiaWindowUia> gaiaReadUia(
  GaiaForegroundWindow window, {
  required bool selection,
}) async {
  final browser = gaiaIsBrowser(window.exe);
  if ((!browser && !selection) || _uiaReading) {
    return (url: null, selection: null);
  }
  final hwnd = window.hwnd;
  _uiaReading = true;
  _noteVoyagerRead(hwnd, 'URL/selection');
  final read = Isolate.run(
    () => _readUia(hwnd, browser: browser, selection: selection),
  );
  read.whenComplete(() => _uiaReading = false).ignore();
  try {
    return await read.timeout(kGaiaUiaBudget);
  } on TimeoutException {
    return (url: null, selection: null);
  }
}

GaiaWindowUia _readUia(
  int hwnd, {
  required bool browser,
  required bool selection,
}) {
  // One synchronous call, so the isolate stays on this thread's apartment.
  CoInitializeEx(nullptr, COINIT_MULTITHREADED);
  final uia = CUIAutomation.createInstance();
  try {
    return (
      url: browser ? _addressBar(uia, hwnd) : null,
      selection: selection ? _selectedText(uia, hwnd) : null,
    );
  } finally {
    _release(uia);
    CoUninitialize();
  }
}

/// The first edit control or combo box in a browser's window: its address bar,
/// an Edit in Chrome and Edge, a ComboBox in Firefox. One on a page is a field
/// the page made, and could hold anything, so with no address bar there's no
/// address.
String? _addressBar(IUIAutomation uia, int hwnd) {
  if (gaiaIsDialog(hwnd)) return null;
  final root = calloc<COMObject>();
  final editCondition = calloc<COMObject>();
  final comboCondition = calloc<COMObject>();
  final condition = calloc<COMObject>();
  final found = calloc<COMObject>();
  final type = calloc<VARIANT>();
  final value = calloc<VARIANT>();
  try {
    if (FAILED(uia.elementFromHandle(hwnd, root.cast())) || root.ref.isNull) {
      return null;
    }
    type.ref
      ..vt = VT_I4
      ..lVal = UIA_EditControlTypeId;
    if (FAILED(
          uia.createPropertyCondition(
            UIA_ControlTypePropertyId,
            type.ref,
            editCondition.cast(),
          ),
        ) ||
        editCondition.ref.isNull) {
      return null;
    }
    type.ref.lVal = UIA_ComboBoxControlTypeId;
    if (FAILED(
          uia.createPropertyCondition(
            UIA_ControlTypePropertyId,
            type.ref,
            comboCondition.cast(),
          ),
        ) ||
        comboCondition.ref.isNull ||
        FAILED(
          // The conditions themselves, not the slots holding them.
          uia.createOrCondition(
            editCondition.ref.lpVtbl.cast(),
            comboCondition.ref.lpVtbl.cast(),
            condition.cast(),
          ),
        ) ||
        condition.ref.isNull) {
      return null;
    }
    final window = _detached(IUIAutomationElement(root));
    if (FAILED(
          // The condition itself, not the slot holding it.
          window.findFirst(
            TreeScope_Descendants,
            condition.ref.lpVtbl.cast(),
            found.cast(),
          ),
        ) ||
        found.ref.isNull) {
      return null;
    }
    final edit = _detached(IUIAutomationElement(found));
    if (edit.currentIsPassword != 0 ||
        _inDocument(uia, found) ||
        FAILED(edit.getCurrentPropertyValue(UIA_ValueValuePropertyId, value)) ||
        value.ref.vt != VT_BSTR) {
      return null;
    }
    final text = value.ref.bstrVal.toDartString().trim();
    return text.isEmpty ? null : text;
  } finally {
    [
      root,
      editCondition,
      comboCondition,
      condition,
      found,
    ].forEach(_releaseFound);
    VariantClear(value);
    free(root);
    free(editCondition);
    free(comboCondition);
    free(condition);
    free(found);
    free(type);
    free(value);
  }
}

/// A browser tab the routine launch card lists (GAIA_ROUTINES_HLD.md §7.2).
typedef GaiaBrowserTab = ({String title, String url});

/// [hwnd]'s tabs, each with its address (GAIA_ROUTINES_HLD.md §7.2). A tab
/// shows its address only while it's selected, so each is selected in turn
/// and the one selected before is selected again after. Off the main
/// isolate, and longer than other screen work: each tab takes a moment.
Future<List<GaiaBrowserTab>> gaiaReadBrowserTabs(int hwnd) async {
  if (_screenWorking.contains(hwnd)) return const [];
  _screenWorking.add(hwnd);
  try {
    return await Isolate.run(
      () => _browserTabs(hwnd),
    ).timeout(const Duration(minutes: 1), onTimeout: () => const []);
  } finally {
    _screenWorking.remove(hwnd);
  }
}

/// An address bar's text as a URL: Chrome's leaves out `https://`.
String gaiaAddressUrl(String address) =>
    RegExp(r'^[a-z][a-z0-9+.-]*://', caseSensitive: false).hasMatch(address)
    ? address
    : 'https://$address';

List<GaiaBrowserTab> _browserTabs(int hwnd) {
  CoInitializeEx(nullptr, COINIT_MULTITHREADED);
  final uia = CUIAutomation.createInstance();
  final root = calloc<COMObject>();
  final condition = calloc<COMObject>();
  final found = calloc<COMObject>();
  final type = calloc<VARIANT>();
  final tabs = <IUIAutomationElement>[];
  try {
    if (FAILED(uia.elementFromHandle(hwnd, root.cast())) || root.ref.isNull) {
      return const [];
    }
    type.ref
      ..vt = VT_I4
      ..lVal = UIA_TabItemControlTypeId;
    if (FAILED(
          uia.createPropertyCondition(
            UIA_ControlTypePropertyId,
            type.ref,
            condition.cast(),
          ),
        ) ||
        condition.ref.isNull) {
      return const [];
    }
    final window = _detached(IUIAutomationElement(root));
    if (FAILED(
          // The condition itself, not the slot holding it.
          window.findAll(
            TreeScope_Descendants,
            condition.ref.lpVtbl.cast(),
            found.cast(),
          ),
        ) ||
        found.ref.isNull) {
      return const [];
    }
    final array = _detached(IUIAutomationElementArray(found));
    for (var i = 0; i < array.length; i++) {
      final element = calloc<COMObject>();
      if (SUCCEEDED(array.getElement(i, element.cast())) &&
          !element.ref.isNull) {
        tabs.add(_detached(IUIAutomationElement(element)));
      } else {
        free(element);
      }
    }
    bool selected(IUIAutomationElement tab) =>
        _withPattern(
          tab,
          UIA_SelectionItemPatternId,
          (pattern) =>
              _detached(
                IUIAutomationSelectionItemPattern(pattern),
              ).currentIsSelected !=
              0,
        ) ??
        false;
    bool select(IUIAutomationElement tab) =>
        _withPattern(
          tab,
          UIA_SelectionItemPatternId,
          (pattern) => SUCCEEDED(
            _detached(IUIAutomationSelectionItemPattern(pattern)).select(),
          ),
        ) ??
        false;
    final before = tabs.indexWhere(selected);
    final addresses = List<String?>.filled(tabs.length, null);
    var shown = _addressBar(uia, hwnd);
    if (before >= 0) addresses[before] = shown;
    for (final (i, tab) in tabs.indexed) {
      if (i == before || !select(tab)) continue;
      // Until the address bar shows the tab's, or a second has gone.
      String? address;
      for (var waited = 0; waited < 1000; waited += 100) {
        sleep(const Duration(milliseconds: 100));
        address = _addressBar(uia, hwnd);
        if (address != null && address != shown) break;
      }
      // Unchanged, it's still the last tab's: this one is left out.
      if (address != null && address != shown) addresses[i] = shown = address;
    }
    if (before >= 0 && tabs.length > 1) select(tabs[before]);
    return [
      for (final (i, tab) in tabs.indexed)
        if (addresses[i] case final address?)
          (title: _taken(tab.currentName), url: gaiaAddressUrl(address)),
    ];
  } on WindowsException {
    return const [];
  } finally {
    tabs.forEach(_release);
    [root, condition, found].forEach(_releaseFound);
    free(root);
    free(condition);
    free(found);
    free(type);
    _release(uia);
    CoUninitialize();
  }
}

/// Whether [element] is on a page, or can't be told apart from one.
bool _inDocument(IUIAutomation uia, Pointer<COMObject> element) {
  final walker = IUIAutomationTreeWalker(uia.controlViewWalker);
  var child = element;
  try {
    while (true) {
      final parent = calloc<COMObject>();
      final hr = walker.getParentElement(
        child.ref.lpVtbl.cast(),
        parent.cast(),
      );
      if (child != element) {
        _releaseFound(child);
        free(child);
      }
      child = parent;
      if (FAILED(hr)) return true;
      if (parent.ref.isNull) return false;
      final type = _detached(IUIAutomationElement(parent)).currentControlType;
      if (type == UIA_DocumentControlTypeId) return true;
    }
  } finally {
    if (child != element) {
      _releaseFound(child);
      free(child);
    }
    _release(walker);
  }
}

/// The selection of the focused control in [hwnd], through its TextPattern;
/// null when it has none, nothing is selected, or the focus has left [hwnd].
/// Searched for in [hwnd] alone: by the time this runs, a summon may have
/// put Gaia in front, and asking Gaia's window turns on its semantics, which
/// the Windows engine can crash on. While [hwnd] is still in front, the
/// focus is asked for directly instead: the search walks the whole tree,
/// slow in a large browser page or document.
String? _selectedText(IUIAutomation uia, int hwnd) {
  final root = calloc<COMObject>();
  final condition = calloc<COMObject>();
  final focused = calloc<COMObject>();
  final pattern = calloc<COMObject>();
  final ranges = calloc<COMObject>();
  final hasFocus = calloc<VARIANT>();
  try {
    hasFocus.ref
      ..vt = VT_BOOL
      ..boolVal = true;
    if (GetForegroundWindow() == hwnd) {
      if (FAILED(uia.getFocusedElement(focused.cast())) || focused.ref.isNull) {
        return null;
      }
    } else if (FAILED(uia.elementFromHandle(hwnd, root.cast())) ||
        root.ref.isNull ||
        FAILED(
          uia.createPropertyCondition(
            UIA_HasKeyboardFocusPropertyId,
            hasFocus.ref,
            condition.cast(),
          ),
        ) ||
        condition.ref.isNull ||
        FAILED(
          // The condition itself, not the slot holding it.
          _detached(IUIAutomationElement(root)).findFirst(
            TreeScope_Subtree,
            condition.ref.lpVtbl.cast(),
            focused.cast(),
          ),
        ) ||
        focused.ref.isNull) {
      return null;
    }
    final element = _detached(IUIAutomationElement(focused));
    if (FAILED(element.getCurrentPattern(UIA_TextPatternId, pattern.cast())) ||
        pattern.ref.isNull) {
      return null;
    }
    final text = _detached(IUIAutomationTextPattern(pattern));
    if (FAILED(text.getSelection(ranges.cast())) || ranges.ref.isNull) {
      return null;
    }
    final array = _detached(IUIAutomationTextRangeArray(ranges));
    final parts = <String>[];
    for (var i = 0; i < array.length; i++) {
      final range = calloc<COMObject>();
      final bstr = calloc<Pointer<Utf16>>();
      try {
        if (FAILED(array.getElement(i, range.cast())) || range.ref.isNull) {
          continue;
        }
        final textRange = _detached(IUIAutomationTextRange(range));
        if (SUCCEEDED(textRange.getText(-1, bstr)) && bstr.value != nullptr) {
          parts.add(bstr.value.toDartString());
          SysFreeString(bstr.value);
        }
      } finally {
        _releaseFound(range);
        free(range);
        free(bstr);
      }
    }
    final selected = parts.join('\n');
    return selected.trim().isEmpty ? null : selected;
  } finally {
    [root, condition, focused, pattern, ranges].forEach(_releaseFound);
    free(root);
    free(condition);
    free(focused);
    free(pattern);
    free(ranges);
    free(hasFocus);
  }
}

/// [object] with its finalizer off: each call here releases what it got
/// itself, before the apartment closes.
T _detached<T extends IUnknown>(T object) => object..detach();

/// Releases what a call put in [object], if it put anything there.
void _releaseFound(Pointer<COMObject> object) {
  if (object.ref.isNull) return;
  IUnknown(object)
    ..detach()
    ..release();
}

void _release(IUnknown object) {
  object
    ..detach()
    ..release();
  free(object.ptr);
}

/// [hwnd]'s exe name, without `.exe`, as [GaiaForegroundWindow.exe] has it.
String _exeOf(int hwnd) {
  final pid = calloc<Uint32>();
  try {
    GetWindowThreadProcessId(hwnd, pid);
    final exe = _processPath(pid.value);
    return exe == null ? '' : p.basenameWithoutExtension(exe);
  } finally {
    free(pid);
  }
}

String? _processPath(int pid) {
  final process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pid);
  if (process == 0) return null;
  final size = calloc<Uint32>()..value = MAX_PATH;
  final path = wsalloc(MAX_PATH);
  try {
    if (QueryFullProcessImageName(process, 0, path, size) == 0) return null;
    return path.toDartString();
  } finally {
    CloseHandle(process);
    free(size);
    free(path);
  }
}

String _windowText(int hwnd) {
  final length = GetWindowTextLength(hwnd);
  if (length == 0) return '';
  final buffer = wsalloc(length + 1);
  try {
    GetWindowText(hwnd, buffer, length + 1);
    return buffer.toDartString();
  } finally {
    free(buffer);
  }
}

/// The exe's own name for itself ("Google Chrome"), from its version
/// resource.
String? _fileDescription(String exe) {
  final path = exe.toNativeUtf16();
  final handle = calloc<Uint32>();
  final translation = r'\VarFileInfo\Translation'.toNativeUtf16();
  final pointer = calloc<Pointer>();
  final length = calloc<Uint32>();
  Pointer<Uint8>? block;
  try {
    final size = GetFileVersionInfoSize(path, handle);
    if (size == 0) return null;
    block = calloc<Uint8>(size);
    if (GetFileVersionInfo(path, 0, size, block) == 0) return null;
    if (VerQueryValue(block, translation, pointer, length) == 0 ||
        length.value < 4) {
      return null;
    }
    final codes = pointer.value.cast<Uint16>();
    String hex(int value) => value.toRadixString(16).padLeft(4, '0');
    final key =
        '\\StringFileInfo\\${hex(codes[0])}${hex(codes[1])}\\FileDescription'
            .toNativeUtf16();
    try {
      if (VerQueryValue(block, key, pointer, length) == 0 ||
          length.value == 0) {
        return null;
      }
      final description = pointer.value.cast<Utf16>().toDartString().trim();
      return description.isEmpty ? null : description;
    } finally {
      free(key);
    }
  } finally {
    free(path);
    free(handle);
    free(translation);
    free(pointer);
    free(length);
    if (block != null) free(block);
  }
}

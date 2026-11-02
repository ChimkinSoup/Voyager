import 'dart:async';
import 'dart:ffi';
import 'dart:isolate';

import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as p;
import 'package:voyager/domain/models/gaia_models.dart';
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
  if (hwnd == 0) return null;
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
    if (other != 0) Isolate.run(() => _moveWindow(other, otherHalf)).ignore();
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
      selection: selection ? _selectedText(uia) : null,
    );
  } finally {
    _release(uia);
    CoUninitialize();
  }
}

/// The first edit control in a browser's window: its address bar, in
/// Chrome, Edge and Firefox alike.
String? _addressBar(IUIAutomation uia, int hwnd) {
  final root = calloc<COMObject>();
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
    if (FAILED(edit.getCurrentPropertyValue(UIA_ValueValuePropertyId, value)) ||
        value.ref.vt != VT_BSTR) {
      return null;
    }
    final text = value.ref.bstrVal.toDartString().trim();
    return text.isEmpty ? null : text;
  } finally {
    [root, condition, found].forEach(_releaseFound);
    VariantClear(value);
    free(root);
    free(condition);
    free(found);
    free(type);
    free(value);
  }
}

/// The focused control's selection, through its TextPattern; null when it
/// has none, or nothing is selected.
String? _selectedText(IUIAutomation uia) {
  final focused = calloc<COMObject>();
  final pattern = calloc<COMObject>();
  final ranges = calloc<COMObject>();
  try {
    if (FAILED(uia.getFocusedElement(focused.cast())) || focused.ref.isNull) {
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
    [focused, pattern, ranges].forEach(_releaseFound);
    free(focused);
    free(pattern);
    free(ranges);
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

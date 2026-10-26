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

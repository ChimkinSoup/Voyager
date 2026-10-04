import 'dart:ffi';
import 'dart:isolate';

import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart';

/// The Windows folder picker, on an isolate of its own.
///
/// `file_picker`'s getDirectoryPath drives this same dialog inline on the
/// platform thread, and takes the process down with an access violation
/// (see the Export Backup tile). Every other `file_picker` dialog runs on a
/// spawned isolate, with a COM apartment of its own; this does the same.
///
/// Returns null when cancelled.
Future<String?> pickFolder({required String title}) {
  // Owned by the window the click came from, so the dialog is modal to it.
  final owner = GetForegroundWindow();
  return Isolate.run(() => _pickFolder(title, owner));
}

String? _pickFolder(String title, int owner) {
  final init = CoInitializeEx(
    nullptr,
    COINIT_APARTMENTTHREADED | COINIT_DISABLE_OLE1DDE,
  );
  // Isolates share pooled threads, so an apartment this call opened is
  // closed again, and one it found open is left alone.
  if (FAILED(init) && init != RPC_E_CHANGED_MODE) throw WindowsException(init);
  try {
    final dialog = FileOpenDialog.createInstance();
    try {
      final options = calloc<Uint32>();
      try {
        _check(dialog.getOptions(options));
        _check(
          dialog.setOptions(
            options.value |
                FOS_PICKFOLDERS |
                FOS_FORCEFILESYSTEM |
                FOS_PATHMUSTEXIST |
                FOS_NOCHANGEDIR,
          ),
        );
      } finally {
        free(options);
      }
      final titlePointer = title.toNativeUtf16();
      try {
        _check(dialog.setTitle(titlePointer));
      } finally {
        free(titlePointer);
      }

      final shown = dialog.show(owner);
      if (shown == HRESULT_FROM_WIN32(ERROR_CANCELLED)) return null;
      _check(shown);

      final itemPointer = calloc<Pointer<COMObject>>();
      try {
        _check(dialog.getResult(itemPointer));
        final item = IShellItem(itemPointer.cast());
        final pathPointer = calloc<Pointer<Utf16>>();
        try {
          _check(item.getDisplayName(SIGDN_FILESYSPATH, pathPointer));
          final path = pathPointer.value.toDartString();
          CoTaskMemFree(pathPointer.value);
          return path;
        } finally {
          free(pathPointer);
          item.release();
        }
      } finally {
        free(itemPointer);
      }
    } finally {
      dialog.release();
    }
  } finally {
    if (SUCCEEDED(init)) CoUninitialize();
  }
}

void _check(int hr) {
  if (FAILED(hr)) throw WindowsException(hr);
}

#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <shobjidl.h>
#include <windows.h>

#include <algorithm>

#include "flutter_window.h"
#include "gaia_tool_pipe.h"
#include "resource.h"
#include "utils.h"

namespace {

// UiaRootObjectId, from UIAutomationCoreApi.h.
constexpr LONG kUiaRootObjectId = -25;

WNDPROC g_flutter_view_proc = nullptr;

// Gaia's view, with the engine's accessibility off: an accessibility query
// (UI Automation or MSAA) is what turns Flutter's semantics on, and the
// Windows engine can't take the first update Gaia sends: an OverlayPortal's
// node comes before its parent lists it, the engine roots its tree there, and
// later crashes on it (AccessibilityBridge::CreateRemoveReparentedNodesUpdate).
// Answered with Windows' default instead, so the engine never sees one;
// screen readers see Gaia as a plain window.
LRESULT CALLBACK GaiaViewProc(HWND hwnd, UINT message, WPARAM wparam,
                              LPARAM lparam) {
  if (message == WM_GETOBJECT) {
    // Only the low 32 bits are valid, as the engine reads it.
    const auto object = static_cast<DWORD>(static_cast<DWORD_PTR>(lparam));
    if (object == static_cast<DWORD>(kUiaRootObjectId) ||
        object == static_cast<DWORD>(OBJID_CLIENT)) {
      return ::DefWindowProcW(hwnd, message, wparam, lparam);
    }
  }
  return ::CallWindowProcW(g_flutter_view_proc, hwnd, message, wparam, lparam);
}

}  // namespace

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // One process per session: closing only hides Voyager to the tray, and a
  // second process would fail to register the hotkeys and open the same
  // database. A second launch hands the running instance the foreground and
  // asks it to show its window instead. The handle is held until exit.
  // A dev profile (DEV_PROFILE_HLD.md) has its own data, so it's its own
  // instance, with its own mutex and messages.
  const std::wstring& profile = DevProfile();
  if (!profile.empty() && !IsValidDevProfile(profile)) {
    const std::wstring text =
        L"VOYAGER_PROFILE must be 1-16 characters of a-z and 0-9, and not "
        L"\"default\": \"" + profile + L"\"";
    ::MessageBoxW(nullptr, text.c_str(), L"Voyager", MB_OK | MB_ICONERROR);
    return EXIT_FAILURE;
  }
  // Gaia's companion (GAIA_HLD.md §3.2): the same exe in its own process,
  // single instance through its own mutex. Only the main instance launches
  // the real one, marked by kGaiaParentEnv, and accepts only that PID on its
  // pipe. Launched any other way, this asks the main instance to show Gaia,
  // starting it first in the tray if it isn't running, and exits.
  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();
  // Gaia's MCP shim (GAIA_HLD.md §5.3): a CLI's stdio relayed to the
  // companion's tool pipe. No window, no engine, no mutex.
  if (std::find(command_line_arguments.begin(), command_line_arguments.end(),
                "--gaia-mcp") != command_line_arguments.end()) {
    return RunGaiaMcpShim();
  }
  const bool companion =
      std::find(command_line_arguments.begin(), command_line_arguments.end(),
                "--companion") != command_line_arguments.end();
  const std::wstring main_mutex =
      ProfileScopedName(L"Local\\Voyager.SingleInstance");
  if (companion && ::GetEnvironmentVariableW(kGaiaParentEnv, nullptr, 0) == 0) {
    HANDLE running = ::OpenMutexW(SYNCHRONIZE, FALSE, main_mutex.c_str());
    if (running) {
      ::CloseHandle(running);
      ::AllowSetForegroundWindow(ASFW_ANY);
      ::PostMessage(HWND_BROADCAST,
                    ::RegisterWindowMessage(
                        ProfileScopedName(kShowGaiaMessage).c_str()),
                    0, 0);
      return EXIT_SUCCESS;
    }
    std::wstring exe(32768, L'\0');
    exe.resize(::GetModuleFileNameW(nullptr, exe.data(),
                                    static_cast<DWORD>(exe.size())));
    std::wstring launch = L"\"" + exe + L"\" --hidden --show-gaia";
    STARTUPINFOW startup{sizeof(startup)};
    PROCESS_INFORMATION process{};
    if (::CreateProcessW(exe.c_str(), launch.data(), nullptr, nullptr, FALSE,
                         0, nullptr, nullptr, &startup, &process)) {
      ::AllowSetForegroundWindow(process.dwProcessId);
      ::CloseHandle(process.hThread);
      ::CloseHandle(process.hProcess);
    }
    return EXIT_SUCCESS;
  }
  if (companion) {
    ::CreateMutex(nullptr, FALSE,
                  ProfileScopedName(L"Local\\Voyager.Companion").c_str());
    if (::GetLastError() == ERROR_ALREADY_EXISTS) return EXIT_SUCCESS;
  }
  // `flutter run -a --gaia-dev`, debug builds only: the companion on its
  // own, with a stand-in for the main instance, so Gaia's UI hot reloads.
  // No mutex, no pipe: it shares nothing with a running Voyager.
  bool gaia_dev = false;
#ifndef NDEBUG
  gaia_dev =
      std::find(command_line_arguments.begin(), command_line_arguments.end(),
                "--gaia-dev") != command_line_arguments.end();
#endif

  if (!companion && !gaia_dev) ::CreateMutex(nullptr, FALSE, main_mutex.c_str());
  if (!companion && !gaia_dev && ::GetLastError() == ERROR_ALREADY_EXISTS) {
    ::AllowSetForegroundWindow(ASFW_ANY);
    ::PostMessage(HWND_BROADCAST,
                  ::RegisterWindowMessage(
                      ProfileScopedName(kShowMainWindowMessage).c_str()),
                  0, 0);
    return EXIT_SUCCESS;
  }

  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger. Not the companion's: a debug
  // build attaches cdb to it at launch (gaia_pipe.cpp), which would pop one
  // up, and its stderr already goes to companion_engine.log.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent() &&
      !companion) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  // Gaia's taskbar button is its own, not grouped under Voyager's, so it
  // shows Gaia's icon. Set before any window exists.
  if (companion || gaia_dev) {
    ::SetCurrentProcessExplicitAppUserModelID(L"Voyager.Gaia");
  }

  flutter::DartProject project(L"data");

  // The login Run entry's launch (see launch_at_login.dart): stays in the tray.
  // The companion starts hidden too; it shows itself when asked.
  const bool start_hidden =
      companion || gaia_dev ||
      std::find(command_line_arguments.begin(), command_line_arguments.end(),
                "--hidden") != command_line_arguments.end();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  // Flutter 3.47+ defaults to Impeller on Windows, which regresses CPU/temp for
  // Voyager's shader/canvas backgrounds. Force Skia until upstream fixes land.
  // Unguarded: FLUTTER_VERSION_* is the app's pubspec version, not the SDK's.
  project.set_impeller_switch(flutter::ImpellerSwitch::Disabled);

  FlutterWindow window(project, start_hidden);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  if (!window.Create(companion || gaia_dev ? L"Gaia" : L"voyager", origin, size)) {
    return EXIT_FAILURE;
  }
  if (companion || gaia_dev) {
    // Gaia's own icon on its title bar and Alt+Tab entry; the window class
    // carries Voyager's.
    ::SendMessage(window.GetHandle(), WM_SETICON, ICON_BIG,
                  reinterpret_cast<LPARAM>(::LoadImage(
                      instance, MAKEINTRESOURCE(IDI_GAIA_ICON), IMAGE_ICON,
                      ::GetSystemMetrics(SM_CXICON),
                      ::GetSystemMetrics(SM_CYICON), 0)));
    ::SendMessage(window.GetHandle(), WM_SETICON, ICON_SMALL,
                  reinterpret_cast<LPARAM>(::LoadImage(
                      instance, MAKEINTRESOURCE(IDI_GAIA_ICON), IMAGE_ICON,
                      ::GetSystemMetrics(SM_CXSMICON),
                      ::GetSystemMetrics(SM_CYSMICON), 0)));
    HWND view = ::FindWindowExW(window.GetHandle(), nullptr, L"FLUTTERVIEW",
                                nullptr);
    if (view) {
      g_flutter_view_proc = reinterpret_cast<WNDPROC>(::SetWindowLongPtrW(
          view, GWLP_WNDPROC, reinterpret_cast<LONG_PTR>(GaiaViewProc)));
    }
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  // window_manager's destroy only posts WM_QUIT, leaving the window alive. Tear
  // down now, while FlutterWindow is intact: left to ~FlutterWindow, destroying
  // the view notifies this window, which forwards it to the dying controller.
  window.Destroy();

  ::CoUninitialize();
  // Not a return: the CRT would run static destructors, freeing the Firebase
  // SDK's globals while its Firestore thread is still terminating on them.
  ::ExitProcess(EXIT_SUCCESS);
}

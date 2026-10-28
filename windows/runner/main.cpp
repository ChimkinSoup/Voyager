#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <shobjidl.h>
#include <windows.h>

#include <algorithm>

#include "flutter_window.h"
#include "gaia_tool_pipe.h"
#include "resource.h"
#include "utils.h"

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
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
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
  // Guarded so 3.44.6 (current pin) still compiles — ImpellerSwitch is 3.47+.
#if FLUTTER_VERSION_MAJOR > 3 || \
    (FLUTTER_VERSION_MAJOR == 3 && FLUTTER_VERSION_MINOR >= 47)
  project.set_impeller_switch(flutter::ImpellerSwitch::Disabled);
#endif

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
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  return EXIT_SUCCESS;
}

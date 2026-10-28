#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <flutter/method_channel.h>
#include <flutter/encodable_value.h>

#include <memory>
#include <vector>

#include "gaia_pipe.h"
#include "gaia_tool_pipe.h"
#include "win32_window.h"

// Registered-message name a second launch broadcasts to ask the running
// instance to show its main window. Scoped per dev profile (see
// ProfileScopedName), as is kQuitMessage.
inline constexpr wchar_t kShowMainWindowMessage[] = L"Voyager.ShowMainWindow";

// Registered-message name scripts/build_release.ps1 broadcasts to quit the
// installed copy the way the tray's Quit does, before replacing its files.
inline constexpr wchar_t kQuitMessage[] = L"Voyager.Quit";

// Registered-message name a `--companion` launch by anything but the main
// instance broadcasts to ask the main instance to show Gaia (main.cpp).
inline constexpr wchar_t kShowGaiaMessage[] = L"Voyager.ShowGaia";

// A window that does nothing but host a Flutter view.
class FlutterWindow : public Win32Window {
 public:
  // Creates a new FlutterWindow hosting a Flutter view running |project|.
  // |start_hidden| skips showing the window on the first frame.
  FlutterWindow(const flutter::DartProject& project, bool start_hidden);
  virtual ~FlutterWindow();

 protected:
  // Win32Window:
  bool OnCreate() override;
  void OnDestroy() override;
  LRESULT MessageHandler(HWND window, UINT const message, WPARAM const wparam,
                         LPARAM const lparam) noexcept override;

 private:
  // Hooks window events system-wide while |watch|, and tells Dart over
  // |cover_channel_| when another window may have come to cover this one.
  void WatchCover(bool watch);

  // The project to run.
  flutter::DartProject project_;

  bool start_hidden_;

  // The Flutter instance hosted by this window.
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;

  // Tells Dart a second launch asked for the main window.
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      instance_channel_;

  // The main instance <-> companion pipe, and its Dart side.
  std::unique_ptr<GaiaPipe> gaia_pipe_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      gaia_pipe_channel_;

  // The companion's pipe for Gaia's MCP shims, created when Dart listens,
  // and its Dart side.
  std::unique_ptr<GaiaToolPipe> gaia_tool_pipe_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      gaia_tool_pipe_channel_;

  // Whether another window covers this one, for Dart to recheck.
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      cover_channel_;
  std::vector<HWINEVENTHOOK> cover_hooks_;

  UINT show_main_window_message_ = 0;
  UINT quit_message_ = 0;
  UINT show_gaia_message_ = 0;
};

#endif  // RUNNER_FLUTTER_WINDOW_H_

#include "flutter_window.h"

#include <flutter/standard_method_codec.h>

#include <optional>
#include <utility>

#include "flutter/generated_plugin_registrant.h"
#include "utils.h"

namespace {

// Posted to the main window when another window was shown, hidden, moved,
// minimised or brought to the front, for Dart to recheck whether one now
// covers it. One at a time: a drag moves a window many times between pumps.
constexpr UINT kCoverEventMessage = WM_APP + 0x48;

HWND g_cover_window = nullptr;
bool g_cover_pending = false;

void CALLBACK OnWindowEvent(HWINEVENTHOOK, DWORD, HWND hwnd, LONG object,
                            LONG child, DWORD, DWORD) {
  // Top-level windows only: the cursor, carets and controls move far more
  // often, and can't cover anything.
  if (object != OBJID_WINDOW || child != CHILDID_SELF || !hwnd ||
      ::GetAncestor(hwnd, GA_ROOT) != hwnd) {
    return;
  }
  if (g_cover_pending || !g_cover_window) return;
  g_cover_pending = true;
  ::PostMessage(g_cover_window, kCoverEventMessage, 0, 0);
}

}  // namespace

FlutterWindow::FlutterWindow(const flutter::DartProject& project,
                             bool start_hidden)
    : project_(project), start_hidden_(start_hidden) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  instance_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(), "voyager/instance",
          &flutter::StandardMethodCodec::GetInstance());
  show_main_window_message_ = ::RegisterWindowMessage(
      ProfileScopedName(kShowMainWindowMessage).c_str());
  quit_message_ =
      ::RegisterWindowMessage(ProfileScopedName(kQuitMessage).c_str());
  show_gaia_message_ =
      ::RegisterWindowMessage(ProfileScopedName(kShowGaiaMessage).c_str());
  gaia_pipe_ = std::make_unique<GaiaPipe>(GetHandle());
  gaia_pipe_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(), "voyager/gaia_pipe",
          &flutter::StandardMethodCodec::GetInstance());
  gaia_pipe_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) {
        const std::string& method = call.method_name();
        if (method == "startCompanion") {
          result->Success(flutter::EncodableValue(
              static_cast<int64_t>(gaia_pipe_->StartCompanion())));
        } else if (method == "connect") {
          result->Success(flutter::EncodableValue(gaia_pipe_->Connect()));
        } else if (method == "send") {
          const auto* frame = std::get_if<std::string>(call.arguments());
          if (frame) gaia_pipe_->Send(*frame);
          result->Success();
        } else if (method == "close") {
          gaia_pipe_->Close();
          result->Success();
        } else {
          result->NotImplemented();
        }
      });
  g_cover_window = GetHandle();
  cover_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(), "voyager/cover",
          &flutter::StandardMethodCodec::GetInstance());
  cover_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) {
        const auto* watch = std::get_if<bool>(call.arguments());
        if (call.method_name() == "watch" && watch) {
          WatchCover(*watch);
          result->Success();
        } else {
          result->NotImplemented();
        }
      });
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  if (start_hidden_) {
    return true;
  }

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  WatchCover(false);
  g_cover_window = nullptr;
  cover_channel_ = nullptr;
  instance_channel_ = nullptr;
  gaia_pipe_channel_ = nullptr;
  gaia_pipe_ = nullptr;
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  if (message == show_main_window_message_ && instance_channel_) {
    instance_channel_->InvokeMethod("showMainWindow", nullptr);
    return 0;
  }
  if (message == quit_message_ && instance_channel_) {
    instance_channel_->InvokeMethod("quit", nullptr);
    return 0;
  }
  if (message == show_gaia_message_ && instance_channel_) {
    instance_channel_->InvokeMethod("showGaia", nullptr);
    return 0;
  }
  if (message == kGaiaPipeEventMessage && gaia_pipe_ && gaia_pipe_channel_) {
    for (auto& event : gaia_pipe_->TakeEvents()) {
      switch (event.kind) {
        case GaiaPipe::Event::Kind::kConnected:
          gaia_pipe_channel_->InvokeMethod("connected", nullptr);
          break;
        case GaiaPipe::Event::Kind::kMessage:
          gaia_pipe_channel_->InvokeMethod(
              "message", std::make_unique<flutter::EncodableValue>(
                             std::move(event.data)));
          break;
        case GaiaPipe::Event::Kind::kDisconnected:
          gaia_pipe_channel_->InvokeMethod("disconnected", nullptr);
          break;
      }
    }
    return 0;
  }

  if (message == kCoverEventMessage) {
    g_cover_pending = false;
    if (cover_channel_) cover_channel_->InvokeMethod("changed", nullptr);
    return 0;
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
    case WM_SYSCOMMAND:
      // A lone Alt press-and-release (lparam 0) would enter keyboard menu
      // mode, which this frameless window has no menu to show for. The mode
      // is invisible but holds mouse capture on this window, so the Flutter
      // view gets no hover until the next click or key. The global hotkeys
      // are all Ctrl+Alt+<key>: their letter goes to the hotkey, and the
      // floater they open sees only Alt coming up. Alt+Space (lparam ' ')
      // would pop the Restore/Move/Size/Close system menu, which this
      // window's own chrome replaces. The taskbar's right-click menu comes
      // by another route and is unaffected.
      if ((wparam & 0xFFF0) == SC_KEYMENU) {
        return 0;
      }
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}

void FlutterWindow::WatchCover(bool watch) {
  for (HWINEVENTHOOK hook : cover_hooks_) ::UnhookWinEvent(hook);
  cover_hooks_.clear();
  if (!watch) return;
  // Out of context, so the events arrive through this thread's message loop.
  constexpr std::pair<DWORD, DWORD> kEvents[] = {
      {EVENT_SYSTEM_FOREGROUND, EVENT_SYSTEM_FOREGROUND},
      {EVENT_SYSTEM_MINIMIZESTART, EVENT_SYSTEM_MINIMIZEEND},
      {EVENT_OBJECT_SHOW, EVENT_OBJECT_HIDE},
      {EVENT_OBJECT_LOCATIONCHANGE, EVENT_OBJECT_LOCATIONCHANGE},
      {EVENT_OBJECT_CLOAKED, EVENT_OBJECT_UNCLOAKED},
  };
  for (const auto& [first, last] : kEvents) {
    HWINEVENTHOOK hook = ::SetWinEventHook(first, last, nullptr, OnWindowEvent,
                                          0, 0, WINEVENT_OUTOFCONTEXT);
    if (hook) cover_hooks_.push_back(hook);
  }
}

#include "gaia_user_input.h"

#include <atomic>
#include <future>
#include <thread>
#include <utility>

namespace {

std::atomic<unsigned int> g_count{0};
std::thread g_thread;
DWORD g_thread_id = 0;

LRESULT CALLBACK KeyboardProc(int code, WPARAM wparam, LPARAM lparam) {
  if (code == HC_ACTION &&
      GaiaIsUserPress(true, wparam,
                      reinterpret_cast<KBDLLHOOKSTRUCT*>(lparam)->flags)) {
    g_count.fetch_add(1, std::memory_order_relaxed);
  }
  return CallNextHookEx(nullptr, code, wparam, lparam);
}

LRESULT CALLBACK MouseProc(int code, WPARAM wparam, LPARAM lparam) {
  if (code == HC_ACTION &&
      GaiaIsUserPress(false, wparam,
                      reinterpret_cast<MSLLHOOKSTRUCT*>(lparam)->flags)) {
    g_count.fetch_add(1, std::memory_order_relaxed);
  }
  return CallNextHookEx(nullptr, code, wparam, lparam);
}

// Low-level hooks run on the thread that set them, while it waits for
// messages, so they get one that does nothing else and can't stall input.
void Watch(std::promise<bool> ready) {
  MSG msg;
  // Makes this thread's queue, for the WM_QUIT that ends it.
  PeekMessage(&msg, nullptr, WM_USER, WM_USER, PM_NOREMOVE);
  g_thread_id = GetCurrentThreadId();
  HINSTANCE module = GetModuleHandle(nullptr);
  HHOOK keyboard = SetWindowsHookEx(WH_KEYBOARD_LL, KeyboardProc, module, 0);
  HHOOK mouse = SetWindowsHookEx(WH_MOUSE_LL, MouseProc, module, 0);
  ready.set_value(keyboard && mouse);
  while (GetMessage(&msg, nullptr, 0, 0) > 0) {
  }
  if (keyboard) UnhookWindowsHookEx(keyboard);
  if (mouse) UnhookWindowsHookEx(mouse);
}

}  // namespace

bool GaiaIsUserPress(bool keyboard, WPARAM message, DWORD flags) {
  if (keyboard) {
    return !(flags & LLKHF_INJECTED) &&
           (message == WM_KEYDOWN || message == WM_SYSKEYDOWN);
  }
  if (flags & LLMHF_INJECTED) return false;
  switch (message) {
    case WM_LBUTTONDOWN:
    case WM_RBUTTONDOWN:
    case WM_MBUTTONDOWN:
    case WM_XBUTTONDOWN:
      return true;
    default:
      return false;
  }
}

int GaiaWatchUserInput(int on) {
  if (g_thread.joinable()) {
    PostThreadMessage(g_thread_id, WM_QUIT, 0, 0);
    g_thread.join();
  }
  if (!on) return 1;
  std::promise<bool> ready;
  auto hooked = ready.get_future();
  g_thread = std::thread(Watch, std::move(ready));
  if (hooked.get()) return 1;
  GaiaWatchUserInput(0);
  return 0;
}

unsigned int GaiaUserInputCount() {
  return g_count.load(std::memory_order_relaxed);
}

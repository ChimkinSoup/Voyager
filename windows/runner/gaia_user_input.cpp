#include "gaia_user_input.h"

#include <atomic>
#include <future>
#include <mutex>
#include <thread>
#include <utility>

namespace {

std::atomic<unsigned int> g_count{0};
// When GaiaEndsSwitch last said yes, as a GetTickCount time.
std::atomic<DWORD> g_switch_tick{0};
std::atomic<bool> g_switched{false};
// Only the hook thread touches it.
GaiaSwitchKeys g_switch_keys;
// GaiaSetOwnHotkeys's, read on the hook thread.
std::mutex g_hotkeys_lock;
std::vector<DWORD> g_hotkeys;
std::thread g_thread;
DWORD g_thread_id = 0;

// Only the hook thread touches it.
GaiaModifierTap g_modifier_tap;

bool Down(int vk) { return (GetAsyncKeyState(vk) & 0x8000) != 0; }

bool IsModifier(DWORD vk) {
  switch (vk) {
    case VK_SHIFT:
    case VK_LSHIFT:
    case VK_RSHIFT:
    case VK_CONTROL:
    case VK_LCONTROL:
    case VK_RCONTROL:
    case VK_MENU:
    case VK_LMENU:
    case VK_RMENU:
    case VK_LWIN:
    case VK_RWIN:
      return true;
    default:
      return false;
  }
}

// GaiaKeyCounts with the modifiers held now.
bool CountsHeld(DWORD vk) {
  UINT mods = 0;
  if (Down(VK_MENU)) mods |= MOD_ALT;
  if (Down(VK_CONTROL)) mods |= MOD_CONTROL;
  if (Down(VK_SHIFT)) mods |= MOD_SHIFT;
  if (Down(VK_LWIN) || Down(VK_RWIN)) mods |= MOD_WIN;
  std::lock_guard<std::mutex> lock(g_hotkeys_lock);
  return GaiaKeyCounts(vk, mods, g_hotkeys);
}

LRESULT CALLBACK KeyboardProc(int code, WPARAM wparam, LPARAM lparam) {
  if (code == HC_ACTION) {
    const auto* key = reinterpret_cast<KBDLLHOOKSTRUCT*>(lparam);
    if ((GaiaIsUserPress(true, wparam, key->flags) &&
         CountsHeld(key->vkCode)) ||
        GaiaEndsModifierTap(g_modifier_tap, wparam, key->vkCode,
                            key->flags)) {
      g_count.fetch_add(1, std::memory_order_relaxed);
    }
    // Win+L's Win key goes up on the lock screen, where no hook sees it.
    if (g_switch_keys.win && !(GetAsyncKeyState(VK_LWIN) & 0x8000) &&
        !(GetAsyncKeyState(VK_RWIN) & 0x8000)) {
      g_switch_keys.win = false;
    }
    if (GaiaEndsSwitch(g_switch_keys, wparam, key->vkCode, key->flags)) {
      g_switch_tick.store(key->time, std::memory_order_relaxed);
      g_switched.store(true, std::memory_order_release);
    }
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

bool GaiaKeyCounts(DWORD vk, UINT mods, const std::vector<DWORD>& hotkeys) {
  if (IsModifier(vk)) return false;
  const DWORD combo = MAKELONG(vk, mods);
  for (const DWORD hotkey : hotkeys) {
    if (hotkey == combo) return false;
  }
  return true;
}

bool GaiaEndsSwitch(GaiaSwitchKeys& state, WPARAM message, DWORD vk,
                    DWORD flags) {
  if (flags & LLKHF_INJECTED) return false;
  const bool down = message == WM_KEYDOWN || message == WM_SYSKEYDOWN;
  const bool up = message == WM_KEYUP || message == WM_SYSKEYUP;
  switch (vk) {
    case VK_LWIN:
    case VK_RWIN:
      state.win = down;
      return false;
    case VK_MENU:
    case VK_LMENU:
    case VK_RMENU:
      if (up && state.alt_tab) {
        state.alt_tab = false;
        return true;
      }
      return false;
    case VK_TAB:
      // Win+Tab only opens Task View.
      if (down && (flags & LLKHF_ALTDOWN)) state.alt_tab = true;
      return false;
    default:
      return down && state.win;
  }
}

bool GaiaEndsModifierTap(GaiaModifierTap& state, WPARAM message, DWORD vk,
                         DWORD flags) {
  if (flags & LLKHF_INJECTED) return false;
  if (message == WM_KEYDOWN || message == WM_SYSKEYDOWN) {
    if (state.vk == 0) {
      if (IsModifier(vk)) state = {vk, false};
    } else if (vk != state.vk) {
      // Held, it repeats; any other key makes it a combination.
      state.other = true;
    }
    return false;
  }
  if ((message != WM_KEYUP && message != WM_SYSKEYUP) || vk != state.vk) {
    return false;
  }
  const bool tap = !state.other;
  state = {};
  return tap;
}

int GaiaWatchUserInput(int on) {
  if (g_thread.joinable()) {
    PostThreadMessage(g_thread_id, WM_QUIT, 0, 0);
    g_thread.join();
  }
  if (!on) return 1;
  g_switch_keys = {};
  g_modifier_tap = {};
  g_switched.store(false, std::memory_order_relaxed);
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

void GaiaSetOwnHotkeys(const unsigned int* hotkeys, int count) {
  std::lock_guard<std::mutex> lock(g_hotkeys_lock);
  g_hotkeys.assign(hotkeys, hotkeys + count);
}

unsigned int GaiaUserSwitchAge() {
  if (!g_switched.load(std::memory_order_acquire)) return 0xFFFFFFFF;
  return GetTickCount() - g_switch_tick.load(std::memory_order_relaxed);
}

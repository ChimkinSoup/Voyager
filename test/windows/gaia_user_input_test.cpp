// Standalone native regression test. From an x64 Visual Studio tools prompt:
// cl /std:c++17 /EHsc /DNOMINMAX /DUNICODE /D_UNICODE /Iwindows\runner
//   test\windows\gaia_user_input_test.cpp windows\runner\gaia_user_input.cpp
//   /Febuild\gaia_user_input_test.exe /link user32.lib
// Sends injected input while the hooks are in: none of it may count as the
// user's. It taps F24 and the wheel, which nothing acts on.
#include <windows.h>

#include <cstdio>

#include "gaia_user_input.h"

namespace {
int g_failures = 0;

void Expect(bool ok, const char* what) {
  if (!ok) {
    ++g_failures;
    std::printf("FAIL: %s\n", what);
  }
}

// Sends |inputs|, then lets the hook thread see them.
void SendAndWait(INPUT* inputs, UINT count) {
  SendInput(count, inputs, sizeof(INPUT));
  Sleep(100);
}
}  // namespace

int main() {
  Expect(GaiaIsUserPress(true, WM_KEYDOWN, 0), "a key press counts");
  Expect(GaiaIsUserPress(true, WM_SYSKEYDOWN, 0), "Alt+Tab counts");
  Expect(!GaiaIsUserPress(true, WM_KEYUP, 0), "a key release doesn't");
  Expect(!GaiaIsUserPress(true, WM_KEYDOWN, LLKHF_INJECTED),
         "an injected key doesn't");
  Expect(GaiaIsUserPress(false, WM_LBUTTONDOWN, 0), "a click counts");
  Expect(GaiaIsUserPress(false, WM_RBUTTONDOWN, 0), "a right click counts");
  Expect(GaiaIsUserPress(false, WM_XBUTTONDOWN, 0), "a side button counts");
  Expect(!GaiaIsUserPress(false, WM_MOUSEMOVE, 0), "a mouse move doesn't");
  Expect(!GaiaIsUserPress(false, WM_MOUSEWHEEL, 0), "the wheel doesn't");
  Expect(!GaiaIsUserPress(false, WM_LBUTTONUP, 0), "a button release doesn't");
  Expect(!GaiaIsUserPress(false, WM_LBUTTONDOWN, LLMHF_INJECTED),
         "an injected click doesn't");

  for (int round = 0; round < 2; ++round) {
    Expect(GaiaWatchUserInput(1) == 1, "the hooks go in");
    const unsigned int before = GaiaUserInputCount();
    INPUT keys[2] = {};
    keys[0].type = keys[1].type = INPUT_KEYBOARD;
    keys[0].ki.wVk = keys[1].ki.wVk = VK_F24;
    keys[1].ki.dwFlags = KEYEVENTF_KEYUP;
    SendAndWait(keys, 2);
    INPUT wheel = {};
    wheel.type = INPUT_MOUSE;
    wheel.mi.dwFlags = MOUSEEVENTF_WHEEL;
    wheel.mi.mouseData = 0;
    SendAndWait(&wheel, 1);
    INPUT move = {};
    move.type = INPUT_MOUSE;
    move.mi.dwFlags = MOUSEEVENTF_MOVE;
    SendAndWait(&move, 1);
    Expect(GaiaUserInputCount() == before, "injected input isn't counted");
    Expect(GaiaWatchUserInput(0) == 1, "the hooks come out");
  }

  std::printf(g_failures ? "%d failed\n" : "All passed\n", g_failures);
  return g_failures ? 1 : 0;
}

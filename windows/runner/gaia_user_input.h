#ifndef RUNNER_GAIA_USER_INPUT_H_
#define RUNNER_GAIA_USER_INPUT_H_

#include <windows.h>

#include <vector>

// Whether a low-level hook's event is the user pressing a key or a mouse
// button: not input any program injected, Gaia's included, and not the mouse
// moving or its wheel (GAIA_AUTONOMY_HLD.md §5.2).
bool GaiaIsUserPress(bool keyboard, WPARAM message, DWORD flags);

// Whether the user pressing |vk|, with |mods| (MOD_ALT, MOD_CONTROL,
// MOD_SHIFT, MOD_WIN) held, is them stepping in: not a modifier on its way
// down, which may be part of a combination (GaiaEndsModifierTap counts one
// tapped alone), nor one of |hotkeys| (each MAKELONG(vk, mods)), Gaia's
// own, which Windows keeps from the app in front.
bool GaiaKeyCounts(DWORD vk, UINT mods, const std::vector<DWORD>& hotkeys);

// What a low-level keyboard hook has seen of a keyboard window switch so far.
struct GaiaSwitchKeys {
  bool alt_tab = false;
  bool win = false;
};

// Whether a low-level keyboard hook's event, in order after those |state|
// has seen, ends the user's own window switch: Alt let go after Tab was
// pressed with it (Alt+Tab), or a key pressed with Win held (Win+1 to Win+9,
// Win+E and the like). Injected keys are left out.
bool GaiaEndsSwitch(GaiaSwitchKeys& state, WPARAM message, DWORD vk,
                    DWORD flags);

// What a low-level keyboard hook has seen of a modifier pressed alone so far:
// the first one down, and whether any other key went down while it was held.
struct GaiaModifierTap {
  DWORD vk = 0;
  bool other = false;
};

// Whether a low-level keyboard hook's event, in order after those |state|
// has seen, ends a modifier tapped alone, which GaiaKeyCounts leaves out on
// its way down: Alt putting the focus on a menu bar, Win opening Start. Not
// one held for a combination, as Gaia's own hotkeys are. Injected keys are
// left out.
bool GaiaEndsModifierTap(GaiaModifierTap& state, WPARAM message, DWORD vk,
                         DWORD flags);

// An Auto session's watch for the user stepping in, looked up by Dart over FFI.
// With |on|, low-level hooks on a thread of their own count the user's presses;
// returns 0 if they couldn't go in. Off takes them out.
extern "C" __declspec(dllexport) int GaiaWatchUserInput(int on);

// The user's presses counted so far.
extern "C" __declspec(dllexport) unsigned int GaiaUserInputCount();

// Gaia's registered hotkeys, |count| of them, each MAKELONG(vk, mods), which
// GaiaUserInputCount leaves out.
extern "C" __declspec(dllexport) void GaiaSetOwnHotkeys(
    const unsigned int* hotkeys, int count);

// Milliseconds since the user last switched windows from the keyboard, as
// GaiaEndsSwitch tells; 0xFFFFFFFF if they haven't while the hooks were in.
extern "C" __declspec(dllexport) unsigned int GaiaUserSwitchAge();

#endif  // RUNNER_GAIA_USER_INPUT_H_

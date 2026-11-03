#ifndef RUNNER_GAIA_USER_INPUT_H_
#define RUNNER_GAIA_USER_INPUT_H_

#include <windows.h>

// Whether a low-level hook's event is the user pressing a key or a mouse
// button: not input any program injected, Gaia's included, and not the mouse
// moving or its wheel (GAIA_AUTONOMY_HLD.md §5.2).
bool GaiaIsUserPress(bool keyboard, WPARAM message, DWORD flags);

// An Auto session's watch for the user stepping in, looked up by Dart over FFI.
// With |on|, low-level hooks on a thread of their own count the user's presses;
// returns 0 if they couldn't go in. Off takes them out.
extern "C" __declspec(dllexport) int GaiaWatchUserInput(int on);

// The user's presses counted so far.
extern "C" __declspec(dllexport) unsigned int GaiaUserInputCount();

#endif  // RUNNER_GAIA_USER_INPUT_H_

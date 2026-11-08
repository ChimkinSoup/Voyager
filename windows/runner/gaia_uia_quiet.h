#ifndef RUNNER_GAIA_UIA_QUIET_H_
#define RUNNER_GAIA_UIA_QUIET_H_

// Keeps a direct call's window behind the user's (GAIA_AUTONOMY_HLD.md §13.3,
// BUG-372). Before a pattern call, UI Automation gives the control focus, and
// to be allowed to, it injects an unassigned key (VK 0xB9) from this process:
// the input lets the target take the foreground from the app the user is
// typing in. This stubs UIAutomationCore.dll's own SendInput in this process,
// so that the target is refused the front, and the call still lands.
// Gaia's own input goes through user32 directly and isn't affected.
//
// Loads UIAutomationCore.dll and keeps it loaded, so the stub stays. Returns 1
// once it's in place, 0 if it couldn't be. Safe to call any number of times.
extern "C" __declspec(dllexport) int GaiaKeepUiaBehind();

#endif  // RUNNER_GAIA_UIA_QUIET_H_

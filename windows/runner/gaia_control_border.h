#ifndef RUNNER_GAIA_CONTROL_BORDER_H_
#define RUNNER_GAIA_CONTROL_BORDER_H_

#include <windows.h>

#include <string>
#include <vector>

// The "Gaia is in control" border (GAIA_HLD.md §15.6): a thin strip along each
// edge of every monitor and a label on the primary one, on top of everything,
// which clicks pass through and captures leave out. Strips rather than one
// window with a hole, as a topmost window the size of the monitor reads as a
// full screen app to Windows, and as covering the main window to Voyager.
class GaiaControlBorder {
 public:
  GaiaControlBorder() = default;
  ~GaiaControlBorder();
  GaiaControlBorder(const GaiaControlBorder&) = delete;
  GaiaControlBorder& operator=(const GaiaControlBorder&) = delete;

  // Shows the border with |label|, or moves it to the monitors as they are.
  void Show(const std::wstring& label);
  void Hide();

 private:
  static LRESULT CALLBACK WindowProc(HWND hwnd, UINT message, WPARAM wparam,
                                     LPARAM lparam) noexcept;
  static BOOL CALLBACK AddMonitor(HMONITOR monitor, HDC, LPRECT, LPARAM self);

  HWND AddWindow(int left, int top, int width, int height);
  void Rebuild();

  std::vector<HWND> windows_;
  HWND label_window_ = nullptr;
  std::wstring label_;
};

#endif  // RUNNER_GAIA_CONTROL_BORDER_H_

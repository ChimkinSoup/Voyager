#ifndef RUNNER_GAIA_CONTROL_BORDER_H_
#define RUNNER_GAIA_CONTROL_BORDER_H_

#include <windows.h>

#include <functional>
#include <string>
#include <vector>

// The "Gaia is in control" border (GAIA_HLD.md §15.6): a glowing strip along
// each edge of every monitor, and on the primary one a notch with a label and a
// button that revokes access. Clicks pass through all but the button. All on top
// of everything, and left out of captures. Strips rather than one window with a
// hole, as a topmost window the size of the monitor reads as a full screen app
// to Windows, and as covering the main window to Voyager.
class GaiaControlBorder {
 public:
  // |on_revoke| runs when the user presses the button.
  explicit GaiaControlBorder(std::function<void()> on_revoke);
  ~GaiaControlBorder();
  GaiaControlBorder(const GaiaControlBorder&) = delete;
  GaiaControlBorder& operator=(const GaiaControlBorder&) = delete;

  // Shows the border with |label| in |accent| (0xRRGGBB), or moves it to the
  // monitors as they are.
  void Show(const std::wstring& label, unsigned int accent);
  void Hide();

 private:
  static LRESULT CALLBACK WindowProc(HWND hwnd, UINT message, WPARAM wparam,
                                     LPARAM lparam) noexcept;
  static BOOL CALLBACK AddMonitor(HMONITOR monitor, HDC, LPRECT, LPARAM self);

  HWND AddWindow(int left, int top, int width, int height, bool clickable);
  void Rebuild();
  void AddNotch(HMONITOR monitor, const RECT& bounds);
  void PaintNotch();
  void SetButtonState(bool hover, bool pressed);

  std::function<void()> on_revoke_;
  std::vector<HWND> windows_;
  HWND notch_ = nullptr;
  HWND button_window_ = nullptr;
  HMONITOR notch_monitor_ = nullptr;
  SIZE notch_size_ = {};
  RECT button_ = {};  // In the notch's client area.
  RECT label_rect_ = {};  // Likewise.
  bool hover_ = false;
  bool pressed_ = false;
  std::wstring label_;
  unsigned int accent_ = 0;
};

#endif  // RUNNER_GAIA_CONTROL_BORDER_H_

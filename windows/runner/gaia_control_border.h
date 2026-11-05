#ifndef RUNNER_GAIA_CONTROL_BORDER_H_
#define RUNNER_GAIA_CONTROL_BORDER_H_

#include <windows.h>

#include <functional>
#include <memory>
#include <string>
#include <vector>

enum class GaiaEffectStyle { kClassic, kAstral, kEcho, kGlide };

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
  void Show(const std::wstring& label, unsigned int accent,
            GaiaEffectStyle style = GaiaEffectStyle::kAstral);
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
  GaiaEffectStyle style_ = GaiaEffectStyle::kAstral;
};

// One of Gaia's flashes (GAIA_AUTONOMY_HLD.md §6.2), in physical pixels.
struct GaiaFlash {
  using Style = GaiaEffectStyle;
  Style style = Style::kAstral;
  enum class ClickVariant { kTrace, kBloom, kTraceBloom };
  ClickVariant click_variant = ClickVariant::kTraceBloom;
  enum class Kind {
    kClick, kDouble, kRight, kScroll, kType, kKey, kWindow, kMark, kDrag
  };
  Kind kind = Kind::kClick;
  POINT point = {};
  // Where a drag lets go; |point| is where it takes hold.
  POINT to = {};
  // The field typed into, the window for a key or a window flash, or the
  // control a mark outlines. Empty for none.
  RECT rect = {};
  // A scroll's: 0 up, 1 down, 2 left, 3 right.
  int direction = 0;
  int amount = 3;
  // How long typing goes on, or a drag takes to travel.
  int duration_ms = 0;
  // The control's name, the keys, or the window's app. Never typed text.
  std::wstring label;
  unsigned int accent = 0;
};

// Plays flashes over everything: small layered windows that are topmost,
// never activate, pass clicks and hit tests through, and are left out of
// captures. A timer runs only while one is playing.
class GaiaFlashes {
 public:
  GaiaFlashes();
  ~GaiaFlashes();
  GaiaFlashes(const GaiaFlashes&) = delete;
  GaiaFlashes& operator=(const GaiaFlashes&) = delete;

  void Play(const GaiaFlash& flash);
  // Ends every flash playing, hiding its windows at once.
  void StopAll();

 private:
  struct Active;

  static LRESULT CALLBACK WindowProc(HWND hwnd, UINT message, WPARAM wparam,
                                     LPARAM lparam) noexcept;

  HWND Acquire();
  void Release(HWND window);
  void Tick();

  HWND timer_window_ = nullptr;
  bool ticking_ = false;
  std::vector<HWND> pool_;
  // Finished windows, hidden one a frame, as hiding is the costliest update.
  std::vector<HWND> hiding_;
  std::vector<std::unique_ptr<Active>> active_;
};

#endif  // RUNNER_GAIA_CONTROL_BORDER_H_

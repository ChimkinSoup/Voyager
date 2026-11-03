#include "gaia_control_border.h"

#include <objidl.h>
#include <shellscalingapi.h>

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <utility>

// gdiplus.h wants min and max, which NOMINMAX takes away.
namespace Gdiplus {
using std::max;
using std::min;
}  // namespace Gdiplus
#include <gdiplus.h>

namespace {

constexpr wchar_t kWindowClass[] = L"VoyagerGaiaControlBorder";
constexpr wchar_t kButtonText[] = L"Revoke access";
// Gaia's typeface (AppFonts.family), as Flutter bundles it beside the exe.
constexpr wchar_t kFontFile[] =
    L"data\\flutter_assets\\assets\\Iosevka-Regular\\Iosevka-Aile-01.ttf";

// All at 100%.
constexpr int kGlowDepth = 26;
constexpr float kLineWidth = 2.5f;
constexpr int kNotchHeight = 42;
// The ring's height along the notch's bottom edge, in pixels at any scale. The
// top edge has none, so the contents centre in what's above it.
constexpr int kNotchRim = 2;
constexpr int kNotchRadius = 16;
constexpr int kNotchPadding = 14;
constexpr int kOrbSize = 14;
constexpr int kGap = 10;
constexpr int kFontSize = 14;
constexpr BYTE kTextLevel = 0xE7;
// How far, in ems, a line centred by its box leaves lowercase below the middle.
constexpr float kTextLift = 0.08f;
// The button's text hangs nothing below the line, so it centres from its capital
// to its baseline instead, a little lower than its box would put it.
constexpr float kButtonTextLift = -0.02f;
constexpr int kButtonHeight = 26;
constexpr int kButtonPadding = 12;
constexpr int kButtonRadius = 6;
constexpr int kMaxLabelWidth = 420;

constexpr float kPi = 3.14159265f;

// WDA_EXCLUDEFROMCAPTURE, from Windows 10 2004. Older ones ignore the call.
constexpr DWORD kExcludeFromCapture = 0x11;

struct Color {
  float r, g, b;
};

// Gaia's Astral palette (gaia_orb_materials.dart).
constexpr Color kGold = {1.0f, 0.875f, 0.569f};
constexpr Color kWhite = {1.0f, 1.0f, 1.0f};
constexpr Color kBlack = {0.0f, 0.0f, 0.0f};

Color FromRgb(unsigned int rgb) {
  return {((rgb >> 16) & 0xFF) / 255.0f, ((rgb >> 8) & 0xFF) / 255.0f,
          (rgb & 0xFF) / 255.0f};
}

Color Mix(Color a, Color b, float t) {
  return {a.r + (b.r - a.r) * t, a.g + (b.g - a.g) * t, a.b + (b.b - a.b) * t};
}

// The fill of Gaia's buttons: its surface (gaiaSurface), halfway to black.
Color GaiaFill(Color accent) {
  return Mix(Mix(FromRgb(0x15181B), accent, 0.1f), kBlack, 0.5f);
}

// |color| at full HSL saturation, as a lit GaiaGlowRing is.
Color Saturated(Color color) {
  const float high = std::max({color.r, color.g, color.b});
  const float low = std::min({color.r, color.g, color.b});
  const float chroma = high - low;
  if (chroma <= 0) return color;
  const float light = (high + low) / 2;
  const float scale = (1 - std::abs(2 * light - 1)) / chroma;
  return {light + (color.r - light) * scale, light + (color.g - light) * scale,
          light + (color.b - light) * scale};
}

float Clamp01(float value) { return std::clamp(value, 0.0f, 1.0f); }

int Scaled(int value, HMONITOR monitor) {
  UINT dpi_x = 96;
  UINT dpi_y = 96;
  ::GetDpiForMonitor(monitor, MDT_EFFECTIVE_DPI, &dpi_x, &dpi_y);
  return ::MulDiv(value, dpi_x, 96);
}

// Gaia's typeface. Loaded the first time the border shows, and kept: GDI+ stays
// up for the process. Windows' sans if the file won't load, as the label still
// has to say what's in control.
const Gdiplus::FontFamily* TextFamily() {
  static const Gdiplus::FontFamily* family = []() -> const Gdiplus::FontFamily* {
    ULONG_PTR token;
    Gdiplus::GdiplusStartupInput input;
    Gdiplus::GdiplusStartup(&token, &input, nullptr);
    wchar_t exe[MAX_PATH];
    ::GetModuleFileName(nullptr, exe, MAX_PATH);
    std::wstring path(exe);
    path.resize(path.find_last_of(L'\\') + 1);
    path += kFontFile;
    auto* collection = new Gdiplus::PrivateFontCollection();
    collection->AddFontFile(path.c_str());
    auto* loaded = new Gdiplus::FontFamily();
    INT found = 0;
    if (collection->GetFamilyCount() > 0) {
      collection->GetFamilies(1, loaded, &found);
    }
    return found > 0 ? loaded : Gdiplus::FontFamily::GenericSansSerif();
  }();
  return family;
}

Gdiplus::REAL TextSize(HMONITOR monitor) {
  return static_cast<Gdiplus::REAL>(Scaled(kFontSize, monitor));
}

int TextWidth(const std::wstring& text, HMONITOR monitor) {
  const Gdiplus::Font font(TextFamily(), TextSize(monitor),
                           Gdiplus::FontStyleRegular, Gdiplus::UnitPixel);
  Gdiplus::Bitmap bitmap(1, 1, PixelFormat32bppPARGB);
  Gdiplus::Graphics graphics(&bitmap);
  graphics.SetTextRenderingHint(Gdiplus::TextRenderingHintAntiAlias);
  Gdiplus::RectF bounds;
  graphics.MeasureString(text.c_str(), static_cast<INT>(text.size()), &font,
                         Gdiplus::PointF(0, 0),
                         Gdiplus::StringFormat::GenericTypographic(), &bounds);
  return static_cast<int>(std::ceil(bounds.Width));
}

// A top-down 32 bit bitmap, premultiplied, for UpdateLayeredWindow.
class Canvas {
 public:
  Canvas(int width, int height) : width_(width), height_(height) {
    BITMAPINFO info = {};
    info.bmiHeader.biSize = sizeof(info.bmiHeader);
    info.bmiHeader.biWidth = width;
    info.bmiHeader.biHeight = -height;
    info.bmiHeader.biPlanes = 1;
    info.bmiHeader.biBitCount = 32;
    info.bmiHeader.biCompression = BI_RGB;
    dc_ = ::CreateCompatibleDC(nullptr);
    bitmap_ = ::CreateDIBSection(dc_, &info, DIB_RGB_COLORS,
                                 reinterpret_cast<void**>(&pixels_), nullptr, 0);
    if (bitmap_) old_ = ::SelectObject(dc_, bitmap_);
  }
  ~Canvas() {
    if (bitmap_) {
      ::SelectObject(dc_, old_);
      ::DeleteObject(bitmap_);
    }
    ::DeleteDC(dc_);
  }
  Canvas(const Canvas&) = delete;
  Canvas& operator=(const Canvas&) = delete;

  bool ok() const { return bitmap_ != nullptr; }
  int width() const { return width_; }
  int height() const { return height_; }
  uint32_t* pixels() const { return pixels_; }

  // Source-over, at straight |alpha|.
  void Blend(int x, int y, Color color, float alpha) {
    if (x < 0 || y < 0 || x >= width_ || y >= height_ || alpha <= 0) return;
    uint8_t* pixel = reinterpret_cast<uint8_t*>(&pixels_[y * width_ + x]);
    const float rest = 1 - alpha;
    pixel[0] = static_cast<uint8_t>(color.b * alpha * 255 + pixel[0] * rest);
    pixel[1] = static_cast<uint8_t>(color.g * alpha * 255 + pixel[1] * rest);
    pixel[2] = static_cast<uint8_t>(color.r * alpha * 255 + pixel[2] * rest);
    pixel[3] = static_cast<uint8_t>(alpha * 255 + pixel[3] * rest);
  }

  // Puts this on |window| at its position.
  void Present(HWND window) {
    POINT source = {0, 0};
    SIZE size = {width_, height_};
    BLENDFUNCTION blend = {AC_SRC_OVER, 0, 255, AC_SRC_ALPHA};
    ::UpdateLayeredWindow(window, nullptr, nullptr, &size, dc_, &source, 0,
                          &blend, ULW_ALPHA);
  }

 private:
  int width_;
  int height_;
  HDC dc_;
  HBITMAP bitmap_ = nullptr;
  HGDIOBJ old_ = nullptr;
  uint32_t* pixels_ = nullptr;
};

// Distance from a point to the edge of a rounded box, negative inside.
float RoundedBox(float x, float y, float left, float top, float right,
                 float bottom, float radius) {
  const float cx = (left + right) / 2;
  const float cy = (top + bottom) / 2;
  const float qx = std::abs(x - cx) - (right - left) / 2 + radius;
  const float qy = std::abs(y - cy) - (bottom - top) / 2 + radius;
  return std::min(std::max(qx, qy), 0.0f) +
         std::hypot(std::max(qx, 0.0f), std::max(qy, 0.0f)) - radius;
}

// Smoothed and unhinted, as Flutter draws Gaia's text; GDI's fits each glyph to
// the pixels, and writes no alpha. Filled as outlines, since GDI+'s own text
// drawing comes out thinner than Flutter's.
void DrawLabel(Canvas& canvas, const std::wstring& text, RECT rect,
               HMONITOR monitor, float lift) {
  const Gdiplus::REAL size = TextSize(monitor);
  Gdiplus::Bitmap bitmap(canvas.width(), canvas.height(), canvas.width() * 4,
                         PixelFormat32bppPARGB,
                         reinterpret_cast<BYTE*>(canvas.pixels()));
  Gdiplus::Graphics graphics(&bitmap);
  graphics.SetSmoothingMode(Gdiplus::SmoothingModeAntiAlias);
  graphics.SetPixelOffsetMode(Gdiplus::PixelOffsetModeHalf);
  Gdiplus::StringFormat format(Gdiplus::StringFormat::GenericTypographic());
  format.SetAlignment(Gdiplus::StringAlignmentCenter);
  format.SetLineAlignment(Gdiplus::StringAlignmentCenter);
  format.SetTrimming(Gdiplus::StringTrimmingEllipsisCharacter);
  format.SetFormatFlags(Gdiplus::StringFormatFlagsNoWrap);
  const Gdiplus::SolidBrush brush(Gdiplus::Color(255, kTextLevel, kTextLevel, kTextLevel));
  const Gdiplus::RectF box(static_cast<Gdiplus::REAL>(rect.left),
                           rect.top - lift * size,
                           static_cast<Gdiplus::REAL>(rect.right - rect.left),
                           static_cast<Gdiplus::REAL>(rect.bottom - rect.top));
  Gdiplus::GraphicsPath path;
  path.AddString(text.c_str(), static_cast<INT>(text.size()), TextFamily(),
                 Gdiplus::FontStyleRegular, size, box, &format);
  graphics.FillPath(&brush, &path);
}

// The accent drifting into gold and back, around the screen.
Color AuroraAt(float x, float y, float width, float height, Color accent) {
  const float angle = std::atan2((y - height / 2) / height,
                                 (x - width / 2) / width);
  const float wave = 0.5f + 0.5f * std::sin(angle * 2 + 0.6f);
  return Mix(accent, kGold, wave * wave * 0.9f);
}

// One piece of the frame, |left| and |top| from the monitor's corner. Its look
// goes by the distance to the monitor's nearest edge, so strips meet cleanly.
void PaintStrip(HWND window, int left, int top, int width, int height,
                int monitor_width, int monitor_height, HMONITOR monitor,
                Color accent) {
  Canvas canvas(width, height);
  if (!canvas.ok()) return;
  const float depth = static_cast<float>(Scaled(kGlowDepth, monitor));
  const float line = kLineWidth * Scaled(100, monitor) / 100.0f;
  for (int y = 0; y < height; ++y) {
    for (int x = 0; x < width; ++x) {
      const float mx = left + x + 0.5f;
      const float my = top + y + 0.5f;
      const float edge =
          std::min({mx, my, monitor_width - mx, monitor_height - my});
      const Color aurora =
          AuroraAt(mx, my, static_cast<float>(monitor_width),
                   static_cast<float>(monitor_height), accent);
      const float fade = Clamp01(1 - edge / depth);
      // A dark falloff first, so the light reads on a white page too.
      canvas.Blend(x, y, {0.03f, 0.04f, 0.09f}, fade * fade * 0.42f);
      canvas.Blend(x, y, aurora, fade * fade * fade * 0.85f);
      canvas.Blend(x, y, Mix(aurora, kWhite, 0.18f),
                   Clamp01(line + 0.5f - edge));
    }
  }
  canvas.Present(window);
}

}  // namespace

GaiaControlBorder::GaiaControlBorder(std::function<void()> on_revoke)
    : on_revoke_(std::move(on_revoke)) {}

GaiaControlBorder::~GaiaControlBorder() { Hide(); }

void GaiaControlBorder::Show(const std::wstring& label, unsigned int accent) {
  label_ = label;
  accent_ = accent;
  Rebuild();
}

void GaiaControlBorder::Hide() {
  notch_ = nullptr;
  button_window_ = nullptr;
  hover_ = false;
  pressed_ = false;
  for (HWND window : windows_) ::DestroyWindow(window);
  windows_.clear();
}

void GaiaControlBorder::Rebuild() {
  static const bool registered = [] {
    WNDCLASS window_class = {};
    window_class.lpfnWndProc = WindowProc;
    window_class.hInstance = ::GetModuleHandle(nullptr);
    window_class.lpszClassName = kWindowClass;
    window_class.hCursor = ::LoadCursor(nullptr, IDC_ARROW);
    return ::RegisterClass(&window_class) != 0;
  }();
  if (!registered) return;
  Hide();
  ::EnumDisplayMonitors(nullptr, nullptr, AddMonitor,
                        reinterpret_cast<LPARAM>(this));
  for (HWND window : windows_) ::ShowWindow(window, SW_SHOWNOACTIVATE);
}

BOOL CALLBACK GaiaControlBorder::AddMonitor(HMONITOR monitor, HDC, LPRECT,
                                            LPARAM self_param) {
  auto* self = reinterpret_cast<GaiaControlBorder*>(self_param);
  MONITORINFO info = {sizeof(info)};
  if (!::GetMonitorInfo(monitor, &info)) return TRUE;
  const RECT& r = info.rcMonitor;
  const int width = r.right - r.left;
  const int height = r.bottom - r.top;
  const int edge = Scaled(kGlowDepth, monitor);
  const Color accent = FromRgb(self->accent_);
  const RECT strips[] = {
      {0, 0, width, edge},
      {0, height - edge, width, height},
      {0, edge, edge, height - edge},
      {width - edge, edge, width, height - edge},
  };
  for (const RECT& strip : strips) {
    const int strip_width = strip.right - strip.left;
    const int strip_height = strip.bottom - strip.top;
    HWND window = self->AddWindow(r.left + strip.left, r.top + strip.top,
                                  strip_width, strip_height, false);
    if (window) {
      PaintStrip(window, strip.left, strip.top, strip_width, strip_height,
                 width, height, monitor, accent);
    }
  }
  if (info.dwFlags & MONITORINFOF_PRIMARY) self->AddNotch(monitor, r);
  return TRUE;
}

void GaiaControlBorder::AddNotch(HMONITOR monitor, const RECT& bounds) {
  const int padding = Scaled(kNotchPadding, monitor);
  const int gap = Scaled(kGap, monitor);
  const int orb = Scaled(kOrbSize, monitor);
  const int button_width =
      TextWidth(kButtonText, monitor) + 2 * Scaled(kButtonPadding, monitor);
  const int height = Scaled(kNotchHeight, monitor);
  const int button_height = Scaled(kButtonHeight, monitor);
  // As far from the notch's right edge as from its top and bottom, inside the
  // ring.
  const int inset = (height - kNotchRim - button_height) / 2;
  const int rest = padding + orb + gap + gap + button_width + inset + kNotchRim;
  // Never wider than the monitor, or the button goes off it.
  const int label_width =
      std::min({TextWidth(label_, monitor) + 2, Scaled(kMaxLabelWidth, monitor),
                static_cast<int>(bounds.right - bounds.left) - rest});
  const int width = rest + label_width;
  button_.right = width - inset - kNotchRim;
  button_.left = button_.right - button_width;
  button_.top = inset;
  button_.bottom = button_.top + button_height;
  label_rect_ = {padding + orb + gap, 0, padding + orb + gap + label_width,
                 height - kNotchRim};
  notch_size_ = {width, height};
  notch_monitor_ = monitor;
  const int left = bounds.left + (bounds.right - bounds.left - width) / 2;
  notch_ = AddWindow(left, bounds.top, width, height, false);
  if (notch_) PaintNotch();
  // The notch's clicks pass through, so the button is a window of its own, over
  // the one painted on the notch. Alpha 1 is as little as still takes a click.
  button_window_ = AddWindow(left + button_.left, bounds.top + button_.top,
                             button_width, button_height, true);
  if (!button_window_) return;
  Canvas hit(button_width, button_height);
  if (!hit.ok()) return;
  std::fill_n(hit.pixels(), button_width * button_height, 0x01000000u);
  hit.Present(button_window_);
}

void GaiaControlBorder::PaintNotch() {
  const int width = notch_size_.cx;
  const int height = notch_size_.cy;
  Canvas canvas(width, height);
  if (!canvas.ok()) return;
  const HMONITOR monitor = notch_monitor_;
  const Color accent = FromRgb(accent_);
  const float w = static_cast<float>(width);
  const float h = static_cast<float>(height);
  const float radius = static_cast<float>(Scaled(kNotchRadius, monitor));

  const Color fill = GaiaFill(accent);
  // GaiaButton's ring with its light held still at the top; on hover, the whole
  // ring in the saturated accent, as a still GaiaButton does. Pressed, it
  // shrinks to 98%.
  const float button_w = static_cast<float>(button_.right - button_.left);
  const float button_h = static_cast<float>(button_.bottom - button_.top);
  const float shrink = pressed_ ? 0.01f : 0;
  const float button_left = button_.left + button_w * shrink;
  const float button_top = button_.top + button_h * shrink;
  const float button_right = button_.right - button_w * shrink;
  const float button_bottom = button_.bottom - button_h * shrink;
  const float button_radius = static_cast<float>(Scaled(kButtonRadius, monitor));
  const float ring_width = static_cast<float>(Scaled(1, monitor));
  const float light_x = (button_left + button_right) / 2;
  const float light_rx = button_w * 0.4f;
  const Color light_color = hover_ ? Saturated(accent) : Mix(accent, kWhite, 0.5f);
  const float orb_size = static_cast<float>(Scaled(kOrbSize, monitor));
  const float orb_x = Scaled(kNotchPadding, monitor) + orb_size / 2;
  const float orb_y = (h - kNotchRim) / 2;

  for (int y = 0; y < height; ++y) {
    for (int x = 0; x < width; ++x) {
      const float px = x + 0.5f;
      const float py = y + 0.5f;
      // Hangs from the top edge: its upper corners are off the bitmap.
      const float box = RoundedBox(px, py, 0, -radius, w, h, radius);
      if (box >= 0.5f) continue;
      const float inside = Clamp01(0.5f - box);
      canvas.Blend(x, y, fill, inside);
      // The ring of light around it, as Gaia's buttons and toasts have.
      const float along = px / w;
      const Color ring = Mix(accent, kGold, 0.5f + 0.5f * std::sin(along * kPi * 2));
      canvas.Blend(x, y, ring, inside * Clamp01(kNotchRim + 0.5f + box) * 0.9f);
      // The orb: a white core in the accent's halo, ringed with gold.
      const float orb = std::hypot(px - orb_x, py - orb_y) / (orb_size / 2);
      canvas.Blend(x, y, accent, Clamp01(1.6f - orb) * 0.28f);
      canvas.Blend(x, y, Mix(accent, kWhite, 0.72f),
                   Clamp01((0.62f - orb) * orb_size / 2));
      canvas.Blend(x, y, kGold,
                   Clamp01(1 - std::abs(orb - 0.95f) * orb_size / 2) * 0.9f);
      // The button.
      const float button = RoundedBox(px, py, button_left, button_top,
                                      button_right, button_bottom, button_radius);
      if (button >= 0.5f) continue;
      const float in_button = Clamp01(0.5f - button);
      canvas.Blend(x, y, kWhite, in_button * 0.1f);
      const float light = std::hypot((px - light_x) / light_rx,
                                     (py - button_top) / button_h);
      canvas.Blend(x, y, light_color,
                   in_button * (hover_ ? 1 : 0.6f * Clamp01(1 - light)));
      // Covers all but the ring.
      canvas.Blend(x, y, fill, Clamp01(0.5f - button - ring_width));
    }
  }

  DrawLabel(canvas, label_, label_rect_, monitor, kTextLift);
  DrawLabel(canvas, kButtonText, button_, monitor, kButtonTextLift);
  canvas.Present(notch_);
}

void GaiaControlBorder::SetButtonState(bool hover, bool pressed) {
  if (hover == hover_ && pressed == pressed_) return;
  hover_ = hover;
  pressed_ = pressed;
  PaintNotch();
}

HWND GaiaControlBorder::AddWindow(int left, int top, int width, int height,
                                  bool clickable) {
  // Topmost, no-activate tool windows, so §15.6's target never lands on one,
  // and pressing the button leaves the foreground where it was.
  HWND window = ::CreateWindowEx(
      WS_EX_TOPMOST | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE | WS_EX_LAYERED |
          (clickable ? 0 : WS_EX_TRANSPARENT),
      kWindowClass, L"", WS_POPUP, left, top, width, height, nullptr, nullptr,
      ::GetModuleHandle(nullptr), this);
  if (!window) return nullptr;
  ::SetWindowDisplayAffinity(window, kExcludeFromCapture);
  windows_.push_back(window);
  return window;
}

LRESULT CALLBACK GaiaControlBorder::WindowProc(HWND hwnd, UINT message,
                                               WPARAM wparam,
                                               LPARAM lparam) noexcept {
  if (message == WM_NCCREATE) {
    auto* create = reinterpret_cast<CREATESTRUCT*>(lparam);
    ::SetWindowLongPtr(hwnd, GWLP_USERDATA,
                       reinterpret_cast<LONG_PTR>(create->lpCreateParams));
  }
  auto* self = reinterpret_cast<GaiaControlBorder*>(
      ::GetWindowLongPtr(hwnd, GWLP_USERDATA));
  const bool on_button = self && hwnd == self->button_window_;
  switch (message) {
    case WM_MOUSEACTIVATE:
      return MA_NOACTIVATE;
    case WM_MOUSEMOVE:
      if (on_button) {
        TRACKMOUSEEVENT track = {sizeof(track), TME_LEAVE, hwnd, 0};
        ::TrackMouseEvent(&track);
        self->SetButtonState(true, self->pressed_);
      }
      return 0;
    case WM_MOUSELEAVE:
      if (on_button) self->SetButtonState(false, false);
      return 0;
    case WM_SETCURSOR:
      if (on_button) {
        ::SetCursor(::LoadCursor(nullptr, IDC_HAND));
        return TRUE;
      }
      break;
    case WM_LBUTTONDOWN:
      if (on_button) self->SetButtonState(true, true);
      return 0;
    case WM_LBUTTONUP:
      if (on_button) {
        const bool pressed = self->pressed_;
        self->SetButtonState(true, false);
        if (pressed) self->on_revoke_();
      }
      return 0;
    case WM_DISPLAYCHANGE:
    case WM_DPICHANGED:
      // Only the first strip acts on it: the rest are about to go.
      if (self && !self->windows_.empty() && hwnd == self->windows_.front()) {
        ::PostMessage(hwnd, WM_APP, 0, 0);
      }
      return 0;
    case WM_APP:
      if (self) self->Rebuild();
      return 0;
  }
  return ::DefWindowProc(hwnd, message, wparam, lparam);
}

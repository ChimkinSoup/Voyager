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

int TextWidth(const std::wstring& text, Gdiplus::REAL size) {
  const Gdiplus::Font font(TextFamily(), size,
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
  void Present(HWND window, BYTE alpha = 255) {
    POINT source = {0, 0};
    SIZE size = {width_, height_};
    BLENDFUNCTION blend = {AC_SRC_OVER, 0, alpha, AC_SRC_ALPHA};
    ::UpdateLayeredWindow(window, nullptr, nullptr, &size, dc_, &source, 0,
                          &blend, ULW_ALPHA);
  }

  // Puts this on |window|, moving it to |at|, at |alpha| overall.
  void PresentAt(HWND window, POINT at, BYTE alpha) {
    POINT source = {0, 0};
    SIZE size = {width_, height_};
    BLENDFUNCTION blend = {AC_SRC_OVER, 0, alpha, AC_SRC_ALPHA};
    ::UpdateLayeredWindow(window, nullptr, &at, &size, dc_, &source, 0, &blend,
                          ULW_ALPHA);
  }

  void Clear() { std::fill_n(pixels_, width_ * height_, 0u); }

  // Clears only |rect|, clipped to this.
  void Clear(const RECT& rect) {
    const int left = std::max(0, static_cast<int>(rect.left));
    const int right = std::min(width_, static_cast<int>(rect.right));
    if (right <= left) return;
    for (int y = std::max(0, static_cast<int>(rect.top));
         y < std::min(height_, static_cast<int>(rect.bottom)); ++y) {
      std::fill_n(pixels_ + y * width_ + left, right - left, 0u);
    }
  }

  // Puts this on |window| where it is, telling Windows only |dirty| changed.
  void PresentDirty(HWND window, const RECT& dirty) {
    POINT source = {0, 0};
    SIZE size = {width_, height_};
    BLENDFUNCTION blend = {AC_SRC_OVER, 0, 255, AC_SRC_ALPHA};
    UPDATELAYEREDWINDOWINFO info = {sizeof(info)};
    info.psize = &size;
    info.hdcSrc = dc_;
    info.pptSrc = &source;
    info.pblend = &blend;
    info.dwFlags = ULW_ALPHA;
    info.prcDirty = &dirty;
    ::UpdateLayeredWindowIndirect(window, &info);
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
               Gdiplus::REAL size, float lift) {
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
                Color accent, GaiaEffectStyle style = GaiaEffectStyle::kClassic) {
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
      const float s = depth / kGlowDepth;
      if (style == GaiaEffectStyle::kEcho) {
        canvas.Blend(x, y, kGold,
                     Clamp01(1 - std::abs(edge - 6 * s) / s) * 0.65f);
      } else if (style == GaiaEffectStyle::kGlide) {
        const float corner = std::min(mx, monitor_width - mx) +
                             std::min(my, monitor_height - my);
        canvas.Blend(x, y, kGold, Clamp01(1 - std::abs(edge - 4 * s) / s) *
                     Clamp01(1 - corner / (90 * s)));
      }
    }
  }
  canvas.Present(window);
}

// Flashes (GAIA_AUTONOMY_HLD.md §6). Sizes at 100%.

constexpr wchar_t kFlashClass[] = L"VoyagerGaiaFlash";
constexpr UINT_PTR kFlashTimer = 1;
constexpr size_t kFlashPool = 16;
// Window updates a flash's faded pieces get a frame, and finished windows
// hidden a frame, as each costs 0.2 ms or more.
constexpr int kFadeUpdates = 4;
constexpr size_t kHidesPerFrame = 3;
// How long before the input a flash starts. gaia_os_control.dart waits as
// long between asking for one and sending.
constexpr float kLeadIn = 120;
constexpr float kRipple = 460;
constexpr float kSecondRipple = 130;
constexpr float kScrollTime = 520;
constexpr float kKeyTime = 900;
constexpr float kWindowTime = 750;
constexpr float kMarkTime = 1100;
constexpr float kFadeOut = 250;
// Once round a field's outline.
constexpr float kSparkLap = 1400;
constexpr float kClickReach = 48;
// How far past its halo's radius an Astral click's light reaches: the orbits'
// glow, the bloom and a right click's corner all end inside it.
constexpr float kAstralClickMargin = 14;
// The side of an Astral scroll's square: its furthest chevron and glow.
constexpr float kAstralScrollSide = 136;
constexpr float kHalo = 7;
constexpr float kSpark = 16;
constexpr float kPillGap = 26;
constexpr float kMaxPillText = 360;

// Under the light, so it reads on a white page.
constexpr Color kShade = {0.03f, 0.04f, 0.09f};

float ScaleAt(HMONITOR monitor) {
  UINT dpi_x = 96;
  UINT dpi_y = 96;
  ::GetDpiForMonitor(monitor, MDT_EFFECTIVE_DPI, &dpi_x, &dpi_y);
  return dpi_x / 96.0f;
}

float Ease(float x) {
  x = Clamp01(x);
  return 1 - (1 - x) * (1 - x) * (1 - x);
}

float Square(float x) { return x * x; }

// In over |in| ms, out over the last |out| of |total|.
float Envelope(float t, float in, float out, float total) {
  return std::min(Clamp01(t / in), Clamp01((total - t) / out));
}

float SegmentDistance(float px, float py, float ax, float ay, float bx,
                      float by) {
  const float dx = bx - ax;
  const float dy = by - ay;
  const float length = dx * dx + dy * dy;
  const float t =
      length > 0 ? Clamp01(((px - ax) * dx + (py - ay) * dy) / length) : 0;
  return std::hypot(px - ax - t * dx, py - ay - t * dy);
}

// A line of light |distance| from its middle: a dark falloff, the accent's
// glow, then the line.
void Light(Canvas& canvas, int x, int y, float distance, float width,
           Color color, float alpha, float s) {
  if (alpha <= 0) return;
  const float halo = kHalo * s;
  const float out = std::abs(distance) - width / 2;
  if (out > halo) return;
  const float nearness = Clamp01(1 - out / halo);
  canvas.Blend(x, y, kShade, alpha * 0.38f * nearness * nearness);
  canvas.Blend(x, y, color, alpha * 0.22f * nearness * nearness * nearness);
  canvas.Blend(x, y, color, alpha * Clamp01(0.5f - out));
}

bool AroundRect(const GaiaFlash& flash) {
  return !::IsRectEmpty(&flash.rect) &&
         (flash.kind == GaiaFlash::Kind::kType ||
          flash.kind == GaiaFlash::Kind::kMark);
}

// A shared material vocabulary for point effects, field contours and labels.
// Coordinates are in logical pixels, so the strands retain their weight at DPI.
using FlashStyle = GaiaFlash::Style;

void FamilyContour(Canvas& canvas, int x, int y, float distance, float along,
                   float s, Color accent, FlashStyle style, float alpha = 1) {
  // A quiet version of each family's material, never a repeated miniature icon.
  const Color color = style == FlashStyle::kAstral ? Mix(accent, kWhite, 0.72f)
                      : style == FlashStyle::kEcho ? accent
                      : Mix(accent, kWhite, 0.2f);
  Light(canvas, x, y, distance, 1.8f * s, color, alpha, s);
  if (style == FlashStyle::kAstral) {
    Light(canvas, x, y, distance + 3 * s, s, kGold, alpha * 0.7f, s);
  } else if (style == FlashStyle::kEcho) {
    Light(canvas, x, y, distance + 3 * s, s, kGold, alpha * 0.45f, s);
  } else if (style == FlashStyle::kGlide) {
    // Long, restrained gold sections, rather than a chain of twinkling beads.
    const float sweep = Square(Clamp01(1 - std::abs(along / s - 24) / 28));
    Light(canvas, x, y, distance, 2 * s, kGold, alpha * sweep, s);
  }
}

// Astral borrows the spinner's two planes: white light and Astral gold.
// Echo is a circular wave.
// Glide is a rounded square. Click motion stays on the existing gold halo.
void PaintFamilyPoint(Canvas& canvas, float cx, float cy, float radius,
                      float phase, float alpha, float s, Color accent,
                      FlashStyle style, bool right = false,
                      bool orbit_light = false, bool twin_lights = false) {
  const float reach = radius + 10 * s;
  const int left = std::max(0, static_cast<int>(cx - reach));
  const int top = std::max(0, static_cast<int>(cy - reach));
  const int end_x = std::min(canvas.width(), static_cast<int>(cx + reach + 1));
  const int end_y = std::min(canvas.height(), static_cast<int>(cy + reach + 1));
  for (int y = top; y < end_y; ++y) {
    for (int x = left; x < end_x; ++x) {
      const float dx = x + 0.5f - cx, dy = y + 0.5f - cy;
      const float r = std::hypot(dx, dy);
      if (style == FlashStyle::kAstral) {
        for (int orbit = 0; orbit < 2; ++orbit) {
          const float tilt = orbit == 0 ? -0.65f : 0.85f;
          const float u = dx * std::cos(tilt) + dy * std::sin(tilt);
          const float v = -dx * std::sin(tilt) + dy * std::cos(tilt);
          const float halo = (std::hypot(u, v / 0.48f) - radius) * 0.6f;
          const float head = (orbit_light ? (orbit == 1 ? phase : 0)
                                         : (orbit == 0 ? phase : -phase)) - kPi / 2;
          const float around = std::atan2(v / 0.48f, u);
          const float glint = std::pow(std::max(0.0f, std::cos(around - head)), 6.0f);
          Light(canvas, x, y, halo, 1.7f * s,
                orbit == 0 ? Mix(accent, kWhite, 0.72f) : kGold,
                alpha * (0.65f + 0.35f * glint), s);
          if (orbit == 1 && orbit_light) {
            const int count = twin_lights ? 2 : 1;
            for (int light = 0; light < count; ++light) {
              const float at = phase - kPi / 2 + light * kPi;
              const float mx = radius * std::cos(at);
              const float my = radius * 0.48f * std::sin(at);
              Light(canvas, x, y, std::hypot(u - mx, v - my), 3.2f * s,
                    Mix(kGold, kWhite, 0.65f), alpha, s);
            }
          }
        }
        Light(canvas, x, y, r, 4 * s, Mix(accent, kWhite, 0.72f), alpha, s);
      } else if (style == FlashStyle::kEcho) {
        Light(canvas, x, y, r - radius, 2.8f * s,
              Mix(accent, kGold, Clamp01(phase * 0.25f)), alpha, s);
        Light(canvas, x, y, r, 4 * s, kGold, alpha * 0.8f, s);
      } else {
        const float box = RoundedBox(dx, dy, -radius * 0.72f, -radius * 0.72f,
                                     radius * 0.72f, radius * 0.72f, 5 * s);
        Light(canvas, x, y, box, 2.4f * s, accent, alpha, s);
        Light(canvas, x, y, r, 3 * s, kGold, alpha * 0.8f, s);
      }
      if (right) {
        const float d = std::min(
            SegmentDistance(dx, dy, 9 * s, 9 * s, 20 * s, 9 * s),
            SegmentDistance(dx, dy, 9 * s, 9 * s, 9 * s, 20 * s));
        Light(canvas, x, y, d, 2 * s, kGold, alpha, s);
      }
    }
  }
}

// A pixel of an Astral click's square within its reach: where it sits from the
// point, and from and round each orbit's ellipse.
struct ClickPixel {
  int x, y;
  float dx, dy, r;
  float around[2];
  float angle[2];
};

// Those pixels, worked out once: the square holds still while a click plays,
// and every click at a scale shares one.
const std::vector<ClickPixel>& ClickGeometry(int width, int height, float cx,
                                             float cy, float radius, float reach) {
  struct Entry {
    int width, height;
    float cx, cy, radius, reach;
    std::vector<ClickPixel> pixels;
  };
  static std::vector<Entry> cache;
  for (const Entry& entry : cache) {
    if (entry.width == width && entry.height == height && entry.cx == cx &&
        entry.cy == cy && entry.radius == radius && entry.reach == reach) {
      return entry.pixels;
    }
  }
  if (cache.size() >= 4) cache.erase(cache.begin());
  Entry entry = {width, height, cx, cy, radius, reach, {}};
  const float tilt_cos[2] = {std::cos(-0.65f), std::cos(0.85f)};
  const float tilt_sin[2] = {std::sin(-0.65f), std::sin(0.85f)};
  for (int y = std::max(0, static_cast<int>(cy - reach));
       y < std::min(height, static_cast<int>(cy + reach) + 1); ++y) {
    for (int x = std::max(0, static_cast<int>(cx - reach));
         x < std::min(width, static_cast<int>(cx + reach) + 1); ++x) {
      ClickPixel pixel = {x, y, x + 0.5f - cx, y + 0.5f - cy, 0, {}, {}};
      pixel.r = std::hypot(pixel.dx, pixel.dy);
      if (pixel.r > reach) continue;
      for (int orbit = 0; orbit < 2; ++orbit) {
        const float u = pixel.dx * tilt_cos[orbit] + pixel.dy * tilt_sin[orbit];
        const float v = (-pixel.dx * tilt_sin[orbit] + pixel.dy * tilt_cos[orbit]) / 0.48f;
        pixel.around[orbit] = std::hypot(u, v) - radius;
        pixel.angle[orbit] = std::fmod(std::atan2(v, u) + 2.5f * kPi, 2 * kPi);
      }
      entry.pixels.push_back(pixel);
    }
  }
  cache.push_back(std::move(entry));
  return cache.back().pixels;
}

// The selected click material also supplies the visual vocabulary for gestures
// and markers. Double-click has two core beats within a single traced form.
void PaintAstralClick(Canvas& canvas, const GaiaFlash& flash, float cx, float cy,
                      float t, float s, Color accent) {
  using Variant = GaiaFlash::ClickVariant;
  const Variant variant = flash.kind == GaiaFlash::Kind::kClick
                              ? flash.click_variant : Variant::kTraceBloom;
  const bool twice = flash.kind == GaiaFlash::Kind::kDouble;
  const bool marker = flash.kind == GaiaFlash::Kind::kMark;
  const float total = twice ? 900 : marker ? kMarkTime : kLeadIn + kRipple;
  const float p = Clamp01(t / total);
  const float alpha = Envelope(t, 65, 220, total);
  if (alpha <= 0) return;
  const float radius = (marker ? 14 : 18) * s;
  const bool trace = variant == Variant::kTrace || variant == Variant::kTraceBloom;
  const bool bloom = variant == Variant::kBloom || variant == Variant::kTraceBloom;
  if (!trace) {
    PaintFamilyPoint(canvas, cx, cy, radius, 0, alpha, s, accent, FlashStyle::kAstral);
  }
  // Everything per frame rather than per pixel.
  const Color white = Mix(accent, kWhite, 0.72f);
  const float head = Ease(p / 0.7f) * 2 * kPi;
  // Beyond this from its ellipse, an orbit's light (1.7 wide, scaled by 0.6)
  // is nothing.
  const float orbit_reach = (0.85f + kHalo) * s / 0.6f + 1;
  const float breath = !bloom ? 0
                       : twice ? 0.45f * std::sin(p * kPi) +
                                     0.55f * Square(std::sin(p * 2 * kPi))
                               : std::sin(p * kPi);
  const float spread = (5 + 8 * breath) * s;
  // Where the bloom's glow falls under half a level.
  const float glow = alpha * 0.24f * breath * 255 / 0.5f;
  const float glow_reach = glow > 1 ? spread * std::sqrt(std::log(glow)) : 0;
  const float corner_alpha = flash.kind == GaiaFlash::Kind::kRight
                                 ? alpha * Clamp01((p - 0.2f) * 5) : 0;
  const float reach = radius + kAstralClickMargin * s;
  for (const ClickPixel& pixel :
       ClickGeometry(canvas.width(), canvas.height(), cx, cy, radius, reach)) {
    const int x = pixel.x, y = pixel.y;
    const float r = pixel.r;
    if (trace) {
      for (int orbit = 0; orbit < 2; ++orbit) {
        const float around = pixel.around[orbit];
        if (std::abs(around) > orbit_reach) continue;
        const float reveal = Clamp01((head - pixel.angle[orbit]) / 0.18f);
        Light(canvas, x, y, around * 0.6f, 1.7f * s,
              orbit == 0 ? white : kGold, alpha * reveal, s);
      }
      Light(canvas, x, y, r, 4 * s, white, alpha, s);
    }
    if (breath > 0) {
      if (r < glow_reach) {
        canvas.Blend(x, y, accent, alpha * 0.24f * breath * std::exp(-r * r / (spread * spread)));
      }
      Light(canvas, x, y, r, (4 + 6 * breath) * s, white, alpha * breath * 0.45f, s);
    }
    // The corner's light ends 8 past its arms, which run from 9 to 20.
    if (corner_alpha > 0 && pixel.dx > s && pixel.dy > s) {
      const float corner = std::min(
          SegmentDistance(pixel.dx, pixel.dy, 9 * s, 9 * s, 20 * s, 9 * s),
          SegmentDistance(pixel.dx, pixel.dy, 9 * s, 9 * s, 9 * s, 20 * s));
      Light(canvas, x, y, corner, 2 * s, kGold, corner_alpha, s);
    }
  }
}

constexpr float kFamilyScrollTime = 760;
constexpr float kAstralDoubleTime = 900;

void PaintScroll(Canvas& canvas, const GaiaFlash& flash, float cx, float cy,
                 float t, float s, Color accent);

// Echo and Glide retain their 100px journey and separated, full-strength beats.
// Astral uses PaintScroll below to share Current's choreography exactly.
void PaintFamilyScroll(Canvas& canvas, const GaiaFlash& flash, float cx,
                       float cy, float t, float s, Color accent) {
  static constexpr float dirs[4][2] = {{0, -1}, {0, 1}, {-1, 0}, {1, 0}};
  const auto& d = dirs[std::clamp(flash.direction, 0, 3)];
  const int count = std::clamp(3 + (flash.amount - 3) / 4, 3, 6);
  const float p = Clamp01(t / kFamilyScrollTime);
  const float alpha = Envelope(t, 70, 170, kFamilyScrollTime);
  if (alpha <= 0) return;
  const float centre = (-50 + 100 * Ease(p)) * s;
  for (int y = 0; y < canvas.height(); ++y) {
    for (int x = 0; x < canvas.width(); ++x) {
      const float px = x + 0.5f - cx, py = y + 0.5f - cy;
      const float u = px * -d[1] + py * d[0];
      const float v = px * d[0] + py * d[1];
      for (int i = 0; i < count; ++i) {
        const float head = centre - i * 16 * s;
        if (std::abs(v - head) > 30 * s || std::abs(u) > 34 * s) continue;
        const float strength = 1 - i * 0.06f;
        const Color color = i == 0 ? Mix(kGold, kWhite, 0.2f) : accent;
        if (flash.style == FlashStyle::kEcho) {
          // Broad curved wavefronts, with a crisp centre and visible ends.
          const float bow = head - u * u / (64 * s);
          const float taper = Clamp01((25 * s - std::abs(u)) / (6 * s));
          Light(canvas, x, y, (v - bow) * 0.85f, 3.5f * s, color,
                alpha * strength * taper, s);
        } else {
          const float distance = std::min(
              SegmentDistance(u, v, -17 * s, head - 12 * s, 0, head),
              SegmentDistance(u, v, 17 * s, head - 12 * s, 0, head));
          Light(canvas, x, y, distance, 3.5f * s, color, alpha * strength, s);
        }
      }
    }
  }
}

void PaintFamilyEffect(Canvas& canvas, const GaiaFlash& flash, float cx,
                       float cy, float t, float s, Color accent) {
  if (flash.kind == GaiaFlash::Kind::kScroll) {
    if (flash.style == FlashStyle::kAstral) {
      PaintScroll(canvas, flash, cx, cy, t, s, accent);
    } else {
      PaintFamilyScroll(canvas, flash, cx, cy, t, s, accent);
    }
    return;
  }
  const bool mark = flash.kind == GaiaFlash::Kind::kMark;
  if (flash.style == FlashStyle::kAstral) {
    PaintAstralClick(canvas, flash, cx, cy, t, s, accent);
    return;
  }
  const int count = flash.kind == GaiaFlash::Kind::kDouble ? 2 : 1;
  for (int i = 0; i < count; ++i) {
    const float p = (t - i * kSecondRipple) / (mark ? kMarkTime : kLeadIn + kRipple);
    if (p < 0 || p >= 1) continue;
    const float alpha = Envelope(p, 0.08f, 0.42f, 1);
    const float radius = (mark ? 14 + std::sin(p * 4 * kPi)
                               : 8 + 18 * Ease(p)) * s;
    PaintFamilyPoint(canvas, cx, cy, radius, p * 3 + i, alpha, s, accent,
                     flash.style, flash.kind == GaiaFlash::Kind::kRight);
  }
}

// The side of the square an effect redraws each frame, centred on its point.
// Zero for one drawn only in strips, pills and a spark.
int EffectSide(const GaiaFlash& flash, float s) {
  // Astral's point effects fit a smaller square, which costs less to update.
  const int point = flash.style == FlashStyle::kAstral
                        ? static_cast<int>(2 * (18 + kAstralClickMargin) * s) + 2
                        : static_cast<int>(2 * kClickReach * s);
  switch (flash.kind) {
    case GaiaFlash::Kind::kClick:
    case GaiaFlash::Kind::kDouble:
    case GaiaFlash::Kind::kRight:
      return point;
    case GaiaFlash::Kind::kScroll:
      return flash.style == FlashStyle::kClassic
                 ? static_cast<int>((std::clamp(flash.amount, 3, 6) * 10 + 64) * s)
             : flash.style == FlashStyle::kAstral
                 ? static_cast<int>(kAstralScrollSide * s)
                 : static_cast<int>(320 * s);
    case GaiaFlash::Kind::kMark:
      return AroundRect(flash) ? 0 : point;
    case GaiaFlash::Kind::kType:
    case GaiaFlash::Kind::kKey:
    case GaiaFlash::Kind::kWindow:
    case GaiaFlash::Kind::kDrag:
      break;
  }
  return 0;
}

// A drag's travel, at least long enough to see.
float DragTravel(const GaiaFlash& flash) {
  return std::max(static_cast<float>(flash.duration_ms), 200.0f);
}

// Once let go, a drag's marker, grown to full size on the way, stays there lit,
// then fades.
constexpr float kDragHold = 300;
constexpr float kDragFade = 250;

// How far a drag's light reaches past its two ends: Current's click ripple at
// the start, the widest of the styles' clicks.
constexpr float kDragReach = 54;

float TotalTime(const GaiaFlash& flash) {
  switch (flash.kind) {
    case GaiaFlash::Kind::kClick:
    case GaiaFlash::Kind::kRight:
      return kLeadIn + kRipple;
    case GaiaFlash::Kind::kDouble:
      return flash.style == FlashStyle::kAstral ? kAstralDoubleTime
                                               : kLeadIn + kSecondRipple + kRipple;
    case GaiaFlash::Kind::kScroll:
      return flash.style == FlashStyle::kClassic || flash.style == FlashStyle::kAstral
                 ? kScrollTime : kFamilyScrollTime;
    case GaiaFlash::Kind::kType:
      return std::max(static_cast<float>(flash.duration_ms), 500.0f) + 300;
    case GaiaFlash::Kind::kKey:
      return kKeyTime;
    case GaiaFlash::Kind::kWindow:
      return flash.style == FlashStyle::kAstral ? 1000 : kWindowTime;
    case GaiaFlash::Kind::kMark:
      return kMarkTime;
    case GaiaFlash::Kind::kDrag:
      return kLeadIn + DragTravel(flash) + kDragHold + kDragFade;
  }
  return 0;
}

// The target ring contracting onto the point, then a ripple from it, or two;
// a right click adds the corner of the menu it opens.
void PaintClick(Canvas& canvas, const GaiaFlash& flash, float cx, float cy,
                float t, float s, Color accent) {
  struct Ring {
    float radius, width, alpha;
    Color color;
  };
  Ring rings[3];
  int count = 0;
  float dot = 0;
  if (t < kLeadIn) {
    const float p = Ease(t / kLeadIn);
    rings[count++] = {(30 - 22 * p) * s, 2.5f * s, Clamp01(t / kLeadIn * 1.5f),
                      accent};
    dot = p * 0.8f;
  }
  const int ripples = flash.kind == GaiaFlash::Kind::kDouble ? 2 : 1;
  for (int i = 0; i < ripples; ++i) {
    const float q = (t - kLeadIn - i * kSecondRipple) / kRipple;
    if (q < 0 || q >= 1) continue;
    rings[count++] = {(8 + 34 * Ease(q)) * s, (3 * (1 - q) + 1) * s,
                      std::pow(1 - q, 1.5f), Mix(accent, kGold, q * 0.9f)};
    if (i == 0) dot = 0.8f * Square(1 - q);
  }
  const float q = Clamp01((t - kLeadIn) / kRipple);
  const float tick = flash.kind == GaiaFlash::Kind::kRight && t >= kLeadIn
                         ? std::pow(1 - q, 1.2f)
                         : 0;
  const float corner_x = cx + 9 * s;
  const float corner_y = cy + 9 * s;
  const float dot_radius = 3.5f * s;
  // Only what the widest ring can light, as a drag's canvas is much larger.
  const float reach = (42 + 4 + kHalo) * s + 1;
  const int from_x = std::max(0, static_cast<int>(cx - reach));
  const int from_y = std::max(0, static_cast<int>(cy - reach));
  const int to_x = std::min(canvas.width(), static_cast<int>(cx + reach) + 1);
  const int to_y = std::min(canvas.height(), static_cast<int>(cy + reach) + 1);
  for (int y = from_y; y < to_y; ++y) {
    for (int x = from_x; x < to_x; ++x) {
      const float px = x + 0.5f;
      const float py = y + 0.5f;
      const float r = std::hypot(px - cx, py - cy);
      for (int i = 0; i < count; ++i) {
        Light(canvas, x, y, r - rings[i].radius, rings[i].width, rings[i].color,
              rings[i].alpha, s);
      }
      if (dot > 0) {
        Light(canvas, x, y, r, 2 * dot_radius, Mix(accent, kWhite, 0.4f), dot,
              s);
      }
      if (tick > 0) {
        const float d = std::min(
            SegmentDistance(px, py, corner_x, corner_y, corner_x + 12 * s,
                            corner_y),
            SegmentDistance(px, py, corner_x, corner_y, corner_x,
                            corner_y + 10 * s));
        Light(canvas, x, y, d, 2 * s, kGold, tick, s);
      }
    }
  }
}

// Chevrons sliding in the scroll's direction, one after another. Each paints
// only the pixels it can reach.
void PaintScroll(Canvas& canvas, const GaiaFlash& flash, float cx, float cy,
                 float t, float s, Color accent) {
  static constexpr float kDirections[4][2] = {{0, -1}, {0, 1}, {-1, 0}, {1, 0}};
  const float* d = kDirections[std::clamp(flash.direction, 0, 3)];
  const int count = std::clamp(3 + (flash.amount - 3) / 4, 3, 6);
  const float stagger = 50;
  const float each = kScrollTime - stagger * (count - 1);
  const float reach = (1.25f + kHalo + 1) * s;
  for (int i = 0; i < count; ++i) {
    const float q = Clamp01((t - i * stagger) / each);
    if (q <= 0 || q >= 1) continue;
    const float alpha = std::sin(q * kPi);
    const Color color = Mix(accent, kGold, static_cast<float>(i) / count);
    const float along = ((i - (count - 1) / 2.0f) * 10 - 9 + 18 * Ease(q)) * s;
    if (flash.style == FlashStyle::kAstral) {
      // Same stagger, lifespan, easing and accent-to-gold ordering as Current;
      // only the arrow geometry and stroke weight differ. Only the pixels
      // within 27 across and 30 along of this one's centre.
      const float mid_x = cx + d[0] * along, mid_y = cy + d[1] * along;
      const float half_x = (d[0] != 0 ? 30 : 27) * s;
      const float half_y = (d[0] != 0 ? 27 : 30) * s;
      const int from_x = std::max(0, static_cast<int>(mid_x - half_x) - 1);
      const int from_y = std::max(0, static_cast<int>(mid_y - half_y) - 1);
      const int to_x = std::min(canvas.width(), static_cast<int>(mid_x + half_x) + 2);
      const int to_y = std::min(canvas.height(), static_cast<int>(mid_y + half_y) + 2);
      for (int y = from_y; y < to_y; ++y) {
        for (int x = from_x; x < to_x; ++x) {
          const float px = x + 0.5f - cx, py = y + 0.5f - cy;
          const float u = px * -d[1] + py * d[0];
          const float v = px * d[0] + py * d[1];
          if (std::abs(u) > 27 * s || std::abs(v - along) > 30 * s) continue;
          const float side = std::abs(u) / s;
          const float sweep = along - (side * 0.42f + side * side * 0.008f) * s;
          const float taper = Clamp01((27 * s - std::abs(u)) / (4 * s));
          Light(canvas, x, y, (v - sweep) * 0.85f, 3.8f * s,
                color, alpha * taper, s);
        }
      }
      continue;
    }
    // The tip, and the arms reaching back from it and out to each side.
    const float ax = cx + d[0] * along;
    const float ay = cy + d[1] * along;
    const float bx = ax - d[0] * 7 * s;
    const float by = ay - d[1] * 7 * s;
    const float lx = bx - d[1] * 9 * s;
    const float ly = by + d[0] * 9 * s;
    const float rx = bx + d[1] * 9 * s;
    const float ry = by - d[0] * 9 * s;
    const int left = std::max(0, static_cast<int>(std::min({ax, lx, rx}) - reach));
    const int top = std::max(0, static_cast<int>(std::min({ay, ly, ry}) - reach));
    const int right = std::min(canvas.width(),
                               static_cast<int>(std::max({ax, lx, rx}) + reach) + 1);
    const int bottom = std::min(
        canvas.height(), static_cast<int>(std::max({ay, ly, ry}) + reach) + 1);
    for (int y = top; y < bottom; ++y) {
      for (int x = left; x < right; ++x) {
        const float px = x + 0.5f;
        const float py = y + 0.5f;
        const float distance =
            std::min(SegmentDistance(px, py, ax, ay, lx, ly),
                     SegmentDistance(px, py, ax, ay, rx, ry));
        Light(canvas, x, y, distance, 2.5f * s, color, alpha, s);
      }
    }
  }
}

// A ring pulsing at the point, round a white core.
void PaintMarkPoint(Canvas& canvas, float cx, float cy, float t, float s,
                    Color accent) {
  const float alpha = Envelope(t, 120, 300, kMarkTime) *
                      (0.65f + 0.35f * std::cos(t / 1000 * 4 * kPi));
  const float radius = (14 + 3 * std::sin(t / 1000 * 4 * kPi)) * s;
  for (int y = 0; y < canvas.height(); ++y) {
    for (int x = 0; x < canvas.width(); ++x) {
      const float r = std::hypot(x + 0.5f - cx, y + 0.5f - cy);
      Light(canvas, x, y, r - radius, 2.5f * s, Mix(accent, kGold, 0.35f),
            alpha, s);
      Light(canvas, x, y, r, 5 * s, Mix(accent, kWhite, 0.4f), alpha * 0.8f, s);
    }
  }
}

// A drag in the style's own vocabulary: taking hold is its click at the start;
// the held point travels as its marker, leaving a comet's trail in its contour
// light; letting go, the marker swells and fades where it lands.
//
// Its canvas spans both ends, which across a large screen is millions of
// pixels, so a frame touches only what it draws: it clears |previous|, what
// the last frame drew, and returns what this one drew. Everything else stays
// clear.
RECT PaintDrag(Canvas& canvas, const GaiaFlash& flash, float fx, float fy,
               float tx, float ty, float t, float s, Color accent,
               const RECT& previous) {
  canvas.Clear(previous);
  RECT drawn = {};
  auto drawing = [&](float left, float top, float right, float bottom) {
    const RECT part = {
        std::max(0L, static_cast<LONG>(std::floor(left))),
        std::max(0L, static_cast<LONG>(std::floor(top))),
        std::min(static_cast<LONG>(canvas.width()),
                 static_cast<LONG>(std::ceil(right)) + 1),
        std::min(static_cast<LONG>(canvas.height()),
                 static_cast<LONG>(std::ceil(bottom)) + 1)};
    ::UnionRect(&drawn, &drawn, &part);
  };
  const float travel = DragTravel(flash);
  const float release = kLeadIn + travel;
  GaiaFlash click = flash;
  click.kind = GaiaFlash::Kind::kClick;
  if (t < kLeadIn + kRipple) {
    // Each style's click paints within this of its point.
    const float reach = kDragReach * s;
    drawing(fx - reach, fy - reach, fx + reach, fy + reach);
    if (flash.style == FlashStyle::kClassic) {
      PaintClick(canvas, click, fx, fy, t, s, accent);
    } else {
      PaintFamilyEffect(canvas, click, fx, fy, t, s, accent);
    }
  }

  const float length = std::hypot(tx - fx, ty - fy);
  const float ux = length > 0 ? (tx - fx) / length : 1;
  const float uy = length > 0 ? (ty - fy) / length : 0;
  // How far along it is, 0 to 1.
  const float moved = Ease((t - kLeadIn) / travel);
  const float head = length * moved;
  const float hx = fx + ux * head, hy = fy + uy * head;
  // The trail fades once let go.
  const float q = Clamp01((t - release) / kRipple);
  const float trail_alpha = Clamp01((t - kLeadIn) / 80) * (1 - q * q);
  const float reach = (2 + kHalo) * s + 1;
  if (head > 0 && trail_alpha > 0) {
    // Only the box from the start to the head, and in each row only the
    // pixels within |reach| of the line.
    drawing(std::min(fx, hx) - reach, std::min(fy, hy) - reach,
            std::max(fx, hx) + reach, std::max(fy, hy) + reach);
    const int from_x = std::max(0, static_cast<int>(std::min(fx, hx) - reach));
    const int from_y = std::max(0, static_cast<int>(std::min(fy, hy) - reach));
    const int to_x = std::min(canvas.width(),
                              static_cast<int>(std::max(fx, hx) + reach) + 1);
    const int to_y = std::min(canvas.height(),
                              static_cast<int>(std::max(fy, hy) + reach) + 1);
    for (int y = from_y; y < to_y; ++y) {
      // across = c - px * uy, within reach, for px = x + 0.5 - fx.
      const float c = (y + 0.5f - fy) * ux;
      int row_from = from_x, row_to = to_x;
      if (std::abs(uy) > 1e-4f) {
        const float a = (c - reach) / uy, b = (c + reach) / uy;
        row_from = std::max(from_x,
                            static_cast<int>(std::floor(std::min(a, b) + fx)) - 1);
        row_to = std::min(to_x,
                          static_cast<int>(std::ceil(std::max(a, b) + fx)) + 1);
      } else if (std::abs(c) > reach) {
        continue;
      }
      for (int x = row_from; x < row_to; ++x) {
        const float px = x + 0.5f - fx, py = y + 0.5f - fy;
        const float across = -px * uy + py * ux;
        if (std::abs(across) > reach) continue;
        const float along = px * ux + py * uy;
        const float nearest = std::clamp(along, 0.0f, head);
        const float d = std::hypot(along - nearest, across);
        if (d > reach) continue;
        // Dimmer toward the tail.
        const float alpha =
            trail_alpha * (0.2f + 0.8f * std::pow(nearest / head, 1.5f));
        if (flash.style == FlashStyle::kClassic) {
          Light(canvas, x, y, d, 2.5f * s,
                Mix(accent, kGold, nearest / head * 0.8f), alpha, s);
        } else {
          FamilyContour(canvas, x, y, d, head - nearest, s, accent,
                        flash.style, alpha);
        }
      }
    }
  }

  // The held point: Astral's orbiting planes, Echo's ring, Glide's rounded
  // square, or Current's ring round a dot. It grows as it travels, arriving
  // the size of the click's halo where it took hold; let go, it stays a
  // moment, then fades.
  const float grow = moved;
  const float fade = Clamp01((t - release - kDragHold) / kDragFade);
  const float head_alpha =
      Clamp01((t - kLeadIn) / 80) * std::pow(1 - fade, 1.5f);
  if (head_alpha <= 0) return drawn;
  const float radius = (10 + 8 * grow) * s;
  const float side = radius + (20 + kHalo) * s;
  drawing(hx - side, hy - side, hx + side, hy + side);
  if (flash.style != FlashStyle::kClassic) {
    PaintFamilyPoint(canvas, hx, hy, radius, t / 1000 * 3 * kPi, head_alpha,
                     s, accent, flash.style, false,
                     flash.style == FlashStyle::kAstral);
  }
  // Ahead of it, which way it's going, until let go: Echo's wavefront, or a
  // scroll's chevron. Each keeps its distance from the marker as it grows.
  const float ahead_alpha = head_alpha * Clamp01((release - t) / 60);
  if (flash.style == FlashStyle::kAstral) return drawn;
  const int from_x = std::max(0, static_cast<int>(hx - side));
  const int from_y = std::max(0, static_cast<int>(hy - side));
  const int to_x = std::min(canvas.width(), static_cast<int>(hx + side) + 1);
  const int to_y = std::min(canvas.height(), static_cast<int>(hy + side) + 1);
  const Color tip = Mix(kGold, kWhite, 0.2f);
  for (int y = from_y; y < to_y; ++y) {
    for (int x = from_x; x < to_x; ++x) {
      const float px = x + 0.5f - hx, py = y + 0.5f - hy;
      const float ahead = px * ux + py * uy;
      const float across = -px * uy + py * ux;
      if (flash.style == FlashStyle::kClassic) {
        const float r = std::hypot(px, py);
        Light(canvas, x, y, r - radius, (3 * (1 - grow) + 1) * s,
              Mix(accent, kGold, grow * 0.9f), head_alpha * Clamp01(grow * 6),
              s);
        Light(canvas, x, y, r, 7 * s, Mix(accent, kWhite, 0.4f), head_alpha,
              s);
      }
      if (ahead_alpha <= 0) continue;
      if (flash.style == FlashStyle::kEcho) {
        const float bow = radius + 5 * s - across * across / (40 * s);
        const float taper = Clamp01((16 * s - std::abs(across)) / (5 * s));
        Light(canvas, x, y, (ahead - bow) * 0.85f, 3 * s, tip,
              ahead_alpha * taper, s);
        continue;
      }
      const float lead =
          radius + (flash.style == FlashStyle::kGlide ? 9 : 4) * s;
      const float d = std::min(
          SegmentDistance(ahead, across, lead, 0, lead - 7 * s, -9 * s),
          SegmentDistance(ahead, across, lead, 0, lead - 7 * s, 9 * s));
      Light(canvas, x, y, d, 2.5f * s, tip, ahead_alpha, s);
    }
  }
  return drawn;
}

// A drag's frame at |t| ms, on its canvas at |origin|: see PaintDrag.
RECT PaintDragFrame(Canvas& canvas, const GaiaFlash& flash, POINT origin,
                    float t, float s, const RECT& previous) {
  return PaintDrag(canvas, flash, flash.point.x - origin.x + 0.5f,
                   flash.point.y - origin.y + 0.5f,
                   flash.to.x - origin.x + 0.5f, flash.to.y - origin.y + 0.5f,
                   t, s, FromRgb(flash.accent), previous);
}

// |flash|'s effect at |t| ms, on its square at |origin|. Not a drag's.
void PaintEffect(Canvas& canvas, const GaiaFlash& flash, POINT origin, float t,
                 float s) {
  canvas.Clear();
  const Color accent = FromRgb(flash.accent);
  const float cx = flash.point.x - origin.x + 0.5f;
  const float cy = flash.point.y - origin.y + 0.5f;
  if (flash.style != FlashStyle::kClassic) {
    PaintFamilyEffect(canvas, flash, cx, cy, t, s, accent);
    return;
  }
  switch (flash.kind) {
    case GaiaFlash::Kind::kClick:
    case GaiaFlash::Kind::kDouble:
    case GaiaFlash::Kind::kRight:
      PaintClick(canvas, flash, cx, cy, t, s, accent);
      break;
    case GaiaFlash::Kind::kScroll:
      PaintScroll(canvas, flash, cx, cy, t, s, accent);
      break;
    case GaiaFlash::Kind::kMark:
      PaintMarkPoint(canvas, cx, cy, t, s, accent);
      break;
    case GaiaFlash::Kind::kType:
    case GaiaFlash::Kind::kKey:
    case GaiaFlash::Kind::kWindow:
    case GaiaFlash::Kind::kDrag:
      break;
  }
}

int AstralWindowCornerSide(const RECT& frame, float s) {
  const int width = frame.right - frame.left;
  const int height = frame.bottom - frame.top;
  const float extent = std::clamp(std::min(width, height) * 0.16f, 64 * s, 176 * s);
  return std::max(0, std::min({static_cast<int>(std::round(extent)), width / 2, height / 2}));
}

// Detached, curved corner brackets for Astral's window adoption. The open
// edges distinguish a window coming into focus from a field being typed into.
void PaintAstralWindowCorner(Canvas& canvas, bool right, bool bottom,
                             float s, Color accent) {
  canvas.Clear();
  const float side = static_cast<float>(canvas.width());
  const float inset = side / 6;
  const float radius = side * 0.28f;
  const float weight = s * std::clamp(std::sqrt(side / (64 * s)), 1.0f, 1.7f);
  for (int y = 0; y < canvas.height(); ++y) {
    for (int x = 0; x < canvas.width(); ++x) {
      const float px = right ? side - x - 0.5f : x + 0.5f;
      const float py = bottom ? side - y - 0.5f : y + 0.5f;
      const float distance = RoundedBox(px, py, inset, inset,
                                        side * 4, side * 4, radius);
      const float progress = Clamp01((std::max(px, py) - inset) / (side * 0.68f));
      const float taper = Clamp01((side * 0.85f - std::max(px, py)) / (side * 0.24f)) *
                          Clamp01((1 - progress) * 12);
      Light(canvas, x, y, distance, 3 * weight, Mix(accent, kWhite, 0.72f),
            taper, s);
      Light(canvas, x, y, distance + 5 * weight, 2 * weight, kGold, taper, s);
    }
  }
}

// A faint, tapered pool at an edge midpoint. These small tiles preserve the
// detached corners and leave most of each edge and all window content clear.
void PaintAstralEdgeFade(Canvas& canvas, bool vertical, float s, Color accent) {
  canvas.Clear();
  const float length = static_cast<float>(vertical ? canvas.height() : canvas.width());
  const float depth = static_cast<float>(vertical ? canvas.width() : canvas.height());
  for (int y = 0; y < canvas.height(); ++y) {
    for (int x = 0; x < canvas.width(); ++x) {
      const float along = (vertical ? y + 0.5f : x + 0.5f) / length * 2 - 1;
      const float normal = (vertical ? x + 0.5f : y + 0.5f) - depth / 2;
      const float taper = Square(Clamp01(1 - along * along));
      const float falloff = std::exp(-Square(normal / (5 * s)));
      canvas.Blend(x, y, kShade, taper * falloff * 0.14f);
      canvas.Blend(x, y, accent, taper * falloff * 0.2f);
      canvas.Blend(x, y, Mix(kGold, kWhite, 0.35f),
                   taper * std::exp(-Square(normal / (1.3f * s))) * 0.2f);
    }
  }
}

// The rounded box an outline round a control draws, in screen pixels.
struct OutlineBox {
  float left, top, right, bottom, radius;
};

OutlineBox OutlineAround(const RECT& rect, float s) {
  const float inset = 3 * s;
  OutlineBox box = {rect.left - inset, rect.top - inset, rect.right + inset,
                    rect.bottom + inset, 0};
  box.radius = std::min(
      {6 * s, (box.right - box.left) / 2, (box.bottom - box.top) / 2});
  return box;
}

// How far an outline's light reaches either side of its box.
float OutlineReach(float s) { return (1 + kHalo) * s + 1; }

// The part of |box|'s outline on |canvas|, which sits at |origin|.
void PaintOutline(Canvas& canvas, const OutlineBox& box, POINT origin, float s,
                  Color accent, FlashStyle style = FlashStyle::kClassic) {
  const float width = box.right - box.left;
  const float height = box.bottom - box.top;
  for (int y = 0; y < canvas.height(); ++y) {
    for (int x = 0; x < canvas.width(); ++x) {
      const float px = origin.x + x + 0.5f;
      const float py = origin.y + y + 0.5f;
      const float distance = RoundedBox(px, py, box.left, box.top, box.right,
                                        box.bottom, box.radius);
      if (style != FlashStyle::kClassic) {
        FamilyContour(canvas, x, y, distance, px - box.left + py - box.top,
                      s, accent, style);
      } else Light(canvas, x, y, distance, 2 * s,
            AuroraAt(px - box.left, py - box.top, width, height, accent), 1, s);
    }
  }
}

// The pieces of screen an outline round |box| lights: four strips round an
// inside it never touches, or one piece for a box too small to have one.
std::vector<RECT> OutlinePieces(const OutlineBox& box, float s) {
  const float reach = OutlineReach(s);
  const RECT outer = {static_cast<LONG>(std::floor(box.left - reach)),
                      static_cast<LONG>(std::floor(box.top - reach)),
                      static_cast<LONG>(std::ceil(box.right + reach)),
                      static_cast<LONG>(std::ceil(box.bottom + reach))};
  const RECT inner = {static_cast<LONG>(std::ceil(box.left + reach)),
                      static_cast<LONG>(std::ceil(box.top + reach)),
                      static_cast<LONG>(std::floor(box.right - reach)),
                      static_cast<LONG>(std::floor(box.bottom - reach))};
  if (inner.right <= inner.left || inner.bottom <= inner.top) return {outer};
  return {
      {outer.left, outer.top, outer.right, inner.top},
      {outer.left, inner.bottom, outer.right, outer.bottom},
      {outer.left, inner.top, inner.left, inner.bottom},
      {inner.right, inner.top, outer.right, inner.bottom},
  };
}

// The spark that runs round a field while Gaia types into it.
std::unique_ptr<Canvas> PaintSpark(float s, Color accent,
                                 FlashStyle style = FlashStyle::kClassic) {
  const int side = 2 * static_cast<int>(std::ceil((kSpark + kHalo) * s));
  auto canvas = std::make_unique<Canvas>(side, side);
  if (!canvas->ok()) return nullptr;
  canvas->Clear();
  const float centre = side / 2.0f;
  for (int y = 0; y < side; ++y) {
    for (int x = 0; x < side; ++x) {
      const float r = style == FlashStyle::kGlide
                          ? SegmentDistance(x + 0.5f, y + 0.5f, centre - 3 * s, centre,
                                            centre + 3 * s, centre)
                          : std::hypot(x + 0.5f - centre, y + 0.5f - centre);
      Light(*canvas, x, y, r, 6 * s, Mix(kGold, kWhite, 0.6f), 1, s);
      canvas->Blend(x, y, Mix(accent, kGold, 0.6f),
                    0.75f * Square(Clamp01(1 - r / (kSpark * s))));
    }
  }
  return canvas;
}

// Where the spark is, |along| of the way round |box| from its top left,
// clockwise.
POINT SparkAt(const OutlineBox& box, float along) {
  const float width = box.right - box.left;
  const float height = box.bottom - box.top;
  float d = along * 2 * (width + height);
  float x = box.left;
  float y = box.top;
  if (d < width) {
    x += d;
  } else if ((d -= width) < height) {
    x = box.right;
    y += d;
  } else if ((d -= height) < width) {
    x = box.right - d;
    y = box.bottom;
  } else {
    y = box.bottom - (d - width);
  }
  return {static_cast<LONG>(x), static_cast<LONG>(y)};
}

// A pill with |text| in it, as Gaia's toasts are: its fill and a ring of
// light. A keycap is larger and squarer. Null if it won't draw.
std::unique_ptr<Canvas> PaintPill(const std::wstring& text, float s,
                                  Color accent, bool keycap,
                                  FlashStyle style = FlashStyle::kClassic) {
  const float height = (keycap ? 34 : 26) * s;
  const Gdiplus::REAL size = (keycap ? 15 : 13) * s;
  const float padding = (keycap ? 14 : 11) * s;
  const float radius = style == FlashStyle::kGlide ? 4 * s
                      : keycap ? 8 * s : height / 2;
  const int margin = static_cast<int>(std::ceil(kHalo * s));
  const float width =
      std::min(static_cast<float>(TextWidth(text, size) + 2), kMaxPillText * s) +
      2 * padding;
  auto canvas = std::make_unique<Canvas>(
      static_cast<int>(std::ceil(width)) + 2 * margin,
      static_cast<int>(std::ceil(height)) + 2 * margin);
  if (!canvas->ok()) return nullptr;
  canvas->Clear();
  const float m = static_cast<float>(margin);
  const Color fill = GaiaFill(accent);
  for (int y = 0; y < canvas->height(); ++y) {
    for (int x = 0; x < canvas->width(); ++x) {
      const float px = x + 0.5f;
      const float py = y + 0.5f;
      const float box = RoundedBox(px, py, m, m, m + width, m + height, radius);
      if (box > 0) {
        canvas->Blend(x, y, kShade, 0.4f * Square(Clamp01(1 - box / m)));
      }
      const float inside = Clamp01(0.5f - box);
      if (inside <= 0) continue;
      canvas->Blend(x, y, fill, inside * 0.94f);
      const float along = (px - m) / width;
      const Color ring =
          Mix(accent, kGold, 0.5f + 0.5f * std::sin(along * kPi * 2));
      if (style == FlashStyle::kClassic) {
        canvas->Blend(x, y, ring, inside * Clamp01(s + 0.5f + box) * 0.9f);
      } else {
        FamilyContour(*canvas, x, y, box, px + py, s, accent, style, 0.8f);
      }
    }
  }
  const RECT text_rect = {static_cast<LONG>(m + padding), margin,
                          static_cast<LONG>(m + width - padding),
                          static_cast<LONG>(m + height)};
  DrawLabel(*canvas, text, text_rect, size, kTextLift);
  return canvas;
}

// Where a box of |size| goes so it stays on |monitor|'s work area.
POINT Clamped(POINT at, SIZE size, HMONITOR monitor) {
  MONITORINFO info = {sizeof(info)};
  if (!::GetMonitorInfo(monitor, &info)) return at;
  const RECT& work = info.rcWork;
  at.x = std::max(work.left, std::min(at.x, work.right - size.cx));
  at.y = std::max(work.top, std::min(at.y, work.bottom - size.cy));
  return at;
}

void SetAlpha(HWND window, float alpha) {
  BLENDFUNCTION blend = {AC_SRC_OVER, 0,
                         static_cast<BYTE>(255 * Clamp01(alpha)), AC_SRC_ALPHA};
  ::UpdateLayeredWindow(window, nullptr, nullptr, nullptr, nullptr, nullptr, 0,
                        &blend, ULW_ALPHA);
}

void ShowOnTop(HWND window) {
  ::SetWindowPos(window, HWND_TOPMOST, 0, 0, 0, 0,
                 SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE | SWP_SHOWWINDOW);
}

}  // namespace

GaiaControlBorder::GaiaControlBorder(std::function<void()> on_revoke)
    : on_revoke_(std::move(on_revoke)) {}

GaiaControlBorder::~GaiaControlBorder() { Hide(); }

void GaiaControlBorder::Show(const std::wstring& label, unsigned int accent,
                             GaiaEffectStyle style) {
  label_ = label;
  accent_ = accent;
  style_ = style;
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
                 width, height, monitor, accent, self->style_);
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
      TextWidth(kButtonText, TextSize(monitor)) + 2 * Scaled(kButtonPadding, monitor);
  const int height = Scaled(kNotchHeight, monitor);
  const int button_height = Scaled(kButtonHeight, monitor);
  // As far from the notch's right edge as from its top and bottom, inside the
  // ring.
  const int inset = (height - kNotchRim - button_height) / 2;
  const int rest = padding + orb + gap + gap + button_width + inset + kNotchRim;
  // Never wider than the monitor, or the button goes off it.
  const int label_width =
      std::min({TextWidth(label_, TextSize(monitor)) + 2, Scaled(kMaxLabelWidth, monitor),
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
      if (style_ == GaiaEffectStyle::kClassic) {
        canvas.Blend(x, y, ring, inside * Clamp01(kNotchRim + 0.5f + box) * 0.9f);
      } else {
        FamilyContour(canvas, x, y, box + 1, px + py, w / width,
                      accent, style_, inside * 0.85f);
      }
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

  DrawLabel(canvas, label_, label_rect_, TextSize(monitor), kTextLift);
  DrawLabel(canvas, kButtonText, button_, TextSize(monitor),
            kButtonTextLift);
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

// One flash playing.
struct GaiaFlashes::Active {
  GaiaFlash flash;
  ULONGLONG start = 0;
  float total = 0;
  float scale = 1;
  // A point effect, redrawn each frame.
  HWND effect = nullptr;
  POINT effect_at = {};
  std::unique_ptr<Canvas> canvas;
  // A drag's: what its last frame drew on |canvas|, all else being clear.
  RECT drawn = {};
  // An outline round a control, faded as its kind fades.
  std::vector<HWND> outline;
  OutlineBox box = {};
  // Typing's spark, moved round the outline.
  HWND spark = nullptr;
  int spark_side = 0;
  // Pills and a window's strips, faded in and out.
  std::vector<HWND> faded;
  // What each group was last set to; they start hidden.
  BYTE outline_alpha = 0;
  // Per faded window, as only a few are updated a frame.
  std::vector<BYTE> faded_alphas;
  size_t next_faded = 0;
};

GaiaFlashes::GaiaFlashes() = default;

GaiaFlashes::~GaiaFlashes() {
  for (auto& active : active_) {
    if (active->effect) ::DestroyWindow(active->effect);
    if (active->spark) ::DestroyWindow(active->spark);
    for (HWND window : active->outline) ::DestroyWindow(window);
    for (HWND window : active->faded) ::DestroyWindow(window);
  }
  for (HWND window : hiding_) ::DestroyWindow(window);
  for (HWND window : pool_) ::DestroyWindow(window);
  if (timer_window_) ::DestroyWindow(timer_window_);
}

void GaiaFlashes::Play(const GaiaFlash& flash) {
  static const bool registered = [] {
    WNDCLASS window_class = {};
    window_class.lpfnWndProc = WindowProc;
    window_class.hInstance = ::GetModuleHandle(nullptr);
    window_class.lpszClassName = kFlashClass;
    return ::RegisterClass(&window_class) != 0;
  }();
  if (!registered) return;
  if (!timer_window_) {
    timer_window_ = ::CreateWindowEx(0, kFlashClass, L"", 0, 0, 0, 0, 0,
                                     HWND_MESSAGE, nullptr,
                                     ::GetModuleHandle(nullptr), this);
    if (!timer_window_) return;
  }
  const bool around_rect = AroundRect(flash);
  const bool window_wide = (flash.kind == GaiaFlash::Kind::kKey ||
                            flash.kind == GaiaFlash::Kind::kWindow) &&
                           !::IsRectEmpty(&flash.rect);
  const POINT centre = around_rect || window_wide
                           ? POINT{(flash.rect.left + flash.rect.right) / 2,
                                   (flash.rect.top + flash.rect.bottom) / 2}
                           : flash.point;
  const HMONITOR monitor = ::MonitorFromPoint(centre, MONITOR_DEFAULTTONEAREST);
  auto active = std::make_unique<Active>();
  active->flash = flash;
  active->start = ::GetTickCount64();
  active->total = TotalTime(flash);
  active->scale = ScaleAt(monitor);
  const float s = active->scale;
  const Color accent = FromRgb(flash.accent);

  // A point effect's square, or the box round both ends of a drag.
  SIZE effect_size = {};
  if (flash.kind == GaiaFlash::Kind::kDrag) {
    const LONG margin = static_cast<LONG>(std::ceil(kDragReach * s));
    active->effect_at = {std::min(flash.point.x, flash.to.x) - margin,
                         std::min(flash.point.y, flash.to.y) - margin};
    effect_size = {std::abs(flash.to.x - flash.point.x) + 2 * margin,
                   std::abs(flash.to.y - flash.point.y) + 2 * margin};
  } else if (const int side = EffectSide(flash, s); side > 0) {
    active->effect_at = {flash.point.x - side / 2, flash.point.y - side / 2};
    effect_size = {side, side};
  }
  if (effect_size.cx > 0) {
    active->canvas = std::make_unique<Canvas>(effect_size.cx, effect_size.cy);
    if (active->canvas->ok()) active->effect = Acquire();
    if (active->effect) {
      if (flash.kind == GaiaFlash::Kind::kDrag) {
        // Cleared whole once; after that, each frame only what it drew.
        active->canvas->Clear();
        active->drawn =
            PaintDragFrame(*active->canvas, flash, active->effect_at, 0, s, {});
      } else {
        PaintEffect(*active->canvas, flash, active->effect_at, 0, s);
      }
      active->canvas->PresentAt(active->effect, active->effect_at, 255);
      ShowOnTop(active->effect);
    }
  }

  if (around_rect) {
    active->box = OutlineAround(flash.rect, s);
    for (const RECT& piece : OutlinePieces(active->box, s)) {
      auto canvas = std::make_unique<Canvas>(piece.right - piece.left, piece.bottom - piece.top);
      HWND window = canvas->ok() ? Acquire() : nullptr;
      if (!window) break;
      const POINT at = {piece.left, piece.top};
      PaintOutline(*canvas, active->box, at, s, accent, flash.style);
      canvas->PresentAt(window, at, 0);
      active->outline.push_back(window);
    }
    if (flash.kind == GaiaFlash::Kind::kType &&
        flash.style != FlashStyle::kAstral) {
      auto spark = PaintSpark(s, accent, flash.style);
      active->spark = spark ? Acquire() : nullptr;
      if (active->spark) {
        active->spark_side = spark->width();
        spark->PresentAt(active->spark, SparkAt(active->box, 0), 0);
      }
    }
  }

  // A window's outline, drawn as the border's frame is, in four strips.
  const RECT& frame = flash.rect;
  if (flash.kind == GaiaFlash::Kind::kWindow && window_wide &&
      flash.style == FlashStyle::kAstral) {
    const int side = AstralWindowCornerSide(frame, s);
    const int inset = side / 6;
    if (side > 0) {
      for (int corner = 0; corner < 4; ++corner) {
        auto canvas = std::make_unique<Canvas>(side, side);
        HWND window = canvas->ok() ? Acquire() : nullptr;
        if (!window) break;
        const bool right = corner % 2 != 0;
        const bool bottom = corner / 2 != 0;
        const POINT at = {right ? frame.right - side + inset : frame.left - inset,
                          bottom ? frame.bottom - side + inset : frame.top - inset};
        PaintAstralWindowCorner(*canvas, right, bottom, s, accent);
        canvas->PresentAt(window, at, 0);
        active->faded.push_back(window);
      }
      const int depth = std::min(Scaled(24, monitor), std::max(2, side / 2));
      for (int edge = 0; edge < 4; ++edge) {
        const bool vertical = edge >= 2;
        const int extent = vertical ? frame.bottom - frame.top : frame.right - frame.left;
        const int length = std::min(extent - 2 * side,
                                    std::clamp(static_cast<int>(extent * 0.28f),
                                               Scaled(96, monitor), Scaled(360, monitor)));
        if (length <= 0) continue;
        auto canvas = std::make_unique<Canvas>(vertical ? depth : length, vertical ? length : depth);
        HWND window = canvas->ok() ? Acquire() : nullptr;
        if (!window) break;
        const POINT at = vertical
            ? POINT{(edge == 2 ? frame.left : frame.right) - depth / 2,
                    (frame.top + frame.bottom - length) / 2}
            : POINT{(frame.left + frame.right - length) / 2,
                    (edge == 0 ? frame.top : frame.bottom) - depth / 2};
        PaintAstralEdgeFade(*canvas, vertical, s, accent);
        canvas->PresentAt(window, at, 0);
        active->faded.push_back(window);
      }
    }
  }
  if (flash.kind == GaiaFlash::Kind::kWindow && window_wide &&
      flash.style != FlashStyle::kAstral) {
    const int width = frame.right - frame.left;
    const int height = frame.bottom - frame.top;
    const int edge =
        std::min({Scaled(kGlowDepth, monitor), width / 2, height / 2});
    const RECT strips[] = {
        {0, 0, width, edge},
        {0, height - edge, width, height},
        {0, edge, edge, height - edge},
        {width - edge, edge, width, height - edge},
    };
    for (const RECT& strip : strips) {
      if (strip.right <= strip.left || strip.bottom <= strip.top) continue;
      HWND window = Acquire();
      if (!window) break;
      ::SetWindowPos(window, HWND_TOPMOST, frame.left + strip.left,
                     frame.top + strip.top, strip.right - strip.left,
                     strip.bottom - strip.top, SWP_NOACTIVATE);
      PaintStrip(window, strip.left, strip.top, strip.right - strip.left,
                 strip.bottom - strip.top, width, height, monitor, accent, flash.style);
      SetAlpha(window, 0);
      active->faded.push_back(window);
    }
  }

  // The pill: the control's name beside the effect, or the keys or the
  // window's name near the top of the window.
  if (!flash.label.empty()) {
    const bool keycap = flash.kind == GaiaFlash::Kind::kKey;
    auto pill = PaintPill(flash.label, s, accent, keycap, flash.style);
    HWND window = pill ? Acquire() : nullptr;
    if (window) {
      const SIZE pill_size = {pill->width(), pill->height()};
      POINT at;
      if (window_wide) {
        at = {(frame.left + frame.right - pill_size.cx) / 2,
              frame.top + static_cast<LONG>((keycap ? 44 : 34) * s)};
      } else {
        // Right of the effect, or left of it at the monitor's edge.
        const RECT target = around_rect ? flash.rect
                                        : RECT{flash.point.x, flash.point.y,
                                               flash.point.x, flash.point.y};
        const LONG gap = static_cast<LONG>(kPillGap * s);
        at = {target.right + gap,
              (target.top + target.bottom) / 2 - pill_size.cy / 2};
        MONITORINFO info = {sizeof(info)};
        if (::GetMonitorInfo(monitor, &info) &&
            at.x + pill_size.cx > info.rcWork.right) {
          at.x = target.left - gap - pill_size.cx;
        }
      }
      pill->PresentAt(window, Clamped(at, pill_size, monitor), 0);
      active->faded.push_back(window);
    }
  }
  for (HWND window : active->outline) ShowOnTop(window);
  for (HWND window : active->faded) ShowOnTop(window);
  if (active->spark) ShowOnTop(active->spark);
  if (!active->effect && !active->spark && active->outline.empty() &&
      active->faded.empty()) {
    return;
  }
  active_.push_back(std::move(active));
  if (!ticking_) {
    ticking_ = ::SetTimer(timer_window_, kFlashTimer, 16, nullptr) != 0;
  }
}

void GaiaFlashes::Tick() {
  // Action feedback keeps its own clock, independent of Windows UI transitions.
  const ULONGLONG now = ::GetTickCount64();
  for (auto it = active_.begin(); it != active_.end();) {
    Active& active = **it;
    const float t = static_cast<float>(now - active.start);
    if (t >= active.total) {
      if (active.effect) hiding_.push_back(active.effect);
      if (active.spark) hiding_.push_back(active.spark);
      for (HWND window : active.outline) hiding_.push_back(window);
      for (HWND window : active.faded) hiding_.push_back(window);
      it = active_.erase(it);
      continue;
    }
    if (active.effect && active.flash.kind == GaiaFlash::Kind::kDrag) {
      // Only what changed: what the last frame drew, and what this one does.
      const RECT drawn = PaintDragFrame(*active.canvas, active.flash,
                                        active.effect_at, t, active.scale,
                                        active.drawn);
      RECT dirty;
      ::UnionRect(&dirty, &active.drawn, &drawn);
      active.drawn = drawn;
      if (!::IsRectEmpty(&dirty)) {
        active.canvas->PresentDirty(active.effect, dirty);
      }
    } else if (active.effect) {
      PaintEffect(*active.canvas, active.flash, active.effect_at, t,
                  active.scale);
      active.canvas->Present(active.effect);
    }
    // Each window update costs, so only when the alpha changes: mostly
    // while fading in and out.
    const BYTE outline_alpha =
        static_cast<BYTE>(255 * Envelope(t, 150, 300, active.total));
    if (!active.outline.empty() && outline_alpha != active.outline_alpha) {
      active.outline_alpha = outline_alpha;
      for (HWND window : active.outline) SetAlpha(window, outline_alpha / 255.0f);
    }
    if (active.spark) {
      // While the typing goes on. Moved and faded in one update.
      const float alpha =
          Clamp01(t / 150) * Clamp01((active.total - 300 - t) / 200);
      const POINT at = SparkAt(active.box, std::fmod(t / kSparkLap, 1.0f));
      const int half = active.spark_side / 2;
      POINT to = {at.x - half, at.y - half};
      BLENDFUNCTION blend = {AC_SRC_OVER, 0, static_cast<BYTE>(255 * alpha),
                             AC_SRC_ALPHA};
      ::UpdateLayeredWindow(active.spark, nullptr, &to, nullptr, nullptr,
                            nullptr, 0, &blend, ULW_ALPHA);
    }
    const BYTE faded_alpha =
        static_cast<BYTE>(255 * Envelope(t, 100, kFadeOut, active.total));
    // A window's eight pieces and its pill would take nine updates a frame,
    // so a few at a time, round them: one that waits catches up a frame on.
    active.faded_alphas.resize(active.faded.size());
    int updates = kFadeUpdates;
    for (size_t i = 0; i < active.faded.size() && updates > 0; ++i) {
      const size_t k = (active.next_faded + i) % active.faded.size();
      if (active.faded_alphas[k] == faded_alpha) continue;
      active.faded_alphas[k] = faded_alpha;
      SetAlpha(active.faded[k], faded_alpha / 255.0f);
      active.next_faded = k + 1;
      --updates;
    }
    ++it;
  }
  if (!hiding_.empty()) {
    // A few at a time, in one batch, which costs about what hiding one alone
    // does.
    const size_t count = std::min(hiding_.size(), kHidesPerFrame);
    HDWP batch = ::BeginDeferWindowPos(static_cast<int>(count));
    for (size_t i = hiding_.size() - count; i < hiding_.size() && batch; ++i) {
      batch = ::DeferWindowPos(batch, hiding_[i], nullptr, 0, 0, 0, 0,
                               SWP_HIDEWINDOW | SWP_NOMOVE | SWP_NOSIZE |
                                   SWP_NOZORDER | SWP_NOACTIVATE);
    }
    if (batch) ::EndDeferWindowPos(batch);
    for (size_t i = hiding_.size() - count; i < hiding_.size(); ++i) {
      Release(hiding_[i]);
    }
    hiding_.resize(hiding_.size() - count);
  }
  if (active_.empty() && hiding_.empty() && ticking_) {
    ::KillTimer(timer_window_, kFlashTimer);
    ticking_ = false;
  }
}

void GaiaFlashes::StopAll() {
  for (auto& active : active_) {
    if (active->effect) hiding_.push_back(active->effect);
    if (active->spark) hiding_.push_back(active->spark);
    for (HWND window : active->outline) hiding_.push_back(window);
    for (HWND window : active->faded) hiding_.push_back(window);
  }
  active_.clear();
  // All in one batch, rather than a few a frame as Tick does: a stop should
  // leave nothing showing.
  if (!hiding_.empty()) {
    HDWP batch = ::BeginDeferWindowPos(static_cast<int>(hiding_.size()));
    for (size_t i = 0; i < hiding_.size() && batch; ++i) {
      batch = ::DeferWindowPos(batch, hiding_[i], nullptr, 0, 0, 0, 0,
                               SWP_HIDEWINDOW | SWP_NOMOVE | SWP_NOSIZE |
                                   SWP_NOZORDER | SWP_NOACTIVATE);
    }
    if (batch) ::EndDeferWindowPos(batch);
    // Release hides any the batch didn't.
    for (HWND window : hiding_) Release(window);
    hiding_.clear();
  }
  if (ticking_) {
    ::KillTimer(timer_window_, kFlashTimer);
    ticking_ = false;
  }
}

HWND GaiaFlashes::Acquire() {
  if (!pool_.empty()) {
    HWND window = pool_.back();
    pool_.pop_back();
    return window;
  }
  // As the border's strips: never activated, never a target, clicks through.
  HWND window = ::CreateWindowEx(
      WS_EX_TOPMOST | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE | WS_EX_LAYERED |
          WS_EX_TRANSPARENT,
      kFlashClass, L"", WS_POPUP, 0, 0, 1, 1, nullptr, nullptr,
      ::GetModuleHandle(nullptr), this);
  if (window) ::SetWindowDisplayAffinity(window, kExcludeFromCapture);
  return window;
}

void GaiaFlashes::Release(HWND window) {
  if (::IsWindowVisible(window)) ::ShowWindow(window, SW_HIDE);
  if (pool_.size() < kFlashPool) {
    pool_.push_back(window);
  } else {
    ::DestroyWindow(window);
  }
}

LRESULT CALLBACK GaiaFlashes::WindowProc(HWND hwnd, UINT message,
                                         WPARAM wparam,
                                         LPARAM lparam) noexcept {
  if (message == WM_NCCREATE) {
    auto* create = reinterpret_cast<CREATESTRUCT*>(lparam);
    ::SetWindowLongPtr(hwnd, GWLP_USERDATA,
                       reinterpret_cast<LONG_PTR>(create->lpCreateParams));
  }
  switch (message) {
    case WM_MOUSEACTIVATE:
      return MA_NOACTIVATE;
    // WindowFromPoint asks windows of its own thread rather than going by
    // WS_EX_TRANSPARENT, and a flash must never cover the click it shows.
    case WM_NCHITTEST:
      return HTTRANSPARENT;
    case WM_TIMER:
      if (wparam == kFlashTimer) {
        auto* self = reinterpret_cast<GaiaFlashes*>(
            ::GetWindowLongPtr(hwnd, GWLP_USERDATA));
        if (self) self->Tick();
      }
      return 0;
  }
  return ::DefWindowProc(hwnd, message, wparam, lparam);
}

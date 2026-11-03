// Standalone native regression test. From an x64 Visual Studio tools prompt:
// cl /std:c++17 /EHsc /DNOMINMAX /DUNICODE /D_UNICODE
//   test\windows\gaia_control_animation_test.cpp /Febuild\gaia_animation_test.exe
//   /link user32.lib gdi32.lib gdiplus.lib shcore.lib ole32.lib
// Captures the native renderer's submitted frames in memory, including updates
// driven by its real WM_TIMER. No overlay bitmap is presented on the desktop.
#include <windows.h>

#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <set>

namespace {
std::set<uint64_t> g_frame_signatures;
std::set<std::pair<LONG, LONG>> g_presented_positions;
std::set<std::pair<LONG, LONG>> g_source_sizes;
int g_presentations = 0;
int g_blank_sources = 0;

BOOL WINAPI CaptureLayeredWindow(HWND, HDC, POINT* at, SIZE*, HDC source,
                                 POINT*, COLORREF, BLENDFUNCTION*, DWORD) {
  ++g_presentations;
  if (at) g_presented_positions.emplace(at->x, at->y);
  if (!source) return TRUE;
  DIBSECTION dib = {};
  if (!GetObject(GetCurrentObject(source, OBJ_BITMAP), sizeof(dib), &dib) ||
      !dib.dsBm.bmBits) return FALSE;
  const auto* bytes = static_cast<const uint8_t*>(dib.dsBm.bmBits);
  g_source_sizes.emplace(dib.dsBm.bmWidth, std::abs(dib.dsBm.bmHeight));
  const int count = dib.dsBm.bmWidthBytes * std::abs(dib.dsBm.bmHeight);
  bool blank = true;
  for (int i = 3; i < count && blank; i += 4) blank = bytes[i] == 0;
  if (blank) ++g_blank_sources;
  uint64_t hash = 14695981039346656037ull;
  for (int i = 0; i < count; ++i) hash = (hash ^ bytes[i]) * 1099511628211ull;
  g_frame_signatures.insert(hash);
  return TRUE;
}
}  // namespace

#define UpdateLayeredWindow CaptureLayeredWindow
#include "../../windows/runner/gaia_control_border.cpp"
#undef UpdateLayeredWindow

void PumpFor(ULONGLONG duration) {
  const auto end = GetTickCount64() + duration;
  while (GetTickCount64() < end) {
    MSG message;
    while (PeekMessage(&message, nullptr, 0, 0, PM_REMOVE)) {
      TranslateMessage(&message);
      DispatchMessage(&message);
    }
    Sleep(1);
  }
}

int main() {
  BOOL animate = TRUE;
  SystemParametersInfo(SPI_GETCLIENTAREAANIMATION, 0, &animate, 0);
  std::printf("Windows client-area animations: %s\n", animate ? "on" : "off");
  const char* names[] = {"Current", "Astral", "Echo", "Glide"};
  const GaiaFlash defaults;
  if (defaults.style != GaiaFlash::Style::kAstral ||
      defaults.click_variant != GaiaFlash::ClickVariant::kTraceBloom) {
    std::puts("FAIL: live native feedback should default to the accepted Trace + Bloom family");
    return 1;
  }
  const float dpi = ScaleAt(MonitorFromPoint({200, 200}, MONITOR_DEFAULTTONEAREST));
  int small_corner = 0;
  for (const bool large : {false, true}) {
    const int width = static_cast<int>((large ? 1600 : 400) * dpi);
    const int height = static_cast<int>((large ? 1000 : 240) * dpi);
    GaiaFlash window;
    window.style = GaiaFlash::Style::kAstral;
    window.kind = GaiaFlash::Kind::kWindow;
    window.accent = 0x7C9EFF;
    window.rect = {200 - width / 2, 200 - height / 2,
                   200 + width / 2, 200 + height / 2};
    g_source_sizes.clear();
    GaiaFlashes player;
    player.Play(window);
    std::set<int> square_sizes;
    for (const auto& size : g_source_sizes) {
      if (size.first == size.second) square_sizes.insert(size.first);
    }
    if (square_sizes.size() != 1 || g_source_sizes.size() < 3) return 1;
    const int size = *square_sizes.begin();
    if (!large) small_corner = size;
    if (large && size <= small_corner * 2) {
      std::puts("FAIL: large-window corners should reach substantially farther than small-window corners");
      return 1;
    }
  }
  std::puts("PASS: Astral corners grow with the window at the monitor's DPI");
  for (int variant = 0; variant < 3; ++variant) {
    GaiaFlash click;
    click.style = GaiaFlash::Style::kAstral;
    click.kind = GaiaFlash::Kind::kClick;
    click.click_variant = static_cast<GaiaFlash::ClickVariant>(variant);
    click.accent = 0x7C9EFF;
    click.point = {200, 200};
    g_frame_signatures.clear();
    GaiaFlashes player;
    player.Play(click);
    PumpFor(240);
    if (g_frame_signatures.size() < 3) {
      std::printf("FAIL: click study %d does not animate\n", variant);
      return 1;
    }
  }
  std::puts("PASS: all three single-click studies animate via WM_TIMER");
  Canvas midpoint(200, 24);
  PaintAstralEdgeFade(midpoint, false, 1, FromRgb(0x7C9EFF));
  uint32_t peak_alpha = 0;
  for (int pixel = 0; pixel < 200 * 24; ++pixel) {
    peak_alpha = std::max(peak_alpha, midpoint.pixels()[pixel] >> 24);
  }
  if (peak_alpha < 30 || peak_alpha > 140) {
    std::puts("FAIL: window midpoint should be visible but faint");
    return 1;
  }
  for (const float t : {120.0f, 125.0f, 130.0f, 135.0f, 140.0f, 450.0f, 720.0f}) {
    GaiaFlash click;
    click.style = GaiaFlash::Style::kAstral;
    click.kind = GaiaFlash::Kind::kDouble;
    click.accent = 0x7C9EFF;
    click.point = {48, 48};
    Canvas frame(96, 96);
    PaintEffect(frame, click, {0, 0}, t, 1);
    int visible = 0;
    for (int pixel = 0; pixel < 96 * 96; ++pixel) {
      if ((frame.pixels()[pixel] >> 24) > 150) ++visible;
    }
    if (visible < 30 || t >= TotalTime(click)) {
      std::printf("FAIL: Astral double-click cuts off at %.0fms\n", t);
      return 1;
    }
  }
  std::puts("PASS: Astral double-click remains continuous across the former restart and through its second half");
  for (int style = 1; style < 4; ++style) {
    for (int direction = 0; direction < 4; ++direction) {
      for (int amount : {3, 15}) {
        GaiaFlash scroll;
        scroll.style = static_cast<GaiaFlash::Style>(style);
        scroll.kind = GaiaFlash::Kind::kScroll;
        scroll.accent = 0x7C9EFF;
        scroll.point = {160, 160};
        scroll.direction = direction;
        scroll.amount = amount;
        Canvas sample(320, 320);
        PaintEffect(sample, scroll, {0, 0}, 240, 1);
        int solid_pixels = 0;
        for (int pixel = 0; pixel < 320 * 320; ++pixel) {
          const auto color = sample.pixels()[pixel];
          if ((color >> 24) > 180 &&
              std::max({color & 255, (color >> 8) & 255, (color >> 16) & 255}) > 100) {
            ++solid_pixels;
          }
        }
        if (solid_pixels < 150) {
          std::printf("FAIL: %s scroll %d amount %d too faint (%d solid pixels)\n",
                      names[style], direction, amount, solid_pixels);
          return 1;
        }
      }
    }
  }
  std::puts("PASS: all new scrolls retain solid strokes in every direction and at both distances");
  for (int style = 0; style < 4; ++style) {
    for (const auto kind : {GaiaFlash::Kind::kClick, GaiaFlash::Kind::kDouble,
                            GaiaFlash::Kind::kRight, GaiaFlash::Kind::kScroll,
                            GaiaFlash::Kind::kMark, GaiaFlash::Kind::kType,
                            GaiaFlash::Kind::kWindow, GaiaFlash::Kind::kKey}) {
      g_frame_signatures.clear();
      g_presented_positions.clear();
      g_source_sizes.clear();
      g_blank_sources = 0;
      GaiaFlashes player;
      GaiaFlash flash;
      flash.style = static_cast<GaiaFlash::Style>(style);
      flash.kind = kind;
      flash.accent = 0x7C9EFF;
      flash.point = {200, 200};
      if (kind == GaiaFlash::Kind::kType) flash.rect = {100, 100, 300, 140};
      if (kind == GaiaFlash::Kind::kWindow || kind == GaiaFlash::Kind::kKey) {
        flash.rect = {100, 100, 500, 340};
      }
      if (kind == GaiaFlash::Kind::kKey) flash.label = L"Ctrl+S";
      player.Play(flash);
      const auto placed = g_presented_positions.size();
      const int blank_at_start = g_blank_sources;
      // Exclude initial placement of the four outline strips: only an actual
      // moving spark submits further positions during the timer ticks.
      g_presented_positions.clear();
      g_frame_signatures.clear();
      g_presentations = 0;
      PumpFor(240);
      if (kind == GaiaFlash::Kind::kWindow) {
        if (g_presentations < 2) {
          std::puts("FAIL: window feedback should fade its native pieces");
          return 1;
        }
        if (flash.style == GaiaFlash::Style::kAstral &&
            (placed != 8 || g_source_sizes.size() < 3 || blank_at_start != 0 ||
             !g_frame_signatures.empty())) {
          std::puts("FAIL: Astral window corners and midpoint fades should be drawn whole once, then only faded");
          return 1;
        }
        continue;
      }
      if (flash.style == GaiaFlash::Style::kAstral && kind == GaiaFlash::Kind::kType) {
        if (!g_presented_positions.empty() || g_presentations < 2 || blank_at_start != 0 ||
            !g_frame_signatures.empty()) {
          std::puts("FAIL: Astral typing should draw its whole outline once, then only fade, without a travelling pearl");
          return 1;
        }
        continue;
      }
      if (kind == GaiaFlash::Kind::kKey) {
        if (g_presentations < 1 ||
            (flash.style == GaiaFlash::Style::kAstral &&
             (blank_at_start != 0 || !g_frame_signatures.empty()))) {
          std::printf("FAIL: %s key feedback: %d updates, %zu material frames\n",
                      names[style], g_presentations, g_frame_signatures.size());
          return 1;
        }
        continue;
      }
      const bool moved = kind == GaiaFlash::Kind::kType
                            ? g_presented_positions.size() > 2 : g_frame_signatures.size() > 2;
      if (!moved) {
        std::printf("FAIL: %s kind %d: %zu frames, %zu positions\n",
                    names[style], static_cast<int>(kind), g_frame_signatures.size(), g_presented_positions.size());
        return 1;
      }
    }
    std::printf("PASS: %s action animation and typing feedback via WM_TIMER\n", names[style]);
  }
  return 0;
}


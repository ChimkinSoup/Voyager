#include "gaia_control_border.h"

#include <shellscalingapi.h>

#include <algorithm>

namespace {

constexpr wchar_t kWindowClass[] = L"VoyagerGaiaControlBorder";
constexpr COLORREF kColor = RGB(0xE5, 0x48, 0x4D);
constexpr int kThickness = 3;  // At 100%.
constexpr int kLabelHeight = 24;
constexpr int kLabelPadding = 12;

// WDA_EXCLUDEFROMCAPTURE, from Windows 10 2004. Older ones ignore the call.
constexpr DWORD kExcludeFromCapture = 0x11;

int Scaled(int value, HMONITOR monitor) {
  UINT dpi_x = 96;
  UINT dpi_y = 96;
  ::GetDpiForMonitor(monitor, MDT_EFFECTIVE_DPI, &dpi_x, &dpi_y);
  return ::MulDiv(value, dpi_x, 96);
}

HFONT LabelFont(HMONITOR monitor) {
  NONCLIENTMETRICS metrics = {sizeof(metrics)};
  ::SystemParametersInfo(SPI_GETNONCLIENTMETRICS, sizeof(metrics), &metrics, 0);
  metrics.lfMessageFont.lfHeight = -Scaled(12, monitor);
  metrics.lfMessageFont.lfWeight = FW_SEMIBOLD;
  return ::CreateFontIndirect(&metrics.lfMessageFont);
}

}  // namespace

GaiaControlBorder::~GaiaControlBorder() { Hide(); }

void GaiaControlBorder::Show(const std::wstring& label) {
  label_ = label;
  Rebuild();
}

void GaiaControlBorder::Hide() {
  label_window_ = nullptr;
  for (HWND window : windows_) ::DestroyWindow(window);
  windows_.clear();
}

void GaiaControlBorder::Rebuild() {
  static const bool registered = [] {
    WNDCLASS window_class = {};
    window_class.lpfnWndProc = WindowProc;
    window_class.hInstance = ::GetModuleHandle(nullptr);
    window_class.lpszClassName = kWindowClass;
    window_class.hbrBackground = ::CreateSolidBrush(kColor);
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
  const int edge = Scaled(kThickness, monitor);
  self->AddWindow(r.left, r.top, width, edge);
  self->AddWindow(r.left, r.bottom - edge, width, edge);
  self->AddWindow(r.left, r.top, edge, height);
  self->AddWindow(r.right - edge, r.top, edge, height);
  if (info.dwFlags & MONITORINFOF_PRIMARY) {
    HDC screen = ::GetDC(nullptr);
    HFONT font = LabelFont(monitor);
    HGDIOBJ old = ::SelectObject(screen, font);
    SIZE text = {};
    ::GetTextExtentPoint32(screen, self->label_.c_str(),
                           static_cast<int>(self->label_.size()), &text);
    ::SelectObject(screen, old);
    ::DeleteObject(font);
    ::ReleaseDC(nullptr, screen);
    const int label_width = std::min(
        static_cast<int>(text.cx) + 2 * Scaled(kLabelPadding, monitor), width);
    self->label_window_ = self->AddWindow(
        r.left + (width - label_width) / 2, r.top, label_width,
        Scaled(kLabelHeight, monitor));
  }
  return TRUE;
}

HWND GaiaControlBorder::AddWindow(int left, int top, int width, int height) {
  HWND window = ::CreateWindowEx(
      WS_EX_TOPMOST | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE | WS_EX_LAYERED |
          WS_EX_TRANSPARENT,
      kWindowClass, L"", WS_POPUP, left, top, width, height, nullptr, nullptr,
      ::GetModuleHandle(nullptr), this);
  if (!window) return nullptr;
  ::SetLayeredWindowAttributes(window, 0, 255, LWA_ALPHA);
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
  switch (message) {
    case WM_PAINT: {
      PAINTSTRUCT paint;
      HDC dc = ::BeginPaint(hwnd, &paint);
      if (self && hwnd == self->label_window_) {
        HFONT font = LabelFont(::MonitorFromWindow(hwnd, MONITOR_DEFAULTTOPRIMARY));
        HGDIOBJ old = ::SelectObject(dc, font);
        ::SetBkMode(dc, TRANSPARENT);
        ::SetTextColor(dc, RGB(0xFF, 0xFF, 0xFF));
        RECT client;
        ::GetClientRect(hwnd, &client);
        ::DrawText(dc, self->label_.c_str(),
                   static_cast<int>(self->label_.size()), &client,
                   DT_CENTER | DT_VCENTER | DT_SINGLELINE | DT_END_ELLIPSIS |
                       DT_NOPREFIX);
        ::SelectObject(dc, old);
        ::DeleteObject(font);
      }
      ::EndPaint(hwnd, &paint);
      return 0;
    }
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

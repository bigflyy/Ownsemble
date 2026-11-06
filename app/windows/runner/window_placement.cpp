#include "window_placement.h"

#include <fstream>

namespace {

constexpr wchar_t kFileName[] = L"window-placement.txt";

// A smaller saved window is treated as broken: it would open unusable.
constexpr LONG kMinimumWidth = 320;
constexpr LONG kMinimumHeight = 240;

// How far below the frame's top edge the title bar is looked for.
constexpr LONG kTitleBarDepth = 12;

// Converts UTF-8 text to the wide text Windows paths use.
std::wstring ToWide(const std::string& text) {
  if (text.empty()) {
    return std::wstring();
  }
  const int length = MultiByteToWideChar(CP_UTF8, 0, text.c_str(), -1, nullptr, 0);
  if (length <= 0) {
    return std::wstring();
  }
  std::wstring wide(length - 1, L'\0');
  MultiByteToWideChar(CP_UTF8, 0, text.c_str(), -1, wide.data(), length);
  return wide;
}

}  // namespace

std::wstring WindowPlacementPath(const std::vector<std::string>& arguments) {
  for (size_t i = 0; i + 1 < arguments.size(); i++) {
    if (arguments[i] == "--data-dir") {
      return ToWide(arguments[i + 1]) + L"\\" + kFileName;
    }
  }
  // An agent check without its own data folder (an integration test gets it
  // as a build define, not an argument) must not open at, or save over, the
  // user's own window (seen 2026-11-07: the user's maximized window made the
  // check's window too big to shrink). Empty: nothing is read or written.
  if (GetEnvironmentVariableW(L"OWNSEMBLE_BACKGROUND_WINDOW", nullptr, 0) > 0) {
    return std::wstring();
  }
  wchar_t app_data[MAX_PATH];
  const DWORD length = GetEnvironmentVariableW(L"APPDATA", app_data, MAX_PATH);
  if (length == 0 || length >= MAX_PATH) {
    return std::wstring();
  }
  return std::wstring(app_data) + L"\\Ownsemble\\v2\\" + kFileName;
}

std::optional<WindowPlacement> LoadWindowPlacement(const std::wstring& path) {
  if (path.empty()) {
    return std::nullopt;
  }
  std::ifstream file(path.c_str());
  LONG left, top, width, height;
  int maximized;
  if (!(file >> left >> top >> width >> height >> maximized)) {
    return std::nullopt;
  }
  if (width < kMinimumWidth || height < kMinimumHeight) {
    return std::nullopt;
  }
  // The title bar's middle must be on a monitor, or the window cannot be
  // reached with the mouse.
  const POINT title_bar = {left + width / 2, top + kTitleBarDepth};
  if (MonitorFromPoint(title_bar, MONITOR_DEFAULTTONULL) == nullptr) {
    return std::nullopt;
  }
  return WindowPlacement{{left, top, left + width, top + height}, maximized != 0};
}

void SaveWindowPlacement(HWND window, const std::wstring& path) {
  if (path.empty()) {
    return;
  }
  WINDOWPLACEMENT placement = {sizeof(placement)};
  if (!GetWindowPlacement(window, &placement)) {
    return;
  }
  // rcNormalPosition counts from the monitor's work area, which starts after
  // a taskbar on the left or top; CreateWindow counts from the screen.
  MONITORINFO monitor = {sizeof(monitor)};
  GetMonitorInfo(MonitorFromWindow(window, MONITOR_DEFAULTTONEAREST), &monitor);
  const LONG work_left = monitor.rcWork.left - monitor.rcMonitor.left;
  const LONG work_top = monitor.rcWork.top - monitor.rcMonitor.top;
  const RECT& frame = placement.rcNormalPosition;
  // A window minimized from maximized comes back maximized.
  const bool maximized =
      placement.showCmd == SW_SHOWMAXIMIZED ||
      (placement.showCmd == SW_SHOWMINIMIZED &&
       (placement.flags & WPF_RESTORETOMAXIMIZED) != 0);
  std::ofstream file(path.c_str(), std::ios::trunc);
  file << frame.left + work_left << ' ' << frame.top + work_top << ' '
       << frame.right - frame.left << ' ' << frame.bottom - frame.top << ' '
       << (maximized ? 1 : 0) << '\n';
}

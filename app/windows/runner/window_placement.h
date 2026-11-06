#ifndef RUNNER_WINDOW_PLACEMENT_H_
#define RUNNER_WINDOW_PLACEMENT_H_

#include <windows.h>

#include <optional>
#include <string>
#include <vector>

// The window's size and place kept between runs. This lives in a small file in
// the data folder and not in the app's database: the window must have its
// final size before the Flutter engine starts, so the first frame is drawn at
// that size.
struct WindowPlacement {
  // The frame in screen pixels. For a maximized window, the frame it goes back
  // to when it is restored.
  RECT frame;
  bool maximized;
};

// The placement file of the data folder the app runs on: --data-dir from
// |arguments| (UTF-8), else the app's default folder under %APPDATA%; empty
// (no file) for an agent check (OWNSEMBLE_BACKGROUND_WINDOW) without one.
std::wstring WindowPlacementPath(const std::vector<std::string>& arguments);

// Reads the file at |path|. Empty when there is none, when it is broken, or
// when the title bar would be on no monitor (for example one unplugged since).
std::optional<WindowPlacement> LoadWindowPlacement(const std::wstring& path);

// Writes the placement of |window| to the file at |path|.
void SaveWindowPlacement(HWND window, const std::wstring& path);

#endif  // RUNNER_WINDOW_PLACEMENT_H_

#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include "flutter_window.h"
#include "utils.h"
#include "window_placement.h"

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");
  // Impeller's OpenGL ES backend adds about one second to engine startup on
  // Windows (measured: window shown at ~1.3 s with Impeller, ~0.4 s with
  // Skia), which breaks the < 1 s cold start target.
  project.set_impeller_switch(flutter::ImpellerSwitch::Disabled);

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  const std::wstring placement_path = WindowPlacementPath(command_line_arguments);
  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project, placement_path);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1100, 760);
  if (const auto placement = LoadWindowPlacement(placement_path)) {
    window.SetStartPlacement(placement->frame, placement->maximized);
  }
  if (!window.Create(L"Ownsemble v2", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  return EXIT_SUCCESS;
}

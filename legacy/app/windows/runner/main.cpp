#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>
#include <cstdlib>

#include "flutter_window.h"
#include "utils.h"

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

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  bool isolated = false;
  for (const auto& argument : command_line_arguments) {
    if (argument == "--smoke-test" || argument == "--smoke-resume" ||
        argument == "--demo" || argument == "--browser-smoke" ||
        argument == "--streaming-smoke") isolated = true;
    const std::string prefix = "--restart-parent=";
    if (argument.rfind(prefix, 0) == 0) {
      const std::string value = argument.substr(prefix.size());
      if (value.empty() || value.size() > 10 ||
          value.find_first_not_of("0123456789") != std::string::npos) {
        return EXIT_FAILURE;
      }
      const DWORD parent_id = static_cast<DWORD>(std::strtoul(value.c_str(), nullptr, 10));
      if (!parent_id || parent_id == GetCurrentProcessId()) return EXIT_FAILURE;
      // The old instance owns the single-instance mutex until it exits.
      // Wait before acquiring it, so a fast child cannot activate a dying parent.
      HANDLE parent_process = OpenProcess(SYNCHRONIZE, FALSE, parent_id);
      if (parent_process) {
        const DWORD outcome = WaitForSingleObject(parent_process, 15000);
        CloseHandle(parent_process);
        if (outcome != WAIT_OBJECT_0) return EXIT_FAILURE;
      }
    }
  }
  HANDLE instance_mutex = nullptr;
  if (!isolated) {
    instance_mutex = CreateMutexW(nullptr, TRUE, L"Local\\OwnsembleDesktopApp");
    if (instance_mutex && GetLastError() == ERROR_ALREADY_EXISTS) {
      HWND previous_window = FindWindowW(nullptr, L"Ownsemble");
      if (previous_window) {
        ShowWindow(previous_window, SW_RESTORE);
        SetForegroundWindow(previous_window);
      }
      CloseHandle(instance_mutex);
      return EXIT_SUCCESS;
    }
  }

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  if (!window.Create(L"Ownsemble", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  if (instance_mutex) CloseHandle(instance_mutex);
  return EXIT_SUCCESS;
}

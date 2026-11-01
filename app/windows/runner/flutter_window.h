#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>

#include <memory>
#include <string>

#include "vk_login_window.h"
#include "win32_window.h"

// A window that does nothing but host a Flutter view.
class FlutterWindow : public Win32Window {
 public:
  // Creates a new FlutterWindow hosting a Flutter view running |project|. Its
  // placement is saved to the file at |placement_path| when it closes.
  FlutterWindow(const flutter::DartProject& project,
                const std::wstring& placement_path);
  virtual ~FlutterWindow();

 protected:
  // Win32Window:
  bool OnCreate() override;
  void OnDestroy() override;
  LRESULT MessageHandler(HWND window, UINT const message, WPARAM const wparam,
                         LPARAM const lparam) noexcept override;

 private:
  // The project to run.
  flutter::DartProject project_;

  // Where the placement is saved when the window closes.
  std::wstring placement_path_;

  // The Flutter instance hosted by this window.
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;

  // The VK login window; it goes before the engine it talks to.
  std::unique_ptr<VkLoginWindow> vk_login_window_;
};

#endif  // RUNNER_FLUTTER_WINDOW_H_

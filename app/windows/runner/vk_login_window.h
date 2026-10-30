#ifndef RUNNER_VK_LOGIN_WINDOW_H_
#define RUNNER_VK_LOGIN_WINDOW_H_

#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <windows.h>
#include <wrl.h>

#include <WebView2.h>

#include <memory>
#include <string>

// The VK login window: a separate top-level window with WebView2 in it, where
// the user types their login into VK's own page. The app never sees those
// fields; Dart only asks for the session cookies the page ends up with.
//
// Native and not a Flutter view, so it costs nothing until it opens. It runs
// in private mode: WebView2 keeps no cookies on disk, and logging out needs
// nothing here.
//
// Channel "ownsemble/vk_login":
//   open {url, userDataDir, cookies?} - opens the window. `cookies` are set
//       before the page loads; only the agent's login check uses them.
//   cookies - the current VK cookies as a list of {name, value, domain}.
//   location - host and path of the current page, without its query.
//   capture {path} - saves a PNG of the page, for the agent's login check.
//   close - closes the window.
// and to Dart:
//   closed - the window is gone, whoever closed it.
class VkLoginWindow {
 public:
  VkLoginWindow(flutter::BinaryMessenger* messenger, HWND owner);
  ~VkLoginWindow();

  VkLoginWindow(const VkLoginWindow&) = delete;
  VkLoginWindow& operator=(const VkLoginWindow&) = delete;

 private:
  using MethodCall = flutter::MethodCall<flutter::EncodableValue>;
  using MethodResult = flutter::MethodResult<flutter::EncodableValue>;

  static LRESULT CALLBACK WndProc(HWND window, UINT message, WPARAM wparam,
                                  LPARAM lparam) noexcept;

  void HandleCall(const MethodCall& call, std::unique_ptr<MethodResult> result);
  void Open(const flutter::EncodableMap& arguments,
            std::unique_ptr<MethodResult> result);
  void OnWebViewReady(ICoreWebView2Controller* controller);
  void CollectCookies(size_t next_address,
                      std::shared_ptr<flutter::EncodableList> found,
                      std::shared_ptr<MethodResult> result);
  void SeedCookies(const flutter::EncodableList& cookies);
  void Capture(const std::wstring& path, std::unique_ptr<MethodResult> result);
  void FitWebView();
  void CreateNativeWindow();
  void Close();

  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
  HWND owner_;
  HWND window_ = nullptr;
  Microsoft::WRL::ComPtr<ICoreWebView2Controller> controller_;
  Microsoft::WRL::ComPtr<ICoreWebView2> webview_;

  // Waiting for WebView2 to start; answered when it has or has failed.
  std::shared_ptr<MethodResult> pending_open_;
  std::wstring start_url_;
  flutter::EncodableList seed_cookies_;

  // Tells a late WebView2 callback that its window was closed meanwhile.
  int generation_ = 0;
};

#endif  // RUNNER_VK_LOGIN_WINDOW_H_

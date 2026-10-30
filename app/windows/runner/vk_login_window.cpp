#include "vk_login_window.h"

#include <flutter/standard_method_codec.h>
#include <shlwapi.h>

#include <algorithm>
#include <iterator>
#include <utility>

#include "resource.h"
#include "utils.h"

using flutter::EncodableList;
using flutter::EncodableMap;
using flutter::EncodableValue;
using Microsoft::WRL::Callback;
using Microsoft::WRL::ComPtr;

namespace {

const wchar_t kWindowClass[] = L"OWNSEMBLE_VK_LOGIN_WINDOW";
// VK's login page breaks up in a narrower window: its parts overlap.
const int kWidth = 1020;
const int kHeight = 900;

// The addresses whose cookies make up a VK session. The session itself is on
// vk.ru; login.vk.ru and vk.com hold the rest of what the web client sends.
const wchar_t* const kCookieAddresses[] = {
    L"https://vk.ru/",
    L"https://login.vk.ru/",
    L"https://api.vk.ru/",
    L"https://vk.com/",
};

std::wstring Utf16FromUtf8(const std::string& text) {
  if (text.empty()) return std::wstring();
  const int length = MultiByteToWideChar(CP_UTF8, 0, text.data(),
                                         static_cast<int>(text.size()),
                                         nullptr, 0);
  std::wstring wide(length, L'\0');
  MultiByteToWideChar(CP_UTF8, 0, text.data(), static_cast<int>(text.size()),
                      wide.data(), length);
  return wide;
}

// A string argument of a method call; empty when it is missing.
std::string StringArgument(const EncodableMap& arguments, const char* name) {
  const auto found = arguments.find(EncodableValue(name));
  if (found == arguments.end()) return std::string();
  const auto* text = std::get_if<std::string>(&found->second);
  return text ? *text : std::string();
}

// Reads a text property of a WebView2 object and frees its buffer.
template <typename Getter>
std::string TakeText(Getter getter) {
  LPWSTR raw = nullptr;
  std::string text;
  if (SUCCEEDED(getter(&raw)) && raw) text = Utf8FromUtf16(raw);
  CoTaskMemFree(raw);
  return text;
}

// Agent checks open every window outside all monitors; see Win32Window::Show.
bool IsBackgroundRun() {
  return GetEnvironmentVariableW(L"OWNSEMBLE_BACKGROUND_WINDOW", nullptr, 0) > 0;
}

}  // namespace

VkLoginWindow::VkLoginWindow(flutter::BinaryMessenger* messenger, HWND owner)
    : owner_(owner) {
  channel_ = std::make_unique<flutter::MethodChannel<EncodableValue>>(
      messenger, "ownsemble/vk_login",
      &flutter::StandardMethodCodec::GetInstance());
  channel_->SetMethodCallHandler(
      [this](const MethodCall& call, std::unique_ptr<MethodResult> result) {
        HandleCall(call, std::move(result));
      });
}

VkLoginWindow::~VkLoginWindow() {
  channel_->SetMethodCallHandler(nullptr);
  Close();
}

void VkLoginWindow::HandleCall(const MethodCall& call,
                               std::unique_ptr<MethodResult> result) {
  const auto* arguments = std::get_if<EncodableMap>(call.arguments());
  const std::string& method = call.method_name();
  if (method == "open" && arguments) {
    Open(*arguments, std::move(result));
  } else if (method == "cookies") {
    if (!webview_) {
      result->Success(EncodableValue(EncodableList()));
      return;
    }
    CollectCookies(0, std::make_shared<EncodableList>(),
                   std::shared_ptr<MethodResult>(std::move(result)));
  } else if (method == "location") {
    if (!webview_) {
      result->Success(EncodableValue(std::string()));
      return;
    }
    std::string source =
        TakeText([&](LPWSTR* out) { return webview_->get_Source(out); });
    // Queries and fragments can hold tokens; nothing here needs them.
    source = source.substr(0, source.find_first_of("?#"));
    const size_t scheme = source.find("://");
    if (scheme != std::string::npos) source = source.substr(scheme + 3);
    result->Success(EncodableValue(source));
  } else if (method == "capture" && arguments) {
    Capture(Utf16FromUtf8(StringArgument(*arguments, "path")),
            std::move(result));
  } else if (method == "close") {
    Close();
    result->Success();
  } else {
    result->NotImplemented();
  }
}

void VkLoginWindow::CreateNativeWindow() {
  static const bool registered = [] {
    WNDCLASSEX window_class = {};
    window_class.cbSize = sizeof(WNDCLASSEX);
    window_class.lpszClassName = kWindowClass;
    window_class.lpfnWndProc = WndProc;
    window_class.hInstance = GetModuleHandle(nullptr);
    window_class.hIcon =
        LoadIcon(window_class.hInstance, MAKEINTRESOURCE(IDI_APP_ICON));
    window_class.hCursor = LoadCursor(nullptr, IDC_ARROW);
    return RegisterClassEx(&window_class) != 0;
  }();
  if (!registered) return;

  // Centered on the app's window, at the app's scale.
  RECT owner_frame = {};
  GetWindowRect(owner_, &owner_frame);
  const double scale = GetDpiForWindow(owner_) / 96.0;
  // Never bigger than the screen the app is on.
  MONITORINFO monitor = {sizeof(MONITORINFO)};
  GetMonitorInfo(MonitorFromWindow(owner_, MONITOR_DEFAULTTONEAREST), &monitor);
  const RECT& screen = monitor.rcWork;
  const int width = std::min<int>(static_cast<int>(kWidth * scale),
                                  screen.right - screen.left);
  const int height = std::min<int>(static_cast<int>(kHeight * scale),
                                   screen.bottom - screen.top);
  const int left = std::clamp<int>(
      (owner_frame.left + owner_frame.right - width) / 2, screen.left,
      screen.right - width);
  const int top = std::clamp<int>(
      (owner_frame.top + owner_frame.bottom - height) / 2, screen.top,
      screen.bottom - height);

  window_ = CreateWindowEx(
      IsBackgroundRun() ? WS_EX_NOACTIVATE : 0, kWindowClass, L"Log in to VK",
      WS_OVERLAPPEDWINDOW, left, top, width, height, owner_, nullptr,
      GetModuleHandle(nullptr), this);
  if (!window_) return;

  if (IsBackgroundRun()) {
    SetWindowPos(window_, HWND_BOTTOM, -20000, -20000, 0, 0,
                 SWP_NOSIZE | SWP_NOACTIVATE);
    ShowWindow(window_, SW_SHOWNOACTIVATE);
  } else {
    ShowWindow(window_, SW_SHOWNORMAL);
  }
}

void VkLoginWindow::Open(const EncodableMap& arguments,
                         std::unique_ptr<MethodResult> result) {
  // A second click on Log in shows the window that is already open.
  if (window_) {
    if (!IsBackgroundRun()) SetForegroundWindow(window_);
    result->Success(EncodableValue(true));
    return;
  }
  CreateNativeWindow();
  if (!window_) {
    result->Error("window_failed", "Could not open the login window");
    return;
  }

  start_url_ = Utf16FromUtf8(StringArgument(arguments, "url"));
  seed_cookies_.clear();
  const auto seed = arguments.find(EncodableValue("cookies"));
  if (seed != arguments.end()) {
    if (const auto* list = std::get_if<EncodableList>(&seed->second)) {
      seed_cookies_ = *list;
    }
  }
  pending_open_ = std::shared_ptr<MethodResult>(std::move(result));
  const int generation = ++generation_;
  const std::wstring user_data =
      Utf16FromUtf8(StringArgument(arguments, "userDataDir"));

  // Called with the outcome of either step of starting WebView2.
  auto fail = [this](const char* code, HRESULT hr) {
    if (pending_open_) {
      pending_open_->Error(code, "HRESULT " + std::to_string(hr));
      pending_open_ = nullptr;
    }
    Close();
  };

  const HRESULT started = CreateCoreWebView2EnvironmentWithOptions(
      nullptr, user_data.c_str(), nullptr,
      Callback<ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler>(
          [this, generation, fail](HRESULT hr,
                                   ICoreWebView2Environment* environment)
              -> HRESULT {
            if (generation != generation_) return S_OK;
            ComPtr<ICoreWebView2Environment10> private_capable;
            ComPtr<ICoreWebView2ControllerOptions> options;
            if (FAILED(hr) || !environment ||
                FAILED(environment->QueryInterface(
                    IID_PPV_ARGS(&private_capable))) ||
                FAILED(private_capable->CreateCoreWebView2ControllerOptions(
                    &options))) {
              fail("webview_failed", hr);
              return S_OK;
            }
            options->put_IsInPrivateModeEnabled(TRUE);
            const HRESULT created =
                private_capable->CreateCoreWebView2ControllerWithOptions(
                    window_, options.Get(),
                    Callback<
                        ICoreWebView2CreateCoreWebView2ControllerCompletedHandler>(
                        [this, generation, fail](
                            HRESULT hr,
                            ICoreWebView2Controller* controller) -> HRESULT {
                          if (generation != generation_) {
                            if (controller) controller->Close();
                            return S_OK;
                          }
                          if (FAILED(hr) || !controller) {
                            fail("webview_failed", hr);
                            return S_OK;
                          }
                          OnWebViewReady(controller);
                          return S_OK;
                        })
                        .Get());
            if (FAILED(created)) fail("webview_failed", created);
            return S_OK;
          })
          .Get());
  // The runtime ships with Windows 11; on an older system it can be missing.
  if (FAILED(started)) fail("webview_missing", started);
}

void VkLoginWindow::OnWebViewReady(ICoreWebView2Controller* controller) {
  controller_ = controller;
  controller_->get_CoreWebView2(&webview_);
  FitWebView();
  if (!IsBackgroundRun()) {
    controller_->MoveFocus(COREWEBVIEW2_MOVE_FOCUS_REASON_PROGRAMMATIC);
  }

  ComPtr<ICoreWebView2Settings> settings;
  if (SUCCEEDED(webview_->get_Settings(&settings))) {
    settings->put_AreDevToolsEnabled(FALSE);
  }

  // Links that want a new window (help pages, the QR code) stay in this one.
  EventRegistrationToken token;
  webview_->add_NewWindowRequested(
      Callback<ICoreWebView2NewWindowRequestedEventHandler>(
          [](ICoreWebView2* sender,
             ICoreWebView2NewWindowRequestedEventArgs* args) -> HRESULT {
            args->put_Handled(TRUE);
            LPWSTR uri = nullptr;
            if (SUCCEEDED(args->get_Uri(&uri)) && uri) sender->Navigate(uri);
            CoTaskMemFree(uri);
            return S_OK;
          })
          .Get(),
      &token);

  SeedCookies(seed_cookies_);
  seed_cookies_.clear();
  webview_->Navigate(start_url_.c_str());

  if (pending_open_) {
    pending_open_->Success(EncodableValue(true));
    pending_open_ = nullptr;
  }
}

void VkLoginWindow::SeedCookies(const EncodableList& cookies) {
  if (cookies.empty()) return;
  ComPtr<ICoreWebView2_2> webview2;
  ComPtr<ICoreWebView2CookieManager> manager;
  if (FAILED(webview_.As(&webview2)) ||
      FAILED(webview2->get_CookieManager(&manager))) {
    return;
  }
  for (const EncodableValue& entry : cookies) {
    const auto* fields = std::get_if<EncodableMap>(&entry);
    if (!fields) continue;
    ComPtr<ICoreWebView2Cookie> cookie;
    const HRESULT created = manager->CreateCookie(
        Utf16FromUtf8(StringArgument(*fields, "name")).c_str(),
        Utf16FromUtf8(StringArgument(*fields, "value")).c_str(),
        Utf16FromUtf8(StringArgument(*fields, "domain")).c_str(), L"/",
        &cookie);
    if (SUCCEEDED(created)) {
      cookie->put_IsSecure(TRUE);
      manager->AddOrUpdateCookie(cookie.Get());
    }
  }
}

void VkLoginWindow::CollectCookies(size_t next_address,
                                   std::shared_ptr<EncodableList> found,
                                   std::shared_ptr<MethodResult> result) {
  ComPtr<ICoreWebView2_2> webview2;
  ComPtr<ICoreWebView2CookieManager> manager;
  if (!webview_ || FAILED(webview_.As(&webview2)) ||
      FAILED(webview2->get_CookieManager(&manager))) {
    result->Success(EncodableValue(*found));
    return;
  }
  if (next_address == std::size(kCookieAddresses)) {
    result->Success(EncodableValue(*found));
    return;
  }
  manager->GetCookies(
      kCookieAddresses[next_address],
      Callback<ICoreWebView2GetCookiesCompletedHandler>(
          [this, next_address, found, result](
              HRESULT hr, ICoreWebView2CookieList* list) -> HRESULT {
            UINT count = 0;
            if (SUCCEEDED(hr) && list) list->get_Count(&count);
            for (UINT i = 0; i < count; i++) {
              ComPtr<ICoreWebView2Cookie> cookie;
              if (FAILED(list->GetValueAtIndex(i, &cookie))) continue;
              found->push_back(EncodableValue(EncodableMap{
                  {EncodableValue("name"),
                   EncodableValue(TakeText([&](LPWSTR* out) {
                     return cookie->get_Name(out);
                   }))},
                  {EncodableValue("value"),
                   EncodableValue(TakeText([&](LPWSTR* out) {
                     return cookie->get_Value(out);
                   }))},
                  {EncodableValue("domain"),
                   EncodableValue(TakeText([&](LPWSTR* out) {
                     return cookie->get_Domain(out);
                   }))},
              }));
            }
            CollectCookies(next_address + 1, found, result);
            return S_OK;
          })
          .Get());
}

void VkLoginWindow::Capture(const std::wstring& path,
                            std::unique_ptr<MethodResult> result) {
  ComPtr<IStream> stream;
  if (!webview_ ||
      FAILED(SHCreateStreamOnFileEx(path.c_str(),
                                    STGM_CREATE | STGM_WRITE | STGM_SHARE_DENY_WRITE,
                                    FILE_ATTRIBUTE_NORMAL, TRUE, nullptr,
                                    &stream))) {
    result->Error("capture_failed", "Could not write the picture");
    return;
  }
  std::shared_ptr<MethodResult> shared(std::move(result));
  webview_->CapturePreview(
      COREWEBVIEW2_CAPTURE_PREVIEW_IMAGE_FORMAT_PNG, stream.Get(),
      Callback<ICoreWebView2CapturePreviewCompletedHandler>(
          [shared, stream](HRESULT hr) -> HRESULT {
            stream->Commit(STGC_DEFAULT);
            shared->Success(EncodableValue(SUCCEEDED(hr)));
            return S_OK;
          })
          .Get());
}

void VkLoginWindow::FitWebView() {
  if (!controller_ || !window_) return;
  RECT bounds;
  GetClientRect(window_, &bounds);
  controller_->put_Bounds(bounds);
}

void VkLoginWindow::Close() {
  // Late WebView2 callbacks must not touch what goes away here.
  generation_++;
  if (controller_) controller_->Close();
  controller_ = nullptr;
  webview_ = nullptr;
  if (window_) {
    HWND window = window_;
    window_ = nullptr;
    DestroyWindow(window);
  }
}

// static
LRESULT CALLBACK VkLoginWindow::WndProc(HWND window, UINT message,
                                        WPARAM wparam, LPARAM lparam) noexcept {
  if (message == WM_NCCREATE) {
    const auto* create = reinterpret_cast<CREATESTRUCT*>(lparam);
    SetWindowLongPtr(window, GWLP_USERDATA,
                     reinterpret_cast<LONG_PTR>(create->lpCreateParams));
    return DefWindowProc(window, message, wparam, lparam);
  }
  auto* that =
      reinterpret_cast<VkLoginWindow*>(GetWindowLongPtr(window, GWLP_USERDATA));
  if (!that) return DefWindowProc(window, message, wparam, lparam);

  switch (message) {
    case WM_SIZE:
      that->FitWebView();
      return 0;
    case WM_SETFOCUS:
      if (that->controller_) {
        that->controller_->MoveFocus(
            COREWEBVIEW2_MOVE_FOCUS_REASON_PROGRAMMATIC);
      }
      return 0;
    case WM_DPICHANGED: {
      const auto* suggested = reinterpret_cast<RECT*>(lparam);
      SetWindowPos(window, nullptr, suggested->left, suggested->top,
                   suggested->right - suggested->left,
                   suggested->bottom - suggested->top,
                   SWP_NOZORDER | SWP_NOACTIVATE);
      return 0;
    }
    case WM_CLOSE:
      that->Close();
      return 0;
    case WM_DESTROY:
      if (that->pending_open_) {
        that->pending_open_->Error("closed", "The login window was closed");
        that->pending_open_ = nullptr;
      }
      that->channel_->InvokeMethod("closed", nullptr);
      return 0;
  }
  return DefWindowProc(window, message, wparam, lparam);
}

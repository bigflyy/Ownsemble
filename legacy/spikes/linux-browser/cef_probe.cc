// Isolated generated-only CEF comparison. No production provider/profile access.
#include <fstream>
#include <atomic>
#include <cstdio>
#include <functional>
#include <string>
#include "include/cef_app.h"
#include "include/cef_audio_handler.h"
#include "include/cef_browser.h"
#include "include/cef_client.h"
#include "include/cef_devtools_message_observer.h"
#include "include/cef_parser.h"
#include "include/cef_render_handler.h"
#include "include/cef_task.h"
#include "include/views/cef_window.h"
#include "include/views/cef_window_delegate.h"
#include "include/views/cef_browser_view.h"
#include "include/views/cef_browser_view_delegate.h"
class Task final : public CefTask {
 public:
  explicit Task(std::function<void()> fn) : fn_(std::move(fn)) {}
  void Execute() override { fn_(); }
 private:
  std::function<void()> fn_;
  IMPLEMENT_REFCOUNTING(Task);
};
void Later(std::function<void()> fn, int ms) {
  CefPostDelayedTask(TID_UI, new Task(std::move(fn)), ms);
}
class Client final : public CefClient, public CefLifeSpanHandler,
                     public CefLoadHandler, public CefRenderHandler,
                     public CefDevToolsMessageObserver, public CefAudioHandler {
 public:
  Client(std::string base, std::string output) : base_(base), output_(output) {
    checks_ = CefDictionaryValue::Create();
    checks_->SetBool("windowless", true);
  }
  void SetWindow(CefRefPtr<CefWindow> window) { window_ = window; }
  CefRefPtr<CefLifeSpanHandler> GetLifeSpanHandler() override { return this; }
  CefRefPtr<CefLoadHandler> GetLoadHandler() override { return this; }
  CefRefPtr<CefRenderHandler> GetRenderHandler() override { return this; }
  CefRefPtr<CefAudioHandler> GetAudioHandler() override { return this; }
  bool GetAudioParameters(CefRefPtr<CefBrowser>, CefAudioParameters&) override {
    capture_configured_.store(true);
    return true;  // CEF routes audio to this handler and mutes physical output.
  }
  void OnAudioStreamStarted(CefRefPtr<CefBrowser>, const CefAudioParameters&, int) override {}
  void OnAudioStreamPacket(CefRefPtr<CefBrowser>, const float**, int frames, int64_t) override {
    // Discard at the native boundary. Never copy, inspect or persist PCM content.
    captured_frames_.fetch_add(frames);
  }
  void OnAudioStreamStopped(CefRefPtr<CefBrowser>) override {}
  void OnAudioStreamError(CefRefPtr<CefBrowser>, const CefString&) override {
    Later([self = CefRefPtr<Client>(this)] { self->Close("audio_capture_failed"); }, 0);
  }
  void GetViewRect(CefRefPtr<CefBrowser>, CefRect& rect) override { rect = CefRect(0, 0, 640, 480); }
  void OnPaint(CefRefPtr<CefBrowser>, PaintElementType, const RectList&, const void*, int, int) override {}
  void OnAfterCreated(CefRefPtr<CefBrowser> browser) override {
    std::fprintf(stderr, "probe:browser_created%c", 10);
    browser_ = browser;
    checks_->SetBool("windowless", browser->GetHost()->IsWindowRenderingDisabled());
    browser->GetHost()->SetAudioMuted(true);
    checks_->SetBool("native_mute_before_load", browser->GetHost()->IsAudioMuted());
    observer_ = browser->GetHost()->AddDevToolsMessageObserver(this);
    auto params = CefDictionaryValue::Create();
    browser->GetHost()->ExecuteDevToolsMethod(1, "Page.enable", params);
    browser->GetHost()->ExecuteDevToolsMethod(2, "Network.enable", params);
    params = CefDictionaryValue::Create();
    params->SetString("source", "window.injected=true;");
    browser->GetHost()->ExecuteDevToolsMethod(3, "Page.addScriptToEvaluateOnNewDocument", params);
    Later([self = CefRefPtr<Client>(this)] { self->Close("probe_timeout"); }, 20000);
  }
  void OnDevToolsMethodResult(CefRefPtr<CefBrowser> browser, int id, bool success,
                             const void* data, size_t size) override {
    std::fprintf(stderr, "probe:devtools_result_%d%c", id, 10);
    if (!success) { Close("devtools_method_failed"); return; }
    if (id == 3) {
      browser->GetMainFrame()->LoadURL(base_ + "/page0");
    } else if (id == 4) {
      auto host = browser->GetHost();
      CefMouseEvent event; event.x = 60; event.y = 60;
      host->SendMouseMoveEvent(event, false);
      host->SendMouseClickEvent(event, MBT_LEFT, false, 1);
      host->SendMouseClickEvent(event, MBT_LEFT, true, 1);
    } else if (id == 5) {
      auto parsed = CefParseJSON(std::string(static_cast<const char*>(data), size), JSON_PARSER_RFC);
      if (!parsed || parsed->GetType() != VTYPE_DICTIONARY) { Close("invalid_result"); return; }
      auto result = parsed->GetDictionary()->GetDictionary("result");
      auto value = result ? result->GetDictionary("value") : nullptr;
      if (!value) { Close("invalid_value"); return; }
      fixture_ = value->Copy(false);
      checks_->SetBool("native_window_hidden", window_ && !window_->IsVisible());
      checks_->SetBool("native_mute_during_media", browser->GetHost()->IsAudioMuted());
      checks_->SetBool("document_start", value->GetBool("start"));
      checks_->SetBool("trusted_click", value->GetBool("click"));
      checks_->SetBool("focused_click", value->GetBool("focus"));
      checks_->SetBool("native_capture_configured", capture_configured_.load());
      checks_->SetBool("native_capture_received", captured_frames_.load() > 0);
      checks_->SetBool("native_capture_discarded", capture_configured_.load() && captured_frames_.load() > 0);
      checks_->SetBool("audio_playing_while_native_muted", value->GetBool("playing") &&
          value->GetBool("domUnmuted") && value->GetInt("audioCode") == 0 && capture_configured_.load() && captured_frames_.load() > 0);
      checks_->SetBool("media_clock_advanced", value->GetDouble("audioTime") > 0 &&
          !value->GetBool("audioPaused") && value->GetInt("audioCode") == 0);
      checks_->SetBool("cached_request_observed", observed_ >= 2);
      Close("");
    }
  }
  void OnDevToolsEvent(CefRefPtr<CefBrowser>, const CefString& method, const void* data, size_t size) override {
    if (method != "Network.requestWillBeSent") return;
    auto parsed = CefParseJSON(std::string(static_cast<const char*>(data), size), JSON_PARSER_RFC);
    if (!parsed || parsed->GetType() != VTYPE_DICTIONARY) return;
    // Project only the generated fixture URI; never retain headers or bodies.
    auto request = parsed->GetDictionary()->GetDictionary("request");
    if (request && request->GetString("url") == base_ + "/asset") ++observed_;
  }
  void OnLoadEnd(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame, int) override {
    if (!frame->IsMain() || frame->GetURL() != base_ + "/page0") return;
    Later([self = CefRefPtr<Client>(this)] {
      if (self->closing_) return;
      auto host = self->browser_->GetHost();
      auto focus = CefDictionaryValue::Create();
      focus->SetBool("enabled", true);
      host->ExecuteDevToolsMethod(4, "Emulation.setFocusEmulationEnabled", focus);

    }, 500);
    Later([self = CefRefPtr<Client>(this)] {
      if (self->closing_) return;
      auto params = CefDictionaryValue::Create();
      params->SetBool("returnByValue", true);
      params->SetString("expression", "({...fixture,audioTime:document.querySelector('audio').currentTime,audioPaused:document.querySelector('audio').paused,audioCode:document.querySelector('audio').error?.code||0,domUnmuted:!document.querySelector('audio').muted&&document.querySelector('audio').volume===1})");
      self->browser_->GetHost()->ExecuteDevToolsMethod(5, "Runtime.evaluate", params);
    }, 5000);
  }
  void Close(const std::string& category) {
    if (closing_) return;
    closing_ = true;
    category_ = category;
    browser_->GetHost()->CloseBrowser(true);
  }
  void OnBeforeClose(CefRefPtr<CefBrowser>) override {
    checks_->SetBool("closed_cleanly", category_.empty());
    auto report = CefDictionaryValue::Create();
    report->SetString("engine", "CEF");
    report->SetBool("fixture_only", true);
    report->SetString("error_category", category_);
    report->SetDictionary("checks", checks_);
    if (fixture_) report->SetDictionary("generated_fixture", fixture_);
    report->SetInt("fixture_asset_observations", observed_);
    auto value = CefValue::Create(); value->SetDictionary(report);
    std::ofstream(output_) << CefWriteJSON(value, JSON_WRITER_PRETTY_PRINT).ToString() << '\n';
    observer_ = nullptr; browser_ = nullptr;
    if (window_) { auto window = window_; window_ = nullptr; window->Close(); }
    CefQuitMessageLoop();
  }
 private:
  std::string base_, output_, category_;
  std::atomic<bool> capture_configured_{false};
  std::atomic<int64_t> captured_frames_{0};
  bool closing_ = false;
  int observed_ = 0;
  CefRefPtr<CefWindow> window_;
  CefRefPtr<CefBrowser> browser_;
  CefRefPtr<CefRegistration> observer_;
  CefRefPtr<CefDictionaryValue> checks_, fixture_;
  IMPLEMENT_REFCOUNTING(Client);
};
class App final : public CefApp, public CefBrowserProcessHandler, public CefWindowDelegate, public CefBrowserViewDelegate {
 public:
  App(std::string base, std::string output, bool native_window) : base_(base), output_(output), native_window_(native_window) {}
  CefRefPtr<CefBrowserProcessHandler> GetBrowserProcessHandler() override { return this; }
  void OnBeforeCommandLineProcessing(const CefString& process_type,
                                     CefRefPtr<CefCommandLine> command_line) override {
    if (process_type.empty()) {
      // This embedded helper owns startup; Chromium's standalone first-run
      // browser UI cannot participate in its windowless lifecycle.
      command_line->AppendSwitch("no-first-run");
    }
  }
  void OnContextInitialized() override {
    std::fprintf(stderr, "probe:context_initialized%c", 10);
    CefWindowInfo window;
    window.SetAsWindowless(0);
    window.runtime_style = CEF_RUNTIME_STYLE_ALLOY;
    CefBrowserSettings settings;
    client_ = new Client(base_, output_);
    if (native_window_) {
      view_ = CefBrowserView::CreateBrowserView(client_, "about:blank", settings, nullptr, nullptr, this);
      CefWindow::CreateTopLevelWindow(this);
      return;
    }
    if (!CefBrowserHost::CreateBrowser(window, client_, "about:blank", settings, nullptr, nullptr)) {
      CefQuitMessageLoop();
    }
  }
  void OnWindowCreated(CefRefPtr<CefWindow> window) override {
    client_->SetWindow(window);
    window->SetTitle("Ownsemble generated hidden browser");
    window->AddChildView(view_);
  }
  CefRect GetInitialBounds(CefRefPtr<CefWindow>) override { return CefRect(0, 0, 640, 480); }
  cef_runtime_style_t GetBrowserRuntimeStyle() override { return CEF_RUNTIME_STYLE_ALLOY; }
  cef_runtime_style_t GetWindowRuntimeStyle() override { return CEF_RUNTIME_STYLE_ALLOY; }
 private:
  bool native_window_;
  CefRefPtr<CefBrowserView> view_;
  std::string base_, output_;
  CefRefPtr<Client> client_;
  IMPLEMENT_REFCOUNTING(App);
};
int main(int argc, char** argv) {
  CefMainArgs args(argc, argv);
  CefRefPtr<App> app = new App(argc >= 6 ? argv[1] : "", argc >= 6 ? argv[2] : "", argc == 7);
  int child = CefExecuteProcess(args, app, nullptr);
  if (child >= 0) return child;
  if (argc < 6 || std::string(argv[1]).rfind("http://127.0.0.1:", 0) != 0) return 2;
  CefSettings settings;
  settings.windowless_rendering_enabled = true;
  settings.no_sandbox = false;
  CefString(&settings.resources_dir_path) = argv[3];
  CefString(&settings.locales_dir_path) = std::string(argv[3]) + "/locales";
  CefString(&settings.root_cache_path) = argv[4];
  CefString(&settings.cache_path) = std::string(argv[4]) + "/session";
  CefString(&settings.log_file) = argv[5];
  std::fprintf(stderr, "probe:initializing%c", 10);
  if (!CefInitialize(args, settings, app, nullptr)) return 3;
  std::fprintf(stderr, "probe:initialized%c", 10);
  CefRunMessageLoop();
  CefShutdown();
  app = nullptr;
  return 0;
}

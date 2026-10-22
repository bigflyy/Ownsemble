// Dedicated native browser process. JSON stays on inherited pipes; no listening
// socket, cookie export, console forwarding or private diagnostic files exist.
#include <sys/prctl.h>
#include <sys/stat.h>
#include <csignal>
#include <cmath>
#include <algorithm>
#include <vector>
#include <unistd.h>
#include <atomic>
#include <cstdlib>
#include <chrono>
#include <condition_variable>
#include <filesystem>
#include <functional>
#include <iostream>
#include <map>
#include <memory>
#include <mutex>
#include <thread>
#include "include/cef_app.h"
#include "linux_process_security.h"
#include "include/cef_audio_handler.h"
#include "include/cef_client.h"
#include "include/cef_devtools_message_observer.h"
#include "include/cef_parser.h"
#include "include/cef_permission_handler.h"
#include "include/cef_request_handler.h"
#include "include/cef_task.h"
#include "include/views/cef_browser_view.h"
#include "include/views/cef_browser_view_delegate.h"
#include "include/views/cef_window.h"
#include "include/views/cef_window_delegate.h"

using Dictionary = CefRefPtr<CefDictionaryValue>;
using Value = CefRefPtr<CefValue>;
class BrowserClient;
std::map<int, CefRefPtr<BrowserClient>> documents;
bool shutting_down = false;
std::mutex output_mutex;
class Task final : public CefTask {
 public:
  explicit Task(std::function<void()> fn) : fn_(std::move(fn)) {}
  void Execute() override { fn_(); }
 private:
  std::function<void()> fn_;
  IMPLEMENT_REFCOUNTING(Task);
};
void Post(std::function<void()> fn, int delay = 0) {
  CefPostDelayedTask(TID_UI, new Task(std::move(fn)), delay);
}
void Emit(Dictionary message) {
  auto value = CefValue::Create(); value->SetDictionary(message);
  const auto line = CefWriteJSON(value, JSON_WRITER_DEFAULT).ToString();
  std::lock_guard<std::mutex> lock(output_mutex);
  std::cout << line << std::endl;
}
void Reply(int id, Value value = nullptr, const std::string& error = "") {
  if (!id) return;
  auto result = CefDictionaryValue::Create();
  result->SetInt("id", id); result->SetBool("ok", error.empty());
  if (!error.empty()) result->SetString("error", error);
  else if (value) result->SetValue("value", value);
  else result->SetNull("value");
  Emit(result);
}
Value Bool(bool value) { auto result = CefValue::Create(); result->SetBool(value); return result; }
Value Text(const std::string& value) { auto result = CefValue::Create(); result->SetString(value); return result; }
Value Object(Dictionary value) { auto result = CefValue::Create(); result->SetDictionary(value); return result; }
Dictionary Event(const std::string& name, int browser, const std::string& uri = "") {
  auto event = CefDictionaryValue::Create(); event->SetString("event", name);
  event->SetInt("browser", browser);
  if (!uri.empty()) event->SetString("uri", uri);
  return event;
}
struct Decision { std::condition_variable ready; bool answered = false, allow = false; };
std::mutex decision_mutex;
std::map<int, std::shared_ptr<Decision>> decisions;
std::atomic<int> next_decision{0};
bool AllowNavigation(int browser, const std::string& uri) {
  if (uri == "about:blank") return true;
  const int token = ++next_decision;
  auto decision = std::make_shared<Decision>();
  { std::lock_guard<std::mutex> lock(decision_mutex); decisions[token] = decision; }
  auto event = Event("navigation", browser, uri); event->SetInt("token", token); Emit(event);
  // Only the helper's browser thread waits. The pipe thread answers directly,
  // without posting back to that thread. A stalled/dead app always denies.
  std::unique_lock<std::mutex> lock(decision_mutex);
  decision->ready.wait_for(lock, std::chrono::seconds(2), [&] { return decision->answered; });
  decisions.erase(token);
  return decision->answered && decision->allow;
}
void RemoveDocument(int id);
void Diag(const std::string& category) { if (std::getenv("OWNSEMBLE_NATIVE_DIAGNOSTICS")) std::cerr << "ownsemble_browser:" << category << std::endl; }

class BrowserClient final : public CefClient, public CefLifeSpanHandler,
    public CefLoadHandler, public CefRequestHandler, public CefPermissionHandler,
    public CefAudioHandler, public CefDevToolsMessageObserver {
 public:
  BrowserClient(int id, int creating) : id_(id), creating_(creating) {}
  void SetWindow(CefRefPtr<CefWindow> window) { window_ = window; }
  CefRefPtr<CefLifeSpanHandler> GetLifeSpanHandler() override { return this; }
  CefRefPtr<CefLoadHandler> GetLoadHandler() override { return this; }
  CefRefPtr<CefRequestHandler> GetRequestHandler() override { return this; }
  CefRefPtr<CefPermissionHandler> GetPermissionHandler() override { return this; }
  CefRefPtr<CefAudioHandler> GetAudioHandler() override { return this; }
  bool GetAudioParameters(CefRefPtr<CefBrowser>, CefAudioParameters&) override { return true; }
  void OnAudioStreamStarted(CefRefPtr<CefBrowser>, const CefAudioParameters&, int) override {}
  void OnAudioStreamPacket(CefRefPtr<CefBrowser>, const float**, int, int64_t) override {
    // Unconditionally discard. Never inspect, copy or persist PCM content.
  }
  void OnAudioStreamStopped(CefRefPtr<CefBrowser>) override {}
  void OnAudioStreamError(CefRefPtr<CefBrowser>, const CefString&) override {
    capture_failed_.store(true);
    Post([self = CefRefPtr<BrowserClient>(this)] { self->Close(0); });
  }
  bool OnBeforeBrowse(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame>, CefRefPtr<CefRequest> request,
                      bool, bool) override {
    return closing_ || !AllowNavigation(id_, request->GetURL().ToString());
  }
  bool OnCertificateError(CefRefPtr<CefBrowser>, cef_errorcode_t, const CefString&,
                          CefRefPtr<CefSSLInfo>, CefRefPtr<CefCallback>) override { return false; }
  bool OnShowPermissionPrompt(CefRefPtr<CefBrowser>, uint64_t, const CefString&, uint32_t,
                              CefRefPtr<CefPermissionPromptCallback> callback) override {
    callback->Continue(CEF_PERMISSION_RESULT_DENY); return true;
  }
  bool OnBeforePopup(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame>, int, const CefString& target,
                     const CefString&, cef_window_open_disposition_t, bool, const CefPopupFeatures&,
                     CefWindowInfo&, CefRefPtr<CefClient>&, CefBrowserSettings&,
                     CefRefPtr<CefDictionaryValue>&, bool*) override {
    return !allow_popups_ || !AllowNavigation(id_, target.empty() ? "about:blank" : target.ToString());
  }
  void OnAfterCreated(CefRefPtr<CefBrowser> browser) override {
    browser->GetHost()->SetAudioMuted(true);
    if (browser->IsPopup()) { popups_.push_back(browser); return; }
    browser_ = browser; Diag("created");
    if (closing_) { browser->GetHost()->CloseBrowser(true); return; }
    observer_ = browser->GetHost()->AddDevToolsMessageObserver(this);
    Cdp("Page.enable", nullptr, [self = CefRefPtr<BrowserClient>(this)](bool ok, Dictionary) {
      if (!ok) { self->FailCreate("browser_capability_missing"); return; }
      self->Cdp("Network.enable", nullptr, [self](bool ready, Dictionary) {
        if (!ready) { self->FailCreate("browser_capability_missing"); return; }
        self->prepared_ = true; self->Ready();
      });
    });
    Post([self = CefRefPtr<BrowserClient>(this)] {
      if (self->creating_) { Diag("create_timeout_prepared_" + std::to_string(self->prepared_) + "_sandbox_" + std::to_string(self->sandboxed_)); self->FailCreate("browser_native_timeout"); }
    }, 15000);
  }
  bool OnProcessMessageReceived(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame>,
                                CefProcessId source, CefRefPtr<CefProcessMessage> message) override {
    if (source != PID_RENDERER || message->GetName() != "ownsemble.sandbox") return false;
    const bool protected_renderer = RendererHasSeccomp(getpid(), message->GetArgumentList()->GetInt(0));
    Diag("sandbox_attested_" + std::to_string(protected_renderer));
    if (!protected_renderer) {
      FailCreate("browser_sandbox_unavailable"); Close(0); return true;
    }
    if (browser_ && browser->IsSame(browser_)) { sandboxed_ = true; Ready(); }
    return true;
  }
  bool Isolated() const { return sandboxed_ && prepared_ && !capture_failed_.load() && !closing_; }
  void Ready() {
    if (!creating_ || !Isolated()) return;
    auto result = CefDictionaryValue::Create(); result->SetBool("audio_isolated", true);
    result->SetBool("sandboxed", true); Reply(creating_, Object(result)); creating_ = 0;
  }
  void FailCreate(const std::string& category) {
    Reply(creating_, nullptr, category); creating_ = 0; Close(0);
  }
  void OnLoadStart(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame, TransitionType) override {
    if (!closing_ && !browser->IsPopup() && frame->IsMain()) Emit(Event("started", id_, frame->GetURL().ToString()));
  }
  void OnLoadEnd(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame, int) override {
    if (!closing_ && !browser->IsPopup() && frame->IsMain()) Emit(Event("loaded", id_, frame->GetURL().ToString()));
  }
  void OnLoadError(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame, ErrorCode code,
                   const CefString&, const CefString&) override {
    if (!closing_ && !browser->IsPopup() && frame->IsMain() && code != ERR_ABORTED) Emit(Event("error", id_));
  }
  void OnRenderProcessTerminated(CefRefPtr<CefBrowser>, TerminationStatus, int, const CefString&) override {
    Emit(Event("error", id_)); Close(0);
  }
  using Completion = std::function<void(bool, Dictionary)>;
  void Cdp(const std::string& method, Dictionary arguments, Completion completed) {
    if (closing_ || !browser_) { completed(false, nullptr); return; }
    const int id = ++next_cdp_;
    pending_[id] = std::move(completed);
    const int actual = browser_->GetHost()->ExecuteDevToolsMethod(id, method, arguments);
    if (actual != id) {
      auto callback = std::move(pending_[id]); pending_.erase(id);
      if (actual > 0) { next_cdp_ = actual; pending_[actual] = std::move(callback); }
      else callback(false, nullptr);
    }
  }
  void OnDevToolsMethodResult(CefRefPtr<CefBrowser>, int id, bool ok, const void* data, size_t size) override {
    Diag("cdp_" + std::to_string(id) + "_ok_" + std::to_string(ok));
    auto found = pending_.find(id); if (found == pending_.end()) return;
    auto callback = std::move(found->second); pending_.erase(found);
    auto value = size ? CefParseJSON(std::string(static_cast<const char*>(data), size), JSON_PARSER_RFC) : nullptr;
    callback(ok, value && value->GetType() == VTYPE_DICTIONARY ? value->GetDictionary() : nullptr);
  }
  void OnDevToolsEvent(CefRefPtr<CefBrowser>, const CefString& method, const void* data, size_t size) override {
    if (closing_ || size > 4 * 1024 * 1024) return;
    if (method != "Network.requestWillBeSent" && method != "Page.navigatedWithinDocument") return;
    auto parsed = CefParseJSON(std::string(static_cast<const char*>(data), size), JSON_PARSER_RFC);
    if (!parsed || parsed->GetType() != VTYPE_DICTIONARY) return;
    auto details = parsed->GetDictionary();
    if (method == "Page.navigatedWithinDocument") { Emit(Event("history", id_, details->GetString("url").ToString())); return; }
    auto request = details->GetDictionary("request"); if (!request) return;
    // Only URI and a bounded kind cross to shared policy. Discard raw headers,
    // bodies, cookies and authentication responses at this native boundary.
    auto event = Event("request", id_, request->GetString("url").ToString());
    const auto kind = details->GetString("type").ToString();
    event->SetString("kind", kind == "Media" || kind == "Fetch" || kind == "XHR" ? kind : "Other"); Emit(event);
  }
  void Command(int request, const std::string& method, Dictionary args) {
    if (method == "close") { Close(request); return; }
    if (closing_ || !browser_ || !Isolated()) { Reply(request, nullptr, "cancelled"); return; }
    auto host = browser_->GetHost();
    if (method == "isolation") Reply(request, Bool(Isolated()));
    else if (method == "url") Reply(request, Text(browser_->GetMainFrame()->GetURL().ToString()));
    else if (method == "navigate") { browser_->GetMainFrame()->LoadURL(args->GetString("uri")); Reply(request); }
    else if (method == "reload") { browser_->Reload(); Reply(request); }
    else if (method == "isHidden") Reply(request, Bool(!window_ || !window_->IsVisible()));
    else if (method == "show") { allow_popups_ = true; window_->Show(); Reply(request); }
    else if (method == "hide" || method == "finishSignIn") {
      allow_popups_ = false; if (window_) window_->Hide();
      const auto popups = popups_;
      for (const auto& popup : popups) popup->GetHost()->CloseBrowser(true);
      Reply(request);
    } else if (method == "activate") {
      auto parameters = CefDictionaryValue::Create(); parameters->SetBool("enabled", true);
      Cdp("Emulation.setFocusEmulationEnabled", parameters, [request](bool ok, Dictionary) {
        Reply(request, nullptr, ok ? "" : "browser_capability_missing");
      });
    } else if (method == "script") {
      auto parameters = CefDictionaryValue::Create(); parameters->SetString("source", args->GetString("source"));
      Cdp("Page.addScriptToEvaluateOnNewDocument", parameters, [request](bool ok, Dictionary) {
        Reply(request, nullptr, ok ? "" : "music_script_failed");
      });
    } else if (method == "evaluate") {
      auto parameters = CefDictionaryValue::Create();
      parameters->SetString("expression", "(async()=>(" + args->GetString("expression").ToString() + "))()");
      parameters->SetBool("awaitPromise", true); parameters->SetBool("returnByValue", true);
      Cdp("Runtime.evaluate", parameters, [request](bool ok, Dictionary result) {
        if (!ok || !result || result->HasKey("exceptionDetails")) { Reply(request, nullptr, "music_script_failed"); return; }
        auto remote = result->GetDictionary("result");
        const auto value = remote ? remote->GetValue("value") : nullptr;
        if (value && CefWriteJSON(value, JSON_WRITER_DEFAULT).length() > 4 * 1024 * 1024) {
          Reply(request, nullptr, "music_script_failed"); return;
        }
        Reply(request, value);
      });
    } else if (method == "pointer") {
      auto number = [&](const char* key) { return args->GetType(key) == VTYPE_INT ? static_cast<double>(args->GetInt(key)) : args->GetDouble(key); };
      const double x = number("x"), y = number("y");
      if (!std::isfinite(x) || !std::isfinite(y) || x < 0 || y < 0 || x > 1200 || y > 900) {
        Reply(request, nullptr, "browser_native_failed"); return;
      }
      CefMouseEvent event; event.x = static_cast<int>(x); event.y = static_cast<int>(y);
      const auto phase = args->GetString("phase").ToString();
      if (phase == "move") host->SendMouseMoveEvent(event, false);
      else if (phase == "down" || phase == "up") host->SendMouseClickEvent(event, MBT_LEFT, phase == "up", 1);
      else { Reply(request, nullptr, "browser_native_failed"); return; }
      Reply(request);
    } else Reply(request, nullptr, "browser_native_failed");
  }
  void Close(int request) {
    if (request) closing_requests_.push_back(request);
    if (closing_) return;
    closing_ = true; allow_popups_ = false;
    Reply(creating_, nullptr, "cancelled"); creating_ = 0;
    auto pending = std::move(pending_); pending_.clear();
    for (auto& [id, callback] : pending) callback(false, nullptr);
    const auto popups = popups_;
    for (const auto& popup : popups) popup->GetHost()->CloseBrowser(true);
    if (browser_) browser_->GetHost()->CloseBrowser(true);
  }
  void OnBeforeClose(CefRefPtr<CefBrowser> browser) override {
    if (browser->IsPopup()) {
      popups_.erase(std::remove_if(popups_.begin(), popups_.end(), [&](const auto& popup) {
        return popup->IsSame(browser);
      }), popups_.end());
      return;
    }
    closing_ = true;
    auto pending = std::move(pending_); pending_.clear();
    for (auto& [id, callback] : pending) callback(false, nullptr);
    Reply(creating_, nullptr, "cancelled"); creating_ = 0;
    for (int request : closing_requests_) Reply(request);
    closing_requests_.clear();
    observer_ = nullptr; browser_ = nullptr;
    if (window_) { auto window = window_; window_ = nullptr; window->Close(); }
    Emit(Event("closed", id_)); RemoveDocument(id_);
  }
 private:
  int id_, creating_, next_cdp_ = 0;
  bool closing_ = false, prepared_ = false, sandboxed_ = false, allow_popups_ = false;
  std::atomic<bool> capture_failed_{false};
  CefRefPtr<CefBrowser> browser_;
  CefRefPtr<CefWindow> window_;
  CefRefPtr<CefRegistration> observer_;
  std::vector<CefRefPtr<CefBrowser>> popups_;
  std::vector<int> closing_requests_;
  std::map<int, Completion> pending_;
  IMPLEMENT_REFCOUNTING(BrowserClient);
};

class WindowHost final : public CefWindowDelegate, public CefBrowserViewDelegate {
 public:
  explicit WindowHost(CefRefPtr<BrowserClient> client) : client_(client) {}
  void Create() {
    CefBrowserSettings settings;
    view_ = CefBrowserView::CreateBrowserView(client_, "about:blank", settings, nullptr, nullptr, this);
    CefWindow::CreateTopLevelWindow(this);
  }
  void OnWindowCreated(CefRefPtr<CefWindow> window) override {
    client_->SetWindow(window); window->SetTitle("Ownsemble private browser");
    window->AddChildView(view_); view_ = nullptr;
    // Intentionally do not Show/Activate. Only explicit private sign-in shows it.
  }
  CefRect GetInitialBounds(CefRefPtr<CefWindow>) override { return CefRect(0, 0, 1200, 900); }
  cef_runtime_style_t GetBrowserRuntimeStyle() override { return CEF_RUNTIME_STYLE_ALLOY; }
  cef_runtime_style_t GetWindowRuntimeStyle() override { return CEF_RUNTIME_STYLE_ALLOY; }
 private:
  CefRefPtr<BrowserClient> client_;
  CefRefPtr<CefBrowserView> view_;
  IMPLEMENT_REFCOUNTING(WindowHost);
};
void RemoveDocument(int id) {
  documents.erase(id);
  if (shutting_down && documents.empty()) Post([] { CefQuitMessageLoop(); }, 100);
}
void Shutdown() {
  if (shutting_down) return;
  shutting_down = true;
  const auto active = documents;
  for (const auto& [id, client] : active) client->Close(0);
  if (documents.empty()) Post([] { CefQuitMessageLoop(); }, 100);
}
bool credentials_disabled = false;
void Handle(Dictionary message) {
  const int request = message->GetInt("id");
  const auto method = message->GetString("method").ToString();
  if (method == "hello") {
    if (!credentials_disabled) { Reply(request, nullptr, "browser_capability_missing"); return; }
    auto hello = CefDictionaryValue::Create(); hello->SetInt("protocol", 1);
    hello->SetBool("audio_capture_required", true); hello->SetBool("sandbox_requested", true);
    Reply(request, Object(hello));
  } else if (method == "shutdown") { Reply(request); Shutdown(); }
  else if (shutting_down) Reply(request, nullptr, "browser_closed");
  else {
    const int id = message->GetInt("browser");
    if (method == "create") {
      if (id <= 0 || documents.count(id)) { Reply(request, nullptr, "browser_native_failed"); return; }
      auto client = CefRefPtr<BrowserClient>(new BrowserClient(id, request)); documents[id] = client;
      auto window = CefRefPtr<WindowHost>(new WindowHost(client)); window->Create();
    } else {
      auto found = documents.find(id);
      if (found == documents.end()) Reply(request, nullptr, method == "close" ? "" : "cancelled");
      else found->second->Command(request, method, message);
    }
  }
}
void ReadInput() {
  std::string line;
  while (std::getline(std::cin, line)) {
    if (line.size() > 4 * 1024 * 1024) break;
    auto value = CefParseJSON(line, JSON_PARSER_RFC);
    if (!value || value->GetType() != VTYPE_DICTIONARY) break;
    auto message = value->GetDictionary();
    if (message->HasKey("decision")) {
      std::lock_guard<std::mutex> lock(decision_mutex);
      auto found = decisions.find(message->GetInt("decision"));
      if (found != decisions.end()) {
        found->second->allow = message->GetBool("allow");
        found->second->answered = true; found->second->ready.notify_all();
      }
    } else Post([message] { Handle(message); });
  }
  Post([] { Shutdown(); });
}

class App final : public CefApp, public CefBrowserProcessHandler, public CefRenderProcessHandler {
 public:
  CefRefPtr<CefBrowserProcessHandler> GetBrowserProcessHandler() override { return this; }
  CefRefPtr<CefRenderProcessHandler> GetRenderProcessHandler() override { return this; }
  void OnBeforeCommandLineProcessing(const CefString& type, CefRefPtr<CefCommandLine> command) override {
    if (!type.empty()) return;
    command->AppendSwitch("no-first-run");
    command->AppendSwitch("no-default-browser-check");
    command->AppendSwitch("disable-background-networking");
    command->AppendSwitch("disable-component-update");
  }
  void OnContextInitialized() override {
    auto context = CefRequestContext::GetGlobalContext();
    auto disabled = Bool(false); CefString error;
    const bool service = context->SetPreference("credentials_enable_service", disabled, error);
    const bool passwords = context->SetPreference("credentials_enable_autosignin", disabled, error);
    credentials_disabled = service && passwords;
    if (!credentials_disabled) std::cerr << "ownsemble_browser:credentials_policy_unavailable service=" << service << " passwords=" << passwords << std::endl;
    std::thread(ReadInput).detach();
  }
  void OnContextCreated(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame> frame, CefRefPtr<CefV8Context>) override {
    if (!frame->IsMain()) return;
    Diag("renderer_context");
    auto message = CefProcessMessage::Create("ownsemble.sandbox");
    message->GetArgumentList()->SetInt(0, getpid());
    frame->SendProcessMessage(PID_BROWSER, message);
  }
 private:
  IMPLEMENT_REFCOUNTING(App);
};
int main(int argc, char** argv) {
  // The helper is always a child of the app. No inherited debugging endpoint.
  prctl(PR_SET_PDEATHSIG, SIGTERM);
  CefMainArgs arguments(argc, argv); CefRefPtr<App> app = new App();
  const int child = CefExecuteProcess(arguments, app, nullptr);
  if (child >= 0) return child;
  std::string profile;
  for (int i = 1; i < argc; ++i) {
    const std::string value = argv[i];
    if (value.rfind("--profile-path=", 0) == 0) profile = value.substr(15);
  }
  if (profile.empty() || !std::filesystem::path(profile).is_absolute()) return 2;
  umask(0077);
  std::filesystem::create_directories(profile);
  const auto directory = std::filesystem::canonical("/proc/self/exe").parent_path().string();
  CefSettings settings;
  settings.no_sandbox = false; settings.command_line_args_disabled = true;
  settings.log_severity = LOGSEVERITY_DISABLE;
  CefString(&settings.log_file) = "/dev/null";
  CefString(&settings.resources_dir_path) = directory;
  CefString(&settings.locales_dir_path) = directory + "/locales";
  CefString(&settings.root_cache_path) = profile;
  CefString(&settings.cache_path) = profile + "/session";
  if (!CefInitialize(arguments, settings, app, nullptr)) return 3;
  CefRunMessageLoop(); CefShutdown(); app = nullptr;
  return 0;
}

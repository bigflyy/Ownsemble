# Ownsemble uses ordinary hidden WebView2 windows, never texture capture.
# The pinned plugin eagerly creates an unused WinRT compositor/dispatcher. Its
# teardown faults in CoreMessaging on this machine, including audio-only runs.
# Replace only that constructor setup in this application's compilation. The
# package cache and both feasibility reference builds remain unchanged.
function(ownsemble_write_generated ownsemble_path ownsemble_contents)
  if(EXISTS "${ownsemble_path}")
    file(READ "${ownsemble_path}" ownsemble_previous)
    if("${ownsemble_previous}" STREQUAL "${ownsemble_contents}")
      return()
    endif()
  endif()
  file(WRITE "${ownsemble_path}" "${ownsemble_contents}")
endfunction()
set(ownsemble_webview_root
  "${CMAKE_CURRENT_SOURCE_DIR}/flutter/ephemeral/.plugin_symlinks/flutter_inappwebview_windows/windows")
set(ownsemble_manager "${ownsemble_webview_root}/in_app_webview/in_app_webview_manager.cpp")
file(SHA256 "${ownsemble_manager}" ownsemble_manager_sha)
if(NOT ownsemble_manager_sha STREQUAL "eefc7b984c208696b3a3a34f99b0ddc11779fb7470009ebbabcfd274421d77ab")
  message(FATAL_ERROR "Review the Ownsemble windowed WebView patch for this plugin version.")
endif()
file(READ "${ownsemble_manager}" ownsemble_manager_source)
string(FIND "${ownsemble_manager_source}" "    if (!rohelper_) {" ownsemble_setup_start)
string(FIND "${ownsemble_manager_source}" "    windowClass_.lpszClassName =" ownsemble_setup_end)
if(ownsemble_setup_start LESS 0 OR ownsemble_setup_end LESS ownsemble_setup_start)
  message(FATAL_ERROR "The pinned WebView constructor no longer matches.")
endif()
string(SUBSTRING "${ownsemble_manager_source}" 0 ${ownsemble_setup_start} ownsemble_prefix)
string(SUBSTRING "${ownsemble_manager_source}" ${ownsemble_setup_end} -1 ownsemble_suffix)
set(ownsemble_windowed_manager "${CMAKE_CURRENT_BINARY_DIR}/ownsemble_webview_manager.cpp")
ownsemble_write_generated("${ownsemble_windowed_manager}"
  "${ownsemble_prefix}    // Ownsemble windowed mode: no texture capture or WinRT compositor.\n${ownsemble_suffix}")
get_target_property(ownsemble_webview_sources flutter_inappwebview_windows_plugin SOURCES)
list(FILTER ownsemble_webview_sources EXCLUDE REGEX "(^|/)in_app_webview_manager[.]cpp$")
set_property(TARGET flutter_inappwebview_windows_plugin PROPERTY SOURCES "${ownsemble_webview_sources}")
target_sources(flutter_inappwebview_windows_plugin PRIVATE "${ownsemble_windowed_manager}")
target_include_directories(flutter_inappwebview_windows_plugin PRIVATE
  "${ownsemble_webview_root}/in_app_webview")

# Browser sound must never compete with the native music player. DOM audio
# muting misses detached Audio objects and WebAudio. Mute the WebView itself
# before its first navigation, including child windows, and expose only a
# read-only boolean for the app's preflight and generated regression fixture.
set(ownsemble_view "${ownsemble_webview_root}/in_app_webview/in_app_webview.cpp")
file(SHA256 "${ownsemble_view}" ownsemble_view_sha)
if(NOT ownsemble_view_sha STREQUAL "4cb00551207fc4f3b5f9642c2c6a79c50f89c86b2c859129c99c12d524ddeb18")
  message(FATAL_ERROR "Review the Ownsemble native browser mute patch for this plugin version.")
endif()
file(READ "${ownsemble_view}" ownsemble_view_source)
string(REPLACE "    prepare(params);"
  "    wil::com_ptr<ICoreWebView2_8> audioView;\n    if (SUCCEEDED(webView->QueryInterface(IID_PPV_ARGS(&audioView)))) {\n      audioView->put_IsMuted(TRUE);\n    }\n\n    prepare(params);"
  ownsemble_view_source "${ownsemble_view_source}")
# The exact spelling is guarded separately, so a package upgrade cannot quietly
# omit the fail-closed mute preflight.
string(FIND "${ownsemble_view_source}" "void InAppWebView::callDevToolsProtocolMethod(" ownsemble_protocol_start)
if(ownsemble_protocol_start LESS 0)
  message(FATAL_ERROR "The pinned WebView protocol wrapper no longer matches.")
endif()
string(SUBSTRING "${ownsemble_view_source}" ${ownsemble_protocol_start} -1 ownsemble_protocol_tail)
string(FIND "${ownsemble_protocol_tail}" "{" ownsemble_protocol_brace)
math(EXPR ownsemble_protocol_insert "${ownsemble_protocol_start}+${ownsemble_protocol_brace}+1")
string(SUBSTRING "${ownsemble_view_source}" 0 ${ownsemble_protocol_insert} ownsemble_view_prefix)
string(SUBSTRING "${ownsemble_view_source}" ${ownsemble_protocol_insert} -1 ownsemble_view_suffix)
set(ownsemble_muted_probe [=[
    if (methodName == "Ownsemble.getAudioMuted" && webView) {
      wil::com_ptr<ICoreWebView2_8> audioView;
      BOOL muted = FALSE;
      HRESULT result = webView->QueryInterface(IID_PPV_ARGS(&audioView));
      if (SUCCEEDED(result)) result = audioView->get_IsMuted(&muted);
      completionHandler(result, SUCCEEDED(result)
        ? std::optional<std::string>(muted ? "{\"muted\":true}" : "{\"muted\":false}")
        : std::nullopt);
      return;
    }
]=])
set(ownsemble_muted_view "${CMAKE_CURRENT_BINARY_DIR}/ownsemble_webview.cpp")
ownsemble_write_generated("${ownsemble_muted_view}"
  "${ownsemble_view_prefix}\n${ownsemble_muted_probe}${ownsemble_view_suffix}")
get_target_property(ownsemble_webview_sources flutter_inappwebview_windows_plugin SOURCES)
list(FILTER ownsemble_webview_sources EXCLUDE REGEX "(^|/)in_app_webview[.]cpp$")
set_property(TARGET flutter_inappwebview_windows_plugin PROPERTY SOURCES "${ownsemble_webview_sources}")
target_sources(flutter_inappwebview_windows_plugin PRIVATE "${ownsemble_muted_view}")

# The pinned Windows delegate implements hide/show but omits isHidden even
# though its Dart API invokes it. Query the actual app-owned HWND; a missing
# method must not masquerade as a visible VK page or abort browser acceptance.
set(ownsemble_delegate "${ownsemble_webview_root}/in_app_webview/webview_channel_delegate.cpp")
file(SHA256 "${ownsemble_delegate}" ownsemble_delegate_sha)
if(NOT ownsemble_delegate_sha STREQUAL "e3a491fea03e5be934c6aec29c6e176f581250f9814eb179f8e0421c37bdbf3e")
  message(FATAL_ERROR "Review the Ownsemble browser visibility patch for this plugin version.")
endif()
file(READ "${ownsemble_delegate}" ownsemble_delegate_source)
string(REPLACE "    // for inAppBrowser"
  "    else if (webView->inAppBrowser && string_equals(methodName, \"isHidden\")) {\n      result->Success(webView->inAppBrowser->isHidden());\n    }\n    // for inAppBrowser"
  ownsemble_delegate_source "${ownsemble_delegate_source}")
set(ownsemble_windowed_delegate "${CMAKE_CURRENT_BINARY_DIR}/ownsemble_webview_delegate.cpp")
ownsemble_write_generated("${ownsemble_windowed_delegate}" "${ownsemble_delegate_source}")
get_target_property(ownsemble_webview_sources flutter_inappwebview_windows_plugin SOURCES)
list(FILTER ownsemble_webview_sources EXCLUDE REGEX "(^|/)webview_channel_delegate[.]cpp$")
set_property(TARGET flutter_inappwebview_windows_plugin PROPERTY SOURCES "${ownsemble_webview_sources}")
target_sources(flutter_inappwebview_windows_plugin PRIVATE "${ownsemble_windowed_delegate}")

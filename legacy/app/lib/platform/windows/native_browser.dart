import 'package:flutter_inappwebview/flutter_inappwebview.dart';

// Windows' standard WebView2 window avoids the inline texture/capture dependency.
class VkBrowser extends InAppBrowser {
  bool allowAuthPopups = false;
  final void Function()? exited;
  final void Function(InAppWebViewController) created;
  final void Function(WebUri?) started, loaded, historyChanged;
  final Future<WebResourceResponse?> Function(WebResourceRequest) intercept;
  final Future<NavigationActionPolicy> Function(NavigationAction) navigate;
  final List<InAppBrowser> popups = [];
  final WebViewEnvironment? environment;
  final void Function(WebResourceError) errored;
  VkBrowser({
    this.exited,
    required this.created,
    required this.started,
    required this.loaded,
    required this.historyChanged,
    required this.intercept,
    required this.navigate,
    required this.errored,
    this.environment,
  }) : super(webViewEnvironment: environment);
  Future<void> finishPrivateSignIn() async {
    allowAuthPopups = false;
    for (final popup in popups) {
      await popup.close();
    }
    popups.clear();
    await hide();
  }

  @override
  void onExit() => exited?.call();
  @override
  void onBrowserCreated() => created(webViewController!);
  @override
  void onReceivedError(WebResourceRequest request, WebResourceError error) =>
      request.isForMainFrame == true ? errored(error) : null;
  @override
  void onLoadStart(WebUri? url) => started(url);
  @override
  void onLoadStop(WebUri? url) => loaded(url);
  @override
  void onUpdateVisitedHistory(WebUri? url, bool? isReload) =>
      historyChanged(url);
  @override
  Future<WebResourceResponse?> shouldInterceptRequest(
    WebResourceRequest request,
  ) => intercept(request);
  @override
  Future<NavigationActionPolicy> shouldOverrideUrlLoading(
    NavigationAction navigationAction,
  ) => navigate(navigationAction);
  @override
  Future<PermissionResponse?> onPermissionRequest(
    PermissionRequest permissionRequest,
  ) async => PermissionResponse(
    resources: permissionRequest.resources,
    action: PermissionResponseAction.DENY,
  );
  @override
  Future<bool> onCreateWindow(CreateWindowAction createWindowAction) async {
    if (!allowAuthPopups) return false;
    final popup = InAppBrowser(
      windowId: createWindowAction.windowId,
      webViewEnvironment: environment,
    );
    popups.add(popup);
    await popup.openUrlRequest(
      urlRequest: URLRequest(url: WebUri('about:blank')),
    );
    return true;
  }
}

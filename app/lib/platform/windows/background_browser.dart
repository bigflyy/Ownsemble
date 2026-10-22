import 'package:flutter_inappwebview/flutter_inappwebview.dart';

InAppBrowserClassSettings backgroundMusicBrowserSettings() =>
    InAppBrowserClassSettings(
      browserSettings: InAppBrowserSettings(
        hidden: true,
        windowFrame: InAppWebViewRect(x: 0, y: 0, width: 1200, height: 900),
      ),
      webViewSettings: InAppWebViewSettings(
        javaScriptEnabled: true,
        useShouldInterceptRequest: true,
        useShouldOverrideUrlLoading: false,
        mediaPlaybackRequiresUserGesture: false,
        supportMultipleWindows: true,
        javaScriptCanOpenWindowsAutomatically: false,
      ),
    );

/// Dispatch trusted renderer input without activating an OS/browser window.
Future<void> dispatchBackgroundMusicTap({
  required double x,
  required double y,
  required Future<void> Function() guard,
  required Future<void> Function(Map<String, dynamic>) dispatch,
  Future<({double x, double y})> Function()? refreshAfterHover,
}) async {
  var targetX = x, targetY = y;
  for (final type in ['mouseMoved', 'mousePressed', 'mouseReleased']) {
    await guard();
    await dispatch({
      'type': type,
      'x': targetX,
      'y': targetY,
      'button': type == 'mouseMoved' ? 'none' : 'left',
      'buttons': type == 'mousePressed' ? 1 : 0,
      'pointerType': 'mouse',
      'clickCount': type == 'mouseMoved' ? 0 : 1,
    });
    if (type == 'mouseMoved') {
      await Future<void>.delayed(const Duration(milliseconds: 150));
      if (refreshAfterHover != null) {
        final point = await refreshAfterHover();
        targetX = point.x;
        targetY = point.y;
      }
    }
  }
}

/// Keep the document active without showing/focusing its native OS window.
/// Call only after the resolver has confirmed the selected music page.
Future<void> activateBackgroundMusicPage(InAppWebViewController view) async {
  await view
      .callDevToolsProtocolMethod(
        methodName: 'Emulation.setFocusEmulationEnabled',
        parameters: {'enabled': true},
      )
      .timeout(const Duration(seconds: 10));
}

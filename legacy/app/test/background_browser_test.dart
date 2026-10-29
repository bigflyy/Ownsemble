import 'package:flutter_test/flutter_test.dart';
import 'package:ownsemble/provider/background_browser.dart';

void main() {
  test('music browser is created hidden and cannot open automatic popups', () {
    final settings = backgroundMusicBrowserSettings();
    expect(settings.browserSettings.hidden, isTrue);
    expect(settings.browserSettings.windowFrame?.width, 1200);
    expect(settings.browserSettings.windowFrame?.height, 900);
    expect(
      settings.webViewSettings.javaScriptCanOpenWindowsAutomatically,
      isFalse,
    );
    expect(settings.webViewSettings.useShouldInterceptRequest, isTrue);
  });
  test('trusted music input sends only renderer mouse events', () async {
    final events = <Map<String, dynamic>>[];
    var guards = 0;
    await dispatchBackgroundMusicTap(
      x: 10,
      y: 20,
      guard: () async {
        guards++;
      },
      dispatch: (event) async {
        events.add(event);
      },
    );
    expect(events.map((e) => e['type']), [
      'mouseMoved',
      'mousePressed',
      'mouseReleased',
    ]);
    expect(events.last['x'], 10);
    expect(events.last['y'], 20);
    expect(events.map((event) => event['buttons']), [0, 1, 0]);
    expect(events.every((event) => event['pointerType'] == 'mouse'), isTrue);
    expect(guards, 3);
  });
  test('trusted hover refreshes the visible target before pressing', () async {
    final events = <Map<String, dynamic>>[];
    final guarded = <({double x, double y})>[];
    var point = (x: 10.0, y: 20.0);
    await dispatchBackgroundMusicTap(
      x: point.x,
      y: point.y,
      guard: () async {
        guarded.add(point);
      },
      dispatch: (event) async {
        events.add(event);
      },
      refreshAfterHover: () async {
        point = (x: 80.0, y: 30.0);
        return point;
      },
    );
    expect(events.map((e) => e['x']), [10.0, 80.0, 80.0]);
    expect(events.map((e) => e['y']), [20.0, 30.0, 30.0]);
    expect(guarded, [
      (x: 10.0, y: 20.0),
      (x: 80.0, y: 30.0),
      (x: 80.0, y: 30.0),
    ]);
  });
  test('lost music guard prevents activation', () async {
    final events = <Map<String, dynamic>>[];
    await expectLater(
      dispatchBackgroundMusicTap(
        x: 10,
        y: 20,
        guard: () async {
          throw StateError('synthetic guard');
        },
        dispatch: (event) async {
          events.add(event);
        },
      ),
      throwsStateError,
    );
    expect(events, isEmpty);
  });
}

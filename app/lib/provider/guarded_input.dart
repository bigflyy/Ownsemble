import '../contracts/music_browser.dart';

Future<void> dispatchGuardedTap({
  required double x,
  required double y,
  required Future<void> Function() guard,
  required Future<void> Function(BrowserPointer) dispatch,
  Future<({double x, double y})> Function()? refreshAfterHover,
}) async {
  var targetX = x, targetY = y;
  for (final phase in PointerPhase.values) {
    await guard();
    await dispatch(BrowserPointer(phase, targetX, targetY));
    if (phase == PointerPhase.move) {
      await Future<void>.delayed(const Duration(milliseconds: 150));
      if (refreshAfterHover != null) {
        final point = await refreshAfterHover();
        targetX = point.x;
        targetY = point.y;
      }
    }
  }
}

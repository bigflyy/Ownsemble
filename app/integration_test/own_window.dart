import 'dart:ffi';
import 'dart:io' show pid;

import 'package:ffi/ffi.dart';

final _user32 = DynamicLibrary.open('user32.dll');

final _findWindowEx = _user32
    .lookupFunction<
      IntPtr Function(IntPtr, IntPtr, Pointer<Utf16>, Pointer<Utf16>),
      int Function(int, int, Pointer<Utf16>, Pointer<Utf16>)
    >('FindWindowExW');
final _getWindowThreadProcessId = _user32
    .lookupFunction<
      Uint32 Function(IntPtr, Pointer<Uint32>),
      int Function(int, Pointer<Uint32>)
    >('GetWindowThreadProcessId');
final _getWindowRect = _user32
    .lookupFunction<
      Int32 Function(IntPtr, Pointer<Int32>),
      int Function(int, Pointer<Int32>)
    >('GetWindowRect');
final _getClientRect = _user32
    .lookupFunction<
      Int32 Function(IntPtr, Pointer<Int32>),
      int Function(int, Pointer<Int32>)
    >('GetClientRect');
final _getDpiForWindow = _user32
    .lookupFunction<Uint32 Function(IntPtr), int Function(int)>(
      'GetDpiForWindow',
    );
final _setWindowPos = _user32
    .lookupFunction<
      Int32 Function(IntPtr, IntPtr, Int32, Int32, Int32, Int32, Uint32),
      int Function(int, int, int, int, int, int, int)
    >('SetWindowPos');

/// The app's real window, as Windows sees it. A size asked through [resize]
/// goes through the runner's limits, so a check on it proves them; a size set
/// in the test binding would not. It never moves or activates the window.
class OwnWindow {
  OwnWindow._(this._handle);

  /// This process's Flutter runner window.
  factory OwnWindow.find() {
    final className = 'FLUTTER_RUNNER_WIN32_WINDOW'.toNativeUtf16();
    final owner = calloc<Uint32>();
    try {
      var window = 0;
      while (true) {
        window = _findWindowEx(0, window, className, nullptr);
        if (window == 0) throw StateError('the app has no window');
        _getWindowThreadProcessId(window, owner);
        if (owner.value == pid) return OwnWindow._(window);
      }
    } finally {
      calloc.free(className);
      calloc.free(owner);
    }
  }

  final int _handle;

  (int, int) _size(int Function(int, Pointer<Int32>) read) {
    final rect = calloc<Int32>(4);
    read(_handle, rect);
    final size = (rect[2] - rect[0], rect[3] - rect[1]);
    calloc.free(rect);
    return size;
  }

  /// The frame's width and height, in real pixels.
  (int, int) get frameSize => _size(_getWindowRect);

  /// The content's width and height, in real pixels.
  (int, int) get clientSize => _size(_getClientRect);

  /// Real pixels per logical pixel.
  double get scale => _getDpiForWindow(_handle) / 96;

  /// Asks Windows for a frame size, which it may limit.
  void resize(int width, int height) {
    const noMoveNoZorderNoActivate = 0x0002 | 0x0004 | 0x0010;
    _setWindowPos(_handle, 0, 0, 0, width, height, noMoveNoZorderNoActivate);
  }
}

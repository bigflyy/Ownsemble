import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

/// What Windows tells this thread about the modifier keys, for the speed
/// gate's keys probe. The Flutter engine asks GetKeyState on every key and
/// makes Flutter's own state match, so a modifier that Windows still believes
/// held turns posted arrows and letters into shortcuts. Null off Windows.
///
/// The "...Anywhere" values are the keyboard as every program sees it: a
/// modifier the check did not post but that is down there was pressed by the
/// user or another program.
///
/// Also says whether this code runs on the thread that owns the app's window:
/// GetKeyState answers per thread, and only that thread's answer is the one
/// the engine sees.
Map<String, Object?>? windowsKeyState() {
  if (!Platform.isWindows) return null;
  final user32 = DynamicLibrary.open('user32.dll');
  final kernel32 = DynamicLibrary.open('kernel32.dll');
  final getKeyState = user32
      .lookupFunction<Int16 Function(Int32), int Function(int)>('GetKeyState');
  final getAsyncKeyState = user32
      .lookupFunction<Int16 Function(Int32), int Function(int)>(
        'GetAsyncKeyState',
      );
  final getCurrentThreadId = kernel32
      .lookupFunction<Uint32 Function(), int Function()>('GetCurrentThreadId');
  final getCurrentProcessId = kernel32
      .lookupFunction<Uint32 Function(), int Function()>('GetCurrentProcessId');
  final getForegroundWindow = user32
      .lookupFunction<IntPtr Function(), int Function()>('GetForegroundWindow');
  final findWindowEx = user32
      .lookupFunction<
        IntPtr Function(IntPtr, IntPtr, Pointer<Utf16>, Pointer<Utf16>),
        int Function(int, int, Pointer<Utf16>, Pointer<Utf16>)
      >('FindWindowExW');
  final getWindowThreadProcessId = user32
      .lookupFunction<
        Uint32 Function(IntPtr, Pointer<Uint32>),
        int Function(int, Pointer<Uint32>)
      >('GetWindowThreadProcessId');

  // The high bit of GetKeyState's answer means "down".
  bool down(int virtualKey) => getKeyState(virtualKey) < 0;
  // GetAsyncKeyState is the keyboard itself, for every program: a key down
  // there and not posted by the check was pressed outside it.
  bool downAnywhere(int virtualKey) => getAsyncKeyState(virtualKey) < 0;

  // The thread of this process's runner window, found by its class name.
  final className = 'FLUTTER_RUNNER_WIN32_WINDOW'.toNativeUtf16();
  final owner = calloc<Uint32>();
  var windowThread = 0;
  var ownWindow = 0;
  try {
    var window = 0;
    while (true) {
      window = findWindowEx(0, window, className, nullptr);
      if (window == 0) break;
      final thread = getWindowThreadProcessId(window, owner);
      if (owner.value == getCurrentProcessId()) {
        windowThread = thread;
        ownWindow = window;
        break;
      }
    }
  } finally {
    calloc.free(className);
    calloc.free(owner);
  }

  return {
    'alt': down(0x12),
    'shift': down(0x10),
    'ctrl': down(0x11),
    'win': down(0x5B) || down(0x5C),
    'altAnywhere': downAnywhere(0x12),
    'shiftAnywhere': downAnywhere(0x10),
    'ctrlAnywhere': downAnywhere(0x11),
    'winAnywhere': downAnywhere(0x5B) || downAnywhere(0x5C),
    'onWindowThread': windowThread == getCurrentThreadId(),
    // The user's typing reaches only the foreground window; a check's window
    // must never be it.
    'foreground': ownWindow != 0 && getForegroundWindow() == ownWindow,
  };
}

import 'dart:ffi';
import 'dart:io';

/// Ends this process at once, on Windows, without any shutdown work.
///
/// A normal shutdown of the Flutter engine with libmpv running crashed or hung
/// in most closes (6 crashes and 3 hangs of 16-20 s in 10 closes, measured with
/// `tool/close_check.dart`): mpv's threads go on calling into an engine that is
/// being torn down. Nothing needs that shutdown: settings are committed to the
/// database as they are written, and an unfinished `.part` file is ignored by
/// the next run. Call it last, after saving.
void endProcessNow() {
  if (!Platform.isWindows) return;
  final kernel32 = DynamicLibrary.open('kernel32.dll');
  final currentProcess = kernel32
      .lookupFunction<IntPtr Function(), int Function()>('GetCurrentProcess');
  final terminateProcess = kernel32
      .lookupFunction<Int32 Function(IntPtr, Uint32), int Function(int, int)>(
        'TerminateProcess',
      );
  terminateProcess(currentProcess(), 0);
}

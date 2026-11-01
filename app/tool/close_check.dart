// Closes the release through its window while a song plays, many times, and
// counts how the process ended. Exit code 0 is a clean close; anything else
// is a crash during shutdown, which no other check sees: the speed gate kills
// or lets the bench exit the app, and the user only sees a window closing.
//
// Run from app/ (never against the user's data folder):
//   dart run tool/close_check.dart --exe FILE --data-dir DIR --runs 20

// ignore_for_file: avoid_print

import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as p;

final _user32 = DynamicLibrary.open('user32.dll');
final _findWindowEx = _user32
    .lookupFunction<
      IntPtr Function(IntPtr, IntPtr, Pointer<Utf16>, Pointer<Utf16>),
      int Function(int, int, Pointer<Utf16>, Pointer<Utf16>)
    >('FindWindowExW');
final _isWindowVisible = _user32
    .lookupFunction<Int32 Function(IntPtr), int Function(int)>(
      'IsWindowVisible',
    );
final _getWindowThreadProcessId = _user32
    .lookupFunction<
      Uint32 Function(IntPtr, Pointer<Uint32>),
      int Function(int, Pointer<Uint32>)
    >('GetWindowThreadProcessId');
final _postMessage = _user32
    .lookupFunction<
      Int32 Function(IntPtr, Uint32, IntPtr, IntPtr),
      int Function(int, int, int, int)
    >('PostMessageW');

const _wmClose = 0x0010;

/// The visible Flutter runner window of process [pid], or 0.
int _visibleWindow(int pid) {
  final className = 'FLUTTER_RUNNER_WIN32_WINDOW'.toNativeUtf16();
  final owner = calloc<Uint32>();
  try {
    var window = 0;
    while (true) {
      window = _findWindowEx(0, window, className, nullptr);
      if (window == 0) return 0;
      _getWindowThreadProcessId(window, owner);
      if (owner.value == pid && _isWindowVisible(window) != 0) return window;
    }
  } finally {
    calloc.free(className);
    calloc.free(owner);
  }
}

Future<void> main(List<String> args) async {
  String? valueOf(String name) {
    final index = args.indexOf(name);
    return index >= 0 && index + 1 < args.length ? args[index + 1] : null;
  }

  final exe = p.absolute(valueOf('--exe')!);
  final dataDir = p.absolute(valueOf('--data-dir')!);
  final runs = int.parse(valueOf('--runs') ?? '20');
  // playToCloseCached leaves a song playing and writes the result file; an
  // older build has no such part, so --part playCached and a wait replace it.
  final part = valueOf('--part') ?? 'playToCloseCached';
  final waitMs = int.parse(valueOf('--wait-ms') ?? '0');
  final result = File(p.join(dataDir, 'close-check.json'));
  final session = valueOf('--vk-session');
  final codes = <int, int>{};
  for (var run = 1; run <= runs; run++) {
    if (result.existsSync()) result.deleteSync();
    final process = await Process.start(exe, [
      '--data-dir',
      dataDir,
      if (session != null) ...['--vk-session', p.absolute(session)],
      '--muted',
      '--no-stream-cache',
      '--bench',
      result.path,
      '--bench-parts',
      part,
    ]);
    final clock = Stopwatch()..start();
    while (_visibleWindow(process.pid) == 0 &&
        clock.elapsed < const Duration(seconds: 10)) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    if (waitMs > 0) {
      await Future<void>.delayed(Duration(milliseconds: waitMs));
    } else {
      while (!result.existsSync() &&
          clock.elapsed < const Duration(seconds: 30)) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    }
    final counts = result.existsSync() ? result.readAsStringSync() : 'none';
    _postMessage(_visibleWindow(process.pid), _wmClose, 0, 0);
    final closing = Stopwatch()..start();
    final code = await process.exitCode.timeout(
      const Duration(seconds: 20),
      onTimeout: () {
        process.kill();
        return -999;
      },
    );
    codes[code] = (codes[code] ?? 0) + 1;
    print(
      'run $run: exit $code after ${closing.elapsedMilliseconds} ms  $counts',
    );
  }
  print(jsonEncode({for (final e in codes.entries) '${e.key}': e.value}));
}

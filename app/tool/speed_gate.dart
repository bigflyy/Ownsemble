// Speed gate for the Windows release build: measures the targets in AGENTS.md
// against a prepared data folder and prints them next to the targets.
//
//  1. Start time: process start until the window is visible. The Flutter
//     runner shows the window only after the first frame is drawn, and the app
//     reads the library before that frame, so this is "start to usable list".
//  2. Idle RAM: working set and private bytes after the app sits idle.
//  3. In-app benchmark (--bench): search, scrolling, cached and streamed
//     playback, all muted.
//
// Run from app/ after `flutter build windows --release`:
//   dart run tool/speed_gate.dart --data-dir DIR --vk-session FILE --out FILE

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

/// Whether process [pid] has a visible Flutter runner window.
bool _hasVisibleWindow(int pid) {
  final className = 'FLUTTER_RUNNER_WIN32_WINDOW'.toNativeUtf16();
  final owner = calloc<Uint32>();
  try {
    var window = 0;
    while (true) {
      window = _findWindowEx(0, window, className, nullptr);
      if (window == 0) return false;
      _getWindowThreadProcessId(window, owner);
      if (owner.value == pid && _isWindowVisible(window) != 0) return true;
    }
  } finally {
    calloc.free(className);
    calloc.free(owner);
  }
}

late final String exe;
late final List<String> appArgs;

Future<void> main(List<String> args) async {
  String? valueOf(String name) {
    final index = args.indexOf(name);
    return index >= 0 && index + 1 < args.length ? args[index + 1] : null;
  }

  final dataDir = p.absolute(valueOf('--data-dir')!);
  final session = valueOf('--vk-session');
  final outFile = valueOf('--out') ?? p.join(dataDir, 'speed-gate.json');
  exe = p.absolute(
    valueOf('--exe') ?? 'build/windows/x64/runner/Release/ownsemble.exe',
  );
  appArgs = [
    '--data-dir',
    dataDir,
    if (session != null) ...['--vk-session', p.absolute(session)],
    '--muted',
  ];
  final starts = int.parse(valueOf('--starts') ?? '6');

  print('Start time ($starts launches)...');
  final startRuns = <Map<String, Object?>>[];
  for (var i = 0; i < starts; i++) {
    startRuns.add(await _measureStart(dataDir));
    print('  launch ${i + 1}: ${jsonEncode(startRuns.last)}');
    await Future<void>.delayed(const Duration(seconds: 1));
  }

  print('Idle RAM...');
  final memory = await _measureIdleMemory();
  print('  ${jsonEncode(memory)}');

  print('In-app benchmark (search, scroll, playback; muted)...');
  final benchFile = p.join(dataDir, 'bench.json');
  if (File(benchFile).existsSync()) File(benchFile).deleteSync();
  final bench = await Process.start(exe, [...appArgs, '--bench', benchFile]);
  final benchExit = await bench.exitCode.timeout(
    const Duration(minutes: 6),
    onTimeout: () {
      bench.kill();
      return -1;
    },
  );
  final benchResult = File(benchFile).existsSync()
      ? jsonDecode(File(benchFile).readAsStringSync())
      : {'error': 'bench exited $benchExit without results'};

  final report = {
    'measuredAt': DateTime.now().toIso8601String(),
    'starts': startRuns,
    'idleMemory': memory,
    'bench': benchResult,
  };
  File(outFile)
      .writeAsStringSync(const JsonEncoder.withIndent('  ').convert(report));
  print('Full report: $outFile');
}

/// Launches the app and times process start to visible window (= first
/// frame) and to the app's own first-frame callback.
Future<Map<String, Object?>> _measureStart(String dataDir) async {
  final metrics = File(p.join(dataDir, 'start-metrics.json'));
  if (metrics.existsSync()) metrics.deleteSync();
  final launchedAt = DateTime.now().millisecondsSinceEpoch;
  final clock = Stopwatch()..start();
  final process = await Process.start(exe, [
    ...appArgs,
    '--metrics',
    metrics.path,
  ]);
  int? visibleMs;
  while (clock.elapsed < const Duration(seconds: 10)) {
    if (_hasVisibleWindow(process.pid)) {
      visibleMs = clock.elapsedMilliseconds;
      break;
    }
    sleep(const Duration(milliseconds: 1));
  }
  while (!metrics.existsSync() && clock.elapsed < const Duration(seconds: 10)) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  await Future<void>.delayed(const Duration(milliseconds: 300));
  process.kill();
  await process.exitCode;
  if (!metrics.existsSync()) {
    return {'windowVisibleMs': visibleMs, 'error': 'no metrics'};
  }
  final app = jsonDecode(metrics.readAsStringSync()) as Map<String, dynamic>;
  return {
    'windowVisibleMs': visibleMs,
    'firstFrameCallbackMs': (app['firstFrameEpochMs'] as int) - launchedAt,
    'dartMainMs': (app['mainStartedEpochMs'] as int) - launchedAt,
    'libraryLoadMs': app['libraryLoadMs'],
    'songsInFirstFrame': app['songsInFirstFrame'],
  };
}

/// Launches the app, leaves it idle and samples its memory.
Future<Map<String, Object?>> _measureIdleMemory() async {
  final process = await Process.start(exe, appArgs);
  final samples = <String, Object?>{};
  final clock = Stopwatch()..start();
  for (final seconds in [10, 30]) {
    await Future<void>.delayed(Duration(seconds: seconds) - clock.elapsed);
    final reply = await Process.run('powershell', [
      '-NoProfile',
      '-Command',
      '\$p = Get-Process -Id ${process.pid}; '
          r'"$($p.WorkingSet64) $($p.PrivateMemorySize64)"',
    ]);
    final parts = (reply.stdout as String).trim().split(' ');
    samples['after${seconds}s'] = {
      'workingSetMB': int.parse(parts[0]) ~/ (1024 * 1024),
      'privateMB': int.parse(parts[1]) ~/ (1024 * 1024),
    };
  }
  process.kill();
  await process.exitCode;
  return samples;
}

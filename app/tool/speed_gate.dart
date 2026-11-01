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
final _postMessage = _user32
    .lookupFunction<
      Int32 Function(IntPtr, Uint32, IntPtr, IntPtr),
      int Function(int, int, int, int)
    >('PostMessageW');
final _getWindowThreadProcessId = _user32
    .lookupFunction<
      Uint32 Function(IntPtr, Pointer<Uint32>),
      int Function(int, Pointer<Uint32>)
    >('GetWindowThreadProcessId');

const _wmClose = 0x0010;

/// Whether process [pid] has a visible Flutter runner window.
bool _hasVisibleWindow(int pid) => _visibleWindow(pid) != 0;

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
    // Streamed songs are not cached, so every run measures the same songs
    // streaming and the gate data does not grow.
    '--no-stream-cache',
  ];
  final starts = int.parse(valueOf('--starts') ?? '6');

  // Only the restart check: quick to repeat while working on it.
  if (args.contains('--only-restart')) {
    final bench = p.join(dataDir, 'bench.json');
    print(jsonEncode(await _checkSavedSong('playToCloseCached', bench)));
    if (session != null) {
      print(jsonEncode(await _checkSavedSong('playToCloseStream', bench)));
    }
    return;
  }

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

  print('Saved volume across a restart...');
  final savedVolume = await _checkSavedVolume(benchFile);
  print('  ${jsonEncode(savedVolume)}');

  print('Last song across a real window close...');
  final savedSongs = {
    'cached': await _checkSavedSong('playToCloseCached', benchFile),
    'stream': session == null
        ? {'skipped': 'no VK session'}
        : await _checkSavedSong('playToCloseStream', benchFile),
  };
  print('  ${jsonEncode(savedSongs)}');

  final report = {
    'measuredAt': DateTime.now().toIso8601String(),
    'starts': startRuns,
    'idleMemory': memory,
    'bench': benchResult,
    'savedVolume': savedVolume,
    'savedSongs': savedSongs,
  };
  File(outFile)
      .writeAsStringSync(const JsonEncoder.withIndent('  ').convert(report));
  print('Full report: $outFile');
}

/// One release run saves a volume the way the slider does; the next run
/// reports what mpv holds before any sound. Not a speed target: it is here
/// because only this tool restarts the real app.
Future<Map<String, Object?>> _checkSavedVolume(String benchFile) async {
  Future<Map<String, Object?>> run(String part) async {
    final file = File(benchFile);
    if (file.existsSync()) file.deleteSync();
    final process = await Process.start(exe, [
      ...appArgs,
      '--bench',
      benchFile,
      '--bench-parts',
      part,
    ]);
    await process.exitCode.timeout(
      const Duration(minutes: 1),
      onTimeout: () {
        process.kill();
        return -1;
      },
    );
    if (!file.existsSync()) return {};
    return (jsonDecode(file.readAsStringSync()) as Map).cast();
  }

  final saved = (await run('saveVolume'))['saveVolume'] as Map?;
  final restored = (await run('savedVolume'))['savedVolume'] as Map?;
  final expected = saved?['volume'] as num?;
  final actual = restored?['mpvVolume'] as num?;
  return {
    'saved': expected,
    'mpvAfterRestart': actual,
    'mutedByUser': restored?['mutedByUser'],
    'ok':
        expected != null &&
        actual != null &&
        (actual - expected).abs() < 0.6 &&
        restored?['mutedByUser'] == false,
  };
}

/// One release run plays a song to a known place and is closed through its
/// window, as the user closes it; the next run must show that song paused
/// there with nothing loaded, and Play must go on from there with sound and
/// no new History entry. Not a speed target, see [_checkSavedVolume].
Future<Map<String, Object?>> _checkSavedSong(
  String playPart,
  String benchFile,
) async {
  final file = File(benchFile);
  if (file.existsSync()) file.deleteSync();
  final first = await Process.start(exe, [
    ...appArgs,
    '--bench',
    benchFile,
    '--bench-parts',
    playPart,
  ]);
  final clock = Stopwatch()..start();
  while (!file.existsSync() && clock.elapsed < const Duration(minutes: 1)) {
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
  if (!file.existsSync()) {
    first.kill();
    return {'ok': false, 'error': 'no play result'};
  }
  await Future<void>.delayed(const Duration(milliseconds: 100));
  final played = (jsonDecode(file.readAsStringSync()) as Map)
      .cast<String, Object?>();
  _postMessage(_visibleWindow(first.pid), _wmClose, 0, 0);
  final closeClock = Stopwatch()..start();
  final exit = await first.exitCode.timeout(
    const Duration(seconds: 15),
    onTimeout: () {
      first.kill();
      return -1;
    },
  );
  final closeMs = closeClock.elapsedMilliseconds;
  file.deleteSync();
  final second = await Process.start(exe, [
    ...appArgs,
    '--bench',
    benchFile,
    '--bench-parts',
    'savedSong',
  ]);
  await second.exitCode.timeout(
    const Duration(minutes: 1),
    onTimeout: () {
      second.kill();
      return -1;
    },
  );
  if (!file.existsSync()) {
    return {'ok': false, 'played': played, 'error': 'no restart result'};
  }
  final bench = jsonDecode(file.readAsStringSync()) as Map;
  final restored = (bench['savedSong'] as Map).cast<String, Object?>();
  final before = (restored['before'] as Map).cast<String, Object?>();
  final playedMs = played['positionMs'] as int;
  final shownMs = before['positionMs'] as int;
  final soundAt = restored['soundAtMs'] as int;
  final later = restored['twoSecondsLaterMs'] as int;
  return {
    'played': played,
    'exitCode': exit,
    'closeMs': closeMs,
    'restored': restored,
    // The close saves the place within a second or so of the last report.
    'ok':
        exit == 0 &&
        played['ok'] == true &&
        before['trackId'] == played['trackId'] &&
        before['listSongs'] == played['listSongs'] &&
        before['playing'] == false &&
        ((before['mpvPath'] as String?) ?? '').isEmpty &&
        shownMs >= playedMs &&
        shownMs < playedMs + 3000 &&
        restored['loaded'] == true &&
        restored['playing'] == true &&
        soundAt >= shownMs &&
        soundAt < shownMs + 3000 &&
        later > soundAt + 1000 &&
        (restored['sampleRate'] as int? ?? 0) > 0 &&
        restored['historyAdded'] == 0,
  };
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

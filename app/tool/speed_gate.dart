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
final _isZoomed = _user32
    .lookupFunction<Int32 Function(IntPtr), int Function(int)>('IsZoomed');
final _setWindowPos = _user32
    .lookupFunction<
      Int32 Function(IntPtr, IntPtr, Int32, Int32, Int32, Int32, Uint32),
      int Function(int, int, int, int, int, int, int)
    >('SetWindowPos');

final _setDpiAwareness = _user32
    .lookupFunction<IntPtr Function(IntPtr), int Function(int)>(
      'SetThreadDpiAwarenessContext',
    );

/// DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2.
const _perMonitorAware = -4;

const _wmClose = 0x0010;
const _wmKeyDown = 0x0100;
const _wmKeyUp = 0x0101;
const _wmChar = 0x0102;
const _wmXButtonDown = 0x020B;
const _wmXButtonUp = 0x020C;

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
  // Real pixels: at a display scale above 100% Windows would otherwise report
  // this process every window size divided by the scale.
  _setDpiAwareness(_perMonitorAware);
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
    print(jsonEncode(await _checkWindowPlacement(dataDir)));
    print(jsonEncode(await _checkRealKeysRetrying(bench)));
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
  // Only the start time: for comparing two builds under the same load.
  if (args.contains('--only-starts')) return;

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

  print('Window size and place across a real close...');
  final windowPlacement = await _checkWindowPlacement(dataDir);
  print('  ${jsonEncode(windowPlacement)}');

  print('Real Windows key messages...');
  final realKeys = await _checkRealKeysRetrying(benchFile);
  print('  ${jsonEncode(realKeys)}');

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
    'windowPlacement': windowPlacement,
    'realKeys': realKeys,
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

/// The frame's width and height of [window].
(int, int) _windowSize(int window) {
  final rect = calloc<Int32>(4);
  _getWindowRect(window, rect);
  final size = (rect[2] - rect[0], rect[3] - rect[1]);
  calloc.free(rect);
  return size;
}

/// The content's width and height in logical pixels, rounded: the sizes the
/// runner's minimum is written in (win32_window.cpp).
(int, int) _logicalClientSize(int window) {
  final rect = calloc<Int32>(4);
  _getClientRect(window, rect);
  final scale = _getDpiForWindow(window) / 96;
  final size = ((rect[2] / scale).round(), (rect[3] / scale).round());
  calloc.free(rect);
  return size;
}

/// The window comes back at a saved size, maximized when saved so, and a real
/// close saves a new size. It cannot get smaller than the minimum, neither
/// from a saved size nor by a resize. Run with OWNSEMBLE_BACKGROUND_WINDOW the
/// window stays off-screen, so its place is not checked here, only its size.
/// Removes the placement file afterwards, so other checks start from the
/// default.
Future<Map<String, Object?>> _checkWindowPlacement(String dataDir) async {
  final file = File(p.join(dataDir, 'window-placement.txt'));

  /// Starts the app on [placement] and hands the window to [check].
  Future<T> withWindow<T>(
    String placement,
    Future<T> Function(int window, Process app) check,
  ) async {
    file.writeAsStringSync(placement);
    final app = await Process.start(exe, appArgs);
    final clock = Stopwatch()..start();
    while (_visibleWindow(app.pid) == 0 &&
        clock.elapsed < const Duration(seconds: 10)) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    final result = await check(_visibleWindow(app.pid), app);
    app.kill();
    await app.exitCode;
    return result;
  }

  final normal = await withWindow(
    '100 100 900 700 0\n',
    (window, _) async => (_windowSize(window), _isZoomed(window) != 0),
  );
  final maximized = await withWindow(
    '100 100 900 700 1\n',
    (window, _) async => _isZoomed(window) != 0,
  );
  final offScreen = await withWindow(
    '50000 50000 900 700 0\n',
    (window, _) async => _windowSize(window),
  );
  const noMoveNoZorderNoActivate = 0x0002 | 0x0004 | 0x0010;
  const smallest = (480, 440);
  final smallSaved = await withWindow(
    '100 100 400 300 0\n',
    (window, _) async => _logicalClientSize(window),
  );
  final smallResize = await withWindow('100 100 900 700 0\n', (
    window,
    _,
  ) async {
    _setWindowPos(window, 0, 0, 0, 100, 100, noMoveNoZorderNoActivate);
    await Future<void>.delayed(const Duration(milliseconds: 300));
    return _logicalClientSize(window);
  });
  final exit = await withWindow('100 100 900 700 0\n', (window, app) async {
    await Future<void>.delayed(const Duration(seconds: 2));
    _setWindowPos(window, 0, 0, 0, 1000, 720, noMoveNoZorderNoActivate);
    await Future<void>.delayed(const Duration(milliseconds: 300));
    _postMessage(window, _wmClose, 0, 0);
    return app.exitCode.timeout(
      const Duration(seconds: 15),
      onTimeout: () => -1,
    );
  });
  final saved = file.readAsStringSync().trim().split(' ');
  file.deleteSync();
  return {
    'normal': '${normal.$1}',
    'maximized': maximized,
    'offScreenFallsBackTo': '$offScreen',
    'smallSavedOpensAt': '$smallSaved',
    'smallResizeStopsAt': '$smallResize',
    'closeExit': exit,
    'saved': saved.join(' '),
    'ok':
        normal.$1 == (900, 700) &&
        !normal.$2 &&
        maximized &&
        offScreen != (900, 700) &&
        smallSaved == smallest &&
        smallResize == smallest &&
        exit == 0 &&
        saved[2] == '1000' &&
        saved[3] == '720' &&
        saved[4] == '0',
  };
}

/// Posts a key press to [window]: down and up, as Windows delivers it. Works
/// on an off-screen window and never touches the user's own keyboard. Ctrl
/// cannot be done this way: the engine asks Windows for the modifier state.
void _pressKey(
  int window,
  int virtualKey,
  int scanCode, {
  bool extended = false,
}) {
  final bits = 1 | (scanCode << 16) | (extended ? 1 << 24 : 0);
  _postMessage(window, _wmKeyDown, virtualKey, bits);
  _postMessage(window, _wmKeyUp, virtualKey, bits | (3 << 30));
}

/// Posts a letter to [window], with the text Windows would send after its
/// key. The key itself does not matter: one stands for all of them, and with
/// any text, so this needs no keyboard layout installed.
void _typeLetter(int window, int codeUnit) {
  const virtualKey = 0x41;
  const scanCode = 0x1E;
  final bits = 1 | (scanCode << 16);
  _postMessage(window, _wmKeyDown, virtualKey, bits);
  _postMessage(window, _wmChar, codeUnit, bits);
  _postMessage(window, _wmKeyUp, virtualKey, bits | (3 << 30));
}

/// Posts a press of a mouse side button to [window], at a point inside it:
/// [button] is 1 for back and 2 for forward. Never touches the user's mouse.
void _pressSideButton(int window, int button) {
  const point = 200 | (200 << 16);
  _postMessage(window, _wmXButtonDown, button << 16, point);
  _postMessage(window, _wmXButtonUp, button << 16, point);
}

/// [_checkRealKeys], again when a letter was lost on the way. A letter is two
/// posted messages here, and on a busy machine the engine can take the key
/// before the text is in its queue; it then types the key's own Latin letter.
/// With a real keyboard Windows makes the text on the app's own thread, so
/// that cannot happen. Any other failure is reported as it is.
Future<Map<String, Object?>> _checkRealKeysRetrying(String benchFile) async {
  var lostLetters = 0;
  while (true) {
    final result = await _checkRealKeys(benchFile);
    final seen = (result['jumpTextsSeen'] as List?) ?? const [];
    final letterLost =
        result['ok'] != true && seen.any((text) => '$text'.endsWith('a'));
    if (!letterLost || lostLetters == 2) {
      return {...result, 'lostLetterRetries': lostLetters};
    }
    lostLetters++;
  }
}

/// The real keyboard path of the release, which simulated keys in the tests
/// skip: Right, Up, Space and Cyrillic letters sent to the engine's own window
/// as messages. The mouse's side buttons too, which only the engine turns
/// into Flutter's buttons.
Future<Map<String, Object?>> _checkRealKeys(String benchFile) async {
  final file = File(benchFile);
  final ready = File('$benchFile.ready');
  for (final old in [file, ready]) {
    if (old.existsSync()) old.deleteSync();
  }
  final process = await Process.start(exe, [
    ...appArgs,
    '--bench',
    benchFile,
    '--bench-parts',
    'keysProbe',
  ]);
  final clock = Stopwatch()..start();
  while (!ready.existsSync() && clock.elapsed < const Duration(seconds: 40)) {
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
  if (!ready.existsSync()) {
    process.kill();
    return {'ok': false, 'error': 'not ready'};
  }
  // The engine's view is the only child of the runner's window.
  final className = 'FLUTTERVIEW'.toNativeUtf16();
  final view = _findWindowEx(
    _visibleWindow(process.pid),
    0,
    className,
    nullptr,
  );
  calloc.free(className);
  _pressKey(view, 0x27, 0x4D, extended: true); // Right
  await Future<void>.delayed(const Duration(milliseconds: 150));
  _pressKey(view, 0x26, 0x48, extended: true); // Up
  await Future<void>.delayed(const Duration(milliseconds: 150));
  _pressKey(view, 0x20, 0x39); // Space
  await Future<void>.delayed(const Duration(milliseconds: 150));
  for (final codeUnit in ready.readAsStringSync().codeUnits) {
    _typeLetter(view, codeUnit);
    await Future<void>.delayed(const Duration(milliseconds: 60));
  }
  await Future<void>.delayed(const Duration(milliseconds: 300));
  _pressSideButton(view, 1);
  await Future<void>.delayed(const Duration(milliseconds: 300));
  _pressSideButton(view, 2);
  await process.exitCode.timeout(
    const Duration(seconds: 30),
    onTimeout: () {
      process.kill();
      return -1;
    },
  );
  if (!file.existsSync()) return {'ok': false, 'error': 'no result'};
  final bench = jsonDecode(file.readAsStringSync()) as Map;
  return (bench['keysProbe'] as Map).cast<String, Object?>();
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

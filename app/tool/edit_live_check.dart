// Plan 10 I2g4: the lyrics editor's real check in the release app (see
// lib/bench/edit_live.dart). Runs the app twice on one data folder, muted:
// editLive, then editLiveAfter, so a restart lies between the saves and the
// checks. While a run waits, this sends it the real Windows key messages it
// asks for (Space, arrows, Enter, Backspace, typed letters), posted to the
// app's own window: no focus taken, no mouse or keyboard of the user used.
// Prints yes/no checks and numbers, never words.
//
//   dart run tool/edit_live_check.dart EXE DATA_DIR SESSION_FILE \
//     FOUND_KEY,HEARD_KEY OUT_JSON
// With OWNSEMBLE_BACKGROUND_WINDOW=1 the window stays off screen.
// ignore_for_file: avoid_print
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

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

const _wmKeyDown = 0x0100;
const _wmKeyUp = 0x0101;
const _wmChar = 0x0102;

/// The runner's visible top window of process [pid], or 0.
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

/// The engine's view: the only child of the runner's window.
int _viewOf(int pid) {
  final className = 'FLUTTERVIEW'.toNativeUtf16();
  try {
    return _findWindowEx(_visibleWindow(pid), 0, className, nullptr);
  } finally {
    calloc.free(className);
  }
}

/// A key press as Windows posts it; [char] is the text Windows sends with
/// it (Enter and Backspace send one, the arrows and Space here none: Space
/// is a key for the editor, not text, see speed_gate.dart).
void _pressKey(
  int window,
  int virtualKey,
  int scanCode, {
  bool extended = false,
  int? char,
}) {
  final bits = 1 | (scanCode << 16) | (extended ? 1 << 24 : 0);
  _postMessage(window, _wmKeyDown, virtualKey, bits);
  if (char != null) _postMessage(window, _wmChar, char, bits);
  _postMessage(window, _wmKeyUp, virtualKey, bits | (3 << 30));
}

/// A letter with its text, as Windows sends a typed Unicode letter
/// (VK_PACKET: the key stands for its text; no layout needed).
void _typeLetter(int window, int codeUnit) {
  const virtualKey = 0xE7;
  const scanCode = 0;
  final bits = 1 | (scanCode << 16);
  _postMessage(window, _wmKeyDown, virtualKey, bits);
  _postMessage(window, _wmChar, codeUnit, bits);
  _postMessage(window, _wmKeyUp, virtualKey, bits | (3 << 30));
}

Future<void> _send(int view, List<Object?> steps) async {
  for (final step in steps.cast<Map<String, Object?>>()) {
    switch (step) {
      case {'wait': final int ms}:
        await Future<void>.delayed(Duration(milliseconds: ms));
      case {'type': final String text}:
        for (final unit in text.codeUnits) {
          _typeLetter(view, unit);
          await Future<void>.delayed(const Duration(milliseconds: 80));
        }
      case {'chars': final String text}:
        // The text alone, as an input method sends it.
        for (final unit in text.codeUnits) {
          _postMessage(view, _wmChar, unit, 1);
          await Future<void>.delayed(const Duration(milliseconds: 80));
        }
      case {'key': 'space'}:
        _pressKey(view, 0x20, 0x39);
      case {'key': 'left'}:
        _pressKey(view, 0x25, 0x4B, extended: true);
      case {'key': 'down'}:
        _pressKey(view, 0x28, 0x50, extended: true);
      case {'key': 'up'}:
        _pressKey(view, 0x26, 0x48, extended: true);
      case {'key': 'enter'}:
        _pressKey(view, 0x0D, 0x1C, char: 0x0D);
      case {'key': 'back'}:
        _pressKey(view, 0x08, 0x0E, char: 0x08);
      default:
        throw ArgumentError('unknown step $step');
    }
    await Future<void>.delayed(const Duration(milliseconds: 60));
  }
}

/// One run of the app with [part]; serves its key requests until it exits.
Future<Map<String, Object?>> _run(
  String exe,
  List<String> appArgs,
  String part,
  String benchFile,
) async {
  final ready = File('$benchFile.ready');
  final go = File('$benchFile.go');
  for (final old in [File(benchFile), ready, go]) {
    if (old.existsSync()) old.deleteSync();
  }
  final process = await Process.start(exe, [
    ...appArgs,
    '--bench',
    benchFile,
    '--bench-parts',
    part,
  ]);
  // The app's own output is not needed; drained so it never blocks.
  process.stdout.drain<void>();
  process.stderr.drain<void>();
  int? exitCode;
  process.exitCode.then((code) => exitCode = code);
  var requests = 0;
  final clock = Stopwatch()..start();
  while (exitCode == null && clock.elapsed < const Duration(minutes: 15)) {
    if (ready.existsSync()) {
      final steps = jsonDecode(ready.readAsStringSync()) as List;
      ready.deleteSync();
      final view = _viewOf(process.pid);
      if (view == 0) {
        print('$part: no window to send keys to');
      } else {
        await _send(view, steps);
      }
      // Time for the engine to take the last messages.
      await Future<void>.delayed(const Duration(milliseconds: 400));
      go.writeAsStringSync('sent');
      requests++;
    }
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
  if (exitCode == null) {
    process.kill();
    return {'error': 'timed out', 'keyRequests': requests};
  }
  final file = File(benchFile);
  if (!file.existsSync()) {
    return {'error': 'no result', 'exit': exitCode, 'keyRequests': requests};
  }
  final result = (jsonDecode(file.readAsStringSync()) as Map)
      .cast<String, Object?>();
  return {
    'exit': exitCode,
    'keyRequests': requests,
    'ms': clock.elapsedMilliseconds,
    ...((result[part] as Map?) ?? {}).cast<String, Object?>(),
    'memoryAfterBenchMB': result['memoryAfterBenchMB'],
  };
}

Object? _at(Object? map, String path) {
  Object? value = map;
  for (final part in path.split('.')) {
    if (value is! Map) return null;
    value = value[part];
  }
  return value;
}

Future<void> main(List<String> args) async {
  if (args.length != 5) {
    print('usage: EXE DATA_DIR SESSION_FILE FOUND_KEY,HEARD_KEY OUT_JSON');
    exit(2);
  }
  final [exe, data, session, keys, out] = args;
  final appArgs = [
    '--data-dir',
    data,
    '--vk-session',
    session,
    '--muted',
    '--bench-edit-keys',
    keys,
  ];
  final first = await _run(exe, appArgs, 'editLive', '$out.1.json');
  final second = await _run(exe, appArgs, 'editLiveAfter', '$out.2.json');
  final b = first;
  final a = second;
  final checks = <String, bool>{
    // The first run: editing and saving.
    'found: played and decoded':
        _at(b, 'found.play.ok') == true &&
        _at(b, 'found.play.stillPlayingAfter1s') == true,
    'found: timed found lyrics shown':
        _at(b, 'found.shownBefore.timed') == true,
    'found: editor holds the song': _at(b, 'found.open.holdSong') == true,
    'found: typed letters arrived':
        _at(b, 'found.typed.textEndsWithTyped') == true,
    'found: Enter split the line':
        _at(b, 'found.split.linesAdded') == 1 &&
        _at(b, 'found.split.firstPartKept') == true &&
        _at(b, 'found.split.newLineUntimed') == true &&
        _at(b, 'found.split.newLineIsRest') == true,
    'found: Backspace joined two lines':
        _at(b, 'found.join.linesRemoved') == 1 &&
        _at(b, 'found.join.textJoined') == true &&
        _at(b, 'found.join.aboveKeptTime') == true,
    'found: - and + moved times':
        _at(b, 'found.nudge.deltaA') == 200 &&
        _at(b, 'found.nudge.deltaB') == -100,
    'found: music break inserted, timed now':
        _at(b, 'found.musicBreak.linesAdded') == 1 &&
        _at(b, 'found.musicBreak.isBreak') == true &&
        _at(b, 'found.musicBreak.timed') == true &&
        _at(b, 'found.musicBreak.afterAbove') == true,
    'found: Space tapped at real positions':
        ((_at(b, 'found.tap.timesSet') as int?) ?? 0) >= 3 &&
        _at(b, 'found.tap.tappedInOrder') == true &&
        _at(b, 'found.tap.playingBeforeTaps') == true &&
        _at(b, 'found.tap.stillPlaying') == true &&
        ((_at(b, 'found.tap.tappedGapsMs') as List?) ?? const [0]).every(
          (gap) => (gap as int) >= 1000,
        ) &&
        ((_at(b, 'found.tap.maxMsFromPosition') as int?) ?? 1 << 30) <= 50,
    'found: saved and shown':
        _at(b, 'found.save1.shown.source') == 'edited' &&
        _at(b, 'found.save1.storedSame') == true &&
        _at(b, 'found.save1.saves') == 1 &&
        _at(b, 'found.save1.holdSong') == false,
    'found: edit as text kept times':
        _at(b, 'found.asText.changedRowKeptTime') == true &&
        _at(b, 'found.asText.otherLinesSame') == true,
    'found: toast Undo back to the first save':
        _at(b, 'found.toastUndo.pressed') == true &&
        _at(b, 'found.toastUndo.backToFirst') == true &&
        _at(b, 'found.toastUndo.saves') == 1,
    'found: saved again (2 saves)':
        _at(b, 'found.save3.saves') == 2 &&
        _at(b, 'found.save3.sameAsSecond') == true,
    'heard: edited and saved':
        _at(b, 'heard.typed') == true &&
        _at(b, 'heard.save.shown.source') == 'edited' &&
        _at(b, 'heard.save.editBasedOn') == 'heard',
    // The second run: after the restart.
    'restart: found edit shows unchanged':
        _at(a, 'found.afterRestart.shown.source') == 'edited' &&
        _at(a, 'found.afterRestart.digest') == _at(b, 'found.digests.second') &&
        _at(a, 'found.afterRestart.saves') == 2 &&
        _at(a, 'found.afterRestart.cyrillicKept') == true,
    'restart: undo the last save':
        _at(a, 'found.undo.digest') == _at(b, 'found.digests.first') &&
        _at(a, 'found.undo.saves') == 1 &&
        _at(a, 'found.undo.shown.source') == 'edited',
    'restart: back to the source, edit kept':
        _at(a, 'found.backToSource.shown.source') == _at(b, 'found.basedOn') &&
        _at(a, 'found.backToSource.editKept') == true &&
        _at(a, 'found.useEditAgain.shown.source') == 'edited',
    'restart: source refresh keeps the edit':
        _at(a, 'found.refresh.shown.source') == 'edited' &&
        _at(a, 'found.refresh.saves') == 1,
    'version: other upload has its own lyrics':
        _at(a, 'found.version.other.routeIsOther') == true &&
        _at(a, 'found.version.other.editShown') == false &&
        _at(a, 'found.version.playOther.ok') == true,
    'version: own upload shows the edit again':
        _at(a, 'found.version.own.routeIsOwn') == true &&
        _at(a, 'found.version.own.shown.source') == 'edited' &&
        _at(a, 'found.version.own.digest') == _at(b, 'found.digests.first'),
    'restart: heard edit shows unchanged':
        _at(a, 'heard.afterRestart.shown.source') == 'edited' &&
        _at(a, 'heard.afterRestart.digest') == _at(b, 'heard.save.digest') &&
        _at(a, 'heard.afterRestart.cyrillicKept') == true,
    'restart: back to the heard words, automatic shows the edit':
        _at(a, 'heard.backToHeard.shown.source') == 'heard' &&
        _at(a, 'heard.backToHeard.editKept') == true &&
        _at(a, 'heard.automatic.shown.source') == 'edited',
  };
  File(out).writeAsStringSync(
    const JsonEncoder.withIndent(
      '  ',
    ).convert({'checks': checks, 'editLive': first, 'editLiveAfter': second}),
  );
  for (final check in checks.entries) {
    print('${check.value ? 'PASS' : 'FAIL'}  ${check.key}');
  }
  final failed = checks.values.where((ok) => !ok).length;
  print(failed == 0 ? 'ALL PASSED' : '$failed FAILED');
  exit(failed == 0 ? 0 : 1);
}

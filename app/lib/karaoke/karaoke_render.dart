/// One karaoke video made by the trimmed ffmpeg (plan 11 B0, D1r).
///
/// The job folder holds the three inputs under fixed ASCII names
/// (audio.f32: 44.1 kHz stereo raw floats; bg.png: the background;
/// karaoke.ass: the lines) and ffmpeg starts there with relative names, so
/// no drive colon needs escaping in the filter and no Cyrillic user or song
/// name ever reaches ffmpeg or libass. ffmpeg writes out.mp4 there; the
/// caller moves it to its place.
///
/// Progress comes from `-progress pipe:1` on ffmpeg's output: blocks of
/// key=value lines, each with out_time_us (microseconds of video written)
/// and ending with progress=continue, or progress=end after the last one.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// The fixed names inside the job folder.
const renderAudioName = 'audio.f32';
const renderBackgroundName = 'bg.png';
const renderScriptName = 'karaoke.ass';
const renderOutName = 'out.mp4';

/// The audio's sample rate (mpv decodes the song to it, and the separator
/// works at it).
const renderSampleRate = 44100;

/// Frames per second of the video.
const renderFps = 30;

/// The ffmpeg arguments for one video of [samples] stereo frames of audio,
/// with [threads] threads for decoding, filtering and x264 each (the PC is
/// shared with the player and the user's other apps). The B0 command: run
/// in the job folder; -t from the sample count (never -shortest, which
/// overshoots with a looped image); yuv420p, which every player accepts;
/// the index in front (+faststart) so the file starts playing at once.
List<String> karaokeRenderArgs({required int samples, required int threads}) {
  final seconds = (samples / renderSampleRate).toStringAsFixed(6);
  return [
    '-hide_banner', '-nostdin', '-y', '-loglevel', 'error', //
    '-progress', 'pipe:1', '-nostats',
    '-threads', '$threads',
    '-f', 'f32le', '-ar', '$renderSampleRate', '-ac', '2',
    '-i', renderAudioName,
    '-f', 'image2', '-loop', '1', '-framerate', '$renderFps',
    '-i', renderBackgroundName,
    '-filter_complex', '[1:v]ass=$renderScriptName,format=yuv420p[v]',
    '-map', '[v]', '-map', '0:a',
    '-c:v', 'libx264', '-preset', 'veryfast', '-crf', '20',
    '-threads', '$threads', '-pix_fmt', 'yuv420p', '-r', '$renderFps',
    '-c:a', 'aac', '-b:a', '192k',
    '-t', seconds,
    '-movflags', '+faststart', renderOutName,
  ];
}

/// Reads ffmpeg's -progress lines and says how far the video is.
class RenderProgress {
  RenderProgress(this.totalMicros);

  /// The whole video's length in microseconds.
  final int totalMicros;

  int _micros = 0;
  bool _ended = false;

  /// Whether ffmpeg said progress=end.
  bool get ended => _ended;

  /// Share of the video written, 0..1.
  double get share =>
      totalMicros <= 0 ? 0 : (_micros / totalMicros).clamp(0.0, 1.0);

  /// Takes one line; true when it ends a block (time to report).
  bool add(String line) {
    final at = line.indexOf('=');
    if (at <= 0) return false;
    final key = line.substring(0, at).trim();
    final value = line.substring(at + 1).trim();
    switch (key) {
      // out_time_ms is microseconds too (an old ffmpeg naming slip); both
      // are read, out_time_us first in each block.
      case 'out_time_us' || 'out_time_ms':
        final micros = int.tryParse(value);
        // N/A before the first frame; never backwards.
        if (micros != null && micros > _micros) _micros = micros;
        return false;
      case 'progress':
        if (value == 'end') {
          _ended = true;
          _micros = totalMicros;
        }
        return true;
    }
    return false;
  }
}

/// The user pressed Stop.
class KaraokeStopped implements Exception {
  const KaraokeStopped();
}

/// ffmpeg did not make the video. [detail] is ffmpeg's last error lines
/// (only fixed ASCII names reach it, so they hold no song or user names).
class KaraokeRenderError implements Exception {
  const KaraokeRenderError(this.message, {this.detail = ''});
  final String message;
  final String detail;

  @override
  String toString() =>
      'KaraokeRenderError: $message${detail.isEmpty ? '' : ' ($detail)'}';
}

/// Stops an export: set once, read by every step.
class KaraokeStop {
  final _stop = Completer<void>();
  bool get stopped => _stop.isCompleted;
  Future<void> get future => _stop.future;
  void stop() {
    if (!_stop.isCompleted) _stop.complete();
  }
}

/// Starts a process (Process.start in the app, normal mode, so Windows
/// makes no console window; a fake in tests).
typedef StartProcess = Future<Process> Function(
  String executable,
  List<String> arguments, {
  String? workingDirectory,
});

Future<Process> _startProcess(
  String executable,
  List<String> arguments, {
  String? workingDirectory,
}) => Process.start(executable, arguments, workingDirectory: workingDirectory);

/// How many of ffmpeg's last error lines are kept for the message.
const _keptErrorLines = 8;

/// Makes out.mp4 in [job] from the inputs there with the ffmpeg at
/// [ffmpegPath]. [onProgress] hears the share done. Throws
/// [KaraokeStopped] after [stop] (ffmpeg is ended at once) and
/// [KaraokeRenderError] when ffmpeg fails; in both cases no out.mp4 is
/// left behind.
Future<void> renderKaraoke({
  required String ffmpegPath,
  required Directory job,
  required int samples,
  int threads = 2,
  void Function(double share)? onProgress,
  KaraokeStop? stop,
  StartProcess start = _startProcess,
}) async {
  final out = File(p.join(job.path, renderOutName));
  void removeOut() {
    try {
      if (out.existsSync()) out.deleteSync();
    } on FileSystemException {
      // ffmpeg may still hold it for a moment; the job folder goes later.
    }
  }

  removeOut();
  if (stop?.stopped ?? false) throw const KaraokeStopped();
  final Process process;
  try {
    process = await start(
      ffmpegPath,
      karaokeRenderArgs(samples: samples, threads: threads),
      workingDirectory: job.path,
    );
  } on ProcessException catch (error) {
    throw KaraokeRenderError(
      'The video maker could not start.',
      detail: error.message,
    );
  }
  final progress = RenderProgress(samples * 1000000 ~/ renderSampleRate);
  final errors = <String>[];
  final reading = process.stdout
      .transform(const Utf8Decoder(allowMalformed: true))
      .transform(const LineSplitter())
      .listen((line) {
        if (progress.add(line)) onProgress?.call(progress.share);
      })
      .asFuture<void>();
  final errorReading = process.stderr
      .transform(const Utf8Decoder(allowMalformed: true))
      .transform(const LineSplitter())
      .listen((line) {
        if (line.trim().isEmpty) return;
        errors.add(line.trim());
        if (errors.length > _keptErrorLines) errors.removeAt(0);
      })
      .asFuture<void>();
  var stopped = false;
  final stopping = stop?.future.then((_) {
    stopped = true;
    process.kill();
  });
  final code = await process.exitCode;
  // The pipes close when the process ends; a killed one may leave them
  // open a moment longer, so the wait is short.
  await Future.wait([reading, errorReading])
      .timeout(const Duration(seconds: 5), onTimeout: () => const []);
  stopping?.ignore();
  if (stopped || (stop?.stopped ?? false)) {
    removeOut();
    throw const KaraokeStopped();
  }
  if (code != 0) {
    removeOut();
    throw KaraokeRenderError(
      'The video maker failed (code $code).',
      detail: errors.join(' | '),
    );
  }
  if (!out.existsSync() || out.lengthSync() == 0) {
    removeOut();
    throw const KaraokeRenderError('The video maker wrote no video.');
  }
  onProgress?.call(1);
}

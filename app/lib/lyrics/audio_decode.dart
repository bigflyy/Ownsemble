// A song's audio as 16 kHz mono samples for the lyrics aligner (plan 10
// G1), decoded by the libmpv the app already ships for playback.
//
// This opens its own mpv instance (not the player's), with mpv's PCM
// writer as the audio output: mpv decodes the file, resamples it to 16 kHz
// mono float and writes the raw samples to a temporary file as fast as it
// can, playing nothing aloud. Synchronous: call it from a background
// isolate.
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'emission_model.dart' show modelSampleRate;

// mpv_event_id values (libmpv client.h).
const _eventShutdown = 1;
const _eventEndFile = 7;
// mpv_end_file_reason values.
const _endEof = 0;

final class _MpvEvent extends Struct {
  @Int32()
  external int eventId;
  @Int32()
  external int error;
  @Uint64()
  external int replyUserdata;
  external Pointer<Void> data;
}

final class _MpvEndFile extends Struct {
  @Int32()
  external int reason;
  @Int32()
  external int error;
}

/// Thrown when mpv cannot read or decode the file.
class DecodeError implements Exception {
  const DecodeError(this.message);
  final String message;

  @override
  String toString() => 'DecodeError: $message';
}

/// Decodes [audioPath] to 16 kHz mono float samples with the libmpv at
/// [mpvLibraryPath] (libmpv-2.dll beside the app on Windows), through a
/// temporary file in [tempDir]. Gives up after [timeout].
Float32List decodeForModel(
  String mpvLibraryPath,
  String audioPath,
  String tempDir, {
  Duration timeout = const Duration(minutes: 2),
}) {
  final mpv = DynamicLibrary.open(mpvLibraryPath);
  final create = mpv
      .lookupFunction<Pointer<Void> Function(), Pointer<Void> Function()>(
        'mpv_create',
      );
  final setOption = mpv
      .lookupFunction<
        Int32 Function(Pointer<Void>, Pointer<Utf8>, Pointer<Utf8>),
        int Function(Pointer<Void>, Pointer<Utf8>, Pointer<Utf8>)
      >('mpv_set_option_string');
  final initialize = mpv
      .lookupFunction<
        Int32 Function(Pointer<Void>),
        int Function(Pointer<Void>)
      >('mpv_initialize');
  final command = mpv
      .lookupFunction<
        Int32 Function(Pointer<Void>, Pointer<Pointer<Utf8>>),
        int Function(Pointer<Void>, Pointer<Pointer<Utf8>>)
      >('mpv_command');
  final waitEvent = mpv
      .lookupFunction<
        Pointer<_MpvEvent> Function(Pointer<Void>, Double),
        Pointer<_MpvEvent> Function(Pointer<Void>, double)
      >('mpv_wait_event');
  final destroy = mpv
      .lookupFunction<
        Void Function(Pointer<Void>),
        void Function(Pointer<Void>)
      >('mpv_terminate_destroy');

  final out = File(
    '$tempDir${Platform.pathSeparator}'
    'fit-${DateTime.now().microsecondsSinceEpoch}-$pid.f32',
  );
  final handle = create();
  if (handle == nullptr) throw const DecodeError('mpv_create failed');
  // mpv must have stopped writing before the samples are read, and
  // mpv_terminate_destroy may be called only once.
  var destroyed = false;
  void destroyOnce() {
    if (destroyed) return;
    destroyed = true;
    destroy(handle);
  }

  try {
    using((arena) {
      void option(String name, String value) {
        final code = setOption(
          handle,
          name.toNativeUtf8(allocator: arena),
          value.toNativeUtf8(allocator: arena),
        );
        if (code < 0) throw DecodeError('option $name: mpv error $code');
      }

      option('config', 'no');
      option('terminal', 'no');
      option('video', 'no');
      option('audio-display', 'no');
      option('ao', 'pcm');
      option('ao-pcm-file', out.path);
      option('ao-pcm-waveheader', 'no');
      option('audio-format', 'float');
      option('audio-samplerate', '$modelSampleRate');
      option('audio-channels', 'mono');
      // ffmpeg's resampler defaults, which the research's audio had. mpv's
      // own (filter size 16, cutoff from it) cut everything above about
      // 5.8 kHz at 16 kHz, where the hiss of s, sh and ch lies, and cost
      // live songs 5 points of lines within 1 s (session 44).
      option('audio-resample-filter-size', '32');
      option('audio-resample-cutoff', '0.97');
      option('audio-resample-linear', 'yes');
      option('replaygain', 'no');
      option('volume', '100');
      if (initialize(handle) < 0) throw const DecodeError('mpv_initialize');
      final args = arena<Pointer<Utf8>>(3);
      args[0] = 'loadfile'.toNativeUtf8(allocator: arena);
      args[1] = audioPath.toNativeUtf8(allocator: arena);
      args[2] = nullptr;
      final code = command(handle, args);
      if (code < 0) throw DecodeError('loadfile: mpv error $code');
    });
    final deadline = DateTime.now().add(timeout);
    while (true) {
      if (DateTime.now().isAfter(deadline)) {
        throw const DecodeError('timed out');
      }
      final event = waitEvent(handle, 1.0).ref;
      if (event.eventId == _eventShutdown) {
        throw const DecodeError('mpv shut down');
      }
      if (event.eventId != _eventEndFile) continue;
      final end = event.data.cast<_MpvEndFile>().ref;
      if (end.reason != _endEof) {
        throw DecodeError('mpv could not play it (error ${end.error})');
      }
      break;
    }
    destroyOnce();
    final bytes = out.readAsBytesSync();
    return Float32List.sublistView(bytes, 0, bytes.length ~/ 4 * 4);
  } on FileSystemException catch (e) {
    throw DecodeError('no samples written: ${e.osError?.message}');
  } finally {
    destroyOnce();
    // Also after a failure: samples written before it must not pile up.
    try {
      if (out.existsSync()) out.deleteSync();
    } on FileSystemException {
      // Still open somewhere; the temp folder is cleaned by Windows.
    }
  }
}

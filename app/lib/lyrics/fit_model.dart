/// The lyrics aligner's model file (plan 10 G2b): downloaded once, on the
/// first "Fit to this recording" the user agrees to, into the data folder.
///
/// It comes from Ownsemble's own GitHub release (user's pick 2026-11-23),
/// through a `.part` file that a retry continues where it stopped (a range
/// request), and only becomes the model once its size and SHA-256 are
/// right. A file with the wrong bytes is deleted, so the next try starts
/// over.
library;

import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';

/// Where a model comes from and what it must be.
class ModelFile {
  const ModelFile({
    required this.url,
    required this.bytes,
    required this.sha256,
    required this.fileName,
  });

  final Uri url;
  final int bytes;

  /// Lowercase hex.
  final String sha256;
  final String fileName;

  /// The size in whole megabytes, for the dialog: "355 MB".
  int get megabytes => (bytes / 1e6).round();
}

/// MMS_FA (Pratap et al. 2023, CC BY-NC 4.0) as int8 ONNX, made by
/// experiments/f2-timing/onnx_probe.py and published as the release
/// aligner-model-1 (session 44).
final alignerModel = ModelFile(
  url: Uri.parse(
    'https://github.com/bigflyy/Ownsemble/releases/download/'
    'aligner-model-1/mms_fa.int8.onnx',
  ),
  bytes: 355118972,
  sha256: '58a7fa943278af3f83b88cb3a12aae0627df92ea9eec1d1de90ff71638b8a0e9',
  fileName: 'mms_fa.int8.onnx',
);

/// Room left free on the drive besides the model: Windows and the songs
/// need space too.
const modelSpareBytes = 1000 * 1000 * 1000;

/// Why a model download did not finish.
class ModelDownloadError implements Exception {
  const ModelDownloadError(this.message, {this.retry = true});

  /// A short reason to show.
  final String message;

  /// Whether trying again may help (no for a full drive).
  final bool retry;

  @override
  String toString() => 'ModelDownloadError: $message';
}

/// Stops a running [downloadModel]; what came so far stays for a retry.
class DownloadStop {
  final _stop = Completer<void>();
  bool get stopped => _stop.isCompleted;
  void stop() {
    if (!_stop.isCompleted) _stop.complete();
  }

  Future<void> get future => _stop.future;
}

/// The download was stopped by the user.
class DownloadStopped implements Exception {
  const DownloadStopped();
}

/// Whether [target] holds the whole model. Only the size is checked here:
/// the bytes were checked once, before the file got its name.
bool hasModel(File target, ModelFile model) =>
    target.existsSync() && target.lengthSync() == model.bytes;

/// Whether [target]'s bytes are the model's (reads the whole file, a few
/// seconds): after the model failed to load.
Future<bool> modelIntact(File target, ModelFile model) async {
  try {
    return hasModel(target, model) && await _sha256Of(target) == model.sha256;
  } on FileSystemException {
    return false;
  }
}

/// Downloads [model] into [target], continuing a `.part` file left by an
/// earlier try. [freeBytes] says how much room the drive has (null:
/// unknown, not checked). [onProgress] gets the bytes so far and the
/// whole size. Throws [ModelDownloadError], or [DownloadStopped] after
/// [stop].
Future<void> downloadModel(
  ModelFile model,
  File target, {
  HttpClient? client,
  int? Function()? freeBytes,
  void Function(int bytes, int total)? onProgress,
  DownloadStop? stop,
  Duration stallTimeout = const Duration(seconds: 30),
}) async {
  if (hasModel(target, model)) return;
  final part = File('${target.path}.part');
  target.parent.createSync(recursive: true);
  var have = part.existsSync() ? part.lengthSync() : 0;
  if (have > model.bytes) {
    part.deleteSync();
    have = 0;
  }
  final free = freeBytes?.call();
  if (free != null && free < model.bytes - have + modelSpareBytes) {
    throw ModelDownloadError(
      'Not enough free space: the model needs '
      '${_gb(model.bytes - have + modelSpareBytes)} GB free, the drive has '
      '${_gb(free)} GB.',
      retry: false,
    );
  }
  final http =
      client ?? (HttpClient()..connectionTimeout = const Duration(seconds: 15));
  try {
    if (have < model.bytes) {
      have = await _fetch(
        http,
        model,
        part,
        have,
        onProgress: onProgress,
        stop: stop,
        stallTimeout: stallTimeout,
      );
    }
    if (have != model.bytes) {
      throw const ModelDownloadError('The download ended early.');
    }
    onProgress?.call(have, model.bytes);
    final digest = await _sha256Of(part);
    if (digest != model.sha256) {
      part.deleteSync();
      throw const ModelDownloadError(
        'The downloaded model was damaged; it was deleted.',
      );
    }
    if (target.existsSync()) target.deleteSync();
    part.renameSync(target.path);
  } on SocketException {
    throw const ModelDownloadError(
      'Could not reach GitHub. Check the connection and try again.',
    );
  } on HttpException {
    throw const ModelDownloadError(
      'The download broke off. Try again to continue it.',
    );
  } on TimeoutException {
    throw const ModelDownloadError(
      'The download stalled. Try again to continue it.',
    );
  } finally {
    if (client == null) http.close(force: true);
  }
}

/// Appends the rest of the model to [part] from byte [have]; returns its
/// size after.
Future<int> _fetch(
  HttpClient http,
  ModelFile model,
  File part,
  int have, {
  void Function(int bytes, int total)? onProgress,
  DownloadStop? stop,
  required Duration stallTimeout,
}) async {
  final request = await http.getUrl(model.url);
  if (have > 0) request.headers.set(HttpHeaders.rangeHeader, 'bytes=$have-');
  final response = await request.close().timeout(stallTimeout);
  final status = response.statusCode;
  if (status == HttpStatus.requestedRangeNotSatisfiable) {
    // A whole part never asks; a short one the server will not continue
    // would fail the same way on every retry: it starts over (Codex review).
    await _drain(response, stallTimeout);
    part.deleteSync();
    throw const ModelDownloadError(
      'GitHub would not continue the download. Try again to start over.',
    );
  }
  if (status != HttpStatus.ok && status != HttpStatus.partialContent) {
    await _drain(response, stallTimeout);
    throw ModelDownloadError(
      'GitHub answered $status. Try again later.',
      retry: true,
    );
  }
  // A server that ignores the range sends everything again.
  if (status == HttpStatus.ok) have = 0;
  if (status == HttpStatus.partialContent) {
    final range = response.headers.value(HttpHeaders.contentRangeHeader);
    if (range == null || !range.startsWith('bytes $have-')) {
      await _drain(response, stallTimeout);
      part.deleteSync();
      throw const ModelDownloadError(
        'GitHub sent the wrong part of the model. Try again to start over.',
      );
    }
  }
  final sink = part.openWrite(
    mode: have == 0 ? FileMode.writeOnly : FileMode.writeOnlyAppend,
  );
  var bytes = have;
  final done = Completer<void>();
  late final StreamSubscription<List<int>> reading;
  reading = response
      .timeout(stallTimeout)
      .listen(
        (chunk) {
          if (bytes + chunk.length > model.bytes) {
            // More than the model: not the model. The hash would fail too,
            // after writing who knows how much.
            if (!done.isCompleted) {
              done.completeError(
                const ModelDownloadError(
                  'GitHub sent more than the model. Try again to start over.',
                ),
              );
            }
            unawaited(reading.cancel());
            return;
          }
          sink.add(chunk);
          bytes += chunk.length;
          onProgress?.call(bytes, model.bytes);
        },
        onError: (Object error, StackTrace trace) {
          if (!done.isCompleted) done.completeError(error, trace);
        },
        onDone: () {
          if (!done.isCompleted) done.complete();
        },
        cancelOnError: true,
      );
  unawaited(
    stop?.future.then((_) async {
      await reading.cancel();
      if (!done.isCompleted) done.completeError(const DownloadStopped());
    }),
  );
  try {
    await done.future;
  } on ModelDownloadError {
    await sink.close();
    part.deleteSync();
    rethrow;
  } finally {
    await sink.close();
  }
  return bytes;
}

/// Reads away an answer not used; one that stalls is let go (a stalled
/// error body must not hold the fit forever, Codex review).
Future<void> _drain(HttpClientResponse response, Duration stallTimeout) async {
  try {
    await response.drain<void>().timeout(stallTimeout);
  } on Object {
    // Only the connection is lost.
  }
}

Future<String> _sha256Of(File file) async {
  final result = _DigestSink();
  final hashing = sha256.startChunkedConversion(result);
  await for (final chunk in file.openRead()) {
    hashing.add(chunk);
  }
  hashing.close();
  return result.value.toString();
}

class _DigestSink implements Sink<Digest> {
  late Digest value;

  @override
  void add(Digest data) => value = data;

  @override
  void close() {}
}

String _gb(int bytes) => (bytes / 1e9).toStringAsFixed(1);

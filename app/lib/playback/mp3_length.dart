/// How long an MP3 file really plays, from its first bytes and its size.
///
/// VK sometimes swaps the file behind a library row for another recording
/// and keeps the length it listed for the old one (Stage K, 2026-11-04: a
/// studio song of 219 s now plays its 226.5 s official release). The file's
/// own length tells such a swap apart: a few kilobytes and the size are
/// enough, so the check costs no extra download.
library;

import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

/// A file whose length differs from the expected length by more than this
/// many seconds is another recording (user, 2026-11-04).
const otherRecordingSeconds = 3.0;

/// A version whose file is within this many seconds of the listed length is
/// a match for the song (user, 2026-11-05).
const matchSeconds = 1.0;

/// How many bytes after the start of the audio are read to find the first
/// frame. A frame of 320 kbit/s is about 1 KB, so this always holds one.
const framesWindow = 16 * 1024;

/// What is known about one audio file: its size and how long it plays.
class FileFacts {
  const FileFacts({required this.bytes, required this.seconds});

  final int bytes;
  final double seconds;

  /// Whether this file plays more than [otherRecordingSeconds] longer or
  /// shorter than [expected] seconds.
  bool differsFrom(double expected) =>
      (seconds - expected).abs() > otherRecordingSeconds;

  @override
  String toString() => '${seconds.toStringAsFixed(1)} s, $bytes bytes';
}

/// Bitrates in kbit/s of MPEG-1 Layer III, by the header's 4-bit index.
const _bitratesV1 = [
  0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 0, //
];

/// Bitrates in kbit/s of MPEG-2 and MPEG-2.5 Layer III.
const _bitratesV2 = [
  0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160, 0, //
];

/// Where the audio of a file starting with [head] begins: after its ID3v2
/// tag (and the tag's footer, when it has one), else at 0. Null when [head]
/// is shorter than a tag header, so the answer is not known yet.
int? audioStartOf(List<int> head) {
  if (head.length < 10) return null;
  final isId3 = head[0] == 0x49 && head[1] == 0x44 && head[2] == 0x33;
  if (!isId3) return 0;
  // The size is 28 bits, 7 in each of 4 bytes, without the 10-byte header.
  final size =
      (head[6] & 0x7F) << 21 |
      (head[7] & 0x7F) << 14 |
      (head[8] & 0x7F) << 7 |
      (head[9] & 0x7F);
  final hasFooter = (head[5] & 0x10) != 0;
  return 10 + size + (hasFooter ? 10 : 0);
}

/// One MP3 frame header, read from 4 bytes.
class _Frame {
  _Frame._(
    this.bytes,
    this.samples,
    this.sampleRate,
    this.bitrate,
    this.mono,
    this.mpeg1,
  );

  /// The frame's whole length in bytes.
  final int bytes;

  /// Samples in the frame: 1152 for MPEG-1, 576 for MPEG-2 and 2.5.
  final int samples;
  final int sampleRate;

  /// Bits per second.
  final int bitrate;
  final bool mono;
  final bool mpeg1;

  /// The Layer III frame header at [at] of [data], or null when there is
  /// none there.
  static _Frame? at(List<int> data, int at) {
    if (at + 4 > data.length) return null;
    final b1 = data[at + 1];
    final b2 = data[at + 2];
    if (data[at] != 0xFF || (b1 & 0xE0) != 0xE0) return null;
    final version = (b1 >> 3) & 3; // 3 = MPEG-1, 2 = MPEG-2, 0 = MPEG-2.5.
    final layer = (b1 >> 1) & 3; // 1 = Layer III.
    final bitrateIndex = b2 >> 4;
    final rateIndex = (b2 >> 2) & 3;
    if (version == 1 ||
        layer != 1 ||
        bitrateIndex == 0 ||
        bitrateIndex == 15 ||
        rateIndex == 3) {
      return null;
    }
    final mpeg1 = version == 3;
    final bitrate = (mpeg1 ? _bitratesV1 : _bitratesV2)[bitrateIndex] * 1000;
    final baseRate = const [44100, 48000, 32000][rateIndex];
    final sampleRate = mpeg1
        ? baseRate
        : (version == 2 ? baseRate ~/ 2 : baseRate ~/ 4);
    final samples = mpeg1 ? 1152 : 576;
    final padding = (b2 >> 1) & 1;
    final bytes = (samples ~/ 8) * bitrate ~/ sampleRate + padding;
    return _Frame._(
      bytes,
      samples,
      sampleRate,
      bitrate,
      data[at + 3] >> 6 == 3,
      mpeg1,
    );
  }
}

/// How long an MP3 of [totalBytes] bytes plays, from [frames]: the bytes
/// from [audioStart] on. Uses the frame count of a Xing or Info header when
/// the first frame has one (VBR files, and LAME's CBR files), else the size
/// and the first frame's bitrate. A frame counts only when the next one
/// follows where it ends, so stray 0xFF bytes are not taken for one.
/// Null when no frame is found.
double? estimateMp3Seconds(
  List<int> frames, {
  required int audioStart,
  required int totalBytes,
}) {
  for (var i = 0; i + 4 <= frames.length; i++) {
    final frame = _Frame.at(frames, i);
    if (frame == null) continue;
    final next = i + frame.bytes;
    // The next frame must follow, unless the window ends before it.
    if (next + 4 <= frames.length && _Frame.at(frames, next) == null) continue;
    // A Xing or Info header sits after the side information.
    final sideInfo = frame.mpeg1
        ? (frame.mono ? 17 : 32)
        : (frame.mono ? 9 : 17);
    final tagAt = i + 4 + sideInfo;
    if (tagAt + 12 <= frames.length) {
      final tag = String.fromCharCodes(frames.sublist(tagAt, tagAt + 4));
      final hasFrameCount = (frames[tagAt + 7] & 1) == 1;
      if ((tag == 'Xing' || tag == 'Info') && hasFrameCount) {
        final count =
            frames[tagAt + 8] << 24 |
            frames[tagAt + 9] << 16 |
            frames[tagAt + 10] << 8 |
            frames[tagAt + 11];
        if (count > 0) return count * frame.samples / frame.sampleRate;
      }
    }
    final audioBytes = totalBytes - audioStart - i;
    if (audioBytes <= 0) return null;
    return audioBytes * 8 / frame.bitrate;
  }
  return null;
}

/// What the first bytes of a file say about it so far.
class HeadReading {
  const HeadReading._(this.facts, this.needMore);

  /// The file's size and length; null when it could not be measured.
  final FileFacts? facts;

  /// Whether more bytes are needed before anything can be said.
  final bool needMore;
}

/// Measures a file of [totalBytes] bytes from [head], its bytes from the
/// start on. Asks for more ([HeadReading.needMore]) until [head] reaches
/// [framesWindow] bytes past the ID3 tag or holds the whole file.
HeadReading readHead(List<int> head, int totalBytes) {
  final whole = head.length >= totalBytes;
  final start = audioStartOf(head);
  if (start == null) {
    return whole
        ? const HeadReading._(null, false)
        : const HeadReading._(null, true);
  }
  if (!whole && head.length < start + framesWindow) {
    return const HeadReading._(null, true);
  }
  if (start >= head.length) return const HeadReading._(null, false);
  final seconds = estimateMp3Seconds(
    head.sublist(start, min(head.length, start + framesWindow)),
    audioStart: start,
    totalBytes: totalBytes,
  );
  return HeadReading._(
    seconds == null ? null : FileFacts(bytes: totalBytes, seconds: seconds),
    false,
  );
}

/// Measures the stored file [file]; null when it is missing, unreadable or
/// holds no MP3 frames. Reads at most a few kilobytes.
FileFacts? measureFile(File file) {
  RandomAccessFile? open;
  try {
    open = file.openSync();
    final total = open.lengthSync();
    final head = open.readSync(10);
    final start = audioStartOf(head);
    if (start == null || start >= total) return null;
    open.setPositionSync(start);
    final frames = open.readSync(framesWindow);
    final seconds = estimateMp3Seconds(
      frames,
      audioStart: start,
      totalBytes: total,
    );
    return seconds == null ? null : FileFacts(bytes: total, seconds: seconds);
  } on FileSystemException {
    return null;
  } finally {
    open?.closeSync();
  }
}

/// Measures the audio at [link] from at most two small range reads: the
/// start (with the size), and when a long ID3 tag hides the first frame,
/// the bytes after the tag. Null when the server gives no audio or no size.
/// Throws as the network does (a timeout, no line).
Future<FileFacts?> measureRemote(
  HttpClient http,
  Uri link, {
  Duration timeout = const Duration(seconds: 10),
}) async {
  if (link.path.toLowerCase().endsWith('.m3u8')) return null;
  final (head, total) = await readRemoteRange(
    http,
    link,
    0,
    framesWindow,
    timeout,
  );
  if (head == null || total == null) return null;
  final reading = readHead(head, total);
  if (!reading.needMore) return reading.facts;
  final start = audioStartOf(head);
  if (start == null || start >= total) return null;
  final (frames, _) = await readRemoteRange(
    http,
    link,
    start,
    framesWindow,
    timeout,
  );
  if (frames == null) return null;
  final seconds = estimateMp3Seconds(
    frames,
    audioStart: start,
    totalBytes: total,
  );
  return seconds == null ? null : FileFacts(bytes: total, seconds: seconds);
}

/// Reads [count] bytes of [link] from [start]; returns them and the whole
/// file's size, or nulls when the answer is not audio, or when a server
/// that ignores the range would hand over the file's start instead.
Future<(Uint8List?, int?)> readRemoteRange(
  HttpClient http,
  Uri link,
  int start,
  int count,
  Duration timeout,
) async {
  final request = await http.getUrl(link).timeout(timeout);
  request.headers.set(
    HttpHeaders.rangeHeader,
    'bytes=$start-${start + count - 1}',
  );
  final response = await request.close().timeout(timeout);
  final type = response.headers.contentType;
  final isAudio =
      type == null ||
      type.primaryType == 'audio' ||
      type.mimeType == 'application/octet-stream';
  final wrongPlace =
      start > 0 && response.statusCode != HttpStatus.partialContent;
  if (!isAudio || response.statusCode >= 300 || wrongPlace) {
    await response.listen(null).cancel();
    return (null, null);
  }
  final range = response.headers.value(HttpHeaders.contentRangeHeader);
  final total = response.statusCode == HttpStatus.partialContent
      ? int.tryParse(range?.split('/').last ?? '')
      : (response.contentLength > 0 ? response.contentLength : null);
  final bytes = BytesBuilder(copy: false);
  final done = Completer<void>();
  late final StreamSubscription<List<int>> subscription;
  subscription = response.listen(
    (chunk) {
      bytes.add(chunk);
      // A server that ignores the range sends the whole file: stop early.
      if (bytes.length >= count && !done.isCompleted) {
        done.complete();
        unawaited(subscription.cancel());
      }
    },
    onError: (Object error, StackTrace trace) {
      if (!done.isCompleted) done.completeError(error, trace);
    },
    onDone: () {
      if (!done.isCompleted) done.complete();
    },
    cancelOnError: true,
  );
  await done.future.timeout(timeout);
  final all = bytes.takeBytes();
  return (
    all.length > count ? Uint8List.sublistView(all, 0, count) : all,
    total,
  );
}

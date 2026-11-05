/// A short fingerprint of VK's file for one library row (Stage L).
///
/// Two accounts' rows are merged for certain only when VK gives both the
/// same file: equal size and equal bytes at a few places. The print is read
/// once, in the background sync, and stored, so a merge never costs a play.
library;

/// How many bytes are read at each sampled place of a file.
const printSampleBytes = 4096;

/// Where a file of [bytes] bytes is sampled: its start and its quarters.
/// Two files of equal size are sampled at the same places.
List<int> printOffsets(int bytes) => [
  0,
  bytes ~/ 4,
  bytes ~/ 2,
  bytes * 3 ~/ 4,
];

/// FNV-1a, 64 bits, over [chunks] in order. Dart's ints wrap at 64 bits, so
/// the multiplication needs no masking.
int fnv1a64(Iterable<List<int>> chunks) {
  var hash = 0xcbf29ce484222325;
  for (final chunk in chunks) {
    for (final byte in chunk) {
      hash ^= byte & 0xff;
      hash *= 0x100000001b3;
    }
  }
  return hash;
}

/// What VK gave for one row's song when it was printed.
class FilePrint {
  /// A file of [bytes] bytes whose samples hash to [sample] and that plays
  /// [seconds] (null when its MP3 frames could not be read).
  const FilePrint({
    required int this.bytes,
    required int this.sample,
    this.seconds,
  });

  /// VK gave no file for the song (blocked, restricted or gone).
  const FilePrint.noFile() : bytes = null, sample = null, seconds = null;

  final int? bytes;
  final int? sample;
  final double? seconds;

  bool get hasFile => bytes != null && sample != null;

  /// Whether this and [other] are certainly one file: both exist, with the
  /// same size and the same bytes at every sampled place.
  bool sameFileAs(FilePrint other) =>
      hasFile &&
      other.hasFile &&
      bytes == other.bytes &&
      sample == other.sample;

  @override
  String toString() => hasFile
      ? '$bytes bytes, ${seconds?.toStringAsFixed(1) ?? '?'} s'
      : 'no file';
}

/// The one-time check of saved songs (user, 2026-11-04).
///
/// Until 970d738, a song whose own file VK's audio server could not send was
/// streamed, saved and downloaded from VK's "official release" of it instead,
/// whenever VK gave both the same track_id. VK gives that id to other
/// recordings too: a studio song was saved as a live version. This finds such
/// files and removes them, so the song streams its own file again.
///
/// A saved file is a byte-for-byte copy of the file it came from, so its size
/// tells which file that was. Only sizes are asked for, never the audio.
library;

import 'dart:async';
import 'dart:io';

import '../library/track.dart';
import '../vk/vk_client.dart' show VkException;

/// Setting that is set once every saved song was checked.
const storedCheckDoneSetting = 'stored_check_done';

/// What the check finds for one saved song.
enum StoredVerdict {
  /// The saved file is the size of the song's own file on VK: it is that file.
  same,

  /// The saved file is not the song's own file: another size than the own
  /// file, or (when VK cannot send the own file) the size of the release.
  wrong,

  /// Nothing to compare with: VK gave no size for either file, or the
  /// release is another size. The file stays.
  unverified,
}

/// Decides about a saved file of [saved] bytes, given the size of the song's
/// own file on VK ([own]) and of VK's official release of it ([release]);
/// null when VK gave none.
StoredVerdict judgeStored({required int saved, int? own, int? release}) {
  if (own != null) {
    return saved == own ? StoredVerdict.same : StoredVerdict.wrong;
  }
  if (release != null && saved == release) return StoredVerdict.wrong;
  return StoredVerdict.unverified;
}

/// Thrown by [StoredCheck.linksOf] when the song cannot be asked about now
/// (its account is logged out): it waits for the next start.
class NotNow implements Exception {
  const NotNow(this.reason);
  final String reason;
}

/// Links VK gives for a song: its own file, and a way to ask for the release
/// (only to recognize what the old switch saved; it is never played).
typedef CopyLinks = ({Uri? own, Future<Uri?> Function() release});

/// What one run of [StoredCheck] did.
class StoredCheckSummary {
  int checked = 0;
  int same = 0;
  int removed = 0;
  int unverified = 0;

  /// Songs not checked this time: VK or the line failed, or the song was
  /// playing or saving. The check runs again at the next start.
  int notReached = 0;

  /// Whether every saved song got a verdict, so the check is done for good.
  bool get complete => notReached == 0;

  @override
  String toString() =>
      '$checked checked: $same same, $removed removed, '
      '$unverified unverified, $notReached not reached';
}

/// Checks each saved song once, one after another, and removes the files
/// that are not the song's own file. A downloaded song with a wrong file is
/// downloaded again from its own file when VK can send it.
class StoredCheck {
  StoredCheck({
    required this.songs,
    required this.savedBytes,
    required this.linksOf,
    required this.sizeOf,
    required this.remove,
    required this.redownload,
    required this.isBusy,
    required this.log,
    this.pause = const Duration(milliseconds: 400),
  });

  /// The songs with a saved file, with whether each is downloaded.
  final List<({Track track, bool pinned})> songs;

  /// The size of [track]'s saved file now; null when the file is gone.
  final int? Function(Track track) savedBytes;

  /// VK's links for [track]; null when no logged-in account has the song.
  /// Throws as VK does (a transient [VkException], a timeout, no line).
  final Future<CopyLinks?> Function(Track track) linksOf;

  /// The size of the file behind [link]; null when it is not audio or the
  /// server does not say.
  final Future<int?> Function(Uri link) sizeOf;

  /// Forgets [track]'s saved file and deletes it.
  final void Function(Track track) remove;

  /// Downloads [track] again; returns an error text, or null.
  final Future<String?> Function(Track track) redownload;

  /// Whether [track] is playing, saving or downloading now; then it waits.
  final bool Function(Track track) isBusy;

  /// One line for perf.log: song ids and sizes, never titles or links.
  final void Function(String line) log;

  /// Between songs, so VK is not asked in a burst.
  final Duration pause;

  Future<StoredCheckSummary> run() async {
    final summary = StoredCheckSummary();
    for (final (:track, :pinned) in songs) {
      if (isBusy(track)) {
        summary.notReached++;
        continue;
      }
      final saved = savedBytes(track);
      if (saved == null) continue;
      final sizes = await _sizesOf(track, summary);
      await Future<void>.delayed(pause);
      if (sizes == null) continue;
      final (:own, :release) = sizes;
      final verdict = judgeStored(saved: saved, own: own, release: release);
      final known =
          'saved $saved bytes, own ${own ?? 'unknown'}, '
          'release ${release ?? 'unknown'}';
      switch (verdict) {
        case StoredVerdict.same:
          summary.checked++;
          summary.same++;
          log('stored check: song ${track.id} same, $known');
        case StoredVerdict.unverified:
          summary.checked++;
          summary.unverified++;
          log('stored check: song ${track.id} unverified, $known');
        case StoredVerdict.wrong:
          // The song may have started meanwhile; leave it for the next run.
          if (isBusy(track)) {
            summary.notReached++;
            continue;
          }
          summary.checked++;
          remove(track);
          summary.removed++;
          var after = '';
          if (pinned && own != null) {
            final error = await redownload(track);
            after = error == null
                ? ', downloaded again'
                : ', downloading again FAILED: $error';
          } else if (pinned) {
            after = ', was downloaded, own file not available';
          }
          log('stored check: song ${track.id} REMOVED, $known$after');
      }
    }
    return summary;
  }

  /// The sizes VK gives for [track]'s own file and, when the own file has
  /// none, its release. Null when the song cannot be judged this time (VK
  /// or the line failed: counted as not reached) or at all (VK refused:
  /// counted as unverified).
  Future<({int? own, int? release})?> _sizesOf(
    Track track,
    StoredCheckSummary summary,
  ) async {
    try {
      final links = await linksOf(track);
      final ownLink = links?.own;
      final own = ownLink == null ? null : await sizeOf(ownLink);
      int? release;
      if (own == null && links != null) {
        final releaseLink = await links.release();
        release = releaseLink == null ? null : await sizeOf(releaseLink);
      }
      return (own: own, release: release);
    } on Object catch (error) {
      if (_isTransient(error)) {
        summary.notReached++;
        return null;
      }
      // VK refused (an expired login, no access): nothing to compare.
      summary.checked++;
      summary.unverified++;
      log('stored check: song ${track.id} unverified, ${error.runtimeType}');
      return null;
    }
  }

  static bool _isTransient(Object error) =>
      (error is VkException && error.transient) ||
      error is NotNow ||
      error is TimeoutException ||
      error is SocketException ||
      error is HttpException;
}

/// The size of the file at [link], read from one byte of it ("bytes=0-0"),
/// so no audio is downloaded. Null when the server answers with an error, a
/// page or a playlist instead of audio, or gives no size.
Future<int?> remoteAudioSize(Uri link, HttpClient http) async {
  if (link.path.toLowerCase().endsWith('.m3u8')) return null;
  final request = await http.getUrl(link).timeout(const Duration(seconds: 15));
  request.headers.set(HttpHeaders.rangeHeader, 'bytes=0-0');
  final response = await request.close().timeout(const Duration(seconds: 15));
  try {
    final type = response.headers.contentType;
    final isAudio =
        type == null ||
        type.primaryType == 'audio' ||
        type.mimeType == 'application/octet-stream';
    if (!isAudio) return null;
    if (response.statusCode == HttpStatus.partialContent) {
      final range = response.headers.value(HttpHeaders.contentRangeHeader);
      return int.tryParse(range?.split('/').last ?? '');
    }
    if (response.statusCode == HttpStatus.ok && response.contentLength > 0) {
      return response.contentLength;
    }
    return null;
  } finally {
    // One byte (or a whole file, if the server ignores the range): stop
    // reading at once.
    await response.listen(null).cancel();
  }
}

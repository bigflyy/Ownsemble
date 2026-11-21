/// VK's lyrics of one song (plan 10, C2), read-only.
///
/// Probe of 2026-11-21 (tool/probe_lyrics.dart): audio.getLyrics with
/// `{audio_id: "<owner>_<id>"}` (an access key may follow) answers in about
/// 250 ms; a song without lyrics answers error 104 (not found). Asked many
/// times in a row VK answers error 9 (flood control), so lyrics are asked
/// one song at a time, when they are shown or the song is downloaded.
library;

import '../lyrics/lyrics.dart';
import 'vk_client.dart';

/// What VK answered for one song's lyrics.
sealed class VkLyricsAnswer {
  const VkLyricsAnswer();
}

/// VK has lyrics for the song. [md5] changes when VK's lyrics change.
class VkLyricsFound extends VkLyricsAnswer {
  const VkLyricsFound(this.lyrics, {this.md5});
  final Lyrics lyrics;
  final String? md5;
}

/// VK has no lyrics for the song.
class VkLyricsNone extends VkLyricsAnswer {
  const VkLyricsNone();
}

/// VK's error for a song it has no lyrics for.
const vkLyricsNotFound = 104;

/// Asks VK for one song's lyrics through [call] (the song's own account).
///
/// A transient failure is tried once more ([retryTransient]); a refusal to go
/// on (error 9 or 14, [VkException.slowDown]) and other failures are thrown
/// for the caller to show.
Future<VkLyricsAnswer> fetchVkLyrics(
  VkApiCall call, {
  required String sourceKey,
  String? accessKey,
}) async {
  final Object? reply;
  try {
    reply = await retryTransient(
      () => call('audio.getLyrics', {
        'audio_id': accessKey == null || accessKey.isEmpty
            ? sourceKey
            : '${sourceKey}_$accessKey',
      }),
      // A person waits for the answer: one more try, not a long backoff.
      attempts: 2,
    );
  } on VkException catch (error) {
    if (error.code == vkLyricsNotFound) return const VkLyricsNone();
    rethrow;
  }
  final lyrics = lyricsFromVk(reply);
  if (lyrics == null) return const VkLyricsNone();
  final md5 = reply is Map ? reply['md5'] : null;
  return VkLyricsFound(lyrics, md5: md5 is String ? md5 : null);
}

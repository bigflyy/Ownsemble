// Edits of the account's VK playlists (plan 08, Stage C), as VK's API
// takes them. What VK does was measured on the test account
// (tool/probe_playlist_edits.dart, 2026-11-18, plan 08 A2):
// - a new song goes on top of the playlist;
// - a song of another owner goes in as a COPY with the account as owner and
//   a new id (track_id, title, artist and length stay): moves and removes
//   work only with the key the playlist read gives;
// - VK keeps no repeat of one key, but adding the original of another
//   owner's song again makes a second copy, so "already in" is the app's
//   own check ([playlistHasSong]);
// - update_time moves on add, not on rename, reorder or remove;
// - replies say little: audio.reorder answers 1 even when nothing moved,
//   addToPlaylist one item also for a key that was there already. So the
//   caller reads the playlist back after every write.

import '../library/same_song.dart';
import 'vk_client.dart';
import 'vk_playlists.dart';
import 'vk_recommendations.dart';

/// The owner and the id of a VK key "ownerId_id" (a playlist's or a
/// song's).
({String owner, String id}) splitVkKey(String key) {
  final split = key.lastIndexOf('_');
  if (split <= 0 || split == key.length - 1) {
    throw ArgumentError.value(key, 'key', 'not "ownerId_id"');
  }
  return (owner: key.substring(0, split), id: key.substring(split + 1));
}

/// A song as VK's audio_ids take it: "ownerId_id", with "_accessKey" after
/// it when the song has one (VK takes both forms, probe-edits-28g).
String vkSongRef(String key, String? accessKey) =>
    accessKey == null || accessKey.isEmpty ? key : '${key}_$accessKey';

/// Whether [songs] (a playlist's, as read) hold the song [key] with the VK
/// recording [vkTrackId] and length [durationSec]: the same key, or a copy
/// of the same recording (VK gives another owner's song a new key in the
/// playlist). A track id counts only with a length within
/// [sameSongLengthTolerance], since VK reuses one id for other songs
/// (found_match.dart); a song without one matches by key only.
bool playlistHasSong(
  List<VkRecSong> songs,
  String key,
  int? vkTrackId,
  int durationSec,
) => songs.any(
  (song) =>
      song.key == key ||
      vkTrackId != null &&
          song.song.vkTrackId == vkTrackId &&
          (song.song.durationSec - durationSec).abs() <=
              sameSongLengthTolerance,
);

/// VK answered an edit with something else than it gives for one that
/// worked.
class VkEditRefused implements Exception {
  const VkEditRefused(this.what);
  final String what;
  @override
  String toString() => 'VK did not $what';
}

/// Makes a playlist [title] of [ownerId], with [songs] in it (each a
/// [vkSongRef]; VK puts the last one on top). The new playlist as VK gives
/// it.
Future<VkPlaylist> createVkPlaylist(
  VkApiCall call,
  int ownerId,
  String title, {
  List<String> songs = const [],
}) async {
  final reply = await call('audio.createPlaylist', {
    'owner_id': '$ownerId',
    'title': title,
    if (songs.isNotEmpty) 'audio_ids': songs.join(','),
  });
  final list = vkPlaylistOf(reply);
  if (list == null) throw const VkEditRefused('make the playlist');
  return list;
}

/// Gives the playlist [playlistKey] the name [title]; its songs stay.
Future<void> renameVkPlaylist(
  VkApiCall call,
  String playlistKey,
  String title,
) async {
  final (:owner, :id) = splitVkKey(playlistKey);
  final reply = await call('audio.editPlaylist', {
    'owner_id': owner,
    'playlist_id': id,
    'title': title,
  });
  if (reply != 1 && reply != true) {
    throw const VkEditRefused('rename the playlist');
  }
}

/// Puts the song [songRef] ([vkSongRef]) on top of the playlist
/// [playlistKey]. False when VK took nothing (an empty reply: a removed
/// copy's key, probe-edits-28h).
Future<bool> addToVkPlaylist(
  VkApiCall call,
  String playlistKey,
  String songRef,
) async {
  final (:owner, :id) = splitVkKey(playlistKey);
  final reply = await call('audio.addToPlaylist', {
    'owner_id': owner,
    'playlist_id': id,
    'audio_ids': songRef,
  });
  if (reply is! List) throw const VkEditRefused('add the song');
  return reply.isNotEmpty;
}

/// Takes the song [songKey] (its key as the playlist read gives it) out of
/// the playlist [playlistKey]. False when it was not there (VK answers 0).
Future<bool> removeFromVkPlaylist(
  VkApiCall call,
  String playlistKey,
  String songKey,
) async {
  final (:owner, :id) = splitVkKey(playlistKey);
  final reply = await call('audio.removeFromPlaylist', {
    'owner_id': owner,
    'playlist_id': id,
    'audio_ids': songKey,
  });
  if (reply == 0 || reply == false) return false;
  if (reply != 1 && reply != true) {
    throw const VkEditRefused('take the song out');
  }
  return true;
}

/// Moves the song [songKey] of the playlist [playlistKey] just before
/// [beforeKey], or just after [afterKey] (keys as the playlist read gives
/// them).
Future<void> moveInVkPlaylist(
  VkApiCall call,
  String playlistKey,
  String songKey, {
  String? beforeKey,
  String? afterKey,
}) async {
  if ((beforeKey == null) == (afterKey == null)) {
    throw ArgumentError('give one of beforeKey and afterKey');
  }
  // audio.reorder takes the song's owner, not the playlist's (they are the
  // same for a made playlist: its songs are the account's or its copies).
  final (owner: _, :id) = splitVkKey(playlistKey);
  final song = splitVkKey(songKey);
  final reply = await call('audio.reorder', {
    'owner_id': song.owner,
    'audio_id': song.id,
    if (beforeKey != null) 'before': splitVkKey(beforeKey).id,
    if (afterKey != null) 'after': splitVkKey(afterKey).id,
    'playlist_id': id,
  });
  if (reply != 1 && reply != true) {
    throw const VkEditRefused('move the song');
  }
}

/// Deletes the playlist [playlistKey] on VK. For a followed playlist (the
/// account's own copy) this is "unfollow": the original stays.
Future<void> deleteVkPlaylist(VkApiCall call, String playlistKey) async {
  final (:owner, :id) = splitVkKey(playlistKey);
  final reply = await call('audio.deletePlaylist', {
    'owner_id': owner,
    'playlist_id': id,
  });
  if (reply != 1 && reply != true) {
    throw const VkEditRefused('delete the playlist');
  }
}

/// The playlist [playlistKey] as VK has it now (title, count, update time);
/// null when VK no longer has it.
Future<VkPlaylist?> fetchVkPlaylist(
  VkApiCall call,
  String playlistKey, {
  String? accessKey,
}) async {
  final (:owner, :id) = splitVkKey(playlistKey);
  final reply = await call('audio.getPlaylistById', {
    'owner_id': owner,
    'playlist_id': id,
    'access_key': ?accessKey,
  });
  return vkPlaylistOf(reply);
}

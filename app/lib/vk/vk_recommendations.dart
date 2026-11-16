/// What VK recommends to an account (plan 07, C1): the lists VK makes for
/// it each day, the "Similar to `song`" shelves of its music page, VK Mix,
/// songs similar to any one song, and the dislike VK's own app sends.
///
/// Everything here reads, apart from [dislikeVkSong] and [undislikeVkSong],
/// which only set VK's dislike mark on one song (A6). Answer shapes as real
/// VK gave them on the test account, 2026-11-16 and 2026-11-17
/// (tool/probe_recommendations.dart, tool/probe_recs_feedback.dart; scrubbed
/// copies in test/fixtures/vk_recommendations):
/// - `catalog.getAudio {need_blocks: 1}`: `{catalog: {default_section,
///   sections: [{id, title, blocks}]}, audios: [audio], playlists:
///   [playlist], audio_stream_mixes: [...]}`. The default section's blocks
///   come in pairs: a `header` block with the shelf's title, then the block
///   that holds it (`music_audios` with `audios_ids: ["owner_id"]`,
///   `music_playlists` with `playlists_ids`). VK's own lists for the
///   account are the playlists of type `generated`, owned by the account,
///   with small negative ids; the page says nothing reliable about their
///   songs, only `audio.get` of the list does.
/// - `audio.get {owner_id, album_id, access_key}` of a list: `{count,
///   items}`, items shaped as the library's songs.
/// - `audio.getStreamMixAudios {mix_id: common}`: a bare list of 2-3 new
///   songs each call.
/// - `audio.getRecommendations {target_audio}`: `{count, items}`; count 0
///   for an upload with no VK track id, an unknown id or any other text.
/// - `audio.addDislike` / `audio.removeDislike {audio_ids}`: the number 1.
/// - Songs that cannot play come with `url: ""` and `content_restricted`.
library;

import '../library/library_store.dart';
import 'vk_album.dart';
import 'vk_client.dart';
import 'vk_sync.dart';

/// Which of VK's own lists a list is; [other] for a list VK may add later.
enum VkListKind { forYou, discoveries, newReleases, daily, other }

/// One list VK made for the account ("Made by algorithms").
class VkRecList {
  const VkRecList({
    required this.kind,
    required this.vkTitle,
    required this.title,
    required this.subtitle,
    required this.key,
    required this.accessKey,
    required this.updateTime,
    required this.count,
    this.coverUrl,
    this.tint,
  });

  final VkListKind kind;

  /// The name as VK sends it (Russian for the test account).
  final String vkTitle;

  /// The name the app shows: English for the lists VK names in Russian
  /// (user, 2026-11-17: "russian and english are both fine").
  final String title;

  /// VK's line under the name ("You listened to `artist`", a few
  /// artists), in English where its wording is known; may be empty.
  final String subtitle;

  /// "ownerId_listId", as `audio.get` reads it ([fetchVkListSongs]).
  final String key;
  final String? accessKey;

  /// When VK last rewrote the list, in seconds since 1970 UTC. VK rewrites
  /// the same lists in place (create_time stays), so a list whose time did
  /// not move has the same songs (A3).
  final int updateTime;

  /// The song count VK states; a hint only.
  final int count;
  final String? coverUrl;
  final int? tint;

  Map<String, Object?> toJson() => {
    'kind': kind.name,
    'vkTitle': vkTitle,
    'title': title,
    'subtitle': subtitle,
    'key': key,
    'accessKey': accessKey,
    'updateTime': updateTime,
    'count': count,
    'coverUrl': coverUrl,
    'tint': tint,
  };

  static VkRecList fromJson(Map<String, dynamic> json) => VkRecList(
    kind: VkListKind.values.asNameMap()[json['kind']] ?? VkListKind.other,
    vkTitle: json['vkTitle'] as String? ?? '',
    title: json['title'] as String? ?? '',
    subtitle: json['subtitle'] as String? ?? '',
    key: json['key'] as String,
    accessKey: json['accessKey'] as String?,
    updateTime: json['updateTime'] as int? ?? 0,
    count: json['count'] as int? ?? 0,
    coverUrl: json['coverUrl'] as String?,
    tint: json['tint'] as int?,
  );
}

/// One recommended song: the song as the library would store it, and VK's
/// reason it cannot play, if any.
class VkRecSong {
  const VkRecSong(this.song, {this.restricted});

  final NewTrack song;

  /// VK's `content_restricted` code of a song VK gives no file for
  /// ([vkRestrictionLabel]); null for a song that plays.
  final int? restricted;

  bool get playable => restricted == null;

  String get key => song.sourceKey;
}

/// A shelf of songs on the music page, such as "Similar to `song`".
class VkSongShelf {
  const VkSongShelf({
    required this.title,
    required this.songs,
    this.blockId,
    this.nextFrom,
  });

  final String title;
  final List<VkRecSong> songs;

  /// The block and the mark `catalog.getBlockItems` continues it from;
  /// null when VK gives no next page.
  final String? blockId;
  final String? nextFrom;
}

/// What the music page recommends.
class VkMusicPage {
  const VkMusicPage({
    required this.lists,
    required this.similar,
    required this.hasMix,
  });

  /// VK's own lists for the account, in the page's order.
  final List<VkRecList> lists;

  /// The "Similar to `song`" shelves, titles in English.
  final List<VkSongShelf> similar;

  /// Whether the page offers VK Mix.
  final bool hasMix;
}

/// The words a row shows for a song VK gives no file for, by VK's code
/// (the popups read in A3); null when [code] is null.
String? vkRestrictionLabel(int? code) => switch (code) {
  null => null,
  1 => 'Unavailable on VK',
  2 => 'Not in your region',
  3 => 'Subscription only',
  5 => 'Not released yet',
  _ => 'Not available',
};

/// The longer reason, for a tooltip.
String? vkRestrictionReason(int? code) => switch (code) {
  null => null,
  1 =>
    'The musician or their representative made this song unavailable '
        'on VK.',
  2 =>
    'VK does not offer this song in your region (the musician decided). '
        'A VPN can cause this too.',
  3 => 'VK offers this song only with a subscription.',
  5 => 'VK will open this song after its official release.',
  _ => 'VK gives no file for this song.',
};

/// [item], a song from a recommendation reply, as a [VkRecSong]; null for
/// an item without a usable id.
VkRecSong? vkRecSongOf(Object? item) {
  if (item is! Map<String, dynamic>) return null;
  if (item['id'] is! int || item['owner_id'] is! int) return null;
  final url = item['url'] as String? ?? '';
  final code = item['content_restricted'];
  return VkRecSong(
    vkItemToTrack(item),
    restricted: url.isEmpty ? (code is int ? code : 0) : null,
  );
}

/// The songs of a reply that is `{items: [...]}` or a bare list, each key
/// once.
List<VkRecSong> vkRecSongsOf(Object? reply) {
  final items = switch (reply) {
    {'items': final List items} => items,
    final List items => items,
    _ => const [],
  };
  final seen = <String>{};
  return [
    for (final item in items)
      if (vkRecSongOf(item) case final song? when seen.add(song.key)) song,
  ];
}

/// The songs of a reply's `audios` list by their key.
Map<String, VkRecSong> _songsByKey(Object? items) {
  final songs = <String, VkRecSong>{};
  for (final item in items is List ? items : const []) {
    final song = vkRecSongOf(item);
    if (song != null) songs[song.key] = song;
  }
  return songs;
}

const _similarPrefix = 'Похоже на ';
const _listenedPrefix = 'Вы слушали: ';

/// English names for the lists VK names in Russian.
(VkListKind, String) _listName(String vkTitle) {
  final daily = RegExp(r'^Плейлист дня (\d+)$').firstMatch(vkTitle);
  if (daily != null) return (VkListKind.daily, 'Daily playlist ${daily[1]}');
  return switch (vkTitle) {
    'Для вас' => (VkListKind.forYou, 'For you'),
    'Открытия' => (VkListKind.discoveries, 'Discoveries'),
    'Новинки' => (VkListKind.newReleases, 'New releases'),
    _ => (VkListKind.other, vkTitle),
  };
}

/// VK's texts, with the no-break spaces VK puts after short words made
/// plain spaces.
String _plain(Object? text) => '${text ?? ''}'.replaceAll(' ', ' ').trim();

String _subtitle(String vkSubtitle) {
  if (vkSubtitle.startsWith(_listenedPrefix)) {
    return 'You listened to ${vkSubtitle.substring(_listenedPrefix.length)}';
  }
  return switch (vkSubtitle) {
    'В вашем вкусе' => 'In your taste',
    _ => vkSubtitle.replaceAll(' и другие', ' and others'),
  };
}

/// Reads the music page's reply ([fetchVkMusicPage]); [me] is the
/// account's VK id, the owner of its generated lists.
VkMusicPage parseVkMusicPage(Object? reply, {required int me}) {
  if (reply is! Map<String, dynamic>) {
    return const VkMusicPage(lists: [], similar: [], hasMix: false);
  }
  final songs = _songsByKey(reply['audios']);
  final lists = <VkRecList>[];
  for (final item in reply['playlists'] as List? ?? const []) {
    if (item is! Map<String, dynamic>) continue;
    if (item['type'] != 'generated' || item['owner_id'] != me) continue;
    if (item['id'] is! int) continue;
    final vkTitle = _plain(item['title']);
    final (kind, title) = _listName(vkTitle);
    final photo = item['photo'];
    lists.add(
      VkRecList(
        kind: kind,
        vkTitle: vkTitle,
        title: title,
        subtitle: _subtitle(_plain(item['subtitle'])),
        key: '${item['owner_id']}_${item['id']}',
        accessKey: item['access_key'] as String?,
        updateTime: item['update_time'] as int? ?? 0,
        count: item['count'] as int? ?? 0,
        coverUrl: photo is Map ? photo['photo_300'] as String? : null,
        tint: parseVkColor(item['main_color']),
      ),
    );
  }
  final catalog = reply['catalog'];
  final sections = catalog is Map ? catalog['sections'] as List? : null;
  final main = (sections ?? const []).whereType<Map>().firstWhere(
    (s) => catalog is Map && s['id'] == catalog['default_section'],
    orElse: () => const {},
  );
  final similar = <VkSongShelf>[];
  String? header;
  for (final block in main['blocks'] as List? ?? const []) {
    if (block is! Map) continue;
    final layout = block['layout'];
    final title = layout is Map && layout['title'] is String
        ? _plain(layout['title'])
        : null;
    if (block['data_type'] == 'none') {
      // A separator ends a shelf; a header starts the next one.
      if (title != null || layout is Map && layout['name'] == 'separator') {
        header = title;
      }
      continue;
    }
    final name = header;
    header = null;
    if (block['data_type'] != 'music_audios' || name == null) continue;
    if (!name.startsWith(_similarPrefix)) continue;
    similar.add(
      VkSongShelf(
        title: 'Similar to ${name.substring(_similarPrefix.length)}',
        songs: [
          for (final id in block['audios_ids'] as List? ?? const [])
            ?songs['$id'],
        ],
        blockId: block['id'] as String?,
        nextFrom: block['next_from'] as String?,
      ),
    );
  }
  return VkMusicPage(
    lists: lists,
    similar: similar,
    hasMix: (reply['audio_stream_mixes'] as List? ?? const []).isNotEmpty,
  );
}

/// The music page as VK's web client loads it (2-3 s; once a 504 after
/// 30 s, so callers keep the last page).
Future<VkMusicPage> fetchVkMusicPage(VkApiCall call, {required int me}) async {
  final reply = await call('catalog.getAudio', {'need_blocks': '1'});
  return parseVkMusicPage(reply, me: me);
}

/// The songs of [list] in VK's order (100 or about 50; 0.5-2 s).
Future<List<VkRecSong>> fetchVkListSongs(VkApiCall call, VkRecList list) async {
  final items = await fetchVkAlbumItems(
    call,
    list.key,
    accessKey: list.accessKey,
    pageSize: 100,
    limit: 300,
  );
  return vkRecSongsOf(items);
}

/// The next songs of a shelf ("Similar to" songs past the first 18).
Future<VkSongShelf> fetchVkShelfMore(VkApiCall call, VkSongShelf shelf) async {
  final blockId = shelf.blockId;
  final nextFrom = shelf.nextFrom;
  if (blockId == null || nextFrom == null) return shelf;
  final reply = await call('catalog.getBlockItems', {
    'block_id': blockId,
    'start_from': nextFrom,
  });
  if (reply is! Map<String, dynamic>) return shelf;
  final songs = _songsByKey(reply['audios']);
  final block = reply['block'];
  final ids = block is Map ? block['audios_ids'] as List? : null;
  final known = {for (final song in shelf.songs) song.key};
  return VkSongShelf(
    title: shelf.title,
    songs: [
      ...shelf.songs,
      for (final id in ids ?? const [])
        if (songs['$id'] case final song? when known.add(song.key)) song,
    ],
    blockId: blockId,
    nextFrom: block is Map ? block['next_from'] as String? : null,
  );
}

/// The next VK Mix songs: 2-3 new ones each call, never the same twice
/// (A1: 4 calls, nothing repeated).
Future<List<VkRecSong>> fetchVkMixSongs(VkApiCall call) async => vkRecSongsOf(
  await call('audio.getStreamMixAudios', {'mix_id': 'common', 'count': '10'}),
);

/// Up to [count] songs VK finds similar to the song [sourceKey]
/// ("ownerId_audioId"; no access key needed, C5 probe). Asked again, VK
/// gives 24-25 of 30 the same and a few new, and an offset does not page:
/// more songs come from asking again. Empty for an upload VK has no track
/// id for ([similarTargetOf] looks for a copy that has one).
Future<List<VkRecSong>> fetchVkSimilarSongs(
  VkApiCall call,
  String sourceKey, {
  int count = 30,
}) async => vkRecSongsOf(
  await call('audio.getRecommendations', {
    'target_audio': sourceKey,
    'count': '$count',
  }),
);

/// The VK song whose similar songs stand for [song]'s: [song] itself when
/// VK knows its recording (it has a track id), else the first VK search
/// hit with the same artist and title that has one (7 of 11 such uploads
/// on the test account, C5 probe); null when there is none.
Future<String?> similarTargetOf(
  VkApiCall call, {
  required String artist,
  required String title,
  String? sourceKey,
  bool hasTrackId = false,
}) async {
  if (sourceKey != null && hasTrackId) return sourceKey;
  String words(String text) => text.toLowerCase().trim();
  final reply = await call('audio.search', {
    'q': '$artist $title',
    'count': '10',
  });
  final items = switch (reply) {
    {'items': final List items} => items,
    _ => const [],
  };
  for (final item in items.whereType<Map<String, dynamic>>()) {
    final trackId = item['track_id'];
    if (trackId == null || trackId == 0) continue;
    if (words('${item['artist']}') != words(artist)) continue;
    if (words('${item['title']}') != words(title)) continue;
    if (item['id'] is int && item['owner_id'] is int) return vkSourceKey(item);
  }
  return null;
}

/// Tells VK the account does not like the song [sourceKey], as VK's own
/// app does; the song then carries `dislike: true` (A6, test account).
Future<void> dislikeVkSong(VkApiCall call, String sourceKey) =>
    call('audio.addDislike', {'audio_ids': sourceKey});

/// Takes back [dislikeVkSong].
Future<void> undislikeVkSong(VkApiCall call, String sourceKey) =>
    call('audio.removeDislike', {'audio_ids': sourceKey});

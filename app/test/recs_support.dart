// A fake VK account for the recommendation tests (plan 07): its music page,
// its lists, VK Mix and similar songs, built from the replies real VK gave
// the test account (test/fixtures/vk_recommendations). Made-up songs use
// only fields real songs carry; vk_recommendations_test.dart checks that.

import 'dart:convert';
import 'dart:io';

const recFixtures = 'test/fixtures/vk_recommendations';

/// A recorded reply, decoded.
Object? recFixture(String name) =>
    jsonDecode(File('$recFixtures/$name.json').readAsStringSync());

/// The account id the fixtures' generated lists belong to (scrubbed).
const recFixtureMe = 10000;

/// One made-up recommended song, shaped as the recorded ones: a song that
/// plays has a link; one VK gives no file for has `url: ""` and its
/// `content_restricted` code.
Map<String, dynamic> recSong(
  int owner,
  int id, {
  String artist = 'Кино',
  String title = 'Закрой за мной дверь',
  int duration = 205,
  int? trackId,
  int? restricted,
}) => {
  'artist': artist,
  'id': id,
  'owner_id': owner,
  'title': title,
  'duration': duration,
  'access_key': 'key$id',
  'url': restricted == null ? 'https://example.invalid/$id.mp3' : '',
  'date': 1671521900,
  'track_id': ?trackId,
  'content_restricted': ?restricted,
};

/// A fake `VkApiCall` answering from the fixtures, with [overrides] by
/// method; every call is logged in [calls] as "method params".
class RecsVk {
  RecsVk({this.overrides = const {}});

  final Map<String, Object? Function(Map<String, String> params)> overrides;
  final calls = <String>[];

  Future<Object?> call(String method, Map<String, String> params) async {
    calls.add(
      '$method ${params.entries.map((e) => '${e.key}=${e.value}').join(' ')}',
    );
    final override = overrides[method];
    if (override != null) return override(params);
    return switch (method) {
      'catalog.getAudio' => recFixture('catalog_get_audio'),
      'audio.get' => recFixture('audio_get_generated_playlist'),
      'audio.getStreamMixAudios' => recFixture('audio_get_stream_mix_audios'),
      'audio.getRecommendations' => recFixture(
        'audio_get_recommendations_target_found',
      ),
      'catalog.getBlockItems' => recFixture('catalog_get_block_items'),
      'audio.addDislike' => recFixture('audio_add_dislike'),
      'audio.removeDislike' => recFixture('audio_remove_dislike'),
      _ => throw StateError('no fake for $method'),
    };
  }
}

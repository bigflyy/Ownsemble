// A fake VK account for the On VK part's tests: what its searches find and
// what its adds answer, in the shapes real VK gave on 2026-11-08 (C1). And a
// player that shows a song as playing without opening any audio.

import 'dart:async';

import 'package:ownsemble/library/track.dart';
import 'package:ownsemble/playback/player_service.dart';

/// A player that "plays" a song by showing it, without opening any audio.
class ShowingPlayer extends PlayerService {
  ShowingPlayer() : super(muted: true, dataDir: '.');

  Track? _shown;
  final _shows = StreamController<Track?>.broadcast();

  @override
  bool get isReady => true;
  @override
  Track? get current => _shown;
  @override
  bool get currentLoaded => _shown != null;
  @override
  Stream<Track?> get currentStream => _shows.stream;
  @override
  Stream<Duration> get positions => const Stream.empty();

  @override
  Future<PlayTiming> play(Track track, {Duration? from}) async {
    _shown = track;
    _shows.add(track);
    playing.value = true;
    return PlayTiming(ok: true, cached: false, resolveMs: 0, toSoundMs: 1);
  }

  @override
  void adopt(Track track) {
    if (_shown == null || _shown!.id == track.id) return;
    _shown = track;
    _shows.add(track);
  }

  /// Clicks that paused or resumed the song.
  var pauseToggles = 0;

  @override
  Future<void> playOrPause() async => pauseToggles++;
}

/// One VK song as `audio.search` lists it.
Map<String, dynamic> vkAudio(
  int owner,
  int id, {
  String artist = 'Кино',
  String title = 'Звезда по имени Солнце',
  int duration = 225,
  int? trackId,
}) => {
  'owner_id': owner,
  'id': id,
  'artist': artist,
  'title': title,
  'duration': duration,
  'date': 1762600000 + id,
  'access_key': 'key$id',
  'url': 'https://audio.invalid/$id.mp3',
  'track_id': ?trackId,
};

/// One account's side of VK: what its searches find and what it adds.
class FakeVk {
  FakeVk(this.userId);

  final int userId;

  /// The catalog, in VK's order.
  final catalog = <Map<String, dynamic>>[];

  /// Searches asked, as "query@offset".
  final searches = <String>[];

  /// Adds asked, as "owner_id_audio_id key".
  final adds = <String>[];

  /// The next add's answer is a refusal with this code text.
  String? refuseWith;

  /// The next search throws this.
  Object? searchFails;

  var _nextId = 900;

  Future<Object?> call(String method, Map<String, String> params) async {
    switch (method) {
      case 'audio.search':
        searches.add('${params['q']}@${params['offset']}');
        final fail = searchFails;
        if (fail != null) {
          searchFails = null;
          throw fail;
        }
        final offset = int.parse(params['offset']!);
        final count = int.parse(params['count']!);
        return {
          'count': catalog.length,
          'items': catalog.skip(offset).take(count).toList(),
        };
      case 'audio.add':
        adds.add(
          '${params['owner_id']}_${params['audio_id']} '
          '${params['access_key']}',
        );
        final refusal = refuseWith;
        if (refusal != null) {
          refuseWith = null;
          return {
            'items_count': 0,
            'errors_count': 1,
            'items': <Object>[],
            'errors': [
              {
                'audio_raw_id': '${params['owner_id']}_${params['audio_id']}',
                'error_code': refusal,
                'error_msg': 'no access to audio',
              },
            ],
          };
        }
        return {
          'items_count': 1,
          'errors_count': 0,
          'items': [
            {
              'new_audio_id': _nextId++,
              'new_owner_id': userId,
              'audio_raw_id': '${params['owner_id']}_${params['audio_id']}',
            },
          ],
          'errors': <Object>[],
        };
    }
    throw StateError('unexpected $method');
  }
}

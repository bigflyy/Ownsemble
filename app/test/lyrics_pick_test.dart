// Tests for plan 10 E1: the automatic pick over VK and the outside sources
// (VK -> LRCLIB -> NetEase + QQ, "timed first"), with stored answers reused
// and fakes for every source. The words are made up.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:ownsemble/library/library_records.dart' show StoredLyrics;
import 'package:ownsemble/library/track.dart';
import 'package:ownsemble/lyrics/lyrics.dart';
import 'package:ownsemble/lyrics/lyrics_controller.dart';
import 'package:ownsemble/lyrics/lyrics_match.dart';
import 'package:ownsemble/lyrics/lyrics_sources.dart';
import 'package:ownsemble/vk/vk_client.dart';

const day = 24 * 60 * 60 * 1000;

Lyrics timedOf(String source) => Lyrics(
  source: source,
  lines: const [
    LyricLine('Раз', startMs: 1000),
    LyricLine('Два', startMs: 2000),
    LyricLine('Три', startMs: 3000),
  ],
);

Lyrics plainOf(String source) =>
    Lyrics(source: source, lines: const [LyricLine('Слова'), LyricLine('ещё')]);

Track song() => Track(
  id: 1,
  sourceId: 1,
  source: TrackSource.vk,
  artist: 'Ночные Тени',
  title: 'Город спит',
  album: 'Альбом',
  durationSec: 200,
  sourceKey: '1_1',
  addedAt: 0,
);

/// An outside source that answers what [answer] says and counts its asks.
class FakeSource implements OutsideLyricsSource {
  FakeSource(this.id);

  @override
  final String id;

  /// Lyrics (timed or plain) as a candidate, null for none, or an error.
  Object? answer;
  NameMatch names = NameMatch.exact;
  int lengthDiff = 0;
  Completer<void>? hold;
  final asked = <SongNames>[];

  @override
  Future<LyricsCandidate?> find(SongNames song) async {
    asked.add(song);
    await hold?.future;
    final result = answer;
    if (result is Exception) throw result;
    if (result is! Lyrics) return null;
    return LyricsCandidate(
      lyrics: result,
      id: '$id-1',
      artist: song.artist,
      title: song.title,
      seconds: song.seconds + lengthDiff,
      names: names,
      lengthDiff: lengthDiff,
    );
  }
}

class Fixture {
  final stored = <String, StoredLyrics>{};
  final vkAsked = <String>[];
  int nowMs = 100 * day;
  final lrclib = FakeSource('lrclib');
  final netease = FakeSource('netease');
  final qq = FakeSource('qq');
  final shown = <LyricsState>[];

  /// VK's answer: Lyrics, null for none, or an error to throw.
  Object? vk;
  bool loggedIn = true;

  late final LyricsController controller = build();

  LyricsController build() => LyricsController(
    load: (source, ref) => stored['$source:$ref'],
    save: (source, ref, lyrics, {md5, meta}) => stored['$source:$ref'] = (
      lyrics: lyrics,
      md5: md5,
      fetchedAtMs: nowMs,
      meta: meta,
    ),
    routeOf: (track) => (
      key: track.sourceKey!,
      accessKey: null,
      call: loggedIn
          ? (method, params) async {
              vkAsked.add(params['audio_id']!);
              final answer = vk;
              if (answer is Exception) throw answer;
              if (answer is Lyrics) return vkReply(answer);
              throw VkException('audio.getLyrics error 104', code: 104);
            }
          : null,
    ),
    sources: [lrclib, netease, qq],
    now: () => nowMs,
  )..addListener(() => shown.add(controller.state));

  Lyrics? get lyrics => switch (controller.state) {
    LyricsShown(:final lyrics) => lyrics,
    _ => null,
  };
}

Map<String, Object?> vkReply(Lyrics lyrics) => {
  'md5': 'm',
  'lyrics': lyrics.timed
      ? {
          'timestamps': [
            for (final line in lyrics.lines)
              {'begin': line.startMs, 'end': null, 'line': line.text},
          ],
        }
      : {
          'text': [for (final line in lyrics.lines) line.text],
        },
};

void main() {
  test('VK timed: outside sources are never asked', () async {
    final f = Fixture()..vk = timedOf('vk');
    f.controller.show(song());
    await pumpEventQueue();
    expect(f.lyrics!.source, 'vk');
    expect(f.lrclib.asked, isEmpty);
    expect(f.netease.asked, isEmpty);
  });

  test('VK plain shows first, then LRCLIB timed replaces it', () async {
    final f = Fixture()
      ..vk = plainOf('vk')
      ..lrclib.answer = timedOf('lrclib')
      ..lrclib.hold = Completer<void>();
    f.controller.show(song());
    await pumpEventQueue();
    final early = f.controller.state as LyricsShown;
    expect(early.lyrics.source, 'vk');
    expect(early.refreshing, isTrue);
    f.lrclib.hold!.complete();
    await pumpEventQueue();
    final shown = f.controller.state as LyricsShown;
    expect(shown.lyrics.source, 'lrclib');
    expect(shown.refreshing, isFalse);
    expect(f.lrclib.asked.single.title, 'Город спит');
    expect(f.lrclib.asked.single.seconds, 200);
    expect(f.netease.asked, isEmpty, reason: 'LRCLIB gave timed lyrics');
    expect(f.stored['lrclib:1_1']!.meta, contains('"exact":true'));
  });

  test('VK plain beats outside plain', () async {
    final f = Fixture()
      ..vk = plainOf('vk')
      ..lrclib.answer = plainOf('lrclib')
      ..netease.answer = plainOf('netease');
    f.controller.show(song());
    await pumpEventQueue();
    expect(f.lyrics!.source, 'vk');
    expect(f.qq.asked, hasLength(1), reason: 'no timed lyrics yet: all asked');
  });

  test('NetEase and QQ together; exact names before a closer length', () async {
    final f = Fixture()
      ..netease.answer = timedOf('netease')
      ..netease.lengthDiff = 2
      ..qq.answer = timedOf('qq')
      ..qq.names = NameMatch.loose;
    f.controller.show(song());
    await pumpEventQueue();
    expect(f.lyrics!.source, 'netease');
    expect(f.vkAsked, ['1_1']);
    expect(f.lrclib.asked, hasLength(1));
    expect(f.qq.asked, hasLength(1));
  });

  test('stored answers show at once and offline, without asking', () async {
    final f = Fixture()
      ..vk = plainOf('vk')
      ..lrclib.answer = timedOf('lrclib');
    f.controller.show(song());
    await pumpEventQueue();
    final again = Fixture()..stored.addAll(f.stored);
    again.nowMs = f.nowMs + 60 * day;
    again.loggedIn = false;
    again.controller.show(song());
    expect(again.lyrics!.source, 'lrclib');
    await pumpEventQueue();
    expect(again.lrclib.asked, isEmpty, reason: 'outside lyrics kept');
    expect(again.lyrics!.source, 'lrclib');
  });

  test('an outside "none" is asked again after 7 days', () async {
    final f = Fixture()..vk = plainOf('vk');
    f.controller.show(song());
    await pumpEventQueue();
    expect(f.lrclib.asked, hasLength(1));
    final soon = Fixture()
      ..stored.addAll(f.stored)
      ..nowMs = f.nowMs + 6 * day;
    soon.controller.show(song());
    await pumpEventQueue();
    expect(soon.lrclib.asked, isEmpty);
    expect(soon.lyrics!.source, 'vk');
    final later = Fixture()
      ..stored.addAll(f.stored)
      ..nowMs = f.nowMs + 8 * day
      ..lrclib.answer = timedOf('lrclib');
    later.controller.show(song());
    await pumpEventQueue();
    expect(later.lrclib.asked, hasLength(1));
    expect(later.vkAsked, isEmpty, reason: 'VK plain still fresh');
    expect(later.lyrics!.source, 'lrclib');
  });

  test('VK logged out or failing does not hide outside lyrics', () async {
    final f = Fixture()
      ..loggedIn = false
      ..lrclib.answer = plainOf('lrclib');
    f.controller.show(song());
    await pumpEventQueue();
    expect(f.lyrics!.source, 'lrclib');
  });

  test('nothing found and a failure: VK names the reason', () async {
    final f = Fixture()
      ..vk = VkException('x', code: 9)
      ..lrclib.answer = const LyricsSourceException('timeout');
    f.controller.show(song());
    await pumpEventQueue();
    final failed = f.controller.state as LyricsFailed;
    expect(failed.slowDown, isTrue);
    expect(failed.reason, contains('VK'));
  });

  test('only an outside failure: its reason; Retry asks again', () async {
    final f = Fixture()
      ..lrclib.answer = const LyricsSourceException(
        'status 429',
        slowDown: true,
      );
    f.controller.show(song());
    await pumpEventQueue();
    final failed = f.controller.state as LyricsFailed;
    expect(failed.slowDown, isTrue);
    expect(failed.reason, contains('lyrics sources'));
    expect(f.stored.containsKey('lrclib:1_1'), isFalse, reason: 'not stored');
    f.lrclib.answer = timedOf('lrclib');
    f.controller.retry();
    await pumpEventQueue();
    expect(f.lyrics!.source, 'lrclib');
    expect(f.vkAsked, hasLength(1), reason: "VK's none is stored");
  });

  test('none anywhere: missing, and every source stored as none', () async {
    final f = Fixture();
    f.controller.show(song());
    await pumpEventQueue();
    expect(f.controller.state, isA<LyricsMissing>());
    expect(
      f.stored.keys,
      unorderedEquals(['vk:1_1', 'lrclib:1_1', 'netease:1_1', 'qq:1_1']),
    );
    expect(f.stored.values.every((row) => row.lyrics == null), isTrue);
  });

  test('a download walks the outside sources too', () async {
    final f = Fixture()
      ..vk = plainOf('vk')
      ..lrclib.answer = timedOf('lrclib');
    await f.controller.keepFor(song());
    expect(f.stored['lrclib:1_1']!.lyrics!.timed, isTrue);
    await f.controller.keepFor(song());
    expect(f.lrclib.asked, hasLength(1), reason: 'timed lyrics are stored');
  });

  test('a song changed during the walk gets no late update', () async {
    final f = Fixture()
      ..lrclib.answer = timedOf('lrclib')
      ..lrclib.hold = Completer<void>();
    f.controller.show(song());
    await pumpEventQueue();
    f.controller.show(null);
    f.lrclib.hold!.complete();
    await pumpEventQueue();
    expect(f.controller.state, isA<LyricsLoading>());
    expect(f.stored['lrclib:1_1']!.lyrics, isNotNull, reason: 'still kept');
  });
}

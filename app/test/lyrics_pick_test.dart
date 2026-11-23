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

  /// Answers lyrics of another version of the song (G4a).
  bool otherVersion = false;
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
      otherVersion: otherVersion,
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

  /// The user's kept choices (LibraryStore.lyricsPickOf).
  final picks = <String, String>{};

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
    loadPick: (ref) => picks[ref],
    savePick: (ref, source) =>
        source == null ? picks.remove(ref) : picks[ref] = source,
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

  group('another version (G4b)', () {
    test('only another version: shown, and every source was asked', () async {
      final f = Fixture()
        ..lrclib.answer = timedOf('lrclib')
        ..lrclib.otherVersion = true
        ..lrclib.lengthDiff = 3651;
      f.controller.show(song());
      await pumpEventQueue();
      expect(f.lyrics!.source, 'lrclib');
      expect(f.stored['lrclib:1_1']!.meta, contains('"other":true'));
      expect(f.netease.asked, hasLength(1), reason: 'the walk went on');
      expect(f.qq.asked, hasLength(1));
    });

    test("words of the song's own length beat another version timed", () async {
      final f = Fixture()
        ..lrclib.answer = timedOf('lrclib')
        ..lrclib.otherVersion = true
        ..lrclib.lengthDiff = 30
        ..netease.answer = plainOf('netease');
      f.controller.show(song());
      await pumpEventQueue();
      expect(f.lyrics!.source, 'netease');
      expect(f.lyrics!.timed, isFalse);
    });

    test('VK words beat another version timed', () async {
      final f = Fixture()
        ..vk = plainOf('vk')
        ..netease.answer = timedOf('netease')
        ..netease.otherVersion = true
        ..netease.lengthDiff = 12;
      f.controller.show(song());
      await pumpEventQueue();
      expect(f.lyrics!.source, 'vk');
    });

    test('the closer of two other versions; stored, the rest is still '
        'asked', () async {
      final f = Fixture()
        ..lrclib.answer = timedOf('lrclib')
        ..lrclib.otherVersion = true
        ..lrclib.lengthDiff = 40
        ..netease.answer = timedOf('netease')
        ..netease.otherVersion = true
        ..netease.lengthDiff = 8;
      f.controller.show(song());
      await pumpEventQueue();
      expect(f.lyrics!.source, 'netease');

      // Next time only another version is stored, and QQ's answer is
      // forgotten: QQ is asked again, LRCLIB and NetEase are not.
      f.stored.remove('qq:1_1');
      f.qq.answer = timedOf('qq');
      final again = Fixture()
        ..stored.addAll(f.stored)
        ..qq.answer = timedOf('qq');
      again.controller.show(song());
      await pumpEventQueue();
      expect(again.lrclib.asked, isEmpty);
      expect(again.qq.asked, hasLength(1));
      expect(again.lyrics!.source, 'qq', reason: 'QQ has the own length');
    });
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

  group('chooser (E2)', () {
    test(
      'lists every source: found best first, then none and not asked',
      () async {
        final f = Fixture()
          ..vk = plainOf('vk')
          ..lrclib.answer = timedOf('lrclib');
        f.controller.show(song());
        await pumpEventQueue();
        final choices = f.controller.choices;
        expect(
          [for (final c in choices) c.source],
          ['lrclib', 'vk', 'netease', 'qq'],
        );
        expect(choices[0].status, LyricsChoiceStatus.found);
        expect(choices[0].title, 'Город спит');
        expect(choices[0].lengthDiff, 0);
        expect(choices[0].exact, isTrue);
        expect(choices[1].artist, 'Ночные Тени', reason: "VK: the song's own");
        expect(choices[2].status, LyricsChoiceStatus.notAsked);
        expect(f.controller.automatic, 'lrclib');
        expect(f.controller.chosen, isNull);
      },
    );

    test('askAll asks only the sources not asked yet, each shown', () async {
      final f = Fixture()
        ..vk = plainOf('vk')
        ..lrclib.answer = timedOf('lrclib')
        ..netease.answer = timedOf('netease')
        ..qq.hold = Completer<void>();
      f.controller.show(song());
      await pumpEventQueue();
      final asking = f.controller.askAll();
      await pumpEventQueue();
      expect(f.lrclib.asked, hasLength(1), reason: 'stored: not asked again');
      expect(f.vkAsked, hasLength(1));
      final mid = {for (final c in f.controller.choices) c.source: c};
      expect(mid['netease']!.status, LyricsChoiceStatus.found);
      expect(mid['qq']!.status, LyricsChoiceStatus.asking);
      f.qq.hold!.complete();
      await asking;
      final after = {for (final c in f.controller.choices) c.source: c};
      expect(after['qq']!.status, LyricsChoiceStatus.none);
      expect(f.lyrics!.source, 'lrclib', reason: 'the automatic pick stays');
    });

    test(
      'askAll again keeps found lyrics when a source now says none',
      () async {
        final f = Fixture()..lrclib.answer = timedOf('lrclib');
        f.controller.show(song());
        await pumpEventQueue();
        f.lrclib.answer = null;
        await f.controller.askAll(again: true);
        expect(f.lrclib.asked, hasLength(2));
        expect(f.stored['lrclib:1_1']!.lyrics, isNotNull);
        expect(f.lyrics!.source, 'lrclib');
      },
    );

    test(
      'a failed source is listed as failed, the others still found',
      () async {
        final f = Fixture()
          ..lrclib.answer = plainOf('lrclib')
          ..netease.answer = const LyricsSourceException('down');
        f.controller.show(song());
        await pumpEventQueue();
        await f.controller.askAll();
        final byId = {for (final c in f.controller.choices) c.source: c};
        expect(byId['netease']!.status, LyricsChoiceStatus.failed);
        expect(byId['lrclib']!.status, LyricsChoiceStatus.found);
        f.netease.answer = timedOf('netease');
        await f.controller.askAll();
        expect(f.netease.asked, hasLength(3), reason: 'failures asked again');
        expect(f.lyrics!.source, 'netease', reason: 'timed beats plain');
      },
    );

    test(
      'use keeps the choice, also for a new controller and offline',
      () async {
        final f = Fixture()
          ..vk = timedOf('vk')
          ..lrclib.answer = timedOf('lrclib');
        f.controller.show(song());
        await pumpEventQueue();
        await f.controller.askAll();
        expect(f.lyrics!.source, 'vk');
        f.controller.use('lrclib');
        expect(f.lyrics!.source, 'lrclib');
        expect(f.controller.chosen, 'lrclib');
        expect(f.controller.automatic, 'vk');
        expect(f.picks, {'1_1': 'lrclib'});

        final again = Fixture()
          ..stored.addAll(f.stored)
          ..picks.addAll(f.picks)
          ..loggedIn = false;
        again.nowMs = f.nowMs + 60 * day;
        again.controller.show(song());
        await pumpEventQueue();
        expect(again.lyrics!.source, 'lrclib');
        expect(again.vkAsked, isEmpty, reason: 'a choice asks nothing more');
      },
    );

    test(
      'useAutomatic forgets the choice and shows the automatic pick',
      () async {
        final f = Fixture()
          ..vk = plainOf('vk')
          ..lrclib.answer = timedOf('lrclib');
        f.controller.show(song());
        await pumpEventQueue();
        f.controller.use('vk');
        expect(f.lyrics!.source, 'vk');
        f.controller.useAutomatic();
        await pumpEventQueue();
        expect(f.lyrics!.source, 'lrclib');
        expect(f.picks, isEmpty);
        expect(f.controller.chosen, isNull);
      },
    );

    test('a choice whose lyrics are not stored is ignored', () async {
      final f = Fixture()..lrclib.answer = timedOf('lrclib');
      f.picks['1_1'] = 'qq';
      f.controller.show(song());
      await pumpEventQueue();
      expect(f.lyrics!.source, 'lrclib');
      expect(f.controller.chosen, isNull);
    });

    test('a slow chooser ask does not hold up the next song (lyrics-41a: '
        'QQ took 6 s and the next song waited)', () async {
      final f = Fixture()
        ..lrclib.answer = timedOf('lrclib')
        ..qq.hold = Completer<void>();
      f.controller.show(song());
      await pumpEventQueue();
      final choosing = f.controller.askAll();
      await pumpEventQueue();
      final next = Track(
        id: 2,
        sourceId: 1,
        source: TrackSource.vk,
        artist: 'Другой',
        title: 'Следующая',
        durationSec: 180,
        sourceKey: '1_2',
        addedAt: 0,
      );
      f.controller.show(next);
      await pumpEventQueue();
      expect(f.lyrics?.source, 'lrclib', reason: 'shown while QQ still waits');
      expect(f.controller.track!.id, 2);
      f.qq.hold!.complete();
      await choosing;
    });

    test('a choice made while the walk runs is not replaced by it', () async {
      final f = Fixture()
        ..vk = plainOf('vk')
        ..lrclib.answer = timedOf('lrclib')
        ..lrclib.hold = Completer<void>();
      f.controller.show(song());
      await pumpEventQueue();
      expect(f.lyrics!.source, 'vk');
      f.controller.use('vk');
      f.lrclib.hold!.complete();
      await pumpEventQueue();
      expect(f.lyrics!.source, 'vk');
    });
  });
}

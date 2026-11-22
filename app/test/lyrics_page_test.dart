// Tests for plan 10 C3: which lyrics the Lyrics place shows and asks for,
// and the place itself (timed lines follow the song, a click seeks, plain
// text, no lyrics, a failure with Try again, nothing playing).

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ownsemble/library/library_records.dart';
import 'package:ownsemble/library/track.dart';
import 'package:ownsemble/lyrics/lyrics.dart';
import 'package:ownsemble/lyrics/lyrics_controller.dart';
import 'package:ownsemble/ui/lyrics_page.dart';
import 'package:ownsemble/ui/theme.dart';
import 'package:ownsemble/vk/vk_client.dart';

const day = 24 * 3600 * 1000;

Track song(int id, {String key = '1_1', TrackSource source = TrackSource.vk}) =>
    Track(
      id: id,
      sourceId: 1,
      source: source,
      artist: 'Артист',
      title: 'Песня $id',
      durationSec: 200,
      sourceKey: key,
      addedAt: 0,
    );

const timed = Lyrics(
  source: 'vk',
  lines: [
    LyricLine('Первая строка', startMs: 1000, endMs: 3000),
    LyricLine('Second line', startMs: 4000, endMs: 6000),
    LyricLine('', startMs: 6500, endMs: 8800),
    LyricLine('Third line', startMs: 9000, endMs: 11000),
  ],
);

const plain = Lyrics(
  source: 'vk',
  lines: [LyricLine('Куплет один'), LyricLine(''), LyricLine('Verse two')],
);

Map<String, Object?> vkReplyOf(Lyrics lyrics) => {
  'md5': 'm',
  'lyrics': lyrics.timed
      ? {
          'timestamps': [
            for (final line in lyrics.lines)
              {
                'begin': line.startMs,
                'end': line.endMs ?? 0,
                'line': line.text,
              },
          ],
        }
      : {
          'text': [for (final line in lyrics.lines) line.text],
        },
};

/// A library stand-in and a VK stand-in that counts its calls.
class Fixture {
  final stored = <String, StoredLyrics>{};
  final asked = <String>[];
  int nowMs = 100 * day;

  /// What VK answers next: lyrics, null for none (error 104), or an error.
  Object? Function(String key) answer = (_) => null;
  Completer<void>? hold;

  late final controller = LyricsController(
    load: (source, ref) => stored['$source:$ref'],
    save: (source, ref, lyrics, {md5, meta}) => stored['$source:$ref'] = (
      lyrics: lyrics,
      md5: md5,
      fetchedAtMs: nowMs,
      meta: meta,
    ),
    routeOf: lyricsRouteBySource(
      (sourceId) => (method, params) async {
        final key = params['audio_id']!;
        asked.add(key);
        await hold?.future;
        final result = answer(key);
        if (result is Exception) throw result;
        if (result is Lyrics) return vkReplyOf(result);
        throw VkException('audio.getLyrics error 104', code: 104);
      },
    ),
    now: () => nowMs,
  );
}

Future<void> settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

void main() {
  group('LyricsController', () {
    test(
      'asks VK once, keeps the answer and shows stored lyrics after',
      () async {
        final f = Fixture()..answer = (_) => timed;
        f.controller.show(song(1));
        expect(f.controller.state, isA<LyricsLoading>());
        await pumpEventQueue();
        expect((f.controller.state as LyricsShown).lyrics, timed);
        expect(f.asked, ['1_1']);
        expect(f.stored['vk:1_1']!.lyrics, timed);

        f.controller.show(song(2, key: '2_2'));
        await pumpEventQueue();
        f.controller.show(song(1));
        expect((f.controller.state as LyricsShown).lyrics, timed);
        expect(f.asked, ['1_1', '2_2'], reason: 'stored, not asked again');
      },
    );

    test('a fresh "none" is trusted; an old one is asked again', () async {
      final f = Fixture();
      f.stored['vk:1_1'] = (
        lyrics: null,
        md5: null,
        fetchedAtMs: f.nowMs - day,
        meta: null,
      );
      f.controller.show(song(1));
      expect(f.controller.state, isA<LyricsMissing>());
      expect(f.asked, isEmpty);

      f.stored['vk:2_2'] = (
        lyrics: null,
        md5: null,
        fetchedAtMs: f.nowMs - 8 * day,
        meta: null,
      );
      f.answer = (_) => plain;
      f.controller.show(song(2, key: '2_2'));
      await pumpEventQueue();
      expect((f.controller.state as LyricsShown).lyrics, plain);
    });

    test('old lyrics show at once and are asked again quietly', () async {
      final f = Fixture()..answer = (_) => throw VkException('x', code: 5);
      f.stored['vk:1_1'] = (
        lyrics: plain,
        md5: 'm',
        fetchedAtMs: f.nowMs - 31 * day,
        meta: null,
      );
      f.controller.show(song(1));
      final shown = f.controller.state as LyricsShown;
      expect(shown.lyrics, plain);
      expect(shown.refreshing, isTrue);
      await pumpEventQueue();
      // The refresh failed: the stored lyrics stay, no error is shown.
      expect(f.controller.state, isA<LyricsShown>());
      expect((f.controller.state as LyricsShown).refreshing, isFalse);
    });

    test('flood control says to wait; Try again asks again', () async {
      final f = Fixture()
        ..answer = (_) => VkException('audio.getLyrics error 9', code: 9);
      f.controller.show(song(1));
      await pumpEventQueue();
      final failed = f.controller.state as LyricsFailed;
      expect(failed.slowDown, isTrue);

      f.answer = (_) => timed;
      f.controller.retry();
      await pumpEventQueue();
      expect(f.controller.state, isA<LyricsShown>());
      expect(f.asked, ['1_1', '1_1']);
    });

    test('an answer for a song no longer shown is dropped', () async {
      final f = Fixture()
        ..hold = Completer<void>()
        ..answer = (key) => key == '1_1' ? timed : plain;
      f.controller.show(song(1));
      f.controller.show(song(2, key: '2_2'));
      f.hold!.complete();
      await pumpEventQueue();
      expect((f.controller.state as LyricsShown).lyrics, plain);
      expect(f.controller.track!.id, 2);
      // Song 1 was no longer shown when its turn came: never asked.
      expect(f.asked, ['2_2']);
      expect(f.stored.keys, ['vk:2_2']);
    });

    test('A, B, then A again: one ask per song, one at a time, and the '
        'row of A is what VK said last', () async {
      final f = Fixture()
        ..hold = Completer<void>()
        ..answer = (key) => key == '1_1' ? timed : plain;
      f.controller.show(song(1));
      f.controller.show(song(2, key: '2_2'));
      f.controller.show(song(1));
      await pumpEventQueue();
      expect(f.asked, ['1_1'], reason: 'B waits its turn; A is shared');
      f.hold!.complete();
      await pumpEventQueue();
      expect((f.controller.state as LyricsShown).lyrics, timed);
      expect(f.asked, ['1_1'], reason: 'B was dropped: no longer shown');
      expect(f.stored['vk:1_1']!.lyrics, timed);
    });

    test('a download while the place asks shares the ask', () async {
      final f = Fixture()
        ..hold = Completer<void>()
        ..answer = (_) => timed;
      f.controller.show(song(1));
      final kept = f.controller.keepFor(song(1));
      f.hold!.complete();
      await kept;
      await pumpEventQueue();
      expect(f.asked, ['1_1']);
    });

    test('a "none" never erases lyrics stored before', () async {
      final f = Fixture();
      f.stored['vk:1_1'] = (
        lyrics: plain,
        md5: 'm',
        fetchedAtMs: f.nowMs - 31 * day,
        meta: null,
      );
      f.controller.show(song(1));
      await pumpEventQueue();
      expect((f.controller.state as LyricsShown).lyrics, plain);
      expect(f.stored['vk:1_1']!.lyrics, plain);
      expect(f.stored['vk:1_1']!.fetchedAtMs, f.nowMs, reason: 'time moved');
    });

    test('a download asks again when VK said "none" a while ago', () async {
      final f = Fixture()..answer = (_) => timed;
      f.stored['vk:1_1'] = (
        lyrics: null,
        md5: null,
        fetchedAtMs: f.nowMs - 8 * day,
        meta: null,
      );
      await f.controller.keepFor(song(1));
      expect(f.stored['vk:1_1']!.lyrics, timed);
    });

    test('opened anew, a song whose ask failed is looked at again', () async {
      final f = Fixture()..answer = (_) => VkException('x', code: 9);
      f.controller.show(song(1));
      await pumpEventQueue();
      expect(f.controller.state, isA<LyricsFailed>());
      f.answer = (_) => timed;
      f.controller.show(song(1));
      expect(f.controller.state, isA<LyricsFailed>(), reason: 'same song');
      f.controller.show(song(1), again: true);
      await pumpEventQueue();
      expect(f.controller.state, isA<LyricsShown>());
    });

    test('lyrics come from the upload that plays', () async {
      final asked = <String>[];
      final controller = LyricsController(
        load: (source, ref) => null,
        save: (source, ref, lyrics, {md5, meta}) {},
        // A chosen version: another upload, through the playing account.
        routeOf: (track) => (
          key: '9_9',
          accessKey: 'k',
          call: (method, params) async {
            asked.add(params['audio_id']!);
            return vkReplyOf(plain);
          },
        ),
      );
      controller.show(song(1));
      await pumpEventQueue();
      expect(asked, ['9_9_k']);
      expect((controller.state as LyricsShown).lyrics, plain);
    });

    test('a song no source covers yet has none, without asking', () async {
      final f = Fixture();
      f.controller.show(song(1, source: TrackSource.generated));
      expect(f.controller.state, isA<LyricsMissing>());
      expect(f.asked, isEmpty);
    });

    test('a download keeps lyrics only when none are stored', () async {
      final f = Fixture()..answer = (_) => timed;
      await f.controller.keepFor(song(1));
      expect(f.stored['vk:1_1']!.lyrics, timed);
      await f.controller.keepFor(song(1));
      expect(f.asked, ['1_1']);
      // A failure is ignored.
      f.answer = (_) => VkException('x', code: 9);
      await f.controller.keepFor(song(2, key: '2_2'));
      expect(f.stored.containsKey('vk:2_2'), isFalse);
    });
  });

  group('LyricsPage', () {
    late Fixture f;
    late StreamController<Duration> positions;
    late StreamController<Track?> songs;
    late Duration position;
    late List<Duration> seeks;
    Track? playing;

    setUp(() {
      f = Fixture();
      positions = StreamController<Duration>.broadcast();
      songs = StreamController<Track?>.broadcast();
      position = Duration.zero;
      seeks = [];
      playing = song(1);
    });
    tearDown(() async {
      await positions.close();
      await songs.close();
    });

    Future<void> open(WidgetTester tester, {double width = 900}) async {
      tester.view.physicalSize = Size(width, 700);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildTheme(OwnColors.dark),
          home: Scaffold(
            body: LyricsPage(
              lyrics: f.controller,
              current: () => playing,
              currentStream: songs.stream,
              position: () => position,
              positions: () => positions.stream,
              seek: (to) async => seeks.add(to),
            ),
          ),
        ),
      );
      await settle(tester);
    }

    /// The text style of the timed line showing [text].
    TextStyle styleOf(WidgetTester tester, String text) => tester
        .widget<AnimatedDefaultTextStyle>(
          find.descendant(
            of: find.ancestor(
              of: find.text(text),
              matching: find.byWidgetPredicate(
                (w) =>
                    w.key is ValueKey<String> &&
                    (w.key! as ValueKey<String>).value.startsWith(
                      'lyrics-line-',
                    ),
              ),
            ),
            matching: find.byType(AnimatedDefaultTextStyle),
          ),
        )
        .style;

    Color colorOf(WidgetTester tester, String text) =>
        styleOf(tester, text).color!;

    testWidgets('timed lines follow the song and a click seeks', (
      tester,
    ) async {
      f.answer = (_) => timed;
      position = const Duration(milliseconds: 4200);
      await open(tester);
      expect(find.byKey(const ValueKey('lyrics-timed')), findsOneWidget);
      expect(colorOf(tester, 'Second line'), OwnColors.dark.text);
      expect(colorOf(tester, 'Первая строка'), isNot(OwnColors.dark.text));

      positions.add(const Duration(milliseconds: 9100));
      await settle(tester);
      expect(colorOf(tester, 'Third line'), OwnColors.dark.text);
      expect(colorOf(tester, 'Second line'), isNot(OwnColors.dark.text));

      await tester.tap(find.text('Первая строка'));
      await settle(tester);
      expect(seeks, [const Duration(milliseconds: 1000)]);
      expect(colorOf(tester, 'Первая строка'), OwnColors.dark.text);
    });

    testWidgets('positions that come late still move the lit line', (
      tester,
    ) async {
      f.answer = (_) => timed;
      Stream<Duration>? late;
      tester.view.physicalSize = const Size(900, 700);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildTheme(OwnColors.dark),
          home: Scaffold(
            body: LyricsPage(
              lyrics: f.controller,
              current: () => playing,
              currentStream: songs.stream,
              position: () => position,
              positions: () => late,
              seek: (to) async => seeks.add(to),
            ),
          ),
        ),
      );
      await settle(tester);
      late = positions.stream;
      await tester.pump(const Duration(milliseconds: 600));
      positions.add(const Duration(milliseconds: 9100));
      await settle(tester);
      expect(colorOf(tester, 'Third line'), OwnColors.dark.text);
    });

    testWidgets('each kind names its source', (tester) async {
      f.answer = (key) => key == '1_1' ? timed : plain;
      await open(tester);
      expect(
        tester.widget<Text>(find.byKey(const ValueKey('lyrics-credit'))).data,
        'From VK',
      );
      playing = song(2, key: '2_2');
      songs.add(playing);
      await settle(tester);
      expect(
        tester.widget<Text>(find.byKey(const ValueKey('lyrics-credit'))).data,
        'Words only, from VK: no source has times for this song',
      );
    });

    testWidgets('the next song brings its own lyrics', (tester) async {
      f.answer = (key) => key == '1_1' ? timed : plain;
      await open(tester);
      expect(find.text('Third line'), findsOneWidget);
      playing = song(2, key: '2_2');
      songs.add(playing);
      await settle(tester);
      expect(find.byKey(const ValueKey('lyrics-plain')), findsOneWidget);
      expect(find.text('Verse two'), findsOneWidget);
      expect(find.textContaining('Words only'), findsOneWidget);
    });

    testWidgets('no lyrics, and a failure with Try again', (tester) async {
      await open(tester);
      expect(find.text('No lyrics found for this song.'), findsOneWidget);

      f.answer = (_) => VkException('error 9', code: 9);
      playing = song(2, key: '2_2');
      songs.add(playing);
      await settle(tester);
      expect(find.textContaining('wait a minute'), findsOneWidget);
      f.answer = (_) => plain;
      await tester.tap(find.byKey(const ValueKey('lyrics-retry')));
      await settle(tester);
      expect(find.text('Verse two'), findsOneWidget);
    });

    testWidgets('nothing playing asks to play a song', (tester) async {
      playing = null;
      await open(tester);
      expect(find.text('Play a song to see its lyrics.'), findsOneWidget);
      expect(f.asked, isEmpty);
    });

    testWidgets('a narrow place uses smaller lines; long ones wrap', (
      tester,
    ) async {
      const long = Lyrics(
        source: 'vk',
        lines: [
          LyricLine(
            'A very long line of words that cannot fit on one row of a '
            'narrow window and has to wrap onto the next',
            startMs: 0,
          ),
        ],
      );
      f.answer = (_) => long;
      await open(tester, width: 500);
      final text = find.textContaining('A very long line');
      final style = styleOf(tester, tester.widget<Text>(text).data!);
      expect(style.fontSize, 24);
      expect(tester.getSize(text).height, greaterThan(40));
      expect(tester.takeException(), isNull);
    });
  });
}

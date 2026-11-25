// Tests for plan 10 I2g1: the user's own edit of a song's lyrics. How an
// edit with missing or out-of-order line starts is shown, how the library
// keeps edits with their history, and how the Lyrics place shows an edit
// first while every source's lyrics stay as they were. The words are made
// up.

import 'package:flutter_test/flutter_test.dart';
import 'package:ownsemble/library/library_store.dart';
import 'package:ownsemble/library/track.dart';
import 'package:ownsemble/lyrics/lyrics.dart';
import 'package:ownsemble/lyrics/lyrics_controller.dart';
import 'package:ownsemble/lyrics/lyrics_edit.dart';

Track song({String key = '1_1'}) => Track(
  id: 1,
  sourceId: 1,
  source: TrackSource.vk,
  artist: 'Ночные Тени',
  title: 'Город спит',
  album: 'Альбом',
  durationSec: 200,
  sourceKey: key,
  addedAt: 0,
);

const lrclibLines = [
  LyricLine('Раз', startMs: 1000, endMs: 1900),
  LyricLine('Два', startMs: 2000, endMs: 2900),
  LyricLine('Три', startMs: 3000, endMs: 3900),
];

void main() {
  group('editForShow', () {
    test('an edit with every start in order shows as typed', () {
      final shown = editForShow(const [
        LyricLine('a', startMs: 1000),
        LyricLine('', startMs: 4000),
        LyricLine('b', startMs: 6000),
      ]);
      expect(shown.source, editedSource);
      expect(shown.timed, isTrue);
      expect(shown.lines, const [
        LyricLine('a', startMs: 1000),
        LyricLine('', startMs: 4000),
        LyricLine('b', startMs: 6000),
      ]);
    });

    test('a line without a start is passed over: the line above stays lit', () {
      final shown = editForShow(const [
        LyricLine('a', startMs: 1000),
        LyricLine('added'),
        LyricLine('b', startMs: 6000),
      ]);
      expect(shown.timed, isTrue, reason: 'one missing start keeps following');
      expect(shown.lines[1].startMs, 1000);
      expect(shown.lines[1].passed, isTrue);
      expect(shown.lineAt(1500), 0);
      expect(shown.lineAt(5999), 0);
      expect(shown.lineAt(6000), 2);
    });

    test('a start earlier than the line above never lights back', () {
      final shown = editForShow(const [
        LyricLine('a', startMs: 1000),
        LyricLine('b', startMs: 5000),
        LyricLine('early', startMs: 3000),
        LyricLine('c', startMs: 8000),
      ]);
      expect(
        [for (final l in shown.lines) l.startMs],
        [1000, 5000, 5000, 8000],
      );
      expect(shown.lines[2].passed, isTrue);
      expect(shown.lineAt(3500), 0, reason: 'its own time is not used');
      expect(shown.lineAt(6000), 1);
      expect(shown.lineAt(8000), 3);
    });

    test('lines above the first start take that start and are passed over', () {
      final shown = editForShow(const [
        LyricLine('new first'),
        LyricLine('a', startMs: 2000),
        LyricLine('b', startMs: 4000),
      ]);
      expect(shown.lines.first.startMs, 2000);
      expect(shown.lines.first.passed, isTrue);
      expect(shown.lineAt(1000), -1);
      expect(shown.lineAt(2500), 1);
    });

    test('an untimed header row shows as a label, a timed one as a line', () {
      final shown = editForShow(const [
        LyricLine('[Chorus]'),
        LyricLine('a', startMs: 2000),
        LyricLine('[Verse 2]', startMs: 5000),
      ]);
      expect(shown.lines[0].label, isTrue);
      expect(shown.lines[0].passed, isFalse);
      expect(shown.lines[2].label, isFalse);
      expect(shown.lineAt(5500), 2);
    });

    test('an edit with no start at all shows as plain words', () {
      final shown = editForShow(const [LyricLine('a'), LyricLine('b')]);
      expect(shown.timed, isFalse);
      expect(shown.lines, const [LyricLine('a'), LyricLine('b')]);
    });

    test('starts on music breaks alone do not make the words follow', () {
      final shown = editForShow(const [
        LyricLine('', startMs: 1000),
        LyricLine('a'),
      ]);
      expect(shown.timed, isFalse);
    });
  });

  group('store', () {
    late LibraryStore store;
    setUp(() => store = LibraryStore.open(':memory:'));
    tearDown(() => store.close());

    test('keeps the newest save, Cyrillic and missing starts included', () {
      expect(store.editOf('1_1'), isNull);
      store.saveEdit(
        '1_1',
        const [LyricLine('Ночь', startMs: 500), LyricLine('улица')],
        basedOn: 'lrclib',
        atMs: 1000,
      );
      final edit = store.editOf('1_1')!;
      expect(edit.lines, const [
        LyricLine('Ночь', startMs: 500),
        LyricLine('улица'),
      ]);
      expect(edit.basedOn, 'lrclib');
      expect(edit.savedAtMs, 1000);
      expect(edit.saves, 1);
      expect(store.editOf('1_2'), isNull, reason: 'per upload');
    });

    test('undo goes back one save; the last undo forgets the edit', () {
      store.saveEdit('1_1', const [LyricLine('one')], atMs: 1);
      store.saveEdit('1_1', const [LyricLine('two')], atMs: 2);
      expect(store.editOf('1_1')!.lines.single.text, 'two');
      expect(store.editOf('1_1')!.saves, 2);
      store.undoEdit('1_1');
      expect(store.editOf('1_1')!.lines.single.text, 'one');
      expect(store.editOf('1_1')!.basedOn, isNull);
      store.undoEdit('1_1');
      expect(store.editOf('1_1'), isNull);
      store.undoEdit('1_1');
    });

    test('keeps the last $lyricsEditsKept saves only', () {
      for (var i = 0; i < lyricsEditsKept + 3; i++) {
        store.saveEdit('1_1', [LyricLine('save $i')], atMs: i);
      }
      expect(store.editOf('1_1')!.saves, lyricsEditsKept);
      for (var i = 0; i < lyricsEditsKept - 1; i++) {
        store.undoEdit('1_1');
      }
      expect(store.editOf('1_1')!.lines.single.text, 'save 3');
    });

    test('forget drops every save of one upload only', () {
      store.saveEdit('1_1', const [LyricLine('a')], atMs: 1);
      store.saveEdit('1_1', const [LyricLine('b')], atMs: 2);
      store.saveEdit('1_2', const [LyricLine('c')], atMs: 3);
      store.forgetEdit('1_1');
      expect(store.editOf('1_1'), isNull);
      expect(store.editOf('1_2')!.lines.single.text, 'c');
    });
  });

  group('the Lyrics place', () {
    late LibraryStore store;
    late LyricsController controller;
    var now = 1000;

    LyricsController build() => LyricsController(
      load: store.lyricsOf,
      save: (source, ref, lyrics, {md5, meta}) => store.saveLyrics(
        source,
        ref,
        lyrics,
        md5: md5,
        meta: meta,
        atMs: now,
      ),
      // No account: stored lyrics only, nothing is asked.
      routeOf: (track) => (key: track.sourceKey!, accessKey: null, call: null),
      loadPick: store.lyricsPickOf,
      savePick: store.saveLyricsPick,
      loadOffset: store.lyricsOffsetOf,
      saveOffset: store.saveLyricsOffset,
      loadHeard: store.heardLyricsOf,
      edits: store,
      now: () => now,
    );

    Lyrics? shown() => switch (controller.state) {
      LyricsShown(:final lyrics) => lyrics,
      _ => null,
    };

    setUp(() {
      store = LibraryStore.open(':memory:');
      store.saveLyrics(
        'vk',
        '1_1',
        const Lyrics(source: 'vk', lines: lrclibLines),
        atMs: now,
      );
      controller = build();
    });
    tearDown(() => store.close());

    test('the editor starts from what shows, offset applied', () {
      controller.show(song());
      controller.setOffset('vk', 500);
      expect(controller.editStartLines(), const [
        LyricLine('Раз', startMs: 1500),
        LyricLine('Два', startMs: 2500),
        LyricLine('Три', startMs: 3500),
      ]);
      expect(controller.editBase, 'vk');
    });

    test('a saved edit shows first and is kept after a restart', () {
      controller.show(song());
      controller.saveEdit(const [
        LyricLine('Раз!', startMs: 1200),
        LyricLine('Два', startMs: 2000),
      ]);
      expect(shown()!.source, editedSource);
      expect(shown()!.lines.first.text, 'Раз!');
      expect(controller.edit!.basedOn, 'vk');
      expect(controller.offsetOf(editedSource), 0);
      // The source's own lyrics are untouched.
      expect(store.lyricsOf('vk', '1_1')!.lyrics!.lines, lrclibLines);

      controller = build()..show(song());
      expect(shown()!.source, editedSource);
    });

    test('back to the source keeps the edit; Use shows it again', () {
      controller.show(song());
      controller.saveEdit(const [LyricLine('mine', startMs: 1000)]);
      controller.showOriginal();
      expect(shown()!.source, 'vk');
      expect(controller.edit, isNotNull);
      controller.use(editedSource);
      expect(shown()!.source, editedSource);
    });

    test('automatic shows the edit over every source', () {
      controller.show(song());
      controller.saveEdit(const [LyricLine('mine', startMs: 1000)]);
      controller.use('vk');
      controller.useAutomatic();
      expect(shown()!.source, editedSource);
    });

    test('undo the last save, then forget: the source shows again', () {
      controller.show(song());
      controller.saveEdit(const [LyricLine('one', startMs: 1000)]);
      controller.saveEdit(const [LyricLine('two', startMs: 1000)]);
      controller.undoLastSave();
      expect(shown()!.lines.single.text, 'one');
      controller.undoLastSave();
      expect(shown()!.source, 'vk');
      expect(controller.edit, isNull);
      expect(store.lyricsPickOf('1_1'), isNull, reason: 'no pick of nothing');

      controller.saveEdit(const [LyricLine('three', startMs: 1000)]);
      controller.forgetEdit();
      expect(shown()!.source, 'vk');
    });

    test('a source saving new lyrics does not replace the edit', () async {
      controller.show(song());
      controller.saveEdit(const [LyricLine('mine', startMs: 1000)]);
      store.saveLyrics(
        'vk',
        '1_1',
        const Lyrics(source: 'vk', lines: [LyricLine('new', startMs: 1)]),
        atMs: now,
      );
      controller.show(song(), again: true);
      await pumpEventQueue();
      expect(shown()!.source, editedSource);
      expect(
        controller.choices.map((choice) => choice.source),
        isNot(contains(editedSource)),
        reason: 'the edit has its own row, like heard words',
      );
    });

    test('another upload of the song has its own lyrics', () {
      store.saveLyrics(
        'vk',
        '2_2',
        const Lyrics(source: 'vk', lines: [LyricLine('other', startMs: 1)]),
        atMs: now,
      );
      controller.show(song());
      controller.saveEdit(const [LyricLine('mine', startMs: 1000)]);
      controller.show(song(key: '2_2'));
      expect(shown()!.source, 'vk');
      expect(controller.edit, isNull);
      controller.show(song());
      expect(shown()!.source, editedSource);
    });

    test('with nothing on show the editor writes from nothing', () {
      store.saveLyrics('vk', '3_3', null, atMs: now);
      controller.show(song(key: '3_3'));
      expect(controller.editBase, isNull, reason: 'nothing shows: Write');
      controller.saveEdit(const [LyricLine('written', startMs: 1000)]);
      expect(shown()!.source, editedSource);
      expect(controller.edit!.basedOn, isNull);
    });

    test('a written edit with no times shows as plain words', () {
      controller.show(song());
      controller.saveEdit(const [LyricLine('a'), LyricLine('b')]);
      expect(shown()!.timed, isFalse);
      expect(controller.timedOf(shown()!).timed, isFalse);
    });
  });
}

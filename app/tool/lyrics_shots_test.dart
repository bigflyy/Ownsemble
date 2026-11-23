// Renders the Lyrics place of plan 10 to PNG files with the real fonts, so
// its look can be checked without opening the app on screen: timed lyrics
// following a playing song, plain lyrics, a song without lyrics, a failed
// ask, the loading spinner, long lines in a narrow window, lines moved
// later by hand (F1); the chooser of every source's lyrics (E2): its list,
// a preview and a kept choice; and Fit to this recording (G2): the question
// before the model's download, the download, the fit running, fitted lines
// and lyrics that do not match. The words are made up.
//
// Run from app/:
//   flutter test tool/lyrics_shots_test.dart \
//       --dart-define=OWNSEMBLE_SHOTS=<folder>

import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ownsemble/library/library_store.dart';
import 'package:ownsemble/library/track.dart';
import 'package:ownsemble/lyrics/fit_model.dart';
import 'package:ownsemble/lyrics/fitted_lines.dart';
import 'package:ownsemble/lyrics/lyrics.dart';
import 'package:ownsemble/lyrics/lyrics_controller.dart';
import 'package:ownsemble/lyrics/lyrics_fitter.dart';
import 'package:ownsemble/lyrics/lyrics_sources.dart';
import 'package:ownsemble/playback/playback_controller.dart';
import 'package:ownsemble/playback/player_service.dart';
import 'package:ownsemble/storage/audio_storage.dart';
import 'package:ownsemble/ui/collections_controller.dart';
import 'package:ownsemble/ui/library_controller.dart';
import 'package:ownsemble/ui/library_screen.dart';
import 'package:ownsemble/ui/shell_settings.dart';
import 'package:ownsemble/ui/sources_scope.dart';
import 'package:ownsemble/ui/theme.dart';
import 'package:ownsemble/vk/vk_client.dart';
import 'package:path/path.dart' as p;

const shotsDir = String.fromEnvironment(
  'OWNSEMBLE_SHOTS',
  defaultValue: 'build/screenshots',
);

/// A player showing a song at a set position without opening any audio.
class _ShownPlayer extends PlayerService {
  _ShownPlayer(AudioStorage storage)
    : super(muted: true, dataDir: '.', storage: storage);

  Track? _track;
  Duration at = const Duration(seconds: 52);
  final _tracks = StreamController<Track?>.broadcast();
  final _positions = StreamController<Duration>.broadcast();

  @override
  Stream<Track?> get currentStream => _tracks.stream;
  @override
  bool get isReady => true;
  @override
  Track? get current => _track;
  @override
  bool get currentLoaded => true;
  @override
  Stream<Duration> get positions => _positions.stream;
  @override
  Duration get position => at;
  @override
  Duration get duration => const Duration(minutes: 3, seconds: 24);

  void moveTo(Duration to) {
    at = to;
    _positions.add(to);
  }

  @override
  Future<PlayTiming> play(Track track, {Duration? from}) async {
    _track = track;
    _tracks.add(track);
    return const PlayTiming(ok: true, cached: true, resolveMs: 0, toSoundMs: 1);
  }
}

/// An outside source with nothing more to say: the shots' outside lyrics
/// are stored before.
class _QuietSource implements OutsideLyricsSource {
  _QuietSource(this.id);

  @override
  final String id;

  @override
  Future<LyricsCandidate?> find(SongNames song) async => null;
}

Lyrics _outsideTimed(String source, int shift) => Lyrics(
  source: source,
  lines: [
    for (final (i, line) in _timedWords.indexed)
      LyricLine(line, startMs: 10000 + shift + i * 6000),
  ],
);

Future<void> loadFont(String family, List<String> files) async {
  final loader = FontLoader(family);
  for (final file in files) {
    final bytes = File(file).readAsBytesSync();
    loader.addFont(Future.value(ByteData.sublistView(bytes)));
  }
  await loader.load();
}

const _timedWords = [
  'Огни на пристани зажглись',
  'Одна за другой вдоль берега',
  'Я считаю лодки, что не пришли',
  'И оставляю окно открытым',
  '',
  'Somebody sings across the water',
  'A tune I almost used to know',
  'The tide keeps every word I gave it',
  'And gives it back to me so slow',
  '',
  'Останься, побудь ещё немного',
  'Ночь прошла едва наполовину',
  'Дорога подождёт до утра',
  'А я подожду тебя здесь',
];

const _longWords = [
  'Это очень длинная строка, которая никак не помещается в узкое окно и '
      'переносится на следующую строку',
  'A second line that is also far too long to fit on one row of a narrow '
      'window, so it wraps as well',
  'Короткая',
];

Map<String, Object?> _timedReply(List<String> words) => {
  'md5': 'm',
  'lyrics': {
    'timestamps': [
      for (final (i, line) in words.indexed)
        {'begin': 10000 + i * 6000, 'end': 15500 + i * 6000, 'line': line},
    ],
  },
};

Map<String, Object?> _plainReply() => {
  'md5': 'm',
  'lyrics': {
    'text': [
      'Огни на пристани зажглись,',
      'Одна за другой вдоль берега.',
      'Я считаю лодки, что не пришли,',
      'И оставляю окно открытым.',
      '',
      'Somebody sings across the water,',
      'A tune I almost used to know.',
      'The tide keeps every word I gave it',
      'And gives it back to me so slow.',
      '',
      'Останься, побудь ещё немного,',
      'Ночь прошла едва наполовину.',
      'Дорога подождёт до утра,',
      'А я подожду тебя здесь.',
      '',
      'Огни на пристани гаснут,',
      'Одна за другой, как пришли.',
    ],
  },
};

void main() {
  setUpAll(() async {
    await loadFont('Golos Text', [
      for (final w in ['Regular', 'Medium', 'SemiBold', 'Bold'])
        'assets/fonts/GolosText-$w.ttf',
    ]);
    final icons = p.normalize(
      p.join(
        p.dirname(Platform.resolvedExecutable),
        '..',
        '..',
        'material_fonts',
        'materialicons-regular.otf',
      ),
    );
    if (File(icons).existsSync()) await loadFont('MaterialIcons', [icons]);
  });

  /// [step]: 'timed', 'moved' (timed, lines moved 1.5 s later), 'plain', 'none', 'failed', 'loading', 'long', 'closed'
  /// (the Songs list with the mic button, before Lyrics is opened).
  Future<void> shoot(
    WidgetTester tester,
    String name, {
    required String step,
    required bool dark,
    required Size size,
  }) async {
    final store = LibraryStore.open(':memory:');
    addTearDown(store.close);
    final vk = store.ensureSource(TrackSource.vk, account: '1', name: 'VK');
    store.upsertAll(vk, [
      for (final (i, (artist, title)) in [
        ('Северные комнаты', 'Огни пристани'),
        ('Мира Холм', 'Поезд на юг'),
        ('Okto', 'Glass Garden'),
        ('Пале Кост', 'Утренний паром'),
        ('The Lanterns', 'Copper Rain'),
      ].indexed)
        NewTrack(
          sourceKey: '1_${i + 1}',
          artist: artist,
          title: title,
          album: title,
          durationSec: 204 + i * 9,
          addedAt: 100 - i,
          tint: 0xFF000000 | (0x2D3B55 + i * 0x0a0806),
        ),
    ]);
    final collections = CollectionsController(store);
    final library = LibraryController(
      store.loadAll(),
      collections: collections,
    );
    final sources = ValueNotifier(store.sources());
    final storage = AudioStorage(dataDir: '.', store: store);
    final player = _ShownPlayer(storage);
    final playback = PlaybackController(player: player);

    final never = Completer<Object?>();
    Future<Object?> fakeVk(String method, Map<String, String> params) async {
      switch (step) {
        case 'loading':
          return never.future;
        case 'failed':
          throw VkException('audio.getLyrics error 9', code: 9);
        case 'none':
          throw VkException('audio.getLyrics error 104', code: 104);
        case 'plain' || 'choices' || 'preview' || 'chosen':
          return _plainReply();
        case 'long':
          return _timedReply(_longWords);
      }
      return _timedReply(_timedWords);
    }

    final choosing = const ['choices', 'preview', 'chosen'].contains(step);
    if (choosing) {
      store
        ..saveLyrics(
          'lrclib',
          '1_1',
          _outsideTimed('lrclib', 0),
          meta:
              '{"id":"1","artist":"Северные комнаты","title":"Огни пристани",'
              '"seconds":204,"exact":true,"diff":0}',
        )
        ..saveLyrics(
          'netease',
          '1_1',
          _outsideTimed('netease', 300),
          meta:
              '{"id":"2","artist":"Severnye komnaty","title":"Ogni pristani '
              '(Live at the Old Harbour Hall, remastered edition)",'
              '"seconds":206,"exact":false,"diff":2}',
        );
      if (step == 'chosen') store.saveLyricsPick('1_1', 'netease');
      // F1: the preview shows NetEase's moved timing.
      if (step == 'preview') store.saveLyricsOffset('1_1', 'netease', -1000);
    }
    final lyrics = LyricsController(
      load: store.lyricsOf,
      save: store.saveLyrics,
      loadPick: store.lyricsPickOf,
      savePick: store.saveLyricsPick,
      loadOffset: store.lyricsOffsetOf,
      saveOffset: store.saveLyricsOffset,
      routeOf: lyricsRouteBySource((_) => fakeVk),
      sources: choosing
          ? [
              _QuietSource('lrclib'),
              _QuietSource('netease'),
              _QuietSource('qq'),
            ]
          : const [],
    );
    // G2: a fit that never ends, held at the step to show.
    final hang = Completer<void>();
    final modelDir = Directory.systemTemp.createTempSync('shots-model');
    addTearDown(() => modelDir.deleteSync(recursive: true));
    final modelThere = step == 'fitting';
    final model = File(p.join(modelDir.path, 'm.onnx'));
    if (modelThere) model.writeAsBytesSync([1, 2, 3]);
    final fitter = LyricsFitter(
      lyrics: lyrics,
      modelFile: model,
      model: modelThere
          ? ModelFile(
              url: Uri.parse('http://localhost/m'),
              bytes: 3,
              sha256: '',
              fileName: 'm.onnx',
            )
          : alignerModel,
      downloadModelTo: (onProgress, stop) async {
        onProgress(142000000, alignerModel.bytes);
        await hang.future;
      },
      audioOf: (track, onProgress) async => model.path,
      fit: (key, path, lines, onProgress) async {
        onProgress(7, 12);
        await hang.future;
        throw StateError('never');
      },
    );
    final settings = ShellSettings.inMemory();
    if (!dark) settings.toggleTheme();
    settings.dockTo(PlayerDock.side);

    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final boundary = GlobalKey();
    await tester.pumpWidget(
      RepaintBoundary(
        key: boundary,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: buildTheme(dark ? OwnColors.dark : OwnColors.light),
          home: SourcesScope(
            sources: sources,
            child: LibraryScreen(
              library: library,
              playback: playback,
              collections: collections,
              settings: settings,
              lyrics: lyrics,
              lyricsFitter: fitter,
            ),
          ),
        ),
      ),
    );
    Future<void> settle() async {
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
    }

    await settle();
    await playback.playFrom(library.all, 0);
    player.playing.value = true;
    await settle();
    if (step != 'closed') {
      // The smallest window keeps the mic in the bar's More menu (B26).
      if (find.byKey(const ValueKey('lyrics')).evaluate().isEmpty) {
        library.toggleLyrics();
      } else {
        await tester.tap(find.byKey(const ValueKey('lyrics')));
      }
      await settle();
      // The song moves on to the 7th line (or the 2nd of the long ones).
      player.moveTo(Duration(milliseconds: step == 'long' ? 16500 : 46500));
      await settle();
      await tester.pump(const Duration(milliseconds: 600));
      await settle();
      if (step == 'moved') {
        // F1: three presses of "later", lines 1.5 s later.
        for (var i = 0; i < 3; i++) {
          await tester.tap(find.byKey(const ValueKey('lyrics-later')));
          await settle();
        }
        await tester.pump(const Duration(milliseconds: 600));
        await settle();
      }
      if (step == 'fitted' || step == 'nomatch') {
        final shown = (lyrics.state as LyricsShown).lyrics;
        lyrics.keepFit(
          lyrics.shownKey!,
          shown.source,
          StoredFit(
            lyricsHash: lyricsHashOf(shown),
            audioBytes: 1,
            starts: step == 'fitted'
                ? [for (final line in shown.lines) line.startMs! + 2500]
                : null,
            sureShare: step == 'fitted' ? 0.86 : 0.31,
            fittedAtMs: 1,
          ),
        );
        await tester.pump(const Duration(milliseconds: 600));
        await settle();
      }
      if (step == 'downloading' || step == 'fitting') {
        unawaited(fitter.fitShown());
        await settle();
      }
      if (step == 'ask') {
        await tester.tap(find.byKey(const ValueKey('lyrics-fit')));
        await settle();
      }
      if (step == 'choices' || step == 'preview') {
        await tester.tap(find.byKey(const ValueKey('lyrics-choose')));
        await settle();
      }
      if (step == 'preview') {
        await tester.tap(find.byKey(const ValueKey('lyrics-choice-netease')));
        await settle();
        await tester.pump(const Duration(milliseconds: 600));
        await settle();
      }
    }
    for (final paragraph
        in tester.allRenderObjects.whereType<RenderParagraph>()) {
      final family = paragraph.text.style?.fontFamily;
      expect(
        family == appFontFamily || family == 'MaterialIcons',
        isTrue,
        reason: '"${paragraph.text.toPlainText()}" is drawn in $family',
      );
    }
    expect(tester.takeException(), isNull);
    await tester.runAsync(() async {
      final render =
          boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await render.toImage();
      final png = await image.toByteData(format: ui.ImageByteFormat.png);
      Directory(shotsDir).createSync(recursive: true);
      File(p.join(shotsDir, '$name.png'))
          .writeAsBytesSync(png!.buffer.asUint8List());
    });
    player.playing.value = false;
    await tester.pump(const Duration(seconds: 5));
  }

  for (final (step, dark, size) in [
    ('closed', true, const Size(1440, 900)),
    ('timed', true, const Size(1440, 900)),
    ('timed', false, const Size(1440, 900)),
    ('timed', true, const Size(760, 900)),
    ('timed', false, const Size(480, 800)),
    ('moved', true, const Size(1440, 900)),
    ('moved', false, const Size(760, 900)),
    ('moved', true, const Size(480, 800)),
    ('plain', false, const Size(1440, 900)),
    ('plain', true, const Size(760, 900)),
    ('none', true, const Size(1440, 900)),
    ('failed', false, const Size(1440, 900)),
    ('loading', true, const Size(1440, 900)),
    ('long', false, const Size(760, 900)),
    ('choices', true, const Size(1440, 900)),
    ('choices', false, const Size(1440, 900)),
    ('choices', true, const Size(760, 900)),
    ('choices', false, const Size(480, 800)),
    ('preview', true, const Size(1440, 900)),
    ('preview', false, const Size(760, 900)),
    ('chosen', true, const Size(1440, 900)),
    ('ask', true, const Size(1440, 900)),
    ('ask', false, const Size(480, 800)),
    ('downloading', true, const Size(1440, 900)),
    ('downloading', false, const Size(760, 900)),
    ('fitting', true, const Size(1440, 900)),
    ('fitting', false, const Size(480, 800)),
    ('fitted', true, const Size(1440, 900)),
    ('fitted', false, const Size(760, 900)),
    ('fitted', true, const Size(480, 800)),
    ('nomatch', false, const Size(1440, 900)),
    ('nomatch', true, const Size(760, 900)),
  ]) {
    final width = size.width < 600
        ? 'smallest'
        : size.width < 1000
        ? 'narrow'
        : 'wide';
    testWidgets(
      'Lyrics: $step, ${dark ? 'dark' : 'light'}, $width',
      (t) => shoot(
        t,
        '${dark ? 'dark' : 'light'}-lyrics-$step-$width',
        step: step,
        dark: dark,
        size: size,
      ),
    );
  }
}

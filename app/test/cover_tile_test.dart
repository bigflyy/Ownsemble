import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:ownsemble/library/track.dart';
import 'package:ownsemble/storage/cover_store.dart';
import 'package:ownsemble/ui/cover_tile.dart';
import 'package:ownsemble/ui/theme.dart';
import 'package:path/path.dart' as p;

const smallUrl = 'https://img.example/a.jpg?size=135';
const largeUrl = 'https://img.example/a.jpg?size=600';
const tint = 0xFF123456;

Track song({String? cover = smallUrl, String? large, int? color = tint}) =>
    Track(
      id: 1,
      sourceId: 1,
      source: TrackSource.vk,
      artist: 'Сплин',
      title: 'Выхода нет',
      album: 'Гранатовый альбом',
      durationSec: 200,
      coverUrl: cover,
      coverLargeUrl: large,
      tint: color,
    );

/// A store that answers from a map and records what it was asked for.
class FakeCovers extends CoverStore {
  FakeCovers() : super(dataDir: '.');

  final stored = <String, String>{};
  final unavailable = <String>{};
  final fetched = <String>[];
  final answers = <String, void Function(String?)>{};

  @override
  String? storedPath(String url) => stored[url];

  @override
  bool isUnavailable(String url) => unavailable.contains(url);

  @override
  CoverRequest? fetch(String url, void Function(String? path) onDone) {
    fetched.add(url);
    answers[url] = onDone;
    return null;
  }
}

/// A widget test on a screen of 1 device pixel per logical pixel.
void coverTest(String name, WidgetTesterCallback body) {
  testWidgets(name, (tester) async {
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetDevicePixelRatio);
    await body(tester);
  });
}

void main() {
  late Directory dir;
  late String imagePath;
  late FakeCovers covers;

  setUp(() {
    PaintingBinding.instance.imageCache
      ..clear()
      ..clearLiveImages();
    dir = Directory.systemTemp.createTempSync('tile');
    imagePath = p.join(dir.path, 'cover.png');
    File(imagePath)
        .writeAsBytesSync(img.encodePng(img.Image(width: 135, height: 135)));
    covers = FakeCovers();
  });

  tearDown(() => dir.deleteSync(recursive: true));

  Widget tile(Track track, {double size = 44, bool scoped = true}) {
    final app = MaterialApp(
      theme: buildTheme(OwnColors.dark),
      home: Center(
        child: TrackTile(track: track, size: size, radius: 8),
      ),
    );
    return scoped ? CoverScope(store: covers, child: app) : app;
  }

  /// Lets the settle delay pass and the image load, in real time.
  Future<void> loadImage(WidgetTester tester) async {
    await tester.pump(const Duration(milliseconds: 100));
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 30)),
      );
      await tester.pump();
    }
  }

  Finder shownImage() => find.byWidgetPredicate(
    (widget) => widget is RawImage && widget.image != null,
  );

  coverTest('without a store or a cover the stand-in shows', (tester) async {
    await tester.pumpWidget(tile(song(), scoped: false));
    expect(find.text('ГА'), findsOneWidget);

    await tester.pumpWidget(tile(song(cover: null)));
    expect(find.text('ГА'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 200));
    expect(covers.fetched, isEmpty);
  });

  coverTest('a cover shows its tint while it comes, no initials', (
    tester,
  ) async {
    await tester.pumpWidget(tile(song()));
    expect(find.text('ГА'), findsNothing);
    final box = tester.widget<Container>(find.byType(Container));
    expect((box.decoration! as BoxDecoration).color, const Color(tint));
    await tester.pump(const Duration(milliseconds: 100));
  });

  coverTest('a row that leaves at once asks for nothing', (tester) async {
    covers.stored[smallUrl] = imagePath;
    await tester.pumpWidget(tile(song()));
    await tester.pump(const Duration(milliseconds: 30));
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(milliseconds: 200));

    expect(covers.fetched, isEmpty);
    expect(PaintingBinding.instance.imageCache.pendingImageCount, 0);
  });

  coverTest('a missing cover is fetched once and then shown', (tester) async {
    await tester.pumpWidget(tile(song()));
    await tester.pump(const Duration(milliseconds: 100));
    expect(covers.fetched, [smallUrl]);

    covers.answers[smallUrl]!(imagePath);
    await loadImage(tester);

    expect(shownImage(), findsOneWidget);
    expect(covers.fetched, hasLength(1));
  });

  coverTest('a failed cover falls back to the stand-in', (tester) async {
    await tester.pumpWidget(tile(song()));
    await tester.pump(const Duration(milliseconds: 100));

    covers.answers[smallUrl]!(null);
    await tester.pump();

    expect(find.text('ГА'), findsOneWidget);
  });

  coverTest('a cover known to be unavailable is not asked for', (tester) async {
    covers.unavailable.add(smallUrl);
    await tester.pumpWidget(tile(song()));
    await tester.pump(const Duration(milliseconds: 100));

    expect(covers.fetched, isEmpty);
    expect(find.text('ГА'), findsOneWidget);
  });

  coverTest('a broken file falls back to the stand-in', (tester) async {
    final broken = p.join(dir.path, 'broken.jpg');
    File(broken).writeAsBytesSync([0xFF, 0xD8, 0, 1, 2, 3]);
    covers.stored[smallUrl] = broken;
    await tester.pumpWidget(tile(song()));
    await loadImage(tester);

    expect(tester.takeException(), isNull);
    expect(find.text('ГА'), findsOneWidget);
  });

  coverTest('a decoded cover shows at once, without waiting', (tester) async {
    covers.stored[smallUrl] = imagePath;
    final decoded = CoverFileImage(imagePath, 44);
    await tester.pumpWidget(tile(song()));
    await tester.runAsync(
      () => precacheImage(decoded, tester.element(find.byType(TrackTile))),
    );

    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(tile(song()));
    await tester.pump();

    expect(shownImage(), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  coverTest('a row reused for a song without a cover shows its stand-in', (
    tester,
  ) async {
    covers.stored[smallUrl] = imagePath;
    await tester.pumpWidget(tile(song()));
    await loadImage(tester);
    expect(shownImage(), findsOneWidget);

    await tester.pumpWidget(tile(song(cover: null)));

    expect(shownImage(), findsNothing);
    expect(find.text('ГА'), findsOneWidget);
  });

  coverTest('the panel tile uses the large cover, small until it comes', (
    tester,
  ) async {
    covers.stored[smallUrl] = imagePath;
    await tester.pumpWidget(tile(song(large: largeUrl), size: 220));
    await loadImage(tester);

    expect(covers.fetched, [largeUrl]);
    expect(shownImage(), findsOneWidget, reason: 'small cover meanwhile');

    final largePath = p.join(dir.path, 'large.png');
    File(largePath)
        .writeAsBytesSync(img.encodePng(img.Image(width: 600, height: 600)));
    covers.answers[largeUrl]!(largePath);
    await loadImage(tester);

    final shown = tester.widget<RawImage>(shownImage());
    expect(shown.image!.width, 220, reason: 'decoded for the size on screen');
  });

  coverTest('a list row never asks for the large cover', (tester) async {
    await tester.pumpWidget(tile(song(large: largeUrl)));
    await tester.pump(const Duration(milliseconds: 100));

    expect(covers.fetched, [smallUrl]);
  });

  test('each size on screen has its own bitmap', () {
    expect(CoverFileImage('a.jpg', 44), isNot(CoverFileImage('a.jpg', 88)));
    expect(CoverFileImage('a.jpg', 44), CoverFileImage('a.jpg', 44));
  });
}

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
const midUrl = 'https://img.example/a.jpg?size=300';
const fullUrl = 'https://img.example/a.jpg?size=1200';
const tint = 0xFF123456;

Track song({
  String? cover = smallUrl,
  String? large,
  String? mid,
  String? full,
  int? color = tint,
}) => Track(
  id: 1,
  sourceId: 1,
  source: TrackSource.vk,
  artist: 'Сплин',
  title: 'Выхода нет',
  album: 'Гранатовый альбом',
  durationSec: 200,
  coverUrl: cover,
  coverLargeUrl: large,
  coverMidUrl: mid,
  coverFullUrl: full,
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

  coverTest('a size VK does not serve: the next size is fetched and shown', (
    tester,
  ) async {
    await tester.pumpWidget(tile(song(mid: midUrl)));
    await tester.pump(const Duration(milliseconds: 100));
    expect(covers.fetched, [smallUrl]);

    covers.answers[smallUrl]!(null);
    await tester.pump();
    expect(covers.fetched, [smallUrl, midUrl]);
    expect(find.text('ГА'), findsNothing, reason: 'still trying');

    covers.answers[midUrl]!(imagePath);
    await loadImage(tester);
    expect(shownImage(), findsOneWidget);
  });

  coverTest('every size failed: the stand-in shows', (tester) async {
    await tester.pumpWidget(tile(song(mid: midUrl, full: fullUrl)));
    await tester.pump(const Duration(milliseconds: 100));
    covers.answers[smallUrl]!(null);
    await tester.pump();
    covers.answers[midUrl]!(null);
    await tester.pump();
    covers.answers[fullUrl]!(null);
    await tester.pump();

    expect(find.text('ГА'), findsOneWidget);
  });

  coverTest('a stored other size shows without asking the network', (
    tester,
  ) async {
    covers.stored[midUrl] = imagePath;
    await tester.pumpWidget(tile(song(mid: midUrl)));
    await loadImage(tester);

    expect(covers.fetched, isEmpty);
    expect(shownImage(), findsOneWidget);
  });

  coverTest('a size known to be unavailable is skipped', (tester) async {
    covers.unavailable.add(smallUrl);
    await tester.pumpWidget(tile(song(mid: midUrl)));
    await tester.pump(const Duration(milliseconds: 100));

    expect(covers.fetched, [midUrl]);
  });

  coverTest('the panel tile tries the other large sizes before giving up', (
    tester,
  ) async {
    covers.stored[smallUrl] = imagePath;
    await tester.pumpWidget(
      tile(song(large: largeUrl, full: fullUrl, mid: midUrl), size: 220),
    );
    await loadImage(tester);
    expect(covers.fetched, [largeUrl]);

    covers.answers[largeUrl]!(null);
    await tester.pump();
    expect(covers.fetched, [largeUrl, fullUrl]);
    await tester.pumpWidget(const SizedBox());
  });

  test('cover links run from the wanted size to the others', () {
    final track = song(large: largeUrl, mid: midUrl, full: fullUrl);
    expect(track.smallCovers, [smallUrl, midUrl, largeUrl, fullUrl]);
    expect(track.largeCovers, [largeUrl, fullUrl, midUrl]);
    expect(track.fullCovers, [fullUrl, largeUrl, midUrl, smallUrl]);
    expect(song(cover: null).smallCovers, isEmpty);
    expect(song(cover: null, mid: midUrl).smallCovers, [midUrl]);
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

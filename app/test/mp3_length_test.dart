import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ownsemble/playback/mp3_length.dart';

import 'mp3_samples.dart';

void main() {
  test('a plain CBR file is measured from its size and bitrate', () {
    final song = songOf(219.2);
    final reading = readHead(song.sublist(0, 20000), song.length);
    expect(reading.needMore, isFalse);
    expect(reading.facts!.bytes, song.length);
    expect(reading.facts!.seconds, closeTo(219.2, 0.3));
  });

  test('an Info frame count gives the exact length', () {
    // The size alone would say about 2 s: the count wins.
    final frames = cbrFrames(80, infoCount: 8400);
    final reading = readHead(frames, frames.length);
    expect(reading.facts!.seconds, closeTo(8400 * frameSeconds, 0.001));
  });

  test('a long ID3 tag with a Cyrillic title is skipped', () {
    final tag = id3Tag('Ты и я', padding: 300000);
    final song = songOf(226.5, tag: tag);
    // The first frame is past the first bytes: more are needed.
    expect(readHead(song.sublist(0, 20000), song.length).needMore, isTrue);
    expect(audioStartOf(song), tag.length);
    final reading = readHead(
      song.sublist(0, tag.length + framesWindow),
      song.length,
    );
    expect(reading.needMore, isFalse);
    expect(reading.facts!.seconds, closeTo(226.5, 0.3));
  });

  test('stray 0xFF bytes before the audio are not taken for a frame', () {
    final junk = [0xFF, 0xFB, 0x10, 0x00, 7, 7, 7, 7, 0xFF, 0xE3, 0x00];
    final song = [...junk, ...songOf(100)];
    final seconds = estimateMp3Seconds(
      song.sublist(0, framesWindow),
      audioStart: 0,
      totalBytes: song.length,
    );
    expect(seconds, closeTo(100, 0.3));
  });

  test('bytes with no frame give no length', () {
    final noise = List<int>.filled(30000, 0x41);
    expect(readHead(noise, noise.length).facts, isNull);
    expect(readHead(noise, noise.length).needMore, isFalse);
  });

  test('a few bytes of a long file ask for more', () {
    expect(readHead([0x49, 0x44], 1000000).needMore, isTrue);
  });

  test('another recording is more than 3 s off, a match within 1 s', () {
    const swapped = FileFacts(bytes: 9062443, seconds: 226.5);
    const listed = FileFacts(bytes: 8770917, seconds: 219.2);
    expect(swapped.differsFrom(219), isTrue);
    expect(listed.differsFrom(219), isFalse);
    expect(const FileFacts(bytes: 1, seconds: 222).differsFrom(219), isFalse);
    expect(const FileFacts(bytes: 1, seconds: 222.1).differsFrom(219), isTrue);
    expect((listed.seconds - 219).abs() <= matchSeconds, isTrue);
  });

  group('stored and remote files', () {
    late Directory folder;
    late HttpServer server;
    final http = HttpClient();
    final tagged = songOf(
      219.2,
      tag: id3Tag('Операция Пластилин', padding: 120000),
    );
    final plain = songOf(226.5);
    var ignoreRanges = false;
    var requests = 0;

    setUp(() async {
      folder = Directory.systemTemp.createTempSync('mp3_length_test');
      requests = 0;
      ignoreRanges = false;
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        requests++;
        final song = request.uri.path == '/tagged' ? tagged : plain;
        final range = request.headers.value(HttpHeaders.rangeHeader);
        final response = request.response
          ..headers.contentType = ContentType('audio', 'mpeg');
        if (request.uri.path == '/page') {
          response
            ..statusCode = HttpStatus.gatewayTimeout
            ..headers.contentType = ContentType.html
            ..write('<html>504</html>');
        } else if (range == null || ignoreRanges) {
          response
            ..contentLength = song.length
            ..add(song);
        } else {
          final match = RegExp(r'bytes=(\d+)-(\d+)').firstMatch(range)!;
          final start = int.parse(match.group(1)!);
          final end = int.parse(match.group(2)!).clamp(0, song.length - 1);
          response
            ..statusCode = HttpStatus.partialContent
            ..headers.set(
              HttpHeaders.contentRangeHeader,
              'bytes $start-$end/${song.length}',
            )
            ..add(song.sublist(start, end + 1));
        }
        await response.close();
      });
    });

    tearDown(() async {
      await server.close(force: true);
      folder.deleteSync(recursive: true);
    });

    Uri at(String path) => Uri.parse('http://127.0.0.1:${server.port}$path');

    test('a stored file is measured from a few kilobytes', () {
      final file = File('${folder.path}/Ты и я.mp3')
        ..writeAsBytesSync(Uint8List.fromList(tagged));
      final facts = measureFile(file)!;
      expect(facts.bytes, tagged.length);
      expect(facts.seconds, closeTo(219.2, 0.3));
      expect(measureFile(File('${folder.path}/missing.mp3')), isNull);
    });

    test('a remote file takes one range read', () async {
      final facts = (await measureRemote(http, at('/plain')))!;
      expect(facts.bytes, plain.length);
      expect(facts.seconds, closeTo(226.5, 0.3));
      expect(requests, 1);
    });

    test('a long tag takes a second read after it', () async {
      final facts = (await measureRemote(http, at('/tagged')))!;
      expect(facts.seconds, closeTo(219.2, 0.3));
      expect(requests, 2);
    });

    test('a server that ignores the range is cut off early', () async {
      ignoreRanges = true;
      final facts = (await measureRemote(http, at('/plain')))!;
      expect(facts.seconds, closeTo(226.5, 0.3));
    });

    test('an error page is no audio', () async {
      expect(await measureRemote(http, at('/page')), isNull);
    });
  });
}

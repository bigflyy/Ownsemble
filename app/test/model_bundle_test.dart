// Plan 10 I2a: the "Hear the words" downloads are bundles of files that are
// ready only when every file of the same version checks out.

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ownsemble/lyrics/fit_model.dart';
import 'package:ownsemble/lyrics/model_bundle.dart';
import 'package:ownsemble/lyrics/stt_models.dart';

void main() {
  late Directory dir;
  late HttpServer server;
  // Path -> bytes served there.
  final served = <String, List<int>>{};
  // Requests seen: "path range".
  final requests = <String>[];
  // Paths that answer 404.
  final missing = <String>{};
  // Path -> bytes after which the connection breaks (once).
  final cutOnce = <String, int>{};

  setUp(() async {
    final faked = HttpOverrides.current;
    HttpOverrides.global = null;
    addTearDown(() => HttpOverrides.global = faked);
    dir = Directory.systemTemp.createTempSync('bundle-test');
    served.clear();
    requests.clear();
    missing.clear();
    cutOnce.clear();
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      final path = request.uri.path;
      final range = request.headers.value(HttpHeaders.rangeHeader);
      requests.add('$path ${range ?? '-'}');
      final body = served[path];
      final response = request.response;
      if (body == null || missing.contains(path)) {
        response.statusCode = HttpStatus.notFound;
        await response.close();
        return;
      }
      final from = range != null
          ? int.parse(range.substring(6, range.length - 1))
          : 0;
      if (from > 0) {
        response
          ..statusCode = HttpStatus.partialContent
          ..headers.set(
            HttpHeaders.contentRangeHeader,
            'bytes $from-${body.length - 1}/${body.length}',
          );
      }
      final part = body.sublist(from);
      response.contentLength = part.length;
      final cut = cutOnce.remove(path);
      if (cut != null) {
        final socket = await response.detachSocket();
        socket.add(part.sublist(0, cut));
        await socket.flush();
        await socket.close();
        return;
      }
      response.add(part);
      await response.close();
    });
  });
  tearDown(() async {
    await server.close(force: true);
    dir.deleteSync(recursive: true);
  });

  Uri at(String path) => Uri.parse('http://127.0.0.1:${server.port}$path');

  ModelFile serve(String path, String fileName, int size, {int seed = 1}) {
    final body = [for (var i = 0; i < size; i++) (i * 7 + seed) % 251];
    served[path] = body;
    return ModelFile(
      url: at(path),
      bytes: size,
      sha256: sha256.convert(body).toString(),
      fileName: fileName,
    );
  }

  ModelBundle bundleOf(List<ModelFile> files, {int version = 1}) =>
      ModelBundle(
        name: 'hear-words',
        version: version,
        files: files,
        notices: 'Test notices: Cyrillic текст.\n',
      );

  Directory root() => Directory('${dir.path}/models');

  test('downloads every file, then marks the bundle ready', () async {
    final bundle = bundleOf([
      serve('/a.onnx', 'a.onnx', 200000),
      serve('/b.npz', 'gigaam/b.npz', 50000, seed: 2),
    ]);
    expect(bundleReady(root(), bundle), isFalse);
    final seen = <int>[];
    await downloadBundle(
      bundle,
      root(),
      onProgress: (bytes, total) {
        expect(total, 250000);
        seen.add(bytes);
      },
    );
    expect(bundleReady(root(), bundle), isTrue);
    expect(seen.last, 250000);
    expect(
      bundleFile(root(), bundle, 'gigaam/b.npz').readAsBytesSync(),
      served['/b.npz'],
    );
    final folder = bundleFolder(root(), bundle).path;
    expect(
      File('$folder/NOTICES.txt').readAsStringSync(),
      contains('текст'),
      reason: 'UTF-8 round trip',
    );
    expect(
      jsonDecode(File('$folder/$bundleMarkerName').readAsStringSync()),
      bundle.manifest,
    );
    // A second call fetches nothing.
    requests.clear();
    await downloadBundle(bundle, root());
    expect(requests, isEmpty);
  });

  test('a stop keeps finished files and the part; the next try continues '
      'the part and never fetches a finished file again', () async {
    final bundle = bundleOf([
      serve('/a.onnx', 'a.onnx', 100000),
      serve('/b.onnx', 'b.onnx', 300000, seed: 3),
    ]);
    final stop = DownloadStop();
    await expectLater(
      downloadBundle(
        bundle,
        root(),
        stop: stop,
        onProgress: (bytes, _) {
          if (bytes > 100000) stop.stop();
        },
      ),
      throwsA(isA<DownloadStopped>()),
    );
    expect(bundleReady(root(), bundle), isFalse);
    final part = File('${bundleFile(root(), bundle, 'b.onnx').path}.part');
    expect(part.existsSync(), isTrue);
    final have = part.lengthSync();
    expect(have, greaterThan(0));
    expect(bundleBytesLeft(root(), bundle), 300000 - have);
    requests.clear();
    await downloadBundle(bundle, root());
    expect(bundleReady(root(), bundle), isTrue);
    expect(requests, ['/b.onnx bytes=$have-']);
  });

  test('a broken connection: the retry continues where it stopped', () async {
    final bundle = bundleOf([serve('/a.onnx', 'a.onnx', 200000)]);
    cutOnce['/a.onnx'] = 70000;
    await expectLater(
      downloadBundle(bundle, root()),
      throwsA(isA<ModelDownloadError>()),
    );
    expect(bundleReady(root(), bundle), isFalse);
    await downloadBundle(bundle, root());
    expect(requests.last, '/a.onnx bytes=70000-');
    expect(bundleReady(root(), bundle), isTrue);
  });

  test('a corrupt part is rejected and deleted; the next try starts the '
      'file over', () async {
    final bundle = bundleOf([serve('/a.onnx', 'a.onnx', 100000)]);
    final target = bundleFile(root(), bundle, 'a.onnx');
    File('${target.path}.part')
      ..parent.createSync(recursive: true)
      ..writeAsBytesSync(List.filled(100000, 9));
    await expectLater(
      downloadBundle(bundle, root()),
      throwsA(
        isA<ModelDownloadError>().having(
          (e) => e.message,
          'message',
          contains('damaged'),
        ),
      ),
    );
    expect(File('${target.path}.part').existsSync(), isFalse);
    expect(bundleReady(root(), bundle), isFalse);
    await downloadBundle(bundle, root());
    expect(requests.last, '/a.onnx -');
    expect(bundleReady(root(), bundle), isTrue);
  });

  test('a whole file with the wrong bytes and no marker is read again and '
      'replaced', () async {
    final bundle = bundleOf([serve('/a.onnx', 'a.onnx', 100000)]);
    bundleFile(root(), bundle, 'a.onnx')
      ..parent.createSync(recursive: true)
      ..writeAsBytesSync(List.filled(100000, 5));
    expect(bundleReady(root(), bundle), isFalse);
    await downloadBundle(bundle, root());
    expect(
      bundleFile(root(), bundle, 'a.onnx').readAsBytesSync(),
      served['/a.onnx'],
    );
  });

  test('a mixed-version bundle is never ready: an old marker, or a marker '
      'whose list differs, refuses it', () async {
    final v1 = bundleOf([serve('/a1.onnx', 'a.onnx', 100000)]);
    await downloadBundle(v1, root());
    expect(bundleReady(root(), v1), isTrue);
    // Version 2 changes the file: its folder is new, version 1 is not it.
    final v2 = bundleOf([
      serve('/a2.onnx', 'a.onnx', 100000, seed: 4),
    ], version: 2);
    expect(bundleReady(root(), v2), isFalse);
    // Version 1's file copied into version 2's folder, with version 1's
    // marker: the same size, a different list.
    final v2folder = bundleFolder(root(), v2)..createSync(recursive: true);
    File('${bundleFolder(root(), v1).path}/a.onnx').copySync(
      '${v2folder.path}/a.onnx',
    );
    File(
      '${bundleFolder(root(), v1).path}/$bundleMarkerName',
    ).copySync('${v2folder.path}/$bundleMarkerName');
    expect(bundleReady(root(), v2), isFalse);
    await downloadBundle(v2, root());
    expect(bundleReady(root(), v2), isTrue);
    expect(
      bundleFile(root(), v2, 'a.onnx').readAsBytesSync(),
      served['/a2.onnx'],
    );
    expect(
      bundleFolder(root(), v1).existsSync(),
      isFalse,
      reason: 'the old version is removed once the new one is ready',
    );
  });

  test('the same version with a changed hash in the app is not ready, and '
      'the stale file is fetched again', () async {
    final first = bundleOf([serve('/a.onnx', 'a.onnx', 100000)]);
    await downloadBundle(first, root());
    final changed = bundleOf([serve('/a.onnx', 'a.onnx', 100000, seed: 8)]);
    expect(bundleReady(root(), changed), isFalse);
    await downloadBundle(changed, root());
    expect(bundleReady(root(), changed), isTrue);
    expect(
      bundleFile(root(), changed, 'a.onnx').readAsBytesSync(),
      served['/a.onnx'],
    );
  });

  test('a failing first address moves on to the mirror', () async {
    final file = serve('/a.onnx', 'a.onnx', 100000);
    served['/mirror/a.onnx'] = served['/a.onnx']!;
    missing.add('/a.onnx');
    final bundle = bundleOf([
      ModelFile(
        url: file.url,
        bytes: file.bytes,
        sha256: file.sha256,
        fileName: file.fileName,
        mirrors: [at('/mirror/a.onnx')],
      ),
    ]);
    await downloadBundle(bundle, root());
    expect(requests, ['/a.onnx -', '/mirror/a.onnx -']);
    expect(bundleReady(root(), bundle), isTrue);
  });

  test('every address failing gives the last reason', () async {
    final file = serve('/a.onnx', 'a.onnx', 1000);
    missing.add('/a.onnx');
    final bundle = bundleOf([
      ModelFile(
        url: file.url,
        bytes: file.bytes,
        sha256: file.sha256,
        fileName: file.fileName,
        mirrors: [at('/nowhere.onnx')],
      ),
    ]);
    await expectLater(
      downloadBundle(bundle, root()),
      throwsA(
        isA<ModelDownloadError>().having(
          (e) => e.message,
          'message',
          contains('answered 404'),
        ),
      ),
    );
  });

  test('the disk check counts the job working space and asks nothing of '
      'the server', () async {
    final bundle = bundleOf([serve('/a.onnx', 'a.onnx', 100000)]);
    await expectLater(
      downloadBundle(
        bundle,
        root(),
        // Enough for the file and the spare, not for the working space.
        freeBytes: () => 100000 + modelSpareBytes + 1000,
        workingBytes: 5000,
      ),
      throwsA(
        isA<ModelDownloadError>()
            .having((e) => e.retry, 'retry', isFalse)
            .having((e) => e.message, 'message', contains('free space')),
      ),
    );
    expect(requests, isEmpty);
    await downloadBundle(
      bundle,
      root(),
      freeBytes: () => 100000 + modelSpareBytes + 5000,
      workingBytes: 5000,
    );
    expect(bundleReady(root(), bundle), isTrue);
  });

  test('bundleIntact deletes a damaged file and the marker', () async {
    final bundle = bundleOf([
      serve('/a.onnx', 'a.onnx', 1000),
      serve('/b.onnx', 'b.onnx', 1000, seed: 6),
    ]);
    await downloadBundle(bundle, root());
    expect(await bundleIntact(root(), bundle), isTrue);
    bundleFile(
      root(),
      bundle,
      'b.onnx',
    ).writeAsBytesSync(List.filled(1000, 1));
    expect(bundleReady(root(), bundle), isTrue, reason: 'sizes only');
    expect(await bundleIntact(root(), bundle), isFalse);
    expect(bundleReady(root(), bundle), isFalse);
    requests.clear();
    await downloadBundle(bundle, root());
    expect(requests, ['/b.onnx -']);
    expect(bundleReady(root(), bundle), isTrue);
  });

  group('the catalog', () {
    test('every file has a hash, a size and one name in its bundle', () {
      for (final bundle in [hearWordsBundle, whisperBundle]) {
        final names = bundle.files.map((f) => f.fileName).toSet();
        expect(names.length, bundle.files.length);
        expect(names, isNot(contains(bundleMarkerName)));
        for (final file in bundle.files) {
          expect(file.sha256, matches(RegExp(r'^[0-9a-f]{64}$')));
          expect(file.bytes, greaterThan(0));
          expect(file.url.scheme, 'https');
        }
      }
      expect(hearWordsBundle.megabytes, 395);
      expect(whisperBundle.megabytes, 585);
    });

    test('Kim Vocal 2 comes only from UVR, never from our release (user '
        '2026-11-24: "except kim")', () {
      final kim = hearWordsBundle.files.singleWhere(
        (f) => f.fileName == 'Kim_Vocal_2.onnx',
      );
      expect(kim.url.host, 'github.com');
      expect(kim.url.path, startsWith('/TRvlvr/model_repo/'));
      expect(kim.mirrors, isEmpty);
      for (final bundle in [hearWordsBundle, whisperBundle]) {
        for (final file in bundle.files) {
          if (file == kim) continue;
          expect(file.url.toString(), startsWith(sttReleaseBase));
        }
      }
    });

    test('whisper.cpp is CPU only, with its licence and build record', () {
      final names = whisperBundle.files.map((f) => f.fileName).toList();
      expect(names.where((n) => n.contains('vulkan')), isEmpty);
      expect(
        names,
        containsAll([
          'whisper.cpp/whisper.dll',
          'whisper.cpp/ggml.dll',
          'whisper.cpp/ggml-base.dll',
          'whisper.cpp/ggml-cpu-x64.dll',
          'whisper.cpp/LICENSE.txt',
          'whisper.cpp/build-info.json',
        ]),
      );
    });
  });
}

import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:ownsemble_flutter_proof/proof_core.dart';
import 'package:ownsemble_flutter_proof/audio_cache.dart';
import 'package:ownsemble_flutter_proof/proof_store.dart';

void main() {
  test(
    'offline reopen prefers real caches and preserves an explicit sample',
    () async {
      final temp = await Directory.systemTemp.createTemp('ownsemble-offline-');
      final store = ProofStore(temp);
      try {
        expect(store.offlineAsset(null), isNull);
        store.saveAsset(
          const CachedAudio('900000000000001_1', 'fixture', 'hash', 1, 4),
        );
        expect(store.offlineAsset(null)?.id, '900000000000001_1');
        store.saveAsset(const CachedAudio('1_2', 'real', 'hash', 1, 4));
        store.saveAsset(
          const CachedAudio('900000000000001_2', 'fixture', 'hash', 1, 4),
        );
        expect(store.offlineAsset(null)?.id, '1_2');
        expect(
          store.offlineAsset('900000000000001_1')?.id,
          '900000000000001_1',
        );
        expect(store.offlineAsset('1_9'), isNull);
      } finally {
        store.close();
        await temp.delete(recursive: true);
      }
    },
  );
  test('provider URLs reject credentials, ports, HTTP, auth origins and suffix lookalikes', () {
    expect(
      allowedAudio(Uri.parse('https://test.vkuseraudio.net/a/index.m3u8')),
      isTrue,
    );
    for (final url in [
      'http://test.vkuseraudio.net/a.mp3',
      'https://name:secret@test.vkuseraudio.net/a.mp3',
      'https://id.vk.com/a.mp3',
      'https://test.vkuseraudio.net.bad.test/a.mp3',
      'https://test.vkuseraudio.net:8443/a.mp3',
    ]) {
      expect(allowedAudio(Uri.parse(url)), isFalse);
    }
  });
  test(
    'ambiguous or absent sources fail; error categories contain no audio URLs',
    () {
      final first = Uri.parse(
        'https://test.vkuseraudio.net/a.mp3?temporary=synthetic',
      );
      expect(selectSource({first}), first);
      expect(() => selectSource({}), throwsA(isA<ProofFailure>()));
      expect(
        () => selectSource({
          first,
          Uri.parse('https://test.vkuseraudio.net/b.mp3'),
        }),
        throwsA(isA<ProofFailure>()),
      );
      expect(categoryOf(Exception(first.toString())), 'operation_failed');
    },
  );
  test(
    'control accepts only fixed actions including restart with a fresh nonce',
    () {
      const nonce = '01234567-0123-4123-8123-012345678901';
      expect(
        parseControl(jsonEncode({'command': 'run', 'nonce': nonce}), null)?.$1,
        'run',
      );
      expect(
        parseControl(jsonEncode({'command': 'run', 'nonce': nonce}), nonce),
        isNull,
      );
      expect(
        parseControl(
          jsonEncode({'command': 'restart', 'nonce': nonce}),
          null,
        )?.$1,
        'restart',
      );
      for (final value in [
        {'command': 'eval', 'nonce': nonce},
        {'command': 'run', 'nonce': nonce, 'script': 'private'},
        {'command': 'run', 'nonce': nonce, 'url': 'https://test.invalid'},
        {'command': 'run', 'nonce': 'bad'},
        {'command': 'restart', 'nonce': nonce, 'executable': 'untrusted.exe'},
        {
          'command': 'restart',
          'nonce': nonce,
          'args': ['untrusted'],
        },
      ]) {
        expect(parseControl(jsonEncode(value), null), isNull);
      }
    },
  );
  test(
    'decoder diagnostics retain specific causes and never return native text',
    () {
      const sensitive = 'https://private.invalid/audio?temporary=synthetic';
      final specific = classifyDecoderFailure(
        'Unable to read key file $sensitive',
      );
      expect(specific, 'decoder_key_unreadable');
      expect(
        classifyDecoderFailure('failed to open $sensitive', specific),
        specific,
      );
      expect(
        classifyDecoderFailure('Invalid data found $sensitive'),
        'decoder_invalid_data',
      );
      expect(
        classifyDecoderFailure('Extension mp3 not allowed $sensitive'),
        'decoder_extension_rejected',
      );
      expect(
        classifyDecoderFailure('Protocol not on whitelist $sensitive'),
        'decoder_protocol_rejected',
      );
      expect(
        classifyDecoderFailure('Failed to recognize file format $sensitive'),
        'decoder_format_unrecognized',
      );
      expect(
        classifyDecoderFailure('No video or audio streams selected.'),
        'decoder_no_audio_stream',
      );
      expect(decoderSignalMask('Failed to recognize file format'), 3);
      expect(decoderSignalMask('https://private.invalid/x?value=synthetic'), 0);
    },
  );
  test('VOD playlists resolve keys and segments but reject live and unsupported encryption', () {
    final source = Uri.parse('https://test.vkuseraudio.net/music/index.m3u8');
    final plan = parseHls(
      '#EXTM3U\n#EXT-X-KEY:METHOD=AES-128,URI="key.pub"\n#EXTINF:4,\na.ts\n#EXT-X-ENDLIST',
      source,
    );
    expect(plan.lines.where((l) => l.resource != null).length, 2);
    expect(
      plan.lines.firstWhere((l) => l.resourceKind == 'key').resource,
      source.resolve('key.pub'),
    );
    expect(
      () => parseHls('#EXTM3U\n#EXTINF:4,\na.ts', source),
      throwsA(isA<ProofFailure>()),
    );
    expect(
      () => parseHls(
        '#EXTM3U\n#EXT-X-KEY:METHOD=SAMPLE-AES,URI="key.pub"\na.ts\n#EXT-X-ENDLIST',
        source,
      ),
      throwsA(isA<ProofFailure>()),
    );
  });
  test(
    'master selection follows bandwidth and byte-range formats fail explicitly',
    () {
      final source = Uri.parse('https://test.vkuseraudio.net/index.m3u8');
      final plan = parseHls(
        '#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=20\na.m3u8\n#EXT-X-STREAM-INF:BANDWIDTH=40\nb.m3u8',
        source,
      );
      expect(plan.variant, source.resolve('b.m3u8'));
      expect(
        () => parseHls(
          '#EXTM3U\n#EXT-X-BYTERANGE:20@0\na.ts\n#EXT-X-ENDLIST',
          source,
        ),
        throwsA(isA<ProofFailure>()),
      );
    },
  );
  test(
    'HLS drops advisory tags, comments and unknown URI-bearing extensions',
    () {
      final plan = parseHls(
        '#EXTM3U\n#EXT-X-ALLOW-CACHE:YES\n'
        '#EXT-X-PROGRAM-DATE-TIME:2026-01-01T00:00:00Z\n'
        '#EXT-X-FUTURE-METADATA:URI="https://account.invalid/private"\n'
        '# a provider comment\n#EXTINF:4,\na.ts\n#EXT-X-ENDLIST',
        Uri.parse('https://test.vkuseraudio.net/index.m3u8'),
      );
      expect(plan.lines.map((l) => l.text).toList(), [
        '#EXTM3U',
        '#EXTINF:4,',
        'a.ts',
        '#EXT-X-ENDLIST',
      ]);
      expect(plan.lines.where((l) => l.resource != null).length, 1);
    },
  );
  test(
    'HLS never ignores known partial, ranged or unsupported resource features',
    () {
      for (final tag in [
        '#EXT-X-BYTERANGE:20@0',
        '#EXT-X-GAP',
        '#EXT-X-I-FRAMES-ONLY',
        '#EXT-X-PART:DURATION=1,URI="partial.ts"',
        '#EXT-X-SKIP:SKIPPED-SEGMENTS=5',
        '#EXT-X-PRELOAD-HINT:TYPE=PART,URI="partial.ts"',
        '#EXT-X-DEFINE:NAME="variable",VALUE="synthetic"',
        '#EXT-X-SESSION-KEY:METHOD=SAMPLE-AES,URI="key.pub"',
      ]) {
        expect(
          () => parseHls(
            '#EXTM3U\n$tag\na.ts\n#EXT-X-ENDLIST',
            Uri.parse('https://test.vkuseraudio.net/index.m3u8'),
          ),
          throwsA(isA<ProofFailure>()),
        );
      }
    },
  );
  test('HLS encryption method matching is exact', () {
    for (final method in [
      'AES-128-UNSUPPORTED',
      'NONE-UNSUPPORTED',
      'SAMPLE-AES',
    ]) {
      expect(
        () => parseHls(
          '#EXTM3U\n#EXT-X-KEY:METHOD=$method,URI="key.pub"\na.ts\n#EXT-X-ENDLIST',
          Uri.parse('https://test.vkuseraudio.net/index.m3u8'),
        ),
        throwsA(isA<ProofFailure>()),
      );
    }
  });
  test('portable cache rewrites local HLS, detects corruption and blocks offline requests', () async {
    final temp = await Directory.systemTemp.createTemp(
      'ownsemble-flutter-cache-',
    );
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    var requests = 0;
    server.listen((request) async {
      requests++;
      request.response.add(
        request.uri.path.endsWith('.m3u8')
            ? utf8.encode(
                '#EXTM3U\n#EXT-X-ALLOW-CACHE:YES\n'
                '#EXT-X-FUTURE-METADATA:URI="https://account.invalid/private"\n'
                '#EXT-X-KEY:METHOD=AES-128,URI="key.pub"\n#EXTINF:4,\na.ts\n#EXT-X-ENDLIST',
              )
            : request.uri.path.endsWith('.pub')
            ? List.filled(16, 7)
            : (await AesCbc.with128bits(macAlgorithm: MacAlgorithm.empty)
                      .encrypt(
                        List.filled(100, 3),
                        secretKey: SecretKey(List.filled(16, 7)),
                        nonce: List.filled(16, 0),
                      ))
                  .cipherText,
      );
      await request.response.close();
    });
    try {
      final cache = AudioCache(temp, (_) async => 4, fixturePort: server.port);
      final asset = await cache.save(
        const Track('1_2', 'Сонг', 'Артист', 4),
        Uri.parse('http://127.0.0.1:${server.port}/index.m3u8'),
      );
      expect(await File(asset.entry).readAsString(), isNot(contains('http')));
      expect(
        requests,
        3,
      ); // Only manifest, local key and segment; no metadata URI.
      await cache.verify(asset);
      cache.offline = true;
      final count = requests;
      await expectLater(
        cache.fetch(Uri.parse('http://127.0.0.1:${server.port}/a.ts')),
        throwsA(isA<ProofFailure>()),
      );
      expect(requests, count);
      await File('${File(asset.entry).parent.path}/part-1.ts')
          .writeAsString('corrupt');
      await expectLater(cache.verify(asset), throwsA(isA<ProofFailure>()));
    } finally {
      await server.close(force: true);
      await temp.delete(recursive: true);
    }
  });
  test('cache rejects redirects to account endpoints and does not publish incomplete audio', () async {
    final temp = await Directory.systemTemp.createTemp(
      'ownsemble-flutter-fail-',
    );
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      request.response.statusCode = 302;
      request.response.headers.set('location', 'https://id.vk.com/');
      await request.response.close();
    });
    try {
      final cache = AudioCache(temp, (_) async => 4, fixturePort: server.port);
      await expectLater(
        cache.save(
          const Track('1_2', 'Track', 'Artist', 4),
          Uri.parse('http://127.0.0.1:${server.port}/a.mp3'),
        ),
        throwsA(isA<ProofFailure>()),
      );
      expect(await temp.list().length, 0);
    } finally {
      await server.close(force: true);
      await temp.delete(recursive: true);
    }
  });
  test(
    'SQLite preserves metadata, duplicate identities and privacy across reopen',
    () async {
      final temp = await Directory.systemTemp.createTemp(
        'ownsemble-flutter-db-',
      );
      try {
        var db = ProofStore(temp);
        db.merge(const [
          Track('1_2', "'; DROP TABLE tracks; --", 'Артист', 4),
          Track('1_3', 'Second', 'Artist', 4),
        ]);
        db.merge(const [Track('1_2', 'Updated', 'Артист', 4)]);
        db.record('test', {
          'count': 2,
          'url': 'https://private.invalid',
          'category': 'https://private.invalid',
        });
        db.close();
        db = ProofStore(temp);
        expect(db.tracks().length, 2);
        expect(db.tracks().first.artist, 'Артист');
        expect(
          await File('${temp.path}/evidence.json').readAsString(),
          isNot(contains('private.invalid')),
        );
        db.close();
      } finally {
        await temp.delete(recursive: true);
      }
    },
  );
}

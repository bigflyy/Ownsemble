import 'package:flutter_test/flutter_test.dart';
import 'package:ownsemble/media/audio_policy.dart';
import 'package:ownsemble/provider/cached_source_witness.dart';

void main() {
  test(
    'master playlist witness follows the same guarded rendition as playback',
    () async {
      final source = Uri.parse(
        'https://music.vkuseraudio.ru/audio/master.m3u8',
      );
      final rendition = source.resolve('high/index.m3u8');
      final segment = rendition.resolve('one.ts?exact=fixture');
      final fetched = <Uri>[];
      final witness = CachedSourceWitness(
        (uri) => loadManifestSegments(uri, (uri) async {
          fetched.add(uri);
          return uri == source
              ? '''#EXTM3U
#EXT-X-STREAM-INF:BANDWIDTH=64000
low/index.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=192000
high/index.m3u8
'''
              : '''#EXTM3U
#EXTINF:4,
one.ts?exact=fixture
#EXT-X-ENDLIST
''';
        }),
      );
      expect(await witness.match([source], {segment}), {source});
      expect(fetched, [source, rendition]);
      final unsafe = '''#EXTM3U
#EXT-X-STREAM-INF:BANDWIDTH=1
https://attacker.test/index.m3u8
''';
      var reads = 0;
      await expectLater(
        loadManifestSegments(source, (_) async {
          reads++;
          return unsafe;
        }),
        throwsA(isA<ProofFailure>()),
      );
      expect(reads, 1);
      reads = 0;
      await expectLater(
        loadManifestSegments(source, (_) async {
          reads++;
          return '''#EXTM3U
#EXT-X-STREAM-INF:BANDWIDTH=1
master.m3u8
''';
        }),
        throwsA(isA<ProofFailure>()),
      );
      expect(reads, 4);
    },
  );

  final first = Uri.parse('https://test.vkuseraudio.net/one.m3u8');
  final second = Uri.parse('https://test.vkuseraudio.net/two.m3u8');
  final segment = Uri.parse(
    'https://test.vkuseraudio.net/selected.ts?key=fixture',
  );
  test(
    'cached source needs an exact segment, not a shared path or hostname',
    () async {
      var reads = 0;
      final witness = CachedSourceWitness((uri) async {
        reads++;
        return {segment};
      });
      expect(await witness.match([first], {}), isEmpty);
      expect(reads, 0);
      expect(
        await witness.match([first], {segment.replace(query: 'key=other')}),
        isEmpty,
      );
      expect(await witness.match([first], {segment}), {first});
      expect(reads, 1);
      expect(
        await witness.match(
          [Uri.parse('https://attacker.test/one.m3u8')],
          {segment},
        ),
        isEmpty,
      );
      expect(reads, 1);
    },
  );
  test(
    'multiple matching manifests remain ambiguous and failures stay closed',
    () async {
      final witness = CachedSourceWitness((_) async => {segment});
      final matched = await witness.match([first, second], {segment});
      expect(() => selectSource(matched), throwsA(isA<ProofFailure>()));
      var reads = 0;
      final broken = CachedSourceWitness((_) async {
        reads++;
        throw StateError('fixture failure');
      });
      expect(await broken.match([first], {segment}), isEmpty);
      expect(await broken.match([first], {segment}), isEmpty);
      expect(reads, 1);
    },
  );
  test('cached manifest probing has a strict request bound', () async {
    var reads = 0;
    final witness = CachedSourceWitness((_) async {
      reads++;
      return {segment};
    });
    final many = List.generate(
      9,
      (i) => Uri.parse('https://test.vkuseraudio.net/$i.m3u8'),
    );
    await expectLater(
      witness.match(many, {segment}),
      throwsA(isA<ProofFailure>()),
    );
    expect(reads, 0);
  });
}

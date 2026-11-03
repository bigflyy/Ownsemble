import 'package:flutter_test/flutter_test.dart';
import 'package:ownsemble/library/track.dart';
import 'package:ownsemble/playback/stream_route.dart';
import 'package:ownsemble/vk/vk_client.dart';

/// [VkClient] standing for one account: answers `audio.getById` for the keys
/// in [links] (null = VK gives no link), throws [failure] when set, and
/// records what it was asked.
class AccountClient extends VkClient {
  AccountClient(this.links, {this.failure}) : super(const []);

  final Map<String, String?> links;
  final Object? failure;
  final asked = <String>[];

  @override
  Future<Object?> call(String method, Map<String, String> params) async {
    final id = params['audios']!;
    asked.add(id);
    final failure = this.failure;
    if (failure != null) throw failure;
    if (!links.containsKey(id)) return [];
    final link = links[id];
    return [
      {'url': link ?? ''},
    ];
  }
}

Track song({
  int sourceId = 1,
  String? key = '1_10',
  int? goneAtMs,
  List<TrackCopy> copies = const [],
}) => Track(
  id: 7,
  sourceId: sourceId,
  source: TrackSource.vk,
  artist: 'Ария',
  title: 'Беспечный ангел',
  durationSec: 200,
  sourceKey: key,
  goneAtMs: goneAtMs,
  copies: copies,
);

void main() {
  group('streamRoutes', () {
    test('a song of one account goes through that account only', () {
      final first = AccountClient({});
      final second = AccountClient({});
      final routes = streamRoutes(
        song(sourceId: 2, key: '2_20'),
        (source) => {1: first, 2: second}[source],
      );
      expect(routes.map((r) => r.sourceId), [2]);
      expect(routes.single.client, same(second));
      expect(routes.single.sourceKey, '2_20');
    });

    test('a merged song tries the listed copy first, then the others', () {
      final track = song(
        copies: const [TrackCopy(sourceId: 2, sourceKey: '2_20')],
      );
      final routes = streamRoutes(track, (source) => AccountClient({}));
      expect(routes.map((r) => r.sourceKey), ['1_10', '2_20']);
    });

    test('copies an account lost come after the live ones', () {
      final track = song(
        goneAtMs: 5,
        copies: const [TrackCopy(sourceId: 2, sourceKey: '2_20')],
      );
      final routes = streamRoutes(track, (source) => AccountClient({}));
      expect(routes.map((r) => r.sourceId), [2, 1]);
    });

    test('accounts with no session are skipped', () {
      final second = AccountClient({});
      final track = song(
        copies: const [TrackCopy(sourceId: 2, sourceKey: '2_20')],
      );
      final routes = streamRoutes(
        track,
        (source) => source == 2 ? second : null,
      );
      expect(routes.map((r) => r.sourceId), [2]);
      expect(streamRoutes(track, (source) => null), isEmpty);
    });

    test('a song with no VK key has no route', () {
      expect(streamRoutes(song(key: null), (s) => AccountClient({})), isEmpty);
      final local = Track(
        id: 1,
        sourceId: 1,
        source: TrackSource.generated,
        artist: 'a',
        title: 'b',
        durationSec: 1,
        sourceKey: '1_1',
      );
      expect(streamRoutes(local, (s) => AccountClient({})), isEmpty);
    });
  });

  group('resolveRouted', () {
    final merged = song(
      copies: const [TrackCopy(sourceId: 2, sourceKey: '2_20')],
    );

    test('the first account with a link wins; the next is not asked', () async {
      final first = AccountClient({'1_10': 'https://a.example/1.mp3'});
      final second = AccountClient({'2_20': 'https://b.example/2.mp3'});
      final routed = await resolveRouted(
        streamRoutes(merged, (s) => {1: first, 2: second}[s]),
      );
      expect(routed!.route.sourceId, 1);
      expect(routed.stream.link, isNotNull);
      expect(routed.skipped, 0);
      expect(second.asked, isEmpty);
    });

    test('an account with no link hands over to the next', () async {
      final first = AccountClient({'1_10': null});
      final second = AccountClient({'2_20': 'https://b.example/2.mp3'});
      final routed = await resolveRouted(
        streamRoutes(merged, (s) => {1: first, 2: second}[s]),
      );
      expect(routed!.route.sourceId, 2);
      expect(routed.route.client, same(second));
      expect(routed.skipped, 1);
    });

    test('an account VK refuses hands over to the next', () async {
      final first = AccountClient(
        {},
        failure: VkException('web_token refused: type=error'),
      );
      final second = AccountClient({'2_20': 'https://b.example/2.mp3'});
      final routed = await resolveRouted(
        streamRoutes(merged, (s) => {1: first, 2: second}[s]),
      );
      expect(routed!.route.sourceId, 2);
    });

    test('a dead line stops at once instead of trying every account', () async {
      final first = AccountClient(
        {},
        failure: VkException('timed out', transient: true),
      );
      final second = AccountClient({'2_20': 'https://b.example/2.mp3'});
      await expectLater(
        resolveRouted(streamRoutes(merged, (s) => {1: first, 2: second}[s])),
        throwsA(isA<VkException>()),
      );
      expect(second.asked, isEmpty);
    });

    test('no account with a link gives the first account\'s answer', () async {
      final first = AccountClient({'1_10': null});
      final second = AccountClient({});
      final routed = await resolveRouted(
        streamRoutes(merged, (s) => {1: first, 2: second}[s]),
      );
      expect(routed!.stream.link, isNull);
      expect(routed.route.sourceId, 1);
    });

    test('every account refused: the first refusal is thrown', () async {
      final first = AccountClient({}, failure: VkException('first'));
      final second = AccountClient({}, failure: VkException('second'));
      await expectLater(
        resolveRouted(streamRoutes(merged, (s) => {1: first, 2: second}[s])),
        throwsA(
          isA<VkException>().having((e) => e.message, 'message', 'first'),
        ),
      );
    });

    test('no route: null', () async {
      expect(await resolveRouted(const []), isNull);
    });
  });
}

import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ownsemble/playback/version_book.dart';
import 'package:ownsemble/vk/vk_client.dart';
import 'package:ownsemble/vk/vk_versions.dart';

/// [VkClient] answering `audio.search` with [items] each time.
class SearchingVk extends VkClient {
  SearchingVk(this.items) : super(const []);

  final List<Map<String, dynamic>> items;
  int searches = 0;

  @override
  Future<Object?> call(String method, Map<String, String> params) async {
    expect(method, 'audio.search');
    searches++;
    return {'count': items.length, 'items': items};
  }
}

/// [VkClient] whose `audio.search` requests hang (never answer) for the
/// first [hanging] calls, then answer with [items].
class StallingVk extends VkClient {
  StallingVk(this.items, {required this.hanging}) : super(const []);

  final List<Map<String, dynamic>> items;
  final int hanging;
  int searches = 0;

  @override
  Future<Object?> call(String method, Map<String, String> params) {
    expect(method, 'audio.search');
    searches++;
    if (searches <= hanging) return Completer<Object?>().future;
    return Future.value({'count': items.length, 'items': items});
  }
}

void main() {
  const query = VersionQuery(
    artist: 'Операция Пластилин',
    title: 'Ты и я',
    vkTrackId: 74440157,
    ownKeys: {'1_1'},
  );

  // Real run 2026-11-06 (plan 03, C1): while the first full file check
  // read thousands of files on the same accounts, VK answered a play's
  // search with no songs at all, and "nothing matches" was stored for good.
  // A search for a library song always finds at least that song.
  test('a search that answers with no songs at all is a failed search', () {
    final vk = SearchingVk(const []);
    expect(
      findVkVersions(vk, query),
      throwsA(
        isA<VkException>().having((e) => e.transient, 'transient', isTrue),
      ),
    );
  });

  test('songs that are not uploads of this one are a real answer', () async {
    final vk = SearchingVk([
      {
        'owner_id': 5,
        'id': 1,
        'artist': 'Другая группа',
        'title': 'Другая песня',
        'duration': 200,
      },
    ]);
    expect(await findVkVersions(vk, query), isEmpty);
    expect(vk.searches, 1);
  });

  // Real VK 2026-11-06 (tool/probe_search_pace.dart, test account): the
  // search answered in 0.2-4 s, but 1 request in about 40 sent nothing until
  // the 15 s limit. Four tries of 15 s kept the versions place "searching"
  // for about a minute before it said the search failed.
  group('a stalled search request', () {
    final song = {
      'owner_id': 7,
      'id': 3,
      'artist': 'Операция Пластилин',
      'title': 'Ты и я',
      'duration': 219,
    };

    test('is sent again after a few seconds and the next answer wins', () {
      fakeAsync((async) {
        final vk = StallingVk([song], hanging: 1);
        List<Object>? found;
        findVkVersions(vk, query).then((versions) => found = versions);
        async.elapse(const Duration(seconds: 5));
        expect(found, hasLength(1));
        expect(vk.searches, 2);
      });
    });

    test('fails within 15 s when VK never answers', () {
      fakeAsync((async) {
        final vk = StallingVk([song], hanging: 99);
        Object? failure;
        findVkVersions(vk, query).catchError((Object e) {
          failure = e;
          return const <Never>[];
        });
        async.elapse(const Duration(seconds: 15));
        expect(
          failure,
          isA<VkException>().having((e) => e.transient, 'transient', isTrue),
        );
        expect(vk.searches, 3);
      });
    });
  });

  test('a captcha is named as VK asking to slow down, not a broken search', () {
    final words = searchFailure(
      VkException('audio.search error 14: Captcha needed', code: 14),
    );
    expect(words, contains('too many searches'));
    expect(words, isNot(contains('error 14')));
  });
}

import 'package:flutter_test/flutter_test.dart';
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
}

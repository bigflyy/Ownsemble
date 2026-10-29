// Checks whether tracks missing from 50-track pages are exactly the tracks
// without a stream URL, using offset += requested page size.
import 'probe.dart' as probe;

Future<void> main() async {
  final cookies = probe.loadSession();
  final auth = await probe.fetchWebToken(cookies);
  String idOf(Map<String, dynamic> t) => '${t['owner_id']}_${t['id']}';
  final full =
      (await probe.callApi(
            'audio.get',
            {'owner_id': '${auth.userId}', 'count': '200'},
            auth.token,
            cookies,
          ) as Map<String, dynamic>)['items']
          as List;
  final fullTracks = full.cast<Map<String, dynamic>>();
  final noUrl = fullTracks
      .where((t) => (t['url'] as String? ?? '').isEmpty)
      .map(idOf)
      .toSet();
  final paged = <String>{};
  for (var offset = 0; offset < fullTracks.length; offset += 50) {
    final page = await probe.callApi(
      'audio.get',
      {'owner_id': '${auth.userId}', 'count': '50', 'offset': '$offset'},
      auth.token,
      cookies,
    ) as Map<String, dynamic>;
    paged.addAll(
      (page['items'] as List).cast<Map<String, dynamic>>().map(idOf),
    );
  }
  final missing = fullTracks.map(idOf).toSet().difference(paged);
  print(
    'paged unique=${paged.length}, missing=${missing.length}, no-url=${noUrl.length}, '
    'missing == no-url: ${missing.length == noUrl.length && missing.containsAll(noUrl)}',
  );
  probe.http.close(force: true);
}

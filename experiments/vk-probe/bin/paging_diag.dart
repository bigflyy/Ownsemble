// Diagnoses offset paging in audio.get: compares each 50-track page with the
// matching slice of a one-request sync. Prints positions only, no titles.
import 'probe.dart' as probe;

Future<void> main() async {
  final cookies = probe.loadSession();
  final auth = await probe.fetchWebToken(cookies);
  String idOf(Map<String, dynamic> t) => '${t['owner_id']}_${t['id']}';
  for (var run = 1; run <= 2; run++) {
    final full = await probe.callApi(
      'audio.get',
      {'owner_id': '${auth.userId}', 'count': '200'},
      auth.token,
      cookies,
    ) as Map<String, dynamic>;
    final fullIds = (full['items'] as List)
        .cast<Map<String, dynamic>>()
        .map(idOf)
        .toList();
    print(
      'run $run: one-request count=${full['count']} items=${fullIds.length}',
    );
    for (var offset = 0; offset < fullIds.length; offset += 50) {
      final page = await probe.callApi(
        'audio.get',
        {'owner_id': '${auth.userId}', 'count': '50', 'offset': '$offset'},
        auth.token,
        cookies,
      ) as Map<String, dynamic>;
      final ids = (page['items'] as List)
          .cast<Map<String, dynamic>>()
          .map(idOf)
          .toList();
      final positions = ids.map(fullIds.indexOf).toList();
      print(
        '  offset $offset: ${ids.length} items, full-list positions ${positions.first}..${positions.last}, '
        'in-order: ${Iterable.generate(positions.length - 1).every((i) => positions[i + 1] == positions[i] + 1)}',
      );
    }
  }
  probe.http.close(force: true);
}

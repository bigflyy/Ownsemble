import 'package:flutter_test/flutter_test.dart';
import 'package:ownsemble/library/search_index.dart';
import 'package:ownsemble/library/track.dart';

Track song(int id, String artist, String title, {String? album}) => Track(
  id: id,
  sourceId: 1,
  source: TrackSource.vk,
  artist: artist,
  title: title,
  album: album,
  durationSec: 200,
);

void main() {
  final index = SearchIndex([
    song(1, 'Ёлка', 'Прованс'),
    song(2, 'Кино', 'Звезда по имени Солнце', album: 'Звезда'),
    song(3, 'Metallica', 'Nothing Else Matters', album: 'Black Album'),
  ]);
  List<int>? ids(String query) =>
      index.search(query)?.map((t) => t.id).toList();

  test('folds ё and ignores case', () {
    expect(ids('елка'), [1]);
    expect(ids('ЁЛК'), [1]);
  });

  test('matches inside words, in any order, across fields', () {
    expect(ids('tallica'), [3]);
    expect(ids('лнце кин'), [2]);
    expect(ids('black nothing'), [3]);
  });

  test('every word must match', () {
    expect(ids('кино metallica'), isEmpty);
  });

  test('keeps library order and treats blank input as no filter', () {
    expect(ids('а'), [1, 2]);
    expect(ids('e'), [3]);
    expect(ids('  '), isNull);
  });
}

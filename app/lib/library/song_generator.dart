import 'dart:math';

import 'library_store.dart';

/// Generates a realistic-looking library for speed checks: Russian and English
/// artists and titles (including "ё"), varied lengths and dates.
///
/// The same [seed] always gives the same songs. They have no audio of their
/// own; the gate tool lets them borrow cached files.
List<NewTrack> generateSongs(int count, {int seed = 2026}) {
  final random = Random(seed);
  String pick(List<String> words) => words[random.nextInt(words.length)];
  String capitalize(String word) =>
      word.isEmpty ? word : word[0].toUpperCase() + word.substring(1);

  // About one artist per 12 songs, as in a typical personal library.
  final artists = List.generate(max(1, count ~/ 12), (index) {
    final russian = random.nextBool();
    final syllables = russian ? _ruSyllables : _enSyllables;
    final first = capitalize(
      List.generate(2 + random.nextInt(2), (_) => pick(syllables)).join(),
    );
    switch (random.nextInt(4)) {
      case 0:
        return first;
      case 1:
        return '${russian ? 'Группа' : 'The'} $first';
      case 2:
        final second = capitalize(
          List.generate(2 + random.nextInt(2), (_) => pick(syllables)).join(),
        );
        return '$first $second';
      default:
        return '$first & ${capitalize(pick(russian ? _ruWords : _enWords))}';
    }
  });

  final now = DateTime.utc(2026, 10, 1).millisecondsSinceEpoch ~/ 1000;
  const fiveYears = 5 * 365 * 24 * 3600;
  return List.generate(count, (index) {
    final russian = random.nextBool();
    final words = russian ? _ruWords : _enWords;
    final title = capitalize(
      List.generate(1 + random.nextInt(4), (_) => pick(words)).join(' '),
    );
    return NewTrack(
      sourceKey: 'gen-$seed-$index',
      artist: artists[random.nextInt(artists.length)],
      title: random.nextInt(10) == 0 ? '$title (Remix)' : title,
      album: random.nextInt(3) == 0 ? null : capitalize(pick(words)),
      durationSec: 120 + random.nextInt(300),
      addedAt: now - random.nextInt(fiveYears),
    );
  });
}

final _ruSyllables =
    'ки но лё ша ма ри зе мфи ра ду ле то сё ва ль ми ро ня жу ко ёж ст ан ви'
        .split(' ');
final _enSyllables = 'ka lo mor ri tan el vi ston bel ra ny dex son ar li mo ver qu sha tor en zy'
    .split(' ');
final _ruWords = 'ёлка звезда ночь город море лето дождь весна дорога небо солнце песня сердце ветер огонь луна всё ещё тёмный зелёный любовь время зима берег последний тишина свет мой твой над без тебя'
    .split(' ');
final _enWords = 'night city love summer rain fire heart road dream light sky ocean moon wild gold shadow dance home storm blue last echo silver forever my your in the of run stay alone'
    .split(' ');

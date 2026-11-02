import 'package:flutter_test/flutter_test.dart';
import 'package:ownsemble/library/search_text.dart';
import 'package:ownsemble/library/track.dart';
import 'package:ownsemble/ui/type_jump.dart';

Track _song(String artist, String title) => Track(
  id: title.hashCode,
  sourceId: 1,
  source: TrackSource.vk,
  artist: artist,
  title: title,
  durationSec: 200,
);

void main() {
  final rows = [
    _song('Metallica', 'One'), // 0
    _song('Кино', 'Группа крови'), // 1
    _song('Rihanna', 'Mad House'), // 2
    _song('Madonna', 'Vogue'), // 3
    _song('Muse', 'Madness'), // 4
    _song('Сплин', 'Ёлка'), // 5
    _song('Queen', "Don't Stop Me Now"), // 6
    _song('Кино', 'Звезда по имени Солнце'), // 7
  ];
  late TypeJump jump;
  late List<int> revealed;

  setUp(() {
    revealed = [];
    jump = TypeJump(rows: () => rows, reveal: revealed.add);
    addTearDown(jump.dispose);
  });

  void typeAll(String text) {
    for (final character in text.split('')) {
      jump.type(character);
    }
  }

  group('hasWordStartingWith', () {
    test('finds the start of any word, not the inside of one', () {
      expect(hasWordStartingWith('mad about you', 'about'), isTrue);
      expect(hasWordStartingWith('mad about you', 'mad'), isTrue);
      expect(hasWordStartingWith('mad about you', 'bout'), isFalse);
    });

    test('a word may follow punctuation', () {
      expect(hasWordStartingWith('#1. поговорить', 'погов'), isTrue);
      expect(hasWordStartingWith('(i can get) no', 'i can'), isTrue);
    });

    test('a later hit counts when the first is inside a word', () {
      expect(hasWordStartingWith('armada mad', 'mad'), isTrue);
    });

    test('the text may run over several words', () {
      expect(hasWordStartingWith('mad about you', 'about y'), isTrue);
    });
  });

  group('matching', () {
    test('a fresh text goes to the first row starting with it', () {
      typeAll('mad');
      expect(jump.row, 2);
      expect(jump.matchCount, 3);
      expect(jump.matchNumber, 1);
      expect(revealed.last, 2);
    });

    test('title and artist both count, album does not', () {
      typeAll('madonna');
      expect(jump.row, 3);
      jump.clear();
      final withAlbum = [
        Track(
          id: 1,
          sourceId: 1,
          source: TrackSource.vk,
          artist: 'a',
          title: 'b',
          album: 'Zulu',
          durationSec: 1,
        ),
      ];
      final other = TypeJump(rows: () => withAlbum, reveal: (_) {});
      addTearDown(other.dispose);
      other.type('z');
      expect(other.row, isNull);
    });

    test('a word inside counts only when nothing starts with the text', () {
      typeAll('st');
      expect(jump.row, 6, reason: 'Stop is the only word; no row starts so');
      jump.clear();
      typeAll('m');
      expect(jump.row, 0, reason: 'Metallica starts; no Don\'t Stop Me Now');
      expect(jump.matchCount, 4);
    });

    test('Cyrillic, either case, on the artist and the title', () {
      typeAll('КИН');
      expect(jump.row, 1);
      expect(jump.matchCount, 2);
      jump.clear();
      typeAll('гру');
      expect(jump.row, 1);
    });

    test('е finds ё and ё finds е', () {
      typeAll('ел');
      expect(jump.row, 5);
      jump.clear();
      final other = TypeJump(rows: () => [_song('x', 'Елка')], reveal: (_) {});
      addTearDown(other.dispose);
      other.type('ё');
      expect(other.row, 0);
    });

    test('a space at the end is ignored, inside it counts', () {
      typeAll('mad ');
      expect(jump.matchCount, 3);
      jump.type('h');
      expect(jump.row, 2);
      expect(jump.matchCount, 1);
    });
  });

  group('moving on', () {
    test('next letters keep the row while it matches', () {
      jump.type('m');
      jump.next();
      jump.next();
      expect(jump.row, 3);
      typeAll('ad');
      expect(jump.row, 3);
      expect(jump.matchNumber, 2);
    });

    test('else they go to the next match after it', () {
      jump.type('m');
      jump.next();
      expect(jump.row, 2);
      typeAll('ado');
      expect(jump.row, 3);
    });

    test('the next match wraps to the top of the list', () {
      final list = [_song('a', 'Mx'), _song('b', 'My')];
      final other = TypeJump(rows: () => list, reveal: (_) {});
      addTearDown(other.dispose);
      other.type('m');
      other.next();
      expect(other.row, 1);
      other.type('x');
      expect(other.row, 0);
    });

    test('next and previous wrap both ways', () {
      typeAll('mad');
      jump.previous();
      expect(jump.row, 4);
      expect(jump.matchNumber, 3);
      jump.next();
      expect(jump.row, 2);
    });
  });

  group('no match', () {
    test('shows no row, and Backspace brings the old one back', () {
      jump.type('m');
      jump.next();
      expect(jump.row, 2);
      jump.type('q');
      expect(jump.row, isNull);
      expect(jump.matchCount, 0);
      expect(jump.isTyping, isTrue);
      jump.backspace();
      expect(jump.text, 'm');
      expect(jump.row, 2);
    });

    test('next and previous do nothing', () {
      typeAll('qqq');
      jump.next();
      jump.previous();
      expect(jump.row, isNull);
    });

    test('Backspace on the last letter ends the jump', () {
      jump.type('m');
      jump.backspace();
      expect(jump.isTyping, isFalse);
      expect(jump.row, isNull);
    });
  });

  group('Ctrl+Backspace takes one word back, as a text editor does', () {
    void typeAll(String text) => text.split('').forEach(jump.type);

    test('the last word goes, the space before it stays', () {
      typeAll('звезда по');
      jump.backspaceWord();
      expect(jump.text, 'звезда ');
    });

    test('spaces at the end go with the word before them', () {
      typeAll('звезда по  ');
      jump.backspaceWord();
      expect(jump.text, 'звезда ');
    });

    test('punctuation is a word of its own', () {
      typeAll("don't");
      jump.backspaceWord();
      expect(jump.text, "don'");
      jump.backspaceWord();
      expect(jump.text, 'don');
    });

    test('the row follows the shorter text', () {
      typeAll('звезда по');
      final row = jump.row;
      typeAll('ъ');
      expect(jump.row, isNull);
      jump.backspaceWord();
      expect(jump.text, 'звезда ');
      expect(jump.row, row);
    });

    test('the only word ends the jump', () {
      typeAll('мад');
      jump.backspaceWord();
      expect(jump.isTyping, isFalse);
      expect(jump.row, isNull);
    });

    test('does nothing with no text', () {
      jump.backspaceWord();
      expect(jump.isTyping, isFalse);
    });
  });

  group('after 2 s without a key', () {
    testWidgets('the text goes, the row stays', (tester) async {
      typeAll('mad');
      await tester.pump(TypeJump.resetAfter - const Duration(milliseconds: 1));
      expect(jump.text, 'mad');
      await tester.pump(const Duration(milliseconds: 1));
      expect(jump.text, isEmpty);
      expect(jump.row, 2);
    });

    testWidgets('every key starts the 2 s again', (tester) async {
      jump.type('m');
      await tester.pump(const Duration(milliseconds: 1500));
      jump.next();
      await tester.pump(const Duration(milliseconds: 1500));
      expect(jump.text, 'm');
      await tester.pump(const Duration(milliseconds: 500));
      expect(jump.text, isEmpty);
    });

    testWidgets('text with no match leaves nothing', (tester) async {
      jump.type('m');
      jump.type('q');
      await tester.pump(TypeJump.resetAfter);
      expect(jump.isTyping, isFalse);
      expect(jump.row, isNull);
    });

    testWidgets('letters after that start from the first match again', (
      tester,
    ) async {
      jump.type('m');
      jump.next();
      await tester.pump(TypeJump.resetAfter);
      expect(jump.row, 2);
      jump.type('m');
      expect(jump.row, 0);
      await tester.pump(TypeJump.resetAfter);
    });

    testWidgets('a cleared jump leaves no timer behind', (tester) async {
      jump.type('m');
      jump.clear();
      expect(jump.row, isNull);
      await tester.pump(TypeJump.resetAfter);
      expect(jump.text, isEmpty);
    });
  });

  test('the list is scanned anew, so a new list is seen', () {
    var list = [_song('a', 'Mx')];
    final other = TypeJump(rows: () => list, reveal: (_) {});
    addTearDown(other.dispose);
    other.type('m');
    expect(other.matchCount, 1);
    other.clear();
    list = [_song('a', 'Mx'), _song('b', 'My')];
    other.type('m');
    expect(other.matchCount, 2);
  });
}

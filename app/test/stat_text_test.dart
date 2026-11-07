import 'package:flutter_test/flutter_test.dart';
import 'package:ownsemble/ui/stat_text.dart';

void main() {
  final now = DateTime(2026, 11, 7, 14);
  int ms(DateTime at) => at.millisecondsSinceEpoch;

  test('heard time', () {
    expect(listenedText(0), '-');
    expect(listenedText(20000), '<1 min');
    expect(listenedText(45 * 60000), '45 min');
    expect(listenedText((3 * 60 + 5) * 60000), '3 h 05 min');
  });

  test('last played, by calendar days', () {
    expect(lastPlayedText(null, now), 'Never');
    expect(lastPlayedText(ms(DateTime(2026, 11, 7, 0, 5)), now), 'Today');
    expect(lastPlayedText(ms(DateTime(2026, 11, 6, 23, 50)), now), 'Yesterday');
    expect(lastPlayedText(ms(DateTime(2026, 11, 3)), now), '4 days ago');
    expect(lastPlayedText(ms(DateTime(2026, 10, 15)), now), '3 weeks ago');
    expect(lastPlayedText(ms(DateTime(2026, 3, 1)), now), '8 months ago');
    expect(lastPlayedText(ms(DateTime(2025, 10, 1)), now), 'A year ago');
    expect(lastPlayedText(ms(DateTime(2023, 1, 1)), now), '3 years ago');
  });

  test('added day', () {
    expect(dayText(0), '-');
    expect(
      dayText(DateTime(2026, 11, 3, 12).millisecondsSinceEpoch ~/ 1000),
      '3 Nov 2026',
    );
  });
}

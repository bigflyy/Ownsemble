import 'package:flutter_test/flutter_test.dart';
import 'package:ownsemble/provider/source_memory.dart';

void main() {
  test('temporary sources require exact identity and expire without files', () {
    var now = DateTime.utc(2026, 10, 20);
    final memory = SourceMemory(
      now: () => now,
      lifetime: const Duration(seconds: 5),
    );
    final uri = Uri.parse('https://music.vkuseraudio.ru/test.mp3');
    memory.remember('1_2', uri, 'Generated fixture');
    expect(memory.lookup('1_3'), isNull);
    expect(memory.lookup('1_2')?.source, uri);
    now = now.add(const Duration(seconds: 5));
    expect(memory.lookup('1_2'), isNull);
  });
  test(
    'source retention is bounded and clearing removes session references',
    () {
      final memory = SourceMemory(capacity: 2);
      final uri = Uri.parse('https://music.vkuseraudio.ru/test.mp3');
      for (final id in ['1_2', '1_3', '1_4']) {
        memory.remember(id, uri, 'Generated');
      }
      expect(memory.lookup('1_2'), isNull);
      expect(memory.lookup('1_3'), isNotNull);
      memory.clear();
      expect(memory.lookup('1_3'), isNull);
      memory.remember(
        '1_2',
        Uri.parse('https://vkuseraudio.ru.attacker.test/a.mp3'),
        'Generated',
      );
      memory.remember('1_3', uri, 'Generated\r\nInjection');
      expect(memory.lookup('1_2'), isNull);
      expect(memory.lookup('1_3'), isNull);
    },
  );
}

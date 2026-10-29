import 'package:flutter_test/flutter_test.dart';
import 'package:ownsemble/library/library_schema.dart';
import 'package:path/path.dart' as p;

void main() {
  test('cached paths are relative to the data folder', () {
    final dataDir = p.join('C:', 'Users', 'x', 'data');
    expect(
      resolveAudioPath(dataDir, p.join('cache', 'vk_1_2.mp3')),
      p.join(dataDir, 'cache', 'vk_1_2.mp3'),
    );
  });

  test('absolute cached paths are used as they are', () {
    final absolute = p.join(p.current, 'Музыка', 'песня.mp3');
    expect(resolveAudioPath('elsewhere', absolute), absolute);
  });
}

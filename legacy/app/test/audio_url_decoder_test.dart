import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ownsemble/provider/audio_url_decoder.dart';

void main() {
  test('music links decode all operations and their composition in memory', () {
    final fixtures = jsonDecode(
      File('test/fixtures/generated-audio-links.json').readAsStringSync(),
    ) as List;
    for (final fixture in fixtures) {
      expect(
        decodeAudioSource(
          fixture['encoded'] as String,
          fixture['userId'] as int,
        )?.toString(),
        fixture['source'],
      );
    }
    expect(decodeAudioSource(fixtures[4]['encoded'] as String, 0), isNull);
    expect(decodeAudioSource(fixtures[4]['encoded'] as String, 1), isNull);
  });
  test('canonical CDN names keep an exact suffix boundary', () {
    expect(
      decodeAudioSource('https://music.vkuseraudio.ru/song.mp3', 0),
      isNotNull,
    );
    expect(
      decodeAudioSource('https://music.vkuseraudio.net./song.mp3', 0)?.host,
      'music.vkuseraudio.net',
    );
    for (final source in [
      'https://music.vkuseraudio.ru.attacker.test/song.mp3',
      'https://music.vkuseraudio.net.attacker.test./song.mp3',
      'https://music.vkuseraudio.net../song.mp3',
    ]) {
      expect(decodeAudioSource(source, 0), isNull);
    }
  });
  test('decoding cannot bypass destination, authority, size or format guards', () {
    for (final value in [
      'https://attacker.test/mp3/audio_api_unavailable.mp3?extra=bad#bad',
      'https://user:secret@vk.com/mp3/audio_api_unavailable.mp3?extra=bad#bad',
      'https://vk.com:8443/mp3/audio_api_unavailable.mp3?extra=bad#bad',
      'https://vk.com/mp3/audio_api_unavailable.mp3?extra=%XX#bad',
      'https://vk.com/mp3/audio_api_unavailable.mp3?extra=!!!!#bad',
      'https://127.0.0.1/song.mp3',
      'http://test.vkuseraudio.net/song.mp3',
      'https://vkuseraudio.net.attacker.test/song.mp3',
      'https://test.vkuseraudio.net/song.mp3?${'a' * 16000}',
    ]) {
      expect(decodeAudioSource(value, 30303030), isNull);
    }
    expect(
      decodeAudioSource('https://test.vkuseraudio.net/song.mp3', 0),
      isNotNull,
    );
  });
}

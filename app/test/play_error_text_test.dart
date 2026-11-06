import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ownsemble/playback/player_service.dart';
import 'package:ownsemble/storage/audio_storage.dart';
import 'package:ownsemble/vk/vk_client.dart';

void main() {
  group('what the user reads when a song fails', () {
    test('a failing audio server is explained without its status code', () {
      final text = describePlayError(AudioServerException(504));
      expect(text, contains("VK's server"));
      expect(text, contains('Try again later'));
      expect(text, isNot(contains('504')));
      expect(text, isNot(contains('HTTP')));
    });

    test('an audio server that never answered points at the line', () {
      expect(
        describePlayError(AudioServerException(0)),
        contains('Check your connection'),
      );
    });

    test('a stalled VK request says VK is not answering', () {
      final text = describePlayError(
        VkException('VK server error 504', transient: true),
      );
      expect(text, contains('VK is not answering'));
      expect(text, isNot(contains('504')));
    });

    test('a refusal from VK keeps its reason', () {
      expect(
        describePlayError(VkException('audio.getById error 15: Access denied')),
        contains('Access denied'),
      );
    });

    test('links never reach the text', () {
      expect(
        describePlayError(const HttpException('failed at https://a.b/c?d=e')),
        isNot(contains('a.b')),
      );
    });

    test('a timeout and a lost connection are plain', () {
      expect(
        describePlayError(TimeoutException('x')),
        contains('did not answer in time'),
      );
      expect(
        describePlayError(const SocketException('x')),
        contains('no connection'),
      );
    });
  });

  group('why VK has no audio for a song', () {
    test('a withdrawn song names who decided', () {
      expect(
        noStreamReason(const VkStream(restricted: true)),
        contains('artist or their representative'),
      );
    });

    test('a song held back until its release says so', () {
      expect(
        noStreamReason(const VkStream(untilRelease: true)),
        contains('after its official release'),
      );
    });

    test('any other song says VK does not offer it', () {
      expect(
        noStreamReason(const VkStream()),
        contains('VK does not offer this song'),
      );
    });
  });
}

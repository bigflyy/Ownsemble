import 'dart:async';
import 'dart:io';

import 'package:media_kit/media_kit.dart';

import '../media/audio_policy.dart';
import '../services/async_wait.dart';
export '../services/async_wait.dart';

Player newProofPlayer() => Player(
  configuration: const PlayerConfiguration(logLevel: MPVLogLevel.error),
);
Future<void> openLocalAudio(
  Player player,
  String path, {
  bool play = true,
}) async {
  final native = player.platform as NativePlayer;
  // In the pinned libmpv, hls -> empty leaves a non-null empty format name;
  // subsequent local MP3 probing fails. Select the known cache container
  // explicitly instead of trying to reset that option with an empty string.
  final format = switch (path.toLowerCase().split('.').last) {
    'm3u8' => 'hls',
    'm4a' || 'mp4' => 'mov',
    'ts' => 'mpegts',
    'wav' => 'wav',
    'mp3' => 'mp3',
    _ => throw const ProofFailure('audio_format_unsupported'),
  };
  await native.setProperty('demuxer-lavf-format', format);
  await native.setProperty('cache-on-disk', 'no');
  await native.setProperty(
    'demuxer-lavf-o',
    'protocol_whitelist=[file,crypto,data],allowed_extensions=[key,ts,mp4,mp3,m4a,aac,m3u8]',
  );
  if (path.endsWith('.m3u8')) {
    await native.setProperty('demuxer', 'lavf');
    await native.setProperty('demuxer-lavf-format', 'hls');
    // media_kit's Windows loadlist path adds a device prefix that FFmpeg's HLS
    // resolver mistakes for a network root. A normal absolute path through the
    // supported native command API keeps relative local keys/segments correct.
    final local = File(path).absolute.path
        .replaceAll(String.fromCharCode(92), '/');
    await native.command(['loadfile', local, 'replace']);
    if (play) await player.play();
  } else {
    await player.open(Media(path), play: play);
  }
}

Future<void> openStreamingAudio(
  Player player,
  Uri uri, {
  bool play = true,
}) async {
  if (uri.scheme != 'http' ||
      uri.host != '127.0.0.1' ||
      !uri.hasPort ||
      uri.userInfo.isNotEmpty ||
      uri.hasQuery) {
    throw const ProofFailure('stream_destination_rejected');
  }
  final native = player.platform as NativePlayer;
  await native.setProperty('cache-on-disk', 'no');
  await native.setProperty('cache', 'yes');
  await native.setProperty('cache-pause', 'yes');
  await native.setProperty('cache-pause-initial', 'yes');
  await native.setProperty('cache-pause-wait', '1');
  await native.setProperty('network-timeout', '35');
  await native.setProperty(
    'demuxer-lavf-o',
    'protocol_whitelist=[file,crypto,data,http,tcp],allowed_extensions=[ALL],extension_picky=[0]',
  );
  await native.setProperty(
    'demuxer-lavf-format',
    uri.path.endsWith('.m3u8')
        ? 'hls'
        : uri.path.endsWith('.m4a')
        ? 'mov'
        : 'mp3',
  );
  await player.open(Media(uri.toString()), play: play);
}

Future<double> decodeLocalAudio(String path) async {
  final player = newProofPlayer();
  var failed = false;
  String? decodeIssue;
  var diagnosticCode = 0;
  final logs = player.stream.log.listen((entry) {
    if (['error', 'fatal'].contains(entry.level) &&
        [
          'ffmpeg',
          'lavf',
          'ad',
          'cplayer',
          'stream',
          'file',
        ].any((prefix) => entry.prefix.startsWith(prefix))) {
      failed = true;
      decodeIssue = classifyDecoderFailure(entry.text, decodeIssue);
      diagnosticCode |= decoderSignalMask(entry.text);
    }
  });
  final errors = player.stream.error.listen((message) {
    failed = true;
    decodeIssue = classifyDecoderFailure(message, decodeIssue);
    diagnosticCode |= decoderSignalMask(message);
  });
  try {
    final native = player.platform as NativePlayer;
    await native.setProperty('vid', 'no');
    await native.setProperty('ao', 'null');
    await native.setProperty('ao-null-untimed', 'yes');
    await native.setProperty('untimed', 'yes');
    // Full decoding receives only local files. Local HLS references are also
    // generated locally; the whitelist blocks accidental remote references.
    await native.setProperty(
      'demuxer-lavf-o',
      'protocol_whitelist=[file,crypto,data]',
    );
    await openLocalAudio(player, path, play: false);
    await waitUntil(
      () => failed || player.state.duration.inMilliseconds > 0,
      'decoder_metadata_timeout',
    );
    if (failed) {
      await Future<void>.delayed(const Duration(milliseconds: 150));
      throw ProofFailure(
        decodeIssue ?? 'decoder_error_event',
        code: diagnosticCode,
      );
    }
    final duration = player.state.duration.inMilliseconds / 1000;
    await player.play();
    await waitUntil(
      () => failed || player.state.completed,
      'full_decode_timeout',
      timeout: const Duration(seconds: 90),
    );
    if (failed) {
      await Future<void>.delayed(const Duration(milliseconds: 150));
      throw ProofFailure(
        decodeIssue ?? 'decoder_error_event',
        code: diagnosticCode,
      );
    }
    return duration;
  } catch (error) {
    if (error is ProofFailure) rethrow;
    throw const ProofFailure('native_decoder_failed');
  } finally {
    await errors.cancel();
    await logs.cancel();
    await player.dispose();
  }
}

Future<void> checkLocalPlayer(String path) async {
  final player = newProofPlayer();
  var failed = false;
  final errors = player.stream.error.listen((_) {
    failed = true;
  });
  try {
    await (player.platform as NativePlayer).setProperty(
      'demuxer-lavf-o',
      'protocol_whitelist=[file,crypto,data]',
    );
    await player.setVolume(0);
    await openLocalAudio(player, path);
    await waitUntil(
      () => failed || player.state.position.inMilliseconds >= 250,
      'player_did_not_advance',
    );
    if (failed) throw const ProofFailure('player_decode_failed');
    final target = Duration(
      milliseconds: (player.state.duration.inMilliseconds / 2).round().clamp(
        500,
        10000,
      ),
    );
    await player.pause();
    await player.seek(target);
    await player.play();
    await waitUntil(
      () =>
          failed ||
          player.state.position > target + const Duration(milliseconds: 150),
      'player_seek_failed',
    );
    if (failed) throw const ProofFailure('player_decode_failed');
  } catch (error) {
    if (error is ProofFailure) rethrow;
    throw const ProofFailure('native_player_failed');
  } finally {
    await errors.cancel();
    await player.dispose();
  }
}

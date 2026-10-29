import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart' hide Track;

import '../library/track.dart';
import '../vk/vk_client.dart';
import 'stream_proxy.dart';

/// Timing of one play request, from the click to audible output.
class PlayTiming {
  const PlayTiming({
    required this.ok,
    required this.cached,
    required this.resolveMs,
    required this.toSoundMs,
    this.networkFirstChunkMs,
    this.sampleRate,
    this.error,
  });

  final bool ok;
  final bool cached;

  /// Time spent getting a fresh stream URL from VK (0 for cached songs).
  final int resolveMs;

  /// Click to the first advance of the playback position, which mpv reports
  /// only once decoded audio is going to the audio device.
  final int toSoundMs;

  /// For streams: time from requesting the audio to its first bytes.
  final int? networkFirstChunkMs;

  /// What the app adds on top of the network: click to sound minus the VK
  /// link request and the audio's first-chunk time.
  int? get appOverheadMs => networkFirstChunkMs == null
      ? null
      : toSoundMs - resolveMs - networkFirstChunkMs!;

  /// Decoded sample rate, proof that real audio was decoded.
  final int? sampleRate;
  final String? error;
}

/// mpv options tuned for fast start of single audio files.
const defaultMpvOptions = <String, String>{
  // Give up on a stalled stream instead of waiting mpv's default 60 s.
  'network-timeout': '20',
};

/// Plays songs with libmpv (media_kit) and measures how fast sound starts.
class PlayerService {
  PlayerService({
    required this.vk,
    required this.muted,
    this.mpvOptions = const {},
    this.mpvLog,
  });

  /// Resolves stream URLs for VK songs; null when no session is configured.
  final VkClient? vk;
  final bool muted;

  /// Extra mpv options (name to value), applied on top of [defaultMpvOptions].
  final Map<String, String> mpvOptions;

  /// When set, mpv's verbose log goes here with links and IPs removed.
  final File? mpvLog;

  late final Player _player;
  late final NativePlayer _mpv;
  late final StreamProxy _proxy;
  bool _ready = false;
  IOSink? _log;
  final _logClock = Stopwatch();
  int _generation = 0;
  Track? _current;

  final _currentController = StreamController<Track?>.broadcast();
  final _timingController = StreamController<PlayTiming>.broadcast();
  final _endedController = StreamController<void>.broadcast();

  /// Whether audio is playing (not paused, not idle).
  final ValueNotifier<bool> playing = ValueNotifier(false);

  bool get isReady => _ready;
  Player get player => _player;
  Track? get current => _current;
  Stream<Track?> get currentStream => _currentController.stream;

  /// Every finished play request's timing, for the status line and logs.
  Stream<PlayTiming> get timings => _timingController.stream;

  /// Fires when the current song plays to its end.
  Stream<void> get ended => _endedController.stream;

  /// Loads libmpv and creates the player. Called after the first frame so it
  /// does not delay startup.
  Future<void> init() async {
    MediaKit.ensureInitialized();
    _proxy = await StreamProxy.start();
    _player = Player(
      configuration: PlayerConfiguration(
        title: 'Ownsemble',
        muted: muted,
        bufferSize: 8 * 1024 * 1024,
        logLevel: mpvLog == null ? MPVLogLevel.error : MPVLogLevel.v,
      ),
    );
    final log = _log = mpvLog?.openWrite(mode: FileMode.append);
    if (log != null) {
      final clock = _logClock..start();
      _player.stream.log.listen((entry) {
        final text = entry.text
            .trim()
            .replaceAll(RegExp(r'https?://\S+'), '<url>')
            .replaceAll(RegExp(r'\d{1,3}(\.\d{1,3}){3}'), '<ip>');
        log.writeln(
          '${clock.elapsedMilliseconds} ${entry.prefix} ${entry.level}: $text',
        );
      });
    }
    _mpv = _player.platform as NativePlayer;
    for (final option in {...defaultMpvOptions, ...mpvOptions}.entries) {
      await _mpv.setProperty(option.key, option.value);
    }
    // Play state comes straight from mpv because songs are loaded with mpv's
    // own loadfile command (see play), which media_kit's state does not track.
    await _mpv.observeProperty('pause', (value) async {
      playing.value = value == 'no' && _current != null;
    });
    await _mpv.observeProperty('eof-reached', (value) async {
      if (value == 'yes') {
        playing.value = false;
        _endedController.add(null);
      }
    });
    _ready = true;
  }

  /// Starts [track] and completes once sound is playing (or it failed).
  Future<PlayTiming> play(Track track) async {
    final generation = ++_generation;
    final clock = Stopwatch()..start();
    _current = track;
    _currentController.add(track);
    var resolveMs = 0;
    PlayTiming finish(PlayTiming timing) {
      if (generation == _generation) _timingController.add(timing);
      return timing;
    }

    ProxiedStream? proxied;
    try {
      String uri;
      if (track.localPath != null) {
        uri = track.localPath!;
      } else if (track.source == TrackSource.vk && vk != null) {
        final url = await vk!.resolveStreamUrl(
          track.sourceKey!,
          track.accessKey,
        );
        resolveMs = clock.elapsedMilliseconds;
        if (url == null) throw StateError('VK has no stream for this song');
        proxied = _proxy.add(Uri.parse(url));
        uri = proxied.localUri.toString();
      } else {
        throw StateError('song has no audio source');
      }
      if (generation != _generation) {
        return const PlayTiming(
          ok: false,
          cached: false,
          resolveMs: 0,
          toSoundMs: 0,
          error: 'superseded',
        );
      }

      // Positions from the previous song may still arrive until the new file
      // is loaded, so only count advances after loadfile has returned.
      var opened = false;
      final sound = Completer<void>();
      final positions = _player.stream.position.listen((position) {
        if (opened && position > Duration.zero && !sound.isCompleted) {
          sound.complete();
        }
      });
      try {
        _log?.writeln(
          '${_logClock.elapsedMilliseconds} === play '
          '${track.isCached ? 'cached' : 'stream'} (link $resolveMs ms)',
        );
        // mpv's loadfile instead of Player.open: open() writes the URI to a
        // temporary playlist file, and stream URLs must never reach disk.
        await _mpv.setProperty('pause', 'no');
        await _mpv.command(['loadfile', uri, 'replace']);
        opened = true;
        await sound.future.timeout(const Duration(seconds: 20));
      } finally {
        await positions.cancel();
      }
      return finish(
        PlayTiming(
          ok: true,
          cached: track.isCached,
          resolveMs: resolveMs,
          toSoundMs: clock.elapsedMilliseconds,
          networkFirstChunkMs: await proxied?.networkFirstChunkMs,
          sampleRate: _player.state.audioParams.sampleRate,
        ),
      );
    } catch (error) {
      return finish(
        PlayTiming(
          ok: false,
          cached: track.isCached,
          resolveMs: resolveMs,
          toSoundMs: clock.elapsedMilliseconds,
          // Error text never includes the stream URL.
          error: error is TimeoutException
              ? 'no sound within 20 s'
              : error.toString().replaceAll(RegExp(r'https?://\S+'), '<url>'),
        ),
      );
    }
  }

  Future<void> playOrPause() async {
    if (_current == null) return;
    await _mpv.setProperty('pause', playing.value ? 'yes' : 'no');
  }

  Future<void> stop() async {
    await _mpv.command(['stop']);
    playing.value = false;
  }

  Future<void> dispose() async {
    if (_ready) {
      await _player.dispose();
      await _proxy.close();
    }
    await _currentController.close();
    await _timingController.close();
    await _endedController.close();
    playing.dispose();
  }
}

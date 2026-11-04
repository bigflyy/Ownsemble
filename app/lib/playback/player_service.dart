import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart' hide Track;

import '../library/library_schema.dart' show resolveAudioPath;
import '../library/track.dart';
import '../storage/audio_storage.dart';
import '../vk/vk_client.dart';
import 'stream_proxy.dart';
import 'stream_route.dart';

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
    this.playlistLinks = 0,
    this.sourceId,
    this.skippedAccounts = 0,
  });

  final bool ok;
  final bool cached;

  /// HLS playlist links VK gave before the link that was used, for perf.log.
  final int playlistLinks;

  /// For streams: the source (account) whose session gave the link, so a
  /// check can prove a song went through the account that owns it.
  final int? sourceId;

  /// For streams: accounts with the song asked before [sourceId] that gave
  /// no link or were refused.
  final int skippedAccounts;

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

/// Shown after "Cannot play: " or "Download failed: ", so it says what
/// happened in the user's terms. The technical detail, such as the audio
/// server's HTTP status, is in perf.log. Never contains links.
String describePlayError(Object error) => switch (error) {
  AudioServerException(status: 0) =>
    "VK's audio server did not answer. Check your connection",
  AudioServerException() =>
    "VK's server is not delivering this song right now. Try again later",
  TimeoutException() => "VK's audio server did not answer in time",
  StateError(:final message) => message,
  VkException(transient: true) =>
    'VK is not answering right now. Try again in a moment',
  VkException(:final message) => 'VK refused the request ($message)',
  HttpException(:final message) => message,
  SocketException() => 'no connection to VK',
  _ => error.toString(),
}.replaceAll(RegExp(r'https?://\S+'), '<url>');

/// Why VK gives no link for a song.
String noStreamReason(VkStream stream) => stream.restricted
    ? 'the artist or their representative made it unavailable on VK'
    : 'VK does not offer this song';

/// mpv options tuned for fast start of single audio files.
const defaultMpvOptions = <String, String>{
  // Give up on a stalled stream instead of waiting mpv's default 60 s.
  'network-timeout': '20',
  // Seek in MP3s by byte position (from the bitrate). Without it, songs
  // with no seek table in their header are seeked by reading every frame
  // up to the target, so a stream seek waited for the download to get
  // there (up to 22 s on a fast line) instead of asking for a range (~1 s).
  'demuxer-lavf-o': 'fflags=+fastseek',
};

/// Plays songs with libmpv (media_kit) and measures how fast sound starts.
class PlayerService {
  PlayerService({
    this.accounts,
    required this.muted,
    required this.dataDir,
    this.mpvOptions = const {},
    this.mpvLog,
    this.storage,
    this.cacheWhileStreaming = true,
  });

  /// Data folder that cached songs' stored paths are relative to.
  final String dataDir;

  /// Stored audio: where songs are cached and downloaded. Without it songs
  /// play from their loaded paths and nothing is cached.
  final AudioStorage? storage;

  /// Whether streamed songs are saved to the cache while they play.
  final bool cacheWhileStreaming;

  /// The logged-in client of each source's account, read at every play, so
  /// logging in or out needs no update here; null when there is no VK at all.
  StreamAccounts? accounts;
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
  bool _loaded = false;

  /// Where the current song goes on from when it was restored from the last
  /// run, until its sound starts. The song is not in mpv until then, so a
  /// start costs no network and no failed link.
  Duration? _resumeAt;

  /// Whether [_current] is a restored song no play request has touched yet:
  /// mpv's own state says nothing about it.
  bool _restored = false;

  /// What the current play request loads, and whether mpv has switched to it
  /// (see the 'path' observer in [init]).
  String? _loadingUri;
  bool _loadingUriActive = false;

  final _currentController = StreamController<Track?>.broadcast();
  final _timingController = StreamController<PlayTiming>.broadcast();
  final _endedController = StreamController<void>.broadcast();

  /// Whether audio is playing (not paused, not idle).
  final ValueNotifier<bool> playing = ValueNotifier(false);

  bool get isReady => _ready;
  Player get player => _player;
  Track? get current => _current;

  /// Whether [current] is loaded in mpv (its last play request succeeded),
  /// so pausing and resuming applies to it.
  bool get currentLoaded => _loaded;
  Stream<Track?> get currentStream => _currentController.stream;

  /// Where a restored song goes on from; null once it sounds, and for every
  /// other song.
  Duration? get resumeAt => _resumeAt;

  /// Shows [track] as the current song, paused at [position], without loading
  /// it. May run before [init], so the first frame already shows it.
  void restore(Track track, Duration position) {
    _current = track;
    _resumeAt = position;
    _restored = true;
  }

  /// Every finished play request's timing, for the status line and logs.
  Stream<PlayTiming> get timings => _timingController.stream;

  /// Every finished request mpv made for a stream, with its timing.
  Stream<ProxyRequestLog> get proxyRequests => _proxy.requests;

  /// Fires when the current song plays to its end.
  Stream<void> get ended => _endedController.stream;

  /// Loads libmpv and creates the player at [volume] (muted when [mute]).
  /// Called after the first frame so it does not delay startup.
  Future<void> init({double volume = 100, bool mute = false}) async {
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
    // Before isReady: no song can start at mpv's default volume.
    await setVolume(volume);
    await setMuted(mute);
    // Play state comes straight from mpv because songs are loaded with mpv's
    // own loadfile command (see play), which media_kit's state does not track.
    await _mpv.observeProperty('pause', (value) async {
      playing.value = value == 'no' && _current != null && !_restored;
    });
    // mpv reports properties in order and media_kit reads the value when it
    // handles the event: once 'path' shows the file being loaded, every later
    // position belongs to that file, not to the previous song.
    await _mpv.observeProperty('path', (value) async {
      if (value == _loadingUri) _loadingUriActive = true;
    });
    await _mpv.observeProperty('eof-reached', (value) async {
      if (value == 'yes') {
        playing.value = false;
        _endedController.add(null);
      }
    });
    _ready = true;
  }

  /// Starts [track] and completes once sound is playing (or it failed). With
  /// [from] it starts at that position instead of the beginning; a failed
  /// start keeps it as [resumeAt], so the next try goes on from there too.
  Future<PlayTiming> play(Track track, {Duration? from}) async {
    final generation = ++_generation;
    final clock = Stopwatch()..start();
    _current = track;
    _loaded = false;
    _resumeAt = from;
    _restored = false;
    _currentController.add(track);
    var resolveMs = 0;
    var playlistLinks = 0;
    RoutedStream? routed;
    PlayTiming finish(PlayTiming timing) {
      if (generation == _generation) _timingController.add(timing);
      return timing;
    }

    ProxiedStream? proxied;
    var cached = false;
    try {
      // Silence the previous song at once: otherwise it keeps playing under
      // the new title while the VK link loads, and forever if loading fails.
      await _mpv.setProperty('pause', 'yes');
      // Saves of songs no longer playing stop, so they do not slow this one.
      _proxy.cancelCachingExcept(null);
      String uri;
      final storedPath = storage?.stateOf(track).path ?? track.localPath;
      final localFile = storedPath == null
          ? null
          : resolveAudioPath(dataDir, storedPath);
      final hasFile = localFile != null && File(localFile).existsSync();
      if (hasFile) {
        cached = true;
        uri = localFile;
      } else if (track.source == TrackSource.vk && accounts != null) {
        // Not cached, or the cached file is gone: stream it, through an
        // account that has the song.
        routed = await resolveStream(track);
        resolveMs = clock.elapsedMilliseconds;
        if (routed == null) {
          throw StateError('no logged-in VK account has this song');
        }
        final RoutedStream(:stream, :route) = routed;
        playlistLinks = stream.playlistLinks;
        final link = stream.link;
        if (link == null) {
          throw StateError(
            track.isGone
                ? 'gone from VK and not stored'
                : noStreamReason(stream),
          );
        }
        final storage = this.storage;
        // Stored audio points at a library row: an album's song outside the
        // library streams without being kept.
        final cachePath =
            storage != null && cacheWhileStreaming && track.inLibrary
            ? storage.streamSavePath(track)
            : null;
        proxied = _proxy.add(
          link,
          cacheTo: cachePath == null ? null : storage!.fileAt(cachePath),
          alternative: () => route.client.releaseLink(stream),
          onSaved: (written, total) =>
              storage?.noteProgress(track, written, total),
        );
        if (cachePath != null) {
          storage!.noteSaving(track, proxied.stored);
          proxied.stored.then((bytes) {
            if (bytes == null) return;
            storage.recordStored(
              track,
              cachePath,
              bytes,
              keep: {?_current?.id},
            );
          });
        }
        uri = proxied.localUri.toString();
      } else if (localFile != null) {
        throw StateError('cached file is missing');
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

      // Errors from the previous song may still arrive until the new file is
      // loaded, so only count them after loadfile returned.
      var opened = false;
      final sound = Completer<void>();
      // Positions count only once mpv has switched to the new file; the
      // previous song keeps reporting positions until it is unloaded.
      _loadingUri = uri;
      _loadingUriActive = false;
      final startsAt = from ?? Duration.zero;
      final positions = _player.stream.position.listen((position) {
        // Starting at a position, nothing older can be reported: the song
        // follows no other one in mpv. It may land a little past the target.
        if (_loadingUriActive &&
            position > startsAt &&
            (from != null || position <= clock.elapsed) &&
            !sound.isCompleted) {
          sound.complete();
        }
      });
      // mpv reports files it cannot open or decode as error log lines.
      final errors = _player.stream.error.listen((message) {
        if (opened && !sound.isCompleted) {
          sound.completeError(StateError('player: $message'));
        }
      });
      // The audio server answered with an error page instead of audio.
      proxied?.upstreamFailure.then((status) {
        if (!sound.isCompleted) {
          sound.completeError(AudioServerException(status));
        }
      });
      try {
        _log?.writeln(
          '${_logClock.elapsedMilliseconds} === play '
          '${cached ? 'cached' : 'stream'} (link $resolveMs ms)',
        );
        // mpv's loadfile instead of Player.open: open() writes the URI to a
        // temporary playlist file, and stream URLs must never reach disk.
        // Unpaused before loadfile, so the song loads playing (starting a
        // paused load and unpausing later is slower), and again after it:
        // mpv runs with keep-open, so right after a song ended the first
        // unpause hits the old song's end again and mpv pauses once more.
        // mpv keeps 'start' for every later file, so each play sets it.
        await _mpv.setProperty(
          'start',
          from == null
              ? 'none'
              : (from.inMilliseconds / 1000).toStringAsFixed(3),
        );
        await _mpv.setProperty('pause', 'no');
        await _mpv.command(['loadfile', uri, 'replace']);
        await _mpv.setProperty('pause', 'no');
        opened = true;
        await sound.future.timeout(const Duration(seconds: 20));
      } finally {
        await positions.cancel();
        await errors.cancel();
      }
      if (generation == _generation) {
        _loaded = true;
        _resumeAt = null;
      }
      return finish(
        PlayTiming(
          ok: true,
          cached: cached,
          resolveMs: resolveMs,
          toSoundMs: clock.elapsedMilliseconds,
          networkFirstChunkMs: await proxied?.networkFirstChunkMs,
          sampleRate: _player.state.audioParams.sampleRate,
          playlistLinks: playlistLinks,
          sourceId: routed?.route.sourceId,
          skippedAccounts: routed?.skipped ?? 0,
        ),
      );
    } catch (error) {
      if (generation == _generation) {
        // Unload whatever is left, so resuming cannot bring back the
        // previous song under this song's title.
        await _mpv.command(['stop']);
        playing.value = false;
      }
      return finish(
        PlayTiming(
          ok: false,
          cached: cached,
          resolveMs: resolveMs,
          toSoundMs: clock.elapsedMilliseconds,
          error: error is TimeoutException
              ? 'no sound after 20 s. The connection may be too slow'
              : describePlayError(error),
          playlistLinks: playlistLinks,
          sourceId: routed?.route.sourceId,
          skippedAccounts: routed?.skipped ?? 0,
        ),
      );
    }
  }

  /// The accounts that would be asked for a link to [track], best first.
  List<StreamRoute> routesFor(Track track) {
    final accounts = this.accounts;
    return accounts == null ? const [] : streamRoutes(track, accounts);
  }

  /// VK's answer for [track] from the first account that has a link for it
  /// (see [resolveRouted]); null when no logged-in account has the song.
  /// Downloads use it too, so a song is fetched the way it plays.
  Future<RoutedStream?> resolveStream(Track track) =>
      resolveRouted(routesFor(track));

  Future<void> playOrPause() async {
    if (_current == null) return;
    await _mpv.setProperty('pause', playing.value ? 'yes' : 'no');
  }

  /// Every position mpv reports while a song plays.
  Stream<Duration> get positions => _player.stream.position;

  /// Position in the loaded song, or where a restored song goes on from
  /// (zero when nothing is loaded).
  Duration get position =>
      _resumeAt ?? (_loaded ? _player.state.position : Duration.zero);

  /// Length of the loaded song as mpv knows it, else the listed length.
  Duration get duration {
    if (_loaded) {
      final known = _player.state.duration;
      if (known > Duration.zero) return known;
    }
    return Duration(seconds: _current?.durationSec ?? 0);
  }

  /// Moves within the loaded song, or moves where a restored song goes on
  /// from; does nothing while no song is loaded.
  Future<void> seek(Duration to) async {
    if (_resumeAt != null) {
      _resumeAt = to;
      return;
    }
    if (!_loaded) return;
    final seconds = to.inMilliseconds / 1000;
    await _mpv.command(['seek', seconds.toStringAsFixed(3), 'absolute']);
  }

  /// Moves by [offset] from where the song is. mpv adds up seeks it has not
  /// finished yet, so quick presses on a stream all count.
  Future<void> seekBy(Duration offset) async {
    final resumeAt = _resumeAt;
    if (resumeAt != null) {
      final length = duration - const Duration(seconds: 1);
      final to = resumeAt + offset;
      _resumeAt = to.isNegative
          ? Duration.zero
          : length > Duration.zero && to > length
          ? length
          : to;
      return;
    }
    if (!_loaded) return;
    final seconds = offset.inMilliseconds / 1000;
    await _mpv.command(['seek', seconds.toStringAsFixed(3), 'relative']);
  }

  /// Sets the volume, 0 to 100.
  Future<void> setVolume(double volume) =>
      _mpv.setProperty('volume', volume.clamp(0, 100).toStringAsFixed(1));

  /// Mutes or unmutes. An app started with --muted (agent checks) stays
  /// muted whatever the user's mute button says.
  Future<void> setMuted(bool mute) =>
      _mpv.setProperty('mute', mute || muted ? 'yes' : 'no');

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

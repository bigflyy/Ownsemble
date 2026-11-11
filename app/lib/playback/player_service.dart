import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart' hide Track;

import '../library/library_schema.dart' show resolveAudioPath;
import '../library/song_version.dart';
import '../library/track.dart';
import '../storage/audio_storage.dart';
import '../vk/vk_client.dart';
import 'mp3_length.dart';
import 'stream_proxy.dart';
import 'stream_route.dart';
import 'version_book.dart';

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
    this.fileSeconds,
    this.version,
    this.versionNews,
  });

  final bool ok;

  /// How long the file that played lasts, measured from its first bytes;
  /// null when it was not checked (Stage K).
  final double? fileSeconds;

  /// How the file that played was chosen, for a song whose VK file was
  /// swapped for another recording; null for a song's own file.
  final VersionState? version;

  /// Set when this play found the song's VK file swapped: what to tell the
  /// user about the version that plays instead.
  final String? versionNews;
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
String noStreamReason(VkStream stream) => switch (stream) {
  VkStream(restricted: true) =>
    'the artist or their representative made it unavailable on VK',
  VkStream(untilRelease: true) =>
    'VK will open this song after its official release',
  _ => 'VK does not offer this song',
};

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

  /// The versions that play for songs whose VK file was swapped for another
  /// recording. With it every library song's file is checked against the
  /// length it should have before mpv gets it (Stage K); without it nothing
  /// is checked.
  VersionBook? versions;
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

  /// The stream of the song playing now and that song's id; null when it
  /// plays from disk. Its save may go on after a skip, see [play].
  ProxiedStream? _currentStream;
  int? _currentStreamTrackId;

  /// How long the song playing now has made sound: runs only while it is
  /// loaded and not paused.
  final _heard = Stopwatch();

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

  /// Whether [current] is only shown, restored from the last run, and
  /// nothing of it was loaded or asked for yet.
  bool get restoredOnly => _restored;

  /// Shows [track] as the current song, paused at [position], without loading
  /// it. May run before [init], so the first frame already shows it.
  void restore(Track track, Duration position) {
    _current = track;
    _resumeAt = position;
    _restored = true;
  }

  /// The song playing now was added to the library as [track] (the same
  /// audio): shows it as that song from now on, without reloading the sound.
  void adopt(Track track) {
    final current = _current;
    if (current == null || current.id == track.id) return;
    _current = track;
    _currentController.add(track);
  }

  /// Every finished play request's timing, for the status line and logs.
  Stream<PlayTiming> get timings => _timingController.stream;

  /// Every finished request mpv made for a stream, with its timing.
  Stream<ProxyRequestLog> get proxyRequests => _proxy.requests;

  /// Every streamed song that was not saved whole, and why.
  Stream<LostSave> get lostSaves => _proxy.lostSaves;

  /// For checks only, see [StreamProxy.saveRateLimit].
  set saveRateLimit(int? bytesPerSecond) =>
      _proxy.saveRateLimit = bytesPerSecond;

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
    playing.addListener(_countHeard);
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
  Future<PlayTiming> play(Track track, {Duration? from}) =>
      _play(track, from: from, round: 0, clock: Stopwatch()..start());

  /// How often one play may switch to another file of the song: its own file
  /// found swapped, then a chosen upload gone or changed as well.
  static const _maxRounds = 3;

  /// One try at playing [track]; [clock] runs from the click, over every
  /// round. A file that turns out to be another recording than the song's
  /// starts the next [round] with the version chosen for it, carrying the
  /// [news] to tell the user.
  Future<PlayTiming> _play(
    Track track, {
    Duration? from,
    required int round,
    required Stopwatch clock,
    String? news,
  }) async {
    final generation = ++_generation;
    // The last song's play time ends here, before anything is awaited.
    _heard.stop();
    final skipped = _currentStream;
    final playedAgain = _currentStreamTrackId == track.id;
    _currentStream = null;
    _currentStreamTrackId = null;
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
    // Library songs from VK are checked: their file must play about as long
    // as the chosen version's, or the listed length (Stage K).
    final versions = this.versions;
    final checked =
        versions != null && track.inLibrary && track.source == TrackSource.vk;
    final choice = checked ? versions.choiceFor(track) : null;
    final expectSeconds = checked
        ? choice?.expectSeconds ?? track.durationSec.toDouble()
        : null;
    double? fileSeconds;
    var downloadAgain = false;
    try {
      // Silence the previous song at once: otherwise it keeps playing under
      // the new title while the VK link loads, and forever if loading fails.
      await _mpv.setProperty('pause', 'yes');
      // The last song's save goes on if it played long enough or plays
      // again; other saves stop, so they do not slow this one.
      _proxy.songChanged(
        skipped,
        heard: _heard.elapsed,
        playedAgain: playedAgain,
      );
      _heard.reset();
      String uri;
      final storedPath = storage?.stateOf(track).path ?? track.localPath;
      final localFile = storedPath == null
          ? null
          : resolveAudioPath(dataDir, storedPath);
      var hasFile = localFile != null && File(localFile).existsSync();
      if (hasFile && expectSeconds != null) {
        // A stored file of another recording (saved after VK swapped the
        // song's file) is thrown away, and the song streams the right one.
        final facts = measureFile(File(localFile));
        if (facts != null && facts.differsFrom(expectSeconds)) {
          downloadAgain = storage?.stateOf(track).pinned ?? false;
          storage?.removeStored(track);
          hasFile = false;
          _log?.writeln(
            '${_logClock.elapsedMilliseconds} stored file of song ${track.id} '
            'is another recording ($facts), streaming instead',
          );
        } else {
          fileSeconds = facts?.seconds;
        }
      }
      if (hasFile) {
        cached = true;
        uri = localFile!;
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
        if (link == null && choice != null && !choice.playsOwnFile) {
          throw const _ChosenFileGone();
        }
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
          onSaved: (written, total) =>
              storage?.noteProgress(track, written, total),
          label: 'song ${track.id}',
          expectSeconds: expectSeconds,
        );
        if (generation == _generation) {
          _currentStream = proxied;
          _currentStreamTrackId = track.id;
        }
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
        // Another play started meanwhile, so mpv never opens this stream.
        proxied?.cancelCaching('another song started first');
        return _superseded;
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
      // The file is another recording than the song: mpv gets none of it.
      proxied?.otherRecording.then((facts) {
        if (!sound.isCompleted) sound.completeError(_OtherRecording(facts));
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
        _countHeard();
      }
      final toSoundMs = clock.elapsedMilliseconds;
      final measured = proxied == null
          ? null
          : await proxied.measured.timeout(
              const Duration(milliseconds: 20),
              onTimeout: () => null,
            );
      if (downloadAgain) unawaited(_downloadAgain(track));
      return finish(
        PlayTiming(
          ok: true,
          cached: cached,
          resolveMs: resolveMs,
          toSoundMs: toSoundMs,
          networkFirstChunkMs: await proxied?.networkFirstChunkMs,
          sampleRate: _player.state.audioParams.sampleRate,
          playlistLinks: playlistLinks,
          sourceId: routed?.route.sourceId,
          skippedAccounts: routed?.skipped ?? 0,
          fileSeconds: measured?.seconds ?? fileSeconds,
          version: choice?.state,
          versionNews: news,
        ),
      );
    } catch (error) {
      // The file is not the song: play the version chosen for it instead.
      final switches = error is _OtherRecording || error is _ChosenFileGone;
      if (switches && versions != null && round < _maxRounds) {
        if (generation == _generation) {
          await _mpv.command(['stop']);
          playing.value = false;
          _currentStream = null;
          _currentStreamTrackId = null;
        }
        // The held stream still counts as saving the song: it ends first,
        // or the next round would find the song "saving" and save nothing.
        if (proxied != null) {
          _proxy.letGo(proxied, 'another recording');
          await proxied.stored.timeout(
            const Duration(seconds: 2),
            onTimeout: () => null,
          );
        }
        var next = news;
        if (choice != null && !choice.playsOwnFile) {
          // The chosen upload is gone or changed too: the song's own file
          // is checked again, and a new choice made if needed.
          versions.forget(track);
        } else if (error is _OtherRecording && routed != null) {
          final decided = await versions.decide(
            track,
            routed.route,
            error.facts,
          );
          next = _newsOf(decided);
        }
        if (generation != _generation) return _superseded;
        return _play(
          track,
          from: from,
          round: round + 1,
          clock: clock,
          news: next,
        );
      }
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

  /// What a play that another play replaced returns.
  static const _superseded = PlayTiming(
    ok: false,
    cached: false,
    resolveMs: 0,
    toSoundMs: 0,
    error: 'superseded',
  );

  /// What to tell the user when a play found the song's VK file swapped.
  static String _newsOf(VersionChoice choice) => switch (choice.state) {
    VersionState.none =>
      "VK changed this song's file to another recording, and no upload "
          'matches your library: this is a different recording than in your '
          'library.',
    _ =>
      "VK changed this song's file to another recording. Playing the "
          'suggested match instead; the mark on the song lets you choose.',
  };

  /// Downloads [track] again after its downloaded file turned out to be
  /// another recording; the save of the play that found it is taken over.
  Future<void> _downloadAgain(Track track) async {
    try {
      await storage?.download(track, () async {
        final resolved = await resolveStream(track);
        return resolved?.stream.link;
      });
    } on Object catch (error) {
      _log?.writeln(
        '${_logClock.elapsedMilliseconds} downloading song ${track.id} '
        'again failed: ${error.runtimeType}',
      );
    }
  }

  /// Before a Download of [track], which does not go through the player's
  /// check: measures the song's own file once, and when it is another
  /// recording, chooses the version to keep (Stage K).
  Future<void> checkVersion(Track track) async {
    final versions = this.versions;
    if (versions == null ||
        !track.inLibrary ||
        track.source != TrackSource.vk ||
        versions.choiceFor(track) != null) {
      return;
    }
    final routed = await resolveRouted(ownRoutesFor(track));
    final link = routed?.stream.link;
    if (routed == null || link == null) return;
    final http = HttpClient()..connectionTimeout = const Duration(seconds: 8);
    try {
      final facts = await measureRemote(http, link);
      if (facts != null && facts.differsFrom(track.durationSec.toDouble())) {
        await versions.decide(track, routed.route, facts);
      }
    } finally {
      http.close(force: true);
    }
  }

  /// Runs [_heard] while the current song is loaded and playing.
  void _countHeard() {
    if (_loaded && playing.value) {
      _heard.start();
    } else {
      _heard.stop();
    }
  }

  /// The accounts that would be asked for a link to [track], best first.
  /// When another upload was chosen for the song (its VK file was swapped),
  /// that upload is asked for instead, through the first account.
  List<StreamRoute> routesFor(Track track) {
    final routes = ownRoutesFor(track);
    final choice = versions?.choiceFor(track);
    final fileKey = choice?.fileKey;
    if (fileKey == null || routes.isEmpty) return routes;
    final first = routes.first;
    return [
      StreamRoute(
        sourceId: first.sourceId,
        client: first.client,
        sourceKey: fileKey,
        accessKey: choice!.fileAccessKey,
      ),
    ];
  }

  /// The accounts that would be asked for [track]'s own file, best first.
  List<StreamRoute> ownRoutesFor(Track track) {
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
    relativeSeeksSent++;
    await _mpv.command(['seek', seconds.toStringAsFixed(3), 'relative']);
  }

  /// Relative seeks handed to mpv so far. The acceptance test reports it
  /// when an arrow key seems to have done nothing: it tells a key that never
  /// reached the player from a seek mpv did not carry out.
  var relativeSeeksSent = 0;

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

/// The file a play got is another recording than expected ([facts]).
class _OtherRecording implements Exception {
  const _OtherRecording(this.facts);
  final FileFacts facts;
}

/// VK gives no link for the upload chosen for a swapped song.
class _ChosenFileGone implements Exception {
  const _ChosenFileGone();
}

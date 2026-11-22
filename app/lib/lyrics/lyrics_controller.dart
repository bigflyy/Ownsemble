/// Which lyrics the Lyrics place shows, fetched when needed (plan 10, C3, E1).
///
/// Lyrics are asked only for the song the place shows (the playing one) and
/// for a song being downloaded: VK refuses many calls in a row (error 9), so
/// never all at once. What the sources answer is kept in the library, so
/// lyrics seen once show again at once and without a network.
///
/// Lyrics belong to one VK upload: they are asked for the upload that plays
/// (the player's first stream route: the account that has the song, or the
/// version chosen for it), so the words and their times fit what is heard.
/// Asks go one at a time, an ask for the same upload is shared, and an ask
/// for a song no longer shown is dropped before it starts (Codex review of
/// session 36).
///
/// Outside sources (E1): when VK has no timed lyrics, LRCLIB is asked, and
/// when it has none either, NetEase and QQ Music together. What shows is the
/// best answer by the user's "timed first" (2026-11-22): VK timed, outside
/// timed, VK plain, outside plain. Every source's answer is stored, so the
/// pick is made again from the stored rows, also offline.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../library/library_records.dart' show StoredLyrics;
import '../library/track.dart';
import '../vk/vk_client.dart';
import '../vk/vk_lyrics.dart';
import 'lyrics.dart';
import 'lyrics_sources.dart';

/// What the Lyrics place shows for its song.
sealed class LyricsState {
  const LyricsState();
}

/// Nothing to show yet: no song, or before the first answer.
class LyricsLoading extends LyricsState {
  const LyricsLoading();
}

/// The song's lyrics. [refreshing] while sources are still asked.
class LyricsShown extends LyricsState {
  const LyricsShown(this.lyrics, {this.refreshing = false});
  final Lyrics lyrics;
  final bool refreshing;
}

/// No source has lyrics for the song.
class LyricsMissing extends LyricsState {
  const LyricsMissing();
}

/// Asking failed and nothing is stored. [slowDown] when a source refused
/// more calls for now.
class LyricsFailed extends LyricsState {
  const LyricsFailed(this.reason, {this.slowDown = false});
  final String reason;
  final bool slowDown;
}

/// Stored VK lyrics older than this are shown and asked again in the
/// background (only the time moves when they did not change). Outside
/// lyrics are kept for good: crowd lyrics seldom change.
const lyricsRefreshAfter = Duration(days: 30);

/// A source's word that it has no lyrics for a song is trusted this long;
/// VK adds lyrics to songs now and then, LRCLIB grows every day.
const lyricsMissingRecheckAfter = Duration(days: 7);

/// The VK upload a song's lyrics are asked for: its key, its access key and
/// the account to ask through (null when no account of it is logged in:
/// stored lyrics still show). Outside sources store their answer under the
/// same key.
typedef LyricsRoute = ({String key, String? accessKey, VkApiCall? call});

/// The route of [track]'s own row through [apiOfSource]: for tests and
/// tools; the app asks the player which upload plays.
LyricsRoute? Function(Track track) lyricsRouteBySource(
  VkApiCall? Function(int sourceId) apiOfSource,
) => (track) {
  final key = track.sourceKey;
  if (track.source != TrackSource.vk || key == null || key.isEmpty) {
    return null;
  }
  return (
    key: key,
    accessKey: track.accessKey,
    call: apiOfSource(track.sourceId),
  );
};

/// An ask dropped before it started: its song is no longer shown.
class _Dropped implements Exception {
  const _Dropped();
}

class LyricsController extends ChangeNotifier {
  LyricsController({
    required this.load,
    required this.save,
    required this.routeOf,
    this.sources = const [],
    int Function()? now,
    this.log,
  }) : _now = now ?? (() => DateTime.now().millisecondsSinceEpoch);

  /// The stored lyrics of a song (LibraryStore.lyricsOf).
  final StoredLyrics? Function(String source, String ref) load;

  /// Keeps a source's answer (LibraryStore.saveLyrics).
  final void Function(
    String source,
    String ref,
    Lyrics? lyrics, {
    String? md5,
    String? meta,
  })
  save;

  /// The upload a song's lyrics come from; null when no source can have
  /// them (a generated song).
  final LyricsRoute? Function(Track track) routeOf;

  /// The outside sources in the order they are asked (outsideLyricsSources):
  /// the first alone after VK, the others together after it.
  final List<OutsideLyricsSource> sources;

  /// One line to perf.log: times and outcomes only, never words or keys.
  final void Function(String line)? log;

  final int Function() _now;

  Track? _track;
  LyricsState _state = const LyricsLoading();

  /// Raised for every new ask for the place, so an answer for a song no
  /// longer shown is dropped.
  int _asking = 0;

  /// The upload whose lyrics the place shows (or waits for).
  String? _shownKey;

  /// Picks running or waiting, by upload key: a second ask shares the first.
  final _asks = <String, Future<Lyrics?>>{};

  /// The end of the line of picks: each waits for the one before.
  Future<void> _line = Future<void>.value();

  /// The song the place shows.
  Track? get track => _track;

  LyricsState get state => _state;

  /// The sources in turn: VK, then the first outside source, then the
  /// others together. The walk stops after the first stage that gives timed
  /// lyrics.
  List<List<String>> get _stages => [
    ['vk'],
    if (sources.isNotEmpty) [sources.first.id],
    if (sources.length > 1) [for (final source in sources.skip(1)) source.id],
  ];

  /// Shows the lyrics of [track] (the playing song; null for none): stored
  /// ones at once, else asked. The same song again changes nothing, unless
  /// [again] (the place opened anew): then a failure or an old answer is
  /// looked at again.
  void show(Track? track, {bool again = false}) {
    final sameSong =
        track != null &&
        _track != null &&
        track.id == _track!.id &&
        track.sourceKey == _track!.sourceKey;
    if (sameSong && !(again && _state is! LyricsShown)) return;
    _track = track;
    _asking++;
    if (track == null) {
      _shownKey = null;
      _set(const LyricsLoading());
      return;
    }
    final route = routeOf(track);
    if (route == null) {
      _shownKey = null;
      _set(const LyricsMissing());
      return;
    }
    _shownKey = route.key;
    final stored = _storedPick(route.key);
    final best = stored.best;
    if (!stored.mustAsk) {
      _set(best == null ? const LyricsMissing() : LyricsShown(best));
      return;
    }
    _set(
      best == null
          ? const LyricsLoading()
          : LyricsShown(best, refreshing: true),
    );
    unawaited(_ask(route, track));
  }

  /// Asks again for the song shown, after a failure.
  void retry() {
    final track = _track;
    final route = track == null ? null : routeOf(track);
    if (track == null || route == null) return;
    _asking++;
    _set(const LyricsLoading());
    unawaited(_ask(route, track));
  }

  /// Fetches and keeps [track]'s lyrics so a downloaded song has them
  /// offline, unless timed lyrics are stored already or every source the
  /// walk reaches answered lately. Failures are ignored.
  Future<void> keepFor(Track track) async {
    final route = routeOf(track);
    if (route == null) return;
    final stored = _storedPick(route.key);
    if (!stored.mustAsk || (stored.best?.timed ?? false)) return;
    for (var attempt = 0; attempt < 2; attempt++) {
      try {
        await _shared(route, track);
        return;
      } on _Dropped {
        // It shared an ask of the place that was dropped: ask on its own.
        continue;
      } on Object {
        return; // The place asks again when it is opened with a network.
      }
    }
  }

  Future<void> _ask(LyricsRoute route, Track track) async {
    final asking = _asking;
    final clock = Stopwatch()..start();
    try {
      final lyrics = await _shared(
        route,
        track,
        // The upload shown when the pick's turn comes, whichever ask of the
        // place started it (A, then B, then A again shares the first pick).
        wanted: () => _shownKey == route.key,
        // A better answer while the walk goes on shows at once (VK's words
        // first, then LRCLIB's timed lines).
        onBetter: (lyrics) {
          if (asking == _asking && _shownKey == route.key) {
            _set(LyricsShown(lyrics, refreshing: true));
          }
        },
      );
      log?.call(
        'lyrics pick '
        '${lyrics == null ? 'none' : '${lyrics.source} ${_kind(lyrics)}'} '
        '${clock.elapsedMilliseconds} ms',
      );
      if (asking != _asking) return;
      _set(lyrics == null ? const LyricsMissing() : LyricsShown(lyrics));
    } on _Dropped {
      return;
    } on Object catch (error) {
      if (asking != _asking) return;
      final shown = _state;
      if (shown is LyricsShown) {
        // What is stored stays; it is asked again next time.
        _set(LyricsShown(shown.lyrics));
        return;
      }
      _set(switch (error) {
        VkException(:final slowDown) when slowDown => const LyricsFailed(
          'VK asks to wait a minute before more lyrics.',
          slowDown: true,
        ),
        LyricsSourceException(:final slowDown) when slowDown =>
          const LyricsFailed(
            'The lyrics sources ask to wait a minute.',
            slowDown: true,
          ),
        _ => LyricsFailed(_reasonOf(error)),
      });
    }
  }

  /// The pick for [route]'s upload: a running one is shared, a new one waits
  /// its turn and, when [wanted] says no by then, is dropped unasked.
  Future<Lyrics?> _shared(
    LyricsRoute route,
    Track track, {
    bool Function()? wanted,
    void Function(Lyrics lyrics)? onBetter,
  }) {
    final running = _asks[route.key];
    if (running != null) return running;
    final ask = _line.then((_) {
      if (wanted != null && !wanted()) throw const _Dropped();
      return _pick(route, track, onBetter: onBetter);
    });
    _line = ask.then<void>((_) {}, onError: (Object _) {});
    _asks[route.key] = ask;
    // Block bodies: Map.remove returns the (failing) ask, which must not
    // become this chain's result.
    unawaited(
      ask.then<void>(
        (_) {
          _asks.remove(route.key);
        },
        onError: (Object _) {
          _asks.remove(route.key);
        },
      ),
    );
    return ask;
  }

  /// What one source has stored for [key]: its lyrics and facts, and
  /// whether it must be asked (never asked, an old "none", old VK lyrics).
  ({Lyrics? lyrics, String? meta, bool ask}) _storedOf(
    String source,
    String key,
  ) {
    final stored = load(source, key);
    if (stored == null) return (lyrics: null, meta: null, ask: true);
    final age = _now() - stored.fetchedAtMs;
    final lyrics = stored.lyrics;
    if (lyrics != null) {
      final old = source == 'vk' && age > lyricsRefreshAfter.inMilliseconds;
      return (lyrics: lyrics, meta: stored.meta, ask: old);
    }
    return (
      lyrics: null,
      meta: null,
      ask: age > lyricsMissingRecheckAfter.inMilliseconds,
    );
  }

  /// The pick from stored rows only, and whether a source the walk reaches
  /// must still be asked.
  ({Lyrics? best, bool mustAsk}) _storedPick(String key) {
    final pick = _Best(_rank);
    var mustAsk = false;
    for (final stage in _stages) {
      for (final source in stage) {
        final stored = _storedOf(source, key);
        final lyrics = stored.lyrics;
        if (lyrics != null) pick.consider(lyrics, stored.meta);
        if (stored.ask) mustAsk = true;
      }
      if (pick.best?.timed ?? false) break;
    }
    return (best: pick.best, mustAsk: mustAsk);
  }

  /// Walks the sources for [route]'s upload: stored answers first, asking
  /// only what is missing or old, stopping after the first stage with timed
  /// lyrics. Returns the best lyrics or null; throws only when nothing was
  /// found and some source failed (VK's failure first: it names the reason
  /// best).
  Future<Lyrics?> _pick(
    LyricsRoute route,
    Track track, {
    void Function(Lyrics lyrics)? onBetter,
  }) async {
    final pick = _Best(_rank, onBetter: onBetter);
    final failures = <(String, Object)>[];
    final names = SongNames(
      artist: track.artist,
      title: track.title,
      album: track.album,
      seconds: track.durationSec,
    );
    Future<void> walk(String source) async {
      final stored = _storedOf(source, route.key);
      final storedLyrics = stored.lyrics;
      if (storedLyrics != null) pick.consider(storedLyrics, stored.meta);
      if (!stored.ask) return;
      final clock = Stopwatch()..start();
      try {
        final (lyrics, meta) = source == 'vk'
            ? await _askVk(route)
            : await _askOutside(source, route.key, names);
        log?.call(
          'lyrics $source ${lyrics == null ? 'none' : _kind(lyrics)} '
          '${clock.elapsedMilliseconds} ms',
        );
        if (lyrics != null) pick.consider(lyrics, meta);
      } on Object catch (error) {
        log?.call(
          'lyrics $source failed ${error.runtimeType}'
          '${error is VkException ? ' ${error.code}' : ''} '
          '${clock.elapsedMilliseconds} ms',
        );
        failures.add((source, error));
      }
    }

    for (final stage in _stages) {
      await Future.wait([for (final source in stage) walk(source)]);
      if (pick.best?.timed ?? false) break;
    }
    if (pick.best == null && failures.isNotEmpty) {
      final vk = failures.where((failure) => failure.$1 == 'vk');
      throw (vk.isNotEmpty ? vk.first : failures.first).$2;
    }
    return pick.best;
  }

  /// Asks VK and keeps its answer. A "none" (or a reply without words)
  /// never erases lyrics stored before: they stay for offline use, only
  /// their time moves.
  Future<(Lyrics?, String?)> _askVk(LyricsRoute route) async {
    final call = route.call;
    if (call == null) throw StateError('no VK account for this song');
    final answer = await fetchVkLyrics(
      call,
      sourceKey: route.key,
      accessKey: route.accessKey,
    );
    switch (answer) {
      case VkLyricsFound(:final lyrics, :final md5):
        save('vk', route.key, lyrics, md5: md5);
        return (lyrics, null);
      case VkLyricsNone():
        final kept = load('vk', route.key);
        final keptLyrics = kept?.lyrics;
        if (keptLyrics != null) {
          save('vk', route.key, keptLyrics, md5: kept!.md5);
          return (keptLyrics, null);
        }
        save('vk', route.key, null);
        return (null, null);
    }
  }

  /// Asks an outside source and keeps its answer.
  Future<(Lyrics?, String?)> _askOutside(
    String source,
    String key,
    SongNames names,
  ) async {
    final found = await sources
        .firstWhere((outside) => outside.id == source)
        .find(names);
    if (found == null) {
      save(source, key, null);
      return (null, null);
    }
    final meta = found.metaToJson();
    save(source, key, found.lyrics, meta: meta);
    return (found.lyrics, meta);
  }

  /// How good an answer is to show: VK timed, outside timed, VK plain,
  /// outside plain (the user's "timed first"); among outside answers of one
  /// kind exact names first, then the closer length, then the earlier
  /// source.
  int _rank(Lyrics lyrics, String? meta) {
    final vk = lyrics.source == 'vk';
    final base = lyrics.timed ? (vk ? 4000 : 3000) : (vk ? 2000 : 1000);
    if (vk) return base;
    var exact = false;
    int? diff;
    try {
      final facts = meta == null ? null : jsonDecode(meta);
      if (facts is Map) {
        exact = facts['exact'] == true;
        diff = (facts['diff'] as num?)?.toInt();
      }
    } on FormatException {
      // Unreadable facts rank last among their kind.
    }
    final order = sources.indexWhere((source) => source.id == lyrics.source);
    return base +
        (exact ? 100 : 0) -
        (diff ?? 9) * 10 -
        (order < 0 ? 9 : order);
  }

  void _set(LyricsState state) {
    _state = state;
    notifyListeners();
  }
}

String _kind(Lyrics lyrics) => lyrics.timed ? 'timed' : 'plain';

/// The best answer seen so far by a rank; tells [onBetter] when it changes.
class _Best {
  _Best(this._rank, {this.onBetter});

  final int Function(Lyrics lyrics, String? meta) _rank;
  final void Function(Lyrics lyrics)? onBetter;

  Lyrics? best;
  int _bestRank = 0;

  void consider(Lyrics lyrics, String? meta) {
    final rank = _rank(lyrics, meta);
    if (best != null && rank <= _bestRank) return;
    best = lyrics;
    _bestRank = rank;
    onBetter?.call(lyrics);
  }
}

/// A short reason to show for a failed ask.
String _reasonOf(Object error) => switch (error) {
  StateError(:final message) when message.startsWith('no VK account') =>
    'Log in to the VK account of this song to see its lyrics.',
  VkException(:final transient) when transient =>
    'VK did not answer. Check the connection and try again.',
  VkException() => 'VK refused the lyrics of this song.',
  LyricsSourceException() =>
    'Could not reach the lyrics sources. Check the connection and try again.',
  _ => 'Could not reach VK. Check the connection and try again.',
};

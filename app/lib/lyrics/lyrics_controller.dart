/// Which lyrics the Lyrics place shows, fetched when needed (plan 10, C3).
///
/// Lyrics are asked only for the song the place shows (the playing one) and
/// for a song being downloaded: VK refuses many calls in a row (error 9), so
/// never all at once. What VK answers is kept in the library, so lyrics seen
/// once show again at once and without a network.
///
/// Lyrics belong to one VK upload: they are asked for the upload that plays
/// (the player's first stream route: the account that has the song, or the
/// version chosen for it), so the words and their times fit what is heard.
/// Asks go one at a time, an ask for the same upload is shared, and an ask
/// for a song no longer shown is dropped before it starts (Codex review of
/// session 36).
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../library/library_records.dart' show StoredLyrics;
import '../library/track.dart';
import '../vk/vk_client.dart';
import '../vk/vk_lyrics.dart';
import 'lyrics.dart';

/// What the Lyrics place shows for its song.
sealed class LyricsState {
  const LyricsState();
}

/// Nothing to show yet: no song, or before the first answer.
class LyricsLoading extends LyricsState {
  const LyricsLoading();
}

/// The song's lyrics. [refreshing] while a newer copy is asked.
class LyricsShown extends LyricsState {
  const LyricsShown(this.lyrics, {this.refreshing = false});
  final Lyrics lyrics;
  final bool refreshing;
}

/// No source has lyrics for the song (Stage E adds more sources than VK).
class LyricsMissing extends LyricsState {
  const LyricsMissing();
}

/// Asking failed. [slowDown] when VK refused more calls for now.
class LyricsFailed extends LyricsState {
  const LyricsFailed(this.reason, {this.slowDown = false});
  final String reason;
  final bool slowDown;
}

/// Stored lyrics older than this are shown and asked again in the
/// background (only the time moves when they did not change).
const lyricsRefreshAfter = Duration(days: 30);

/// A source's word that it has no lyrics for a song is trusted this long;
/// VK adds lyrics to songs now and then.
const lyricsMissingRecheckAfter = Duration(days: 7);

/// The VK upload a song's lyrics are asked for: its key, its access key and
/// the account to ask through (null when no account of it is logged in:
/// stored lyrics still show).
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
    int Function()? now,
    this.log,
  }) : _now = now ?? (() => DateTime.now().millisecondsSinceEpoch);

  /// The stored lyrics of a song (LibraryStore.lyricsOf).
  final StoredLyrics? Function(String source, String ref) load;

  /// Keeps a source's answer (LibraryStore.saveLyrics).
  final void Function(String source, String ref, Lyrics? lyrics, {String? md5})
  save;

  /// The upload a song's lyrics come from; null when no source can have
  /// them yet (a generated song).
  final LyricsRoute? Function(Track track) routeOf;

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

  /// Asks running or waiting, by upload key: a second ask shares the first.
  final _asks = <String, Future<Lyrics?>>{};

  /// The end of the line of asks: each waits for the one before.
  Future<void> _line = Future<void>.value();

  /// The song the place shows.
  Track? get track => _track;

  LyricsState get state => _state;

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
    final stored = load('vk', route.key);
    final age = stored == null ? null : _now() - stored.fetchedAtMs;
    final lyrics = stored?.lyrics;
    if (lyrics != null) {
      final stale = age! > lyricsRefreshAfter.inMilliseconds;
      _set(LyricsShown(lyrics, refreshing: stale));
      if (stale) unawaited(_ask(route, quiet: true));
      return;
    }
    if (stored != null && age! <= lyricsMissingRecheckAfter.inMilliseconds) {
      _set(const LyricsMissing());
      return;
    }
    _set(const LyricsLoading());
    unawaited(_ask(route));
  }

  /// Asks again for the song shown, after a failure.
  void retry() {
    final track = _track;
    final route = track == null ? null : routeOf(track);
    if (route == null) return;
    _asking++;
    _set(const LyricsLoading());
    unawaited(_ask(route));
  }

  /// Fetches and keeps [track]'s lyrics so a downloaded song has them
  /// offline, unless they are stored already or VK said lately it has none.
  /// Failures are ignored.
  Future<void> keepFor(Track track) async {
    final route = routeOf(track);
    if (route == null) return;
    final stored = load('vk', route.key);
    if (stored != null &&
        (stored.lyrics != null ||
            _now() - stored.fetchedAtMs <=
                lyricsMissingRecheckAfter.inMilliseconds)) {
      return;
    }
    for (var attempt = 0; attempt < 2; attempt++) {
      try {
        await _shared(route);
        return;
      } on _Dropped {
        // It shared an ask of the place that was dropped: ask on its own.
        continue;
      } on Object {
        return; // The place asks again when it is opened with a network.
      }
    }
  }

  Future<void> _ask(LyricsRoute route, {bool quiet = false}) async {
    final asking = _asking;
    final clock = Stopwatch()..start();
    try {
      final lyrics = await _shared(
        route,
        // The upload shown when the ask's turn comes, whichever ask of the
        // place started it (A, then B, then A again shares the first ask).
        wanted: () => _shownKey == route.key,
      );
      log?.call(
        'lyrics vk ${lyrics == null
            ? 'none'
            : lyrics.timed
            ? 'timed'
            : 'plain'} '
        '${clock.elapsedMilliseconds} ms',
      );
      if (asking != _asking) return;
      _set(lyrics == null ? const LyricsMissing() : LyricsShown(lyrics));
    } on _Dropped {
      return;
    } on Object catch (error) {
      log?.call(
        'lyrics vk failed ${error.runtimeType} '
        '${error is VkException ? error.code : ''} '
        '${clock.elapsedMilliseconds} ms',
      );
      if (asking != _asking) return;
      final shown = _state;
      if (quiet && shown is LyricsShown) {
        // The stored copy stays; it is asked again next time.
        _set(LyricsShown(shown.lyrics));
        return;
      }
      _set(
        error is VkException && error.slowDown
            ? const LyricsFailed(
                'VK asks to wait a minute before more lyrics.',
                slowDown: true,
              )
            : LyricsFailed(_reasonOf(error)),
      );
    }
  }

  /// The ask for [route]'s upload: a running one is shared, a new one waits
  /// its turn and, when [wanted] says no by then, is dropped unasked.
  Future<Lyrics?> _shared(LyricsRoute route, {bool Function()? wanted}) {
    final running = _asks[route.key];
    if (running != null) return running;
    final ask = _line.then((_) {
      if (wanted != null && !wanted()) throw const _Dropped();
      return _fetch(route);
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

  /// Asks VK and keeps its answer; returns the lyrics to show or null. A
  /// "none" (or a reply without words) never erases lyrics stored before:
  /// they stay for offline use, only their time moves.
  Future<Lyrics?> _fetch(LyricsRoute route) async {
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
        return lyrics;
      case VkLyricsNone():
        final kept = load('vk', route.key);
        final keptLyrics = kept?.lyrics;
        if (keptLyrics != null) {
          save('vk', route.key, keptLyrics, md5: kept!.md5);
          return keptLyrics;
        }
        save('vk', route.key, null);
        return null;
    }
  }

  void _set(LyricsState state) {
    _state = state;
    notifyListeners();
  }
}

/// A short reason to show for a failed ask.
String _reasonOf(Object error) => switch (error) {
  StateError(:final message) when message.startsWith('no VK account') =>
    'Log in to the VK account of this song to see its lyrics.',
  VkException(:final transient) when transient =>
    'VK did not answer. Check the connection and try again.',
  VkException() => 'VK refused the lyrics of this song.',
  _ => 'Could not reach VK. Check the connection and try again.',
};

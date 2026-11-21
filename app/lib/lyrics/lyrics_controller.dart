/// Which lyrics the Lyrics place shows, fetched when needed (plan 10, C3).
///
/// Lyrics are asked only for the song the place shows (the playing one) and
/// for a song being downloaded: VK refuses many calls in a row (error 9), so
/// never all at once. What VK answers is kept in the library, so lyrics seen
/// once show again at once and without a network.
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

/// The source and the song there a [track]'s lyrics are kept under, or
/// null when no source can have them yet (a generated song).
({String source, String ref})? lyricsKeyOf(Track track) {
  final key = track.sourceKey;
  if (track.source != TrackSource.vk || key == null || key.isEmpty) {
    return null;
  }
  return (source: 'vk', ref: key);
}

class LyricsController extends ChangeNotifier {
  LyricsController({
    required this.load,
    required this.save,
    required this.apiOfSource,
    int Function()? now,
    this.log,
  }) : _now = now ?? (() => DateTime.now().millisecondsSinceEpoch);

  /// The stored lyrics of a song (LibraryStore.lyricsOf).
  final StoredLyrics? Function(String source, String ref) load;

  /// Keeps a source's answer (LibraryStore.saveLyrics).
  final void Function(String source, String ref, Lyrics? lyrics, {String? md5})
  save;

  /// The VK account a song of the given source streams through.
  final VkApiCall? Function(int sourceId) apiOfSource;

  /// One line to perf.log: times and outcomes only, never words or keys.
  final void Function(String line)? log;

  final int Function() _now;

  Track? _track;
  LyricsState _state = const LyricsLoading();

  /// Raised for every new ask, so an answer for a song no longer shown is
  /// dropped.
  int _asking = 0;

  /// The song the place shows.
  Track? get track => _track;

  LyricsState get state => _state;

  /// Shows the lyrics of [track] (the playing song; null for none): stored
  /// ones at once, else asked. The same song again changes nothing.
  void show(Track? track) {
    final sameSong =
        track != null &&
        _track != null &&
        track.id == _track!.id &&
        track.sourceKey == _track!.sourceKey;
    if (sameSong) return;
    _track = track;
    _asking++;
    if (track == null) {
      _set(const LyricsLoading());
      return;
    }
    final key = lyricsKeyOf(track);
    if (key == null) {
      _set(const LyricsMissing());
      return;
    }
    final stored = load(key.source, key.ref);
    final age = stored == null ? null : _now() - stored.fetchedAtMs;
    final lyrics = stored?.lyrics;
    if (lyrics != null) {
      final stale = age! > lyricsRefreshAfter.inMilliseconds;
      _set(LyricsShown(lyrics, refreshing: stale));
      if (stale) unawaited(_ask(track, quiet: true));
      return;
    }
    if (stored != null && age! <= lyricsMissingRecheckAfter.inMilliseconds) {
      _set(const LyricsMissing());
      return;
    }
    _set(const LyricsLoading());
    unawaited(_ask(track));
  }

  /// Asks again for the song shown, after a failure.
  void retry() {
    final track = _track;
    if (track == null) return;
    _asking++;
    _set(const LyricsLoading());
    unawaited(_ask(track));
  }

  /// Fetches and keeps [track]'s lyrics when none are stored yet, so a
  /// downloaded song has them offline. Failures are ignored.
  Future<void> keepFor(Track track) async {
    final key = lyricsKeyOf(track);
    if (key == null || load(key.source, key.ref) != null) return;
    try {
      await _fetch(track, key);
    } on Object {
      // The place asks again when it is opened with a network.
    }
  }

  Future<void> _ask(Track track, {bool quiet = false}) async {
    final asking = _asking;
    final key = lyricsKeyOf(track)!;
    final clock = Stopwatch()..start();
    try {
      final lyrics = await _fetch(track, key);
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

  /// Asks the source and keeps its answer; returns the lyrics or null.
  Future<Lyrics?> _fetch(Track track, ({String source, String ref}) key) async {
    final api = apiOfSource(track.sourceId);
    if (api == null) throw StateError('no VK account for this song');
    final answer = await fetchVkLyrics(
      api,
      sourceKey: key.ref,
      accessKey: track.accessKey,
    );
    switch (answer) {
      case VkLyricsFound(:final lyrics, :final md5):
        save(key.source, key.ref, lyrics, md5: md5);
        return lyrics;
      case VkLyricsNone():
        save(key.source, key.ref, null);
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

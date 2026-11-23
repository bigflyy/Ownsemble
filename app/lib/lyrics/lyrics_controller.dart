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
///
/// The chooser (E2, user pick 2026-11-22 "List like Versions"): every
/// source's answer for the song is listed ([choices]), the sources not asked
/// yet are asked ([askAll]), and the user's choice ([use]) is kept per upload
/// and shown instead of the automatic pick until [useAutomatic].
///
/// Fit to this recording (G2): a source's timed lines fitted to the upload's
/// recording are kept per upload and source ([keepFit]) and shown instead
/// of the source's own times ([timedOf]) while they are for these lyrics and
/// this recording. A fit has its own hand offset: the one set for the
/// source's own timing stays for when the fit is undone ([forgetFit]).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:math' show min;

import 'package:flutter/foundation.dart';

import '../library/library_records.dart' show StoredLyrics;
import '../library/track.dart';
import '../vk/vk_client.dart';
import '../vk/vk_lyrics.dart';
import 'fitted_lines.dart';
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

/// How one source stands for the song in the chooser.
enum LyricsChoiceStatus {
  /// Never asked for this song.
  notAsked,

  /// Being asked now (with nothing stored yet).
  asking,

  /// Its lyrics are stored.
  found,

  /// It said it has none.
  none,

  /// Asking it failed and nothing is stored.
  failed,
}

/// One source's lyrics for the song shown, as the chooser lists them.
class LyricsChoice {
  const LyricsChoice({
    required this.source,
    required this.status,
    this.lyrics,
    this.artist,
    this.title,
    this.seconds,
    this.lengthDiff,
    this.otherVersion = false,
    this.exact = false,
    this.asking = false,
  });

  /// 'vk', 'lrclib', 'netease' or 'qq'.
  final String source;
  final LyricsChoiceStatus status;
  final Lyrics? lyrics;

  /// The names and length of the source's song the lyrics belong to (VK:
  /// the song's own).
  final String? artist;
  final String? title;
  final int? seconds;

  /// Seconds between that length and the played song's; null when unknown.
  final int? lengthDiff;

  /// Another version's lyrics (G4a): a song of another length.
  final bool otherVersion;

  /// Whether the names agree exactly (not only after transliteration).
  final bool exact;

  /// Whether the source is being asked again while its lyrics show.
  final bool asking;

  String get label => lyricsSourceLabel(source);
}

/// An ask dropped before it started: its song is no longer shown.
class _Dropped implements Exception {
  const _Dropped();
}

/// One press of "earlier" or "later" moves timed lines this much (F1), as
/// in VLC's subtitle delay and Musixmatch's sync.
const lyricsOffsetStepMs = 500;

/// Lines move at most this far either way: past it the words belong to
/// another version.
const lyricsOffsetLimitMs = 60000;

class LyricsController extends ChangeNotifier {
  LyricsController({
    required this.load,
    required this.save,
    required this.routeOf,
    this.sources = const [],
    this.loadPick,
    this.savePick,
    this.loadOffset,
    this.saveOffset,
    this.loadFit,
    this.saveFit,
    this.audioBytesOf,
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

  /// The source the user chose for an upload (LibraryStore.lyricsPickOf).
  final String? Function(String ref)? loadPick;

  /// Keeps the user's choice, null for automatic (LibraryStore
  /// .saveLyricsPick). Without it choices last for this run only.
  final void Function(String ref, String? source)? savePick;

  /// Choices made in this run when no [savePick] keeps them.
  final _picks = <String, String?>{};

  /// How far the user moved a source's timed lines for an upload
  /// (LibraryStore.lyricsOffsetOf), milliseconds, > 0 later (F1).
  final int Function(String ref, String source)? loadOffset;

  /// Keeps a moved timing, 0 to forget it (LibraryStore.saveLyricsOffset).
  /// Without it offsets last for this run only.
  final void Function(String ref, String source, int offsetMs)? saveOffset;

  /// Offsets set in this run when no [saveOffset] keeps them, as
  /// "upload key|source".
  final _offsets = <String, int>{};

  /// A source's lines fitted to an upload's recording (LibraryStore
  /// .lyricsFitOf), and keeping one, null to forget it (.saveLyricsFit).
  /// Without [saveFit] fits last for this run only.
  final StoredFit? Function(String ref, String source)? loadFit;
  final void Function(String ref, String source, StoredFit? fit)? saveFit;
  final _fits = <String, StoredFit>{};

  /// The size of a song's stored audio file, null when none is stored: a
  /// fit of another file is not used.
  final int? Function(Track track)? audioBytesOf;

  /// Sources being asked by [askAll], and those whose ask failed, as
  /// "upload key|source".
  final _choiceAsking = <String>{};
  final _choiceFailed = <String>{};

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
    final picked = _pickedLyrics(route.key);
    if (picked != null) {
      _set(LyricsShown(picked));
      return;
    }
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
    if (!stored.mustAsk || stored.settled) return;
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
          if (asking == _asking &&
              _shownKey == route.key &&
              _pickedLyrics(route.key) == null) {
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
      final shown = _pickedLyrics(route.key) ?? lyrics;
      _set(shown == null ? const LyricsMissing() : LyricsShown(shown));
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
      // Another version is asked again like a "none": the source may have
      // the song's own length by now (Codex review).
      final old = source == 'vk'
          ? age > lyricsRefreshAfter.inMilliseconds
          : _isOtherVersion(stored.meta) &&
                age > lyricsMissingRecheckAfter.inMilliseconds;
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
  ({Lyrics? best, bool settled, bool mustAsk}) _storedPick(String key) {
    final pick = _Best(_rank);
    var mustAsk = false;
    for (final stage in _stages) {
      for (final source in stage) {
        final stored = _storedOf(source, key);
        final lyrics = stored.lyrics;
        if (lyrics != null) pick.consider(lyrics, stored.meta);
        if (stored.ask) mustAsk = true;
      }
      if (pick.settled) break;
    }
    return (best: pick.best, settled: pick.settled, mustAsk: mustAsk);
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
      if (pick.settled) break;
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
  ///
  /// With [keepFound] (the chooser asking again) a "none" does not erase
  /// lyrics stored before: they stay, only their time moves, as VK's.
  Future<(Lyrics?, String?)> _askOutside(
    String source,
    String key,
    SongNames names, {
    bool keepFound = false,
  }) async {
    final found = await sources
        .firstWhere((outside) => outside.id == source)
        .find(names);
    if (found == null) {
      final kept = keepFound ? load(source, key) : null;
      final keptLyrics = kept?.lyrics;
      if (keptLyrics != null) {
        save(source, key, keptLyrics, meta: kept!.meta);
        return (keptLyrics, kept.meta);
      }
      save(source, key, null);
      return (null, null);
    }
    if (found.otherVersion) {
      // Another version never replaces lyrics of the song's own length
      // stored before (Codex review: the chooser's ask again); only their
      // time moves.
      final kept = load(source, key);
      final keptLyrics = kept?.lyrics;
      if (keptLyrics != null && !_isOtherVersion(kept!.meta)) {
        save(source, key, keptLyrics, meta: kept.meta);
        return (keptLyrics, kept.meta);
      }
    }
    final meta = found.metaToJson();
    save(source, key, found.lyrics, meta: meta);
    return (found.lyrics, meta);
  }

  /// Every source in the order they are asked: VK, then the outside ones.
  List<String> get _allSources => [
    'vk',
    for (final source in sources) source.id,
  ];

  /// The source the user chose for [key], or null (automatic).
  String? _pickOf(String key) =>
      savePick == null ? _picks[key] : loadPick?.call(key);

  /// The lyrics the user chose for [key], when that source still has them
  /// stored; null means the automatic pick shows.
  Lyrics? _pickedLyrics(String key) {
    final source = _pickOf(key);
    return source == null ? null : load(source, key)?.lyrics;
  }

  /// The source the user chose for the song shown, while its lyrics are
  /// stored; null when the automatic pick shows.
  String? get chosen {
    final key = _shownKey;
    if (key == null || _pickedLyrics(key) == null) return null;
    return _pickOf(key);
  }

  /// The source the automatic pick takes for the song shown, from what is
  /// stored; null when none has lyrics.
  String? get automatic {
    final key = _shownKey;
    return key == null ? null : _storedPick(key).best?.source;
  }

  /// Every source's answer for the song shown, for the chooser: found
  /// lyrics best first (the automatic pick's order), then the sources
  /// being asked, without lyrics, failed or not asked, in asking order.
  List<LyricsChoice> get choices {
    final key = _shownKey;
    final track = _track;
    if (key == null || track == null) return const [];
    final found = <(int, LyricsChoice)>[];
    final rest = <LyricsChoice>[];
    for (final source in _allSources) {
      final stored = load(source, key);
      final lyrics = stored?.lyrics;
      final asking = _choiceAsking.contains('$key|$source');
      if (lyrics != null) {
        found.add((
          _rank(lyrics, stored!.meta),
          _choiceOf(source, lyrics, stored.meta, track, asking: asking),
        ));
        continue;
      }
      rest.add(
        LyricsChoice(
          source: source,
          status: asking
              ? LyricsChoiceStatus.asking
              : _choiceFailed.contains('$key|$source')
              ? LyricsChoiceStatus.failed
              : stored == null
              ? LyricsChoiceStatus.notAsked
              : LyricsChoiceStatus.none,
        ),
      );
    }
    found.sort((a, b) => b.$1.compareTo(a.$1));
    return [for (final (_, choice) in found) choice, ...rest];
  }

  LyricsChoice _choiceOf(
    String source,
    Lyrics lyrics,
    String? meta,
    Track track, {
    required bool asking,
  }) {
    if (source == 'vk') {
      return LyricsChoice(
        source: source,
        status: LyricsChoiceStatus.found,
        lyrics: lyrics,
        artist: track.artist,
        title: track.title,
        seconds: track.durationSec,
        lengthDiff: 0,
        exact: true,
        asking: asking,
      );
    }
    Map<Object?, Object?> facts = const {};
    try {
      final decoded = meta == null ? null : jsonDecode(meta);
      if (decoded is Map) facts = decoded;
    } on FormatException {
      // Unreadable facts: the lyrics are listed without names.
    }
    return LyricsChoice(
      source: source,
      status: LyricsChoiceStatus.found,
      lyrics: lyrics,
      artist: facts['artist'] as String?,
      title: facts['title'] as String?,
      seconds: (facts['seconds'] as num?)?.toInt(),
      lengthDiff: (facts['diff'] as num?)?.toInt(),
      otherVersion: facts['other'] == true,
      exact: facts['exact'] == true,
      asking: asking,
    );
  }

  /// Asks every source not stored yet or due again for the song shown (all
  /// of them with [again]: the chooser's refresh), each answer shown as it
  /// comes. A "none" never erases lyrics found before.
  Future<void> askAll({bool again = false}) async {
    final track = _track;
    final route = track == null ? null : routeOf(track);
    if (track == null || route == null) return;
    final key = route.key;
    final wanted = [
      for (final source in _allSources)
        if (!_choiceAsking.contains('$key|$source') &&
            (again || _storedOf(source, key).ask))
          source,
    ];
    if (wanted.isEmpty) return;
    for (final source in wanted) {
      _choiceAsking.add('$key|$source');
      _choiceFailed.remove('$key|$source');
    }
    notifyListeners();
    final names = SongNames(
      artist: track.artist,
      title: track.title,
      album: track.album,
      seconds: track.durationSec,
    );
    Future<void> askOne(String source) async {
      final clock = Stopwatch()..start();
      try {
        final (lyrics, _) = source == 'vk'
            ? await _askVk(route)
            : await _askOutside(source, key, names, keepFound: true);
        log?.call(
          'lyrics choose $source ${lyrics == null ? 'none' : _kind(lyrics)} '
          '${clock.elapsedMilliseconds} ms',
        );
      } on Object catch (error) {
        log?.call(
          'lyrics choose $source failed ${error.runtimeType} '
          '${clock.elapsedMilliseconds} ms',
        );
        _choiceFailed.add('$key|$source');
      } finally {
        _choiceAsking.remove('$key|$source');
        if (_shownKey == key) notifyListeners();
      }
    }

    // Not in the line of picks: a slow source here (QQ took 6 s, lyrics-41a)
    // must not hold up the next song's lyrics. It only waits for a pick of
    // this same upload, so no source is asked twice at once; one VK call
    // more is no flood.
    try {
      await _asks[key];
    } on Object {
      // The pick's failure is the place's to show; the chooser asks anew.
    }
    // What that pick asked meanwhile is not asked again.
    final still = [
      for (final source in wanted)
        if (again || _storedOf(source, key).ask) source,
    ];
    for (final source in wanted.where((source) => !still.contains(source))) {
      _choiceAsking.remove('$key|$source');
    }
    await Future.wait([for (final source in still) askOne(source)]);
    // What shows may change: a source asked for the first time can beat the
    // automatic pick. A pick still running for the song sets it itself.
    if (_shownKey != key || _asks.containsKey(key)) return;
    final current = _state;
    final shown =
        _pickedLyrics(key) ??
        _storedPick(key).best ??
        (current is LyricsShown ? current.lyrics : null);
    if (shown != null) {
      _set(LyricsShown(shown));
    } else if (current is! LyricsFailed) {
      _set(const LyricsMissing());
    }
  }

  /// Shows [source]'s stored lyrics for the song shown and keeps that
  /// choice for its upload.
  void use(String source) {
    final key = _shownKey;
    if (key == null) return;
    final lyrics = load(source, key)?.lyrics;
    if (lyrics == null) return;
    _keepPick(key, source);
    log?.call('lyrics use $source');
    _asking++;
    _set(LyricsShown(lyrics));
  }

  /// Forgets the user's choice for the song shown: the automatic pick shows
  /// again (asked when stored rows are missing or old).
  void useAutomatic() {
    final key = _shownKey;
    final track = _track;
    if (key == null || track == null) return;
    _keepPick(key, null);
    log?.call('lyrics use automatic');
    _asking++;
    final stored = _storedPick(key);
    final best = stored.best;
    final route = routeOf(track);
    if (!stored.mustAsk || route == null) {
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

  /// The upload whose lyrics the place shows, null for none.
  String? get shownKey => _shownKey;

  /// The upload [track]'s lyrics come from now: it changes when another
  /// version is chosen for the song.
  String? routeKeyOf(Track track) => routeOf(track)?.key;

  /// The kept fit of [source]'s lines for the song shown, whether or not
  /// it is for the lyrics stored now.
  StoredFit? _fitOf(String source) {
    final key = _shownKey;
    if (key == null) return null;
    return saveFit == null ? _fits['$key|$source'] : loadFit?.call(key, source);
  }

  /// The fit of [lyrics] for the song shown, when it was made for these
  /// lyrics and the recording stored now.
  StoredFit? fitFor(Lyrics lyrics) {
    final fit = _fitOf(lyrics.source);
    final track = _track;
    if (fit == null || track == null) return null;
    return fit.isFor(lyrics, audioBytes: audioBytesOf?.call(track))
        ? fit
        : null;
  }

  /// Whether [lyrics] show fitted to the recording.
  bool isFitted(Lyrics lyrics) => fitFor(lyrics)?.fits ?? false;

  /// How many seconds longer (> 0) or shorter the song of [lyrics] is than
  /// the song shown, when they are another version's lyrics (G4a): their
  /// times are that version's, not this recording's. Null for lyrics of
  /// the song's own length, VK's, and lyrics not stored for the song shown.
  int? otherVersionOf(Lyrics lyrics) {
    final key = _shownKey;
    final track = _track;
    if (key == null || track == null || lyrics.source == 'vk') return null;
    // Read once per lyrics object, not on every build, and kept with that
    // object: lyrics stored again later (a refresh) come as a new object
    // with their own facts, and a chooser preview of other lyrics does not
    // move what the lyrics shown are (Codex review).
    final place = '$key|${track.durationSec}';
    final cached = _otherOf[lyrics];
    if (cached != null && cached.place == place) return cached.diff;
    final stored = load(lyrics.source, key);
    // Facts of other lyrics than these say nothing about these.
    if (stored?.lyrics != lyrics) return null;
    final meta = stored!.meta;
    int? diff;
    try {
      final facts = meta == null ? null : jsonDecode(meta);
      if (facts is Map && facts['other'] == true) {
        final seconds = (facts['seconds'] as num?)?.toInt();
        diff = seconds == null
            ? (facts['diff'] as num?)?.toInt() ?? 0
            : seconds - track.durationSec;
      }
    } on FormatException {
      // Unreadable facts: taken as the song's own lyrics, as before G4.
    }
    _otherOf[lyrics] = (place: place, diff: diff);
    return diff;
  }

  final _otherOf = Expando<({String place, int? diff})>();

  /// Whether stored facts mark another version's lyrics (G4a).
  static bool _isOtherVersion(String? meta) {
    if (meta == null) return false;
    try {
      final facts = jsonDecode(meta);
      return facts is Map && facts['other'] == true;
    } on FormatException {
      return false;
    }
  }

  /// How another version's length compares with the song's, in words:
  /// "25 s longer", "60 min shorter" ([otherVersionOf]'s seconds).
  static String otherLengthText(int diffSeconds) {
    final size = diffSeconds.abs();
    final amount = size >= 120 ? '${(size / 60).round()} min' : '$size s';
    return diffSeconds == 0
        ? 'another length'
        : '$amount ${diffSeconds > 0 ? 'longer' : 'shorter'}';
  }

  /// [lyrics] as they show for the song: fitted to its recording when a
  /// fit is kept for them, else as the source timed them; another
  /// version's lyrics (G4c) show their words only until a fit places them.
  Lyrics timedOf(Lyrics lyrics) {
    final starts = fitFor(lyrics)?.starts;
    if (starts == null) {
      if (!lyrics.timed || otherVersionOf(lyrics) == null) return lyrics;
      final words = _lastWords;
      if (words != null && identical(words.$1, lyrics)) return words.$2;
      final plain = Lyrics(
        source: lyrics.source,
        lines: [for (final line in lyrics.lines) LyricLine(line.text)],
      );
      _lastWords = (lyrics, plain);
      return plain;
    }
    final last = _lastTimed;
    if (last != null &&
        identical(last.$1, lyrics) &&
        listEquals(last.$2, starts)) {
      return last.$3;
    }
    // Plain words timed by the fit show their headers as labels (H5).
    final fitted = withStarts(lyrics, starts, labelUnsung: !lyrics.timed);
    _lastTimed = (lyrics, starts, fitted);
    return fitted;
  }

  (Lyrics, List<int>, Lyrics)? _lastTimed;
  (Lyrics, Lyrics)? _lastWords;

  /// Keeps [fit] of [source]'s lines for the upload [key] (null forgets
  /// it). A new fit starts with no hand offset of its own; the offset of
  /// the source's own timing is left as it is.
  void keepFit(String key, String source, StoredFit? fit) {
    if (saveFit == null) {
      if (fit == null) {
        _fits.remove('$key|$source');
      } else {
        _fits['$key|$source'] = fit;
      }
    } else {
      saveFit!(key, source, fit);
    }
    _keepOffset(key, _fitted(source), 0);
    log?.call(
      fit == null
          ? 'lyrics fit $source forgotten'
          : 'lyrics fit $source kept, fits ${fit.fits}',
    );
    notifyListeners();
  }

  /// Shows [source]'s own timing again for the song shown, or for the
  /// upload [key] when given (the key the menu was opened for: the song may
  /// have moved on since, Codex review).
  void forgetFit(String source, {String? key}) {
    final upload = key ?? _shownKey;
    if (upload != null) keepFit(upload, source, null);
  }

  /// The offsets' source name for a fit's own hand offset.
  static String _fitted(String source) => '$source@fit';

  /// The name [source]'s hand offset is kept under for the song shown: its
  /// fit's own while its lines show fitted.
  String _offsetName(String source) {
    final state = _state;
    final key = _shownKey;
    // Another source's lines (the chooser's preview): its fit counts only
    // when it is for its lyrics as stored now (Codex review).
    final lyrics = state is LyricsShown && state.lyrics.source == source
        ? state.lyrics
        : key == null
        ? null
        : load(source, key)?.lyrics;
    final fit = lyrics == null ? null : fitFor(lyrics);
    return fit?.fits ?? false ? _fitted(source) : source;
  }

  /// How far [source]'s timed lines are moved for the song shown,
  /// milliseconds, > 0 later; 0 when not moved or no song is shown. While
  /// they show fitted, this is the fit's own offset.
  int offsetOf(String source) {
    final key = _shownKey;
    if (key == null) return 0;
    final name = _offsetName(source);
    return saveOffset == null
        ? _offsets['$key|$name'] ?? 0
        : loadOffset?.call(key, name) ?? 0;
  }

  void _keepOffset(String key, String name, int offsetMs) {
    if (saveOffset == null) {
      _offsets['$key|$name'] = offsetMs;
    } else {
      saveOffset!(key, name, offsetMs);
    }
  }

  /// The source of the lyrics the place shows now; null when none show.
  String? get shownSource => switch (_state) {
    LyricsShown(:final lyrics) => lyrics.source,
    _ => null,
  };

  /// The offset of the lyrics the place shows now.
  int get shownOffset => switch (_state) {
    LyricsShown(:final lyrics) when timedOf(lyrics).timed => offsetOf(
      lyrics.source,
    ),
    _ => 0,
  };

  /// Moves the shown lyrics' lines by [deltaMs] (> 0 later) and keeps it
  /// for the song and that source; the result stays within
  /// [lyricsOffsetLimitMs] and on [lyricsOffsetStepMs] steps.
  void shiftShown(int deltaMs) {
    final state = _state;
    if (state is! LyricsShown || !timedOf(state.lyrics).timed) return;
    setOffset(state.lyrics.source, offsetOf(state.lyrics.source) + deltaMs);
  }

  /// Sets how far [source]'s lines are moved for the song shown.
  void setOffset(String source, int offsetMs) {
    final key = _shownKey;
    if (key == null) return;
    final steps = (offsetMs / lyricsOffsetStepMs).round();
    final kept = (steps * lyricsOffsetStepMs).clamp(
      -lyricsOffsetLimitMs,
      lyricsOffsetLimitMs,
    );
    if (kept == offsetOf(source)) return;
    final name = _offsetName(source);
    _keepOffset(key, name, kept);
    log?.call('lyrics offset $name $kept ms');
    notifyListeners();
  }

  void _keepPick(String key, String? source) {
    if (savePick == null) {
      _picks[key] = source;
    } else {
      savePick!(key, source);
    }
  }

  /// How good an answer is to show: VK timed, outside timed, VK plain,
  /// outside plain (the user's "timed first"); among outside answers of one
  /// kind exact names first, then the closer length, then the earlier
  /// source. Another version's lyrics (G4a) come after all of them: their
  /// timing is not this recording's, and they show as words until fitted.
  int _rank(Lyrics lyrics, String? meta) {
    final vk = lyrics.source == 'vk';
    final base = lyrics.timed ? (vk ? 4000 : 3000) : (vk ? 2000 : 1000);
    if (vk) return base;
    var exact = false;
    var other = false;
    int? diff;
    try {
      final facts = meta == null ? null : jsonDecode(meta);
      if (facts is Map) {
        exact = facts['exact'] == true;
        other = facts['other'] == true;
        diff = (facts['diff'] as num?)?.toInt();
      }
    } on FormatException {
      // Unreadable facts rank last among their kind.
    }
    final order = sources.indexWhere((source) => source.id == lyrics.source);
    if (other) {
      // 300-799: below every answer of the song's own length.
      return 500 +
          (lyrics.timed ? 200 : 0) -
          min(diff ?? 99, 99) * 2 -
          (order < 0 ? 9 : order);
    }
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

  /// Whether the walk can stop: the best is timed and of the song's own
  /// length (another version ranks below 1000, see [LyricsController]).
  bool get settled => best != null && best!.timed && _bestRank >= 1000;

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

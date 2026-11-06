/// Which file plays for songs whose VK file was swapped (Stage K): found by
/// the player's length check, decided here, stored per song.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../library/library_store.dart';
import '../library/song_version.dart';
import '../library/track.dart';
import '../vk/vk_client.dart';
import '../vk/vk_versions.dart';
import 'mp3_length.dart';
import 'stream_route.dart';

/// Finds the uploads of [track]'s song, asking VK as [route]'s account;
/// [progress] (when given) hears them as they come in.
typedef FindVersions = Future<List<SongVersion>> Function(
  Track track,
  StreamRoute route,
  VersionProgress? progress,
);

/// Measures the file VK gives for [route]'s key now; null: no audio.
typedef MeasureVkFile = Future<FileFacts?> Function(StreamRoute route);

/// The versions chosen for swapped songs, and the search that finds them.
///
/// The player asks [choiceFor] before each play and calls [decide] when the
/// song's own file turns out to be another recording; the song's mark and
/// the version dialog read and change the same choices.
class VersionBook extends ChangeNotifier {
  VersionBook({
    required LibraryStore store,
    required this._find,
    required this._measure,
    this.persist = true,
    int Function()? now,
  }) : _store = store,
       _now = now ?? (() => DateTime.now().millisecondsSinceEpoch),
       _choices = store.versionChoices();

  /// The book for the app: VK's search through the song's own account.
  /// [log] (perf.log) hears how each search went: times and counts only.
  factory VersionBook.vk(
    LibraryStore store, {
    bool persist = true,
    void Function(String line)? log,
  }) => VersionBook(
    store: store,
    persist: persist,
    find: (track, route, progress) async {
      final stats = VersionSearchStats();
      try {
        final found = await findVkVersions(
          route.client,
          VersionQuery(
            artist: track.artist,
            title: track.title,
            vkTrackId: store.vkTrackIdOf(track.id),
            ownKeys: {for (final copy in track.allCopies) ?copy.sourceKey},
          ),
          progress: progress,
          stats: stats,
        );
        log?.call('versions of song ${track.id}: $stats');
        return found;
      } on Object catch (error) {
        log?.call(
          'versions of song ${track.id} failed after ${stats.searchMs} '
          'ms in ${stats.searchTries} requests: ${searchFailure(error)}',
        );
        rethrow;
      }
    },
    measure: (route) =>
        measureVkFile(route.client, route.sourceKey, route.accessKey),
  );

  final LibraryStore _store;
  final FindVersions _find;
  final MeasureVkFile _measure;
  final int Function() _now;

  /// Whether choices are written to the library. Off in the speed gate's
  /// runs, which keep their data unchanged: choices then last one run.
  final bool persist;

  final Map<int, VersionChoice> _choices;
  final _searching = <int>{};

  /// The version that plays for [track]; null when its own file plays
  /// unchecked so far. A choice made for another listed length (a sync
  /// changed it since) no longer applies.
  VersionChoice? choiceFor(Track track) {
    if (!track.inLibrary) return null;
    final choice = _choices[track.id];
    if (choice == null || choice.listedSec != track.durationSec) return null;
    return choice;
  }

  /// Whether the versions of [track] are being looked for now.
  bool isSearching(Track track) => _searching.contains(track.id);

  /// [track]'s own file, as asked through [ownRoute], plays as [own]: more
  /// than 3 s off the listed length. Looks for uploads of the song and
  /// keeps the best one within 1 s of the listed length as the suggested
  /// version; with none, VK's file plays, marked. When VK's search fails,
  /// VK's file plays this time and the next run searches again.
  Future<VersionChoice> decide(
    Track track,
    StreamRoute ownRoute,
    FileFacts own,
  ) async {
    _searching.add(track.id);
    notifyListeners();
    try {
      return _keep(
        decideVersion(
          trackId: track.id,
          listedSec: track.durationSec,
          ownSeconds: own.seconds,
          ownBytes: own.bytes,
          found: await _findAndKeep(track, ownRoute),
          nowMs: _now(),
        ),
      );
    } on Object {
      return _keep(
        VersionChoice(
          trackId: track.id,
          state: VersionState.none,
          ownSeconds: own.seconds,
          ownBytes: own.bytes,
          listedSec: track.durationSec,
          decidedAtMs: _now(),
          stored: false,
        ),
      );
    } finally {
      _searching.remove(track.id);
      notifyListeners();
    }
  }

  /// Searches for [track]'s uploads and keeps them in the library, so its
  /// versions open at once next time; [progress] hears them as they come.
  Future<List<SongVersion>> _findAndKeep(
    Track track,
    StreamRoute route, [
    VersionProgress? progress,
  ]) async {
    final found = await _find(track, route, progress);
    if (persist) _store.saveFoundVersions(track.id, found, atMs: _now());
    return found;
  }

  /// The versions of each song opened lately, newest last.
  final _lists = <int, VersionList>{};
  static const _listsKept = 16;

  /// The versions of [track]: what the last search found shows at once,
  /// with VK's current file as its print measured it. A new search runs
  /// through [route] when the stored one is older than
  /// [LibraryStore.foundVersionsLifetime] (or missing) or when [refresh]
  /// asks; its uploads show as VK answers, each with its length once its
  /// file is measured. Called early (when the song's menu opens), so the
  /// list is ready by the click. Without a [route] (no logged-in account)
  /// only the stored list shows.
  VersionList listOf(Track track, StreamRoute? route, {bool refresh = false}) {
    var list = _lists.remove(track.id);
    if (list == null || list.listedSec != track.durationSec) {
      list = VersionList._(track.id, track.durationSec);
      list._current = SongVersion(
        key: route?.sourceKey ?? track.sourceKey ?? '',
        accessKey: route?.accessKey ?? track.accessKey,
        artist: track.artist,
        title: track.title,
        album: track.album,
        coverUrl: track.coverUrl,
        coverLargeUrl: track.coverLargeUrl,
        listedSec: track.durationSec,
        // Its print, else what the play that found the swap measured.
        file:
            _store.printedFileOf(track.id) ??
            switch (choiceFor(track)) {
              VersionChoice(:final ownSeconds, :final ownBytes?) => FileFacts(
                bytes: ownBytes,
                seconds: ownSeconds,
              ),
              _ => null,
            },
        isCurrentFile: true,
      );
      final stored = _store.foundVersions(track.id);
      if (stored != null) {
        list._uploads = stored.versions;
        list._foundAtMs = stored.foundAtMs;
      }
    }
    _lists[track.id] = list;
    while (_lists.length > _listsKept) {
      _lists.remove(_lists.keys.first);
    }
    if (route != null) {
      if (list._current?.file == null && !list._measuringCurrent) {
        _measureCurrent(list, route);
      }
      final foundAt = list._foundAtMs;
      final old =
          foundAt == null ||
          _now() - foundAt > LibraryStore.foundVersionsLifetime.inMilliseconds;
      if (!list._searching && (old || refresh)) _search(list, track, route);
    }
    return list;
  }

  Future<void> _measureCurrent(VersionList list, StreamRoute route) async {
    list._measuringCurrent = true;
    list._changed();
    try {
      final facts = await _measure(route);
      final current = list._current;
      if (facts != null && current != null) {
        list._current = current.withFile(facts);
      }
    } on Object {
      // Listed without a length: VK gives no file now.
    } finally {
      list._measuringCurrent = false;
      list._changed();
    }
  }

  Future<void> _search(VersionList list, Track track, StreamRoute route) async {
    list
      .._searching = true
      .._error = null
      .._changed();
    try {
      final found = await _findAndKeep(track, route, (versions, measuring) {
        list
          .._uploads = versions
          .._measuring = measuring
          .._changed();
      });
      list
        .._uploads = found
        .._foundAtMs = _now();
    } on Object catch (error) {
      list._error = error;
    } finally {
      list
        .._searching = false
        .._measuring = const {}
        .._changed();
    }
  }

  /// A version as a song, to show and play like any other: the same
  /// upload gets the same id every time (negative, as album songs outside
  /// the library do), so the playing mark finds its row.
  Track versionTrack(Track row, SongVersion version) {
    final id = _versionIds.putIfAbsent(
      version.key,
      () => -1000000000 - _versionIds.length,
    );
    return Track(
      id: id,
      sourceId: row.sourceId,
      source: row.source,
      artist: version.artist,
      title: version.title,
      album: version.album,
      durationSec: version.file?.seconds.round() ?? version.listedSec,
      sourceKey: version.key,
      accessKey: version.accessKey,
      coverUrl: version.coverUrl,
      coverLargeUrl: version.coverLargeUrl,
    );
  }

  final _versionIds = <String, int>{};

  /// Takes over the choices stored in the library, which the background
  /// check after a sync decides (Stage M2), so swapped songs show their tag
  /// before they are played. A stored choice wins over the one in memory; a
  /// choice kept only in memory (VK's search failed) stays.
  void reload() {
    final stored = _store.versionChoices();
    if (persist) {
      _choices.removeWhere(
        (id, choice) => choice.stored && !stored.containsKey(id),
      );
    }
    _choices.addAll(stored);
    notifyListeners();
  }

  /// The user picked [version] for [track]: it plays from now on, until
  /// changed or reset.
  void pick(Track track, SongVersion version) {
    final before = _choices[track.id];
    _keep(
      VersionChoice(
        trackId: track.id,
        state: VersionState.picked,
        fileKey: version.key,
        fileAccessKey: version.accessKey,
        fileSeconds: version.file?.seconds ?? version.listedSec.toDouble(),
        ownSeconds:
            before?.ownSeconds ??
            (version.isCurrentFile ? version.file?.seconds : null) ??
            track.durationSec.toDouble(),
        ownBytes: before?.ownBytes,
        listedSec: track.durationSec,
        decidedAtMs: _now(),
      ),
    );
    notifyListeners();
  }

  /// Back to automatic: the next play checks the song's own file again and
  /// suggests a version when it is still another recording.
  void reset(Track track) => forget(track);

  /// Forgets [track]'s choice (also when its chosen file changed on VK).
  void forget(Track track) {
    if (_choices.remove(track.id) == null) return;
    if (persist) _store.removeVersionChoice(track.id);
    notifyListeners();
  }

  VersionChoice _keep(VersionChoice choice) {
    _choices[choice.trackId] = choice;
    if (persist && choice.stored) _store.saveVersionChoice(choice);
    return choice;
  }
}

/// Why a version search failed, in words for the versions heading and
/// perf.log: VK's own words (no titles, keys or links in them), or the kind
/// of network failure.
String searchFailure(Object error) => switch (error) {
  VkException(slowDown: true) =>
    'VK asks for a captcha after too many searches; wait a few minutes',
  VkException(:final message) => message,
  SocketException() => 'no connection to VK',
  HandshakeException() => 'secure connection to VK failed',
  TimeoutException() => 'VK did not answer in time',
  _ => error.runtimeType.toString(),
};

/// What a song's mark says, for the row tag and the player; null when the
/// song has no mark.
({String label, String explanation})? versionMark(
  VersionChoice? choice, {
  bool searching = false,
}) {
  if (searching) {
    return (
      label: 'finding version',
      explanation:
          "VK changed this song's file to another recording. Looking for "
          'the recording in your library...',
    );
  }
  if (choice == null) return null;
  String length(double? seconds) {
    if (seconds == null) return '?';
    final whole = seconds.round();
    return '${whole ~/ 60}:${(whole % 60).toString().padLeft(2, '0')}';
  }

  final vkFile =
      "VK changed this song's file: VK's file now plays "
      '${length(choice.ownSeconds)}, your library lists '
      '${length(choice.listedSec.toDouble())}.';
  return switch (choice.state) {
    VersionState.suggested => (
      label: 'suggested version',
      explanation:
          '$vkFile Playing the suggested match, another upload of the song '
          'that plays ${length(choice.fileSeconds)}. Click to choose a '
          'version.',
    ),
    VersionState.picked => (
      label: 'your version',
      explanation:
          "$vkFile Playing the version you chose "
          '(${length(choice.fileSeconds)}). Click to change it.',
    ),
    VersionState.none => (
      label: 'different recording',
      explanation:
          '$vkFile No upload on VK matches, so what plays is a different '
          'recording than in your library. Click to see the versions.',
    ),
  };
}

/// The versions of one song as they come in (see [VersionBook.listOf]).
class VersionList extends ChangeNotifier {
  VersionList._(this.trackId, this.listedSec);

  /// The library row and the length it listed when the list was made.
  final int trackId;
  final int listedSec;

  SongVersion? _current;
  List<SongVersion> _uploads = const [];
  Set<String> _measuring = const {};
  bool _searching = false;
  bool _measuringCurrent = false;
  Object? _error;
  int? _foundAtMs;

  /// VK's file for the row now; its [SongVersion.file] is null until it is
  /// measured, or when VK gives no file.
  SongVersion? get current => _current;

  /// The other uploads VK's search found, in the order found.
  List<SongVersion> get uploads => _uploads;

  /// Whether VK's search runs now.
  bool get searching => _searching;

  /// Whether [version]'s file is being measured now.
  bool isMeasuring(SongVersion version) => version.isCurrentFile
      ? _measuringCurrent
      : _measuring.contains(version.key);

  /// Why the last search failed; null when it did not.
  Object? get error => _error;

  /// When the uploads shown were found; null before the first search ends.
  int? get foundAtMs => _foundAtMs;

  void _changed() => notifyListeners();
}

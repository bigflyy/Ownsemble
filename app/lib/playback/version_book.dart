/// Which file plays for songs whose VK file was swapped (Stage K): found by
/// the player's length check, decided here, stored per song.
library;

import 'package:flutter/foundation.dart';

import '../library/library_store.dart';
import '../library/song_version.dart';
import '../library/track.dart';
import '../vk/vk_versions.dart';
import 'mp3_length.dart';
import 'stream_route.dart';

/// Finds the uploads of [track]'s song, asking VK as [route]'s account.
typedef FindVersions = Future<List<SongVersion>> Function(
  Track track,
  StreamRoute route,
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
  factory VersionBook.vk(LibraryStore store, {bool persist = true}) =>
      VersionBook(
        store: store,
        persist: persist,
        find: (track, route) => findVkVersions(
          route.client,
          VersionQuery(
            artist: track.artist,
            title: track.title,
            vkTrackId: store.vkTrackIdOf(track.id),
            ownKeys: {for (final copy in track.allCopies) ?copy.sourceKey},
          ),
        ),
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
          found: await _find(track, ownRoute),
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

  /// Every version of [track] for the dialog, best first: VK's current file
  /// for the row (asked through [ownRoute]) and the uploads VK's search
  /// finds. Throws as VK does when the search fails.
  Future<List<SongVersion>> versionsOf(
    Track track,
    StreamRoute ownRoute,
  ) async {
    final (found, own) = await (
      _find(track, ownRoute),
      _measure(ownRoute)
          .then<FileFacts?>((facts) => facts, onError: (_) => null),
    ).wait;
    return rankVersions(track.durationSec, [
      SongVersion(
        key: ownRoute.sourceKey,
        accessKey: ownRoute.accessKey,
        artist: track.artist,
        title: track.title,
        album: track.album,
        listedSec: track.durationSec,
        file: own,
        isCurrentFile: true,
      ),
      ...found,
    ]);
  }

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

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../library/library_store.dart';
import '../library/track.dart';

/// Where a song's audio is stored right now: its path (relative to the data
/// folder, or absolute) and whether it is downloaded. Null path: not stored.
typedef StoredState = ({String? path, bool pinned});

/// The app's stored audio: songs cached while streaming and downloaded
/// songs, both in the data folder's `cache` folder under internal names.
///
/// Everything that decides where audio files live goes through here, so a
/// later setting (readable names and tags in a folder the user picks) is a
/// change to this class, not to the player or the UI.
///
/// The library list holds the songs as loaded at start or after a sync; what
/// changed since (cached, downloaded, removed) is kept here and wins.
class AudioStorage extends ChangeNotifier {
  AudioStorage({required this.dataDir, required this._store});

  /// Setting with the cache limit in bytes.
  static const limitSetting = 'cache_limit_bytes';

  /// Default limit for cached (not downloaded) songs: 5 GB.
  static const defaultLimitBytes = 5 * 1024 * 1024 * 1024;

  final String dataDir;
  final LibraryStore _store;
  final _changed = <int, StoredState>{};
  final _downloading = <int>{};

  /// Saves running while songs stream (track id to the save's result).
  final _saving = <int, Future<int?>>{};

  /// How far running saves and downloads are (track id to whole percent).
  final _percent = <int, int>{};
  final _progress = ValueNotifier<int>(0);

  /// Fires when a running save or download gets further. Apart from this
  /// notifier itself, which rebuilds the song list: a save reports up to a
  /// hundred times.
  Listenable get progress => _progress;

  /// How [track]'s audio is stored now.
  StoredState stateOf(Track track) =>
      _changed[track.id] ?? (path: track.localPath, pinned: track.pinned);

  /// Whether a Download of [track] is in progress.
  bool isDownloading(Track track) => _downloading.contains(track.id);

  /// Whether [track] is being saved while it streams.
  bool isSaving(Track track) => _saving.containsKey(track.id);

  /// How much of [track]'s audio is stored, 0 to 1: the part saved so far
  /// during a save or download, else all or nothing.
  double savedShare(Track track) {
    final percent = _percent[track.id];
    if (percent != null) return percent / 100;
    return stateOf(track).path == null ? 0 : 1;
  }

  /// Notes that a save of [track] reached [bytes] of [total] (negative:
  /// size unknown, no progress to show).
  void noteProgress(Track track, int bytes, int total) {
    if (total <= 0) return;
    final percent = bytes * 100 ~/ total;
    if (_percent[track.id] == percent) return;
    _percent[track.id] = percent;
    _progress.value++;
  }

  /// Cache limit for songs that are not downloaded, in bytes.
  int get limitBytes =>
      int.tryParse(_store.readSetting(limitSetting) ?? '') ?? defaultLimitBytes;

  /// Where [track]'s audio is stored, relative to the data folder.
  String relativePathFor(Track track) =>
      p.join('cache', '${track.source.name}_${track.sourceKey}.mp3');

  /// Where to save [track] while it streams; null while a Download fetches
  /// it or an earlier play still saves it in the background, because both
  /// would write the same `.part` file.
  String? streamSavePath(Track track) =>
      isDownloading(track) || isSaving(track) ? null : relativePathFor(track);

  /// The file at a stored [path].
  File fileAt(String path) => File(resolveAudioPath(dataDir, path));

  /// Notes that [track] is being saved while it streams; [stored] completes
  /// with the size once saved, or null. A Download meanwhile waits for it
  /// instead of fetching the song a second time.
  void noteSaving(Track track, Future<int?> stored) {
    _saving[track.id] = stored;
    notifyListeners();
    stored.whenComplete(() {
      if (!identical(_saving[track.id], stored)) return;
      _saving.remove(track.id);
      _percent.remove(track.id);
      notifyListeners();
    });
  }

  /// Records that [track]'s whole audio is now at [path] ([bytes] long),
  /// then removes the oldest cached songs if the cache is over its limit;
  /// [keep] (the song playing now) and [track] itself stay.
  void recordStored(
    Track track,
    String path,
    int bytes, {
    bool pinned = false,
    Set<int> keep = const {},
  }) {
    final wasPinned = stateOf(track).pinned;
    _store.saveAudioFile(track.id, path, bytes, pinned: pinned);
    _changed[track.id] = (path: path, pinned: pinned || wasPinned);
    applyLimit(keep: {...keep, track.id});
    notifyListeners();
  }

  /// Removes cached songs, played longest ago first, until the cache fits
  /// its limit. Downloaded songs and [keep] are never removed, nor a file
  /// another song still points at. Returns the ids of songs removed.
  List<int> applyLimit({Set<int> keep = const {}}) {
    final limit = limitBytes;
    final removed = <int>[];
    if (_store.cachedBytes() <= limit) return removed;
    for (final cached in _store.evictionOrder()) {
      if (keep.contains(cached.trackId)) continue;
      _store.removeAudioFile(cached.trackId);
      _changed[cached.trackId] = (path: null, pinned: false);
      removed.add(cached.trackId);
      if (_store.audioPathUsers(cached.path) == 0) {
        try {
          fileAt(cached.path).deleteSync();
        } on FileSystemException {
          // Already gone, or open elsewhere: the row is gone either way and
          // a leftover file is only wasted space.
        }
      }
      if (_store.cachedBytes() <= limit) break;
    }
    if (removed.isNotEmpty) notifyListeners();
    return removed;
  }

  /// Downloads [track]: keeps its audio until the user removes it. A song
  /// already cached is just marked downloaded; otherwise its audio is
  /// fetched from the link [resolveUrl] gives, and only from it: no other
  /// copy's file is ever kept instead. Throws when that fails.
  Future<void> download(Track track, Future<Uri?> Function() resolveUrl) async {
    final state = stateOf(track);
    if (state.path != null && fileAt(state.path!).existsSync()) {
      _store.setPinned(track.id, true);
      _changed[track.id] = (path: state.path, pinned: true);
      notifyListeners();
      return;
    }
    if (!_downloading.add(track.id)) return;
    notifyListeners();
    try {
      // The song is being saved while it streams: wait for that save.
      final saving = _saving[track.id];
      if (saving != null && await saving != null) {
        final path = stateOf(track).path;
        if (path != null) {
          _store.setPinned(track.id, true);
          _changed[track.id] = (path: path, pinned: true);
          return;
        }
      }
      final url = await resolveUrl();
      if (url == null) throw StateError('VK has no stream for this song');
      final path = relativePathFor(track);
      void onProgress(int bytes, int total) =>
          noteProgress(track, bytes, total);
      final bytes = await fetchToFile(
        url,
        fileAt(path),
        onProgress: onProgress,
      );
      recordStored(track, path, bytes, pinned: true);
    } finally {
      _downloading.remove(track.id);
      _percent.remove(track.id);
      notifyListeners();
    }
  }

  /// Makes a downloaded song plain cache again: it stays stored until the
  /// cache limit needs the space. [keep] is the song playing now.
  void removeDownload(Track track, {Set<int> keep = const {}}) {
    final state = stateOf(track);
    if (state.path == null || !state.pinned) return;
    _store.setPinned(track.id, false);
    _changed[track.id] = (path: state.path, pinned: false);
    applyLimit(keep: keep);
    notifyListeners();
  }
}

/// The audio server answered with an error instead of audio, or not at all
/// ([status] 0).
class AudioServerException extends HttpException {
  AudioServerException(this.status) : super('audio server answered $status');

  final int status;
}

/// Fetches [url] completely into [target] through a `.part` file; returns
/// the size. Fails on an HTTP error, a stall of 30 s or a short body, and
/// then leaves no file behind. [onProgress] gets the bytes so far and the
/// whole size (negative when unknown).
Future<int> fetchToFile(
  Uri url,
  File target, {
  HttpClient? client,
  void Function(int bytes, int total)? onProgress,
}) async {
  final http =
      client ?? (HttpClient()..connectionTimeout = const Duration(seconds: 10));
  final part = File('${target.path}.part');
  try {
    final response = await (await http.getUrl(url))
        .close()
        .timeout(const Duration(seconds: 15));
    if (response.statusCode != HttpStatus.ok) {
      await response.drain<void>();
      throw AudioServerException(response.statusCode);
    }
    part.parent.createSync(recursive: true);
    final sink = part.openWrite();
    var bytes = 0;
    try {
      await for (final chunk in response.timeout(const Duration(seconds: 30))) {
        sink.add(chunk);
        bytes += chunk.length;
        onProgress?.call(bytes, response.contentLength);
      }
    } finally {
      await sink.close();
    }
    if (response.contentLength >= 0 && bytes != response.contentLength) {
      throw HttpException(
        'download ended early: $bytes of ${response.contentLength} bytes',
      );
    }
    if (target.existsSync()) target.deleteSync();
    part.renameSync(target.path);
    return bytes;
  } catch (_) {
    if (part.existsSync()) part.deleteSync();
    rethrow;
  } finally {
    if (client == null) http.close(force: true);
  }
}

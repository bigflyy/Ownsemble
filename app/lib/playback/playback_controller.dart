import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../library/track.dart';
import 'play_queue.dart';
import 'player_service.dart';

/// What the player controls do: playing from a list, previous and next,
/// shuffle, repeat, auto-advance, seeking and volume. Records every song
/// that starts playing in the History.
class PlaybackController extends ChangeNotifier {
  PlaybackController({
    required this.player,
    required this.recordPlay,
    PlayQueue? queue,
    String? Function(String key)? readSetting,
    this._writeSetting,
  }) : queue = queue ?? PlayQueue(),
       _readSetting = readSetting {
    final saved = double.tryParse(readSetting?.call(volumeSetting) ?? '');
    if (saved != null) _volume = saved.clamp(0, 100);
    _mutedByUser = readSetting?.call(muteSetting) == 'on';
    _showRemaining = readSetting?.call(remainingSetting) == 'on';
    this.queue.shuffle = readSetting?.call(shuffleSetting) == 'on';
    this.queue.repeat =
        Repeat.values.asNameMap()[readSetting?.call(repeatSetting)] ??
        Repeat.off;
    _ended = player.ended.listen((_) => unawaited(_onEnded()));
    player.playing.addListener(_onPlayingChanged);
  }

  /// Settings with the chosen volume and whether the user muted.
  static const volumeSetting = 'player.volume';
  static const muteSetting = 'player.mute';

  /// Settings with the shuffle and repeat buttons' state and whether the time
  /// label shows the remaining time.
  static const shuffleSetting = 'player.shuffle';
  static const repeatSetting = 'player.repeat';
  static const remainingSetting = 'player.remaining';

  /// Settings with the song to restore: `{"id", "ms", "index"}` (library id,
  /// position, index in the list), written often and so kept small; the
  /// list's song ids, written when the list changes (up to 60 KB at 10,000
  /// songs); and the queued songs' ids.
  static const songSetting = 'player.song';
  static const listSetting = 'player.list';
  static const queuedSetting = 'player.queued';

  /// While a song plays its position is saved this often, so a crash or a
  /// forced end loses at most this much. A normal close saves the exact place.
  static const saveEvery = Duration(seconds: 5);

  /// A song closer to its end than this comes back from its start: going on
  /// from there would end it at once and move to the next song.
  static const nearEnd = Duration(seconds: 3);

  final PlayerService player;
  final PlayQueue queue;
  final String? Function(String key)? _readSetting;
  final void Function(String key, String? value)? _writeSetting;

  /// Writes a History entry for a song that started playing.
  final void Function(Track track) recordPlay;

  late final StreamSubscription<void> _ended;

  /// Counts play requests, so an automatic skip stops when the user picks
  /// another song meanwhile.
  int _request = 0;

  /// Saves the position while a song plays; null while none does.
  Timer? _saveTimer;

  /// The list and queue as last saved, to write them only when they change.
  List<Track>? _savedList;
  String? _savedQueued;

  /// True while a restored song is starting, so a second press of Play does
  /// not start it again.
  bool _resuming = false;

  /// Whether nothing plays or is about to: nothing started yet, the list
  /// ended, or the last song failed. A paused song does not count.
  bool _idle = true;

  double _volume = 100;
  bool _mutedByUser = false;
  bool _showRemaining = false;

  /// At most this many songs in a row are skipped because they cannot play
  /// (blocked by VK, gone and not stored) before auto-advance gives up.
  static const maxSkips = 20;

  double get volume => _volume;
  bool get mutedByUser => _mutedByUser;
  bool get shuffle => queue.shuffle;
  Repeat get repeat => queue.repeat;

  /// Whether the time label shows the remaining time instead of the total.
  bool get showRemaining => _showRemaining;

  /// A click on the song at [index] of [list]: the song that is already
  /// loaded pauses or resumes; any other song starts, and [list] becomes the
  /// list next and previous move in. A song that failed is retried.
  Future<PlayTiming?> playFrom(List<Track> list, int index) async {
    if (!player.isReady) return null;
    final track = list[index];
    if (track.id == player.current?.id &&
        (player.currentLoaded || player.resumeAt != null)) {
      await playOrPause();
      return null;
    }
    return _play(queue.start(list, index));
  }

  /// Pauses or resumes. A song restored from the last run starts here, at
  /// its saved position; that is not a new play, so History does not change.
  Future<void> playOrPause() async {
    if (!player.isReady) return;
    final track = player.current;
    final resumeAt = player.resumeAt;
    if (track == null || resumeAt == null) return player.playOrPause();
    if (_resuming) return;
    _resuming = true;
    try {
      await _play(track, from: resumeAt, record: false);
    } finally {
      _resuming = false;
    }
  }

  /// The Next button: the next song of the list (wraps at the end).
  Future<PlayTiming?> next() async {
    if (!player.isReady) return null;
    final track = queue.next(auto: false);
    return track == null ? null : _play(track);
  }

  /// The Previous button: back to the start of the song after 3 s of it,
  /// else the previous song of the list.
  Future<PlayTiming?> previous() async {
    if (!player.isReady || queue.current == null) return null;
    final track = queue.previous(player.position);
    if (track == null) {
      await player.seek(Duration.zero);
      return null;
    }
    return _play(track);
  }

  /// Moving back in a song that ended leaves it paused there, which is not
  /// idle: the song can go on from that place.
  Future<void> seek(Duration to) async {
    _idle = false;
    await player.seek(to);
    // A restored song reports no positions, so the seek bar waits for this.
    if (player.resumeAt != null) notifyListeners();
  }

  /// Moves by [offset] within the song, for the arrow keys.
  Future<void> seekBy(Duration offset) async {
    await player.seekBy(offset);
    if (player.resumeAt != null) notifyListeners();
  }

  /// Sound from any cause means something plays, for example the last song
  /// of a list resumed after it ended.
  void _onPlayingChanged() {
    if (player.playing.value) {
      _idle = false;
      _saveTimer ??= Timer.periodic(saveEvery, (_) => saveSession());
    } else {
      _saveTimer?.cancel();
      _saveTimer = null;
      saveSession();
    }
  }

  /// "Play next": [track] plays right after the current song.
  Future<void> playNext(Track track) {
    queue.playNext(track);
    return _queueGrew();
  }

  /// "Add to queue": [track] plays after the songs already queued.
  Future<void> addToQueue(Track track) {
    queue.addToQueue(track);
    return _queueGrew();
  }

  /// Takes the song at [index] of the queue out of it.
  void removeQueued(int index) {
    queue.removeQueued(index);
    saveSession();
    notifyListeners();
  }

  /// A click on a queued song in Up next: it plays now.
  Future<PlayTiming?> playQueued(int index) async {
    if (!player.isReady) return null;
    return _play(queue.takeQueued(index));
  }

  /// With nothing playing a song just queued starts at once, since no song
  /// will end to make room for it.
  Future<void> _queueGrew() async {
    notifyListeners();
    saveSession();
    if (!_idle || !player.isReady) return;
    final track = queue.next(auto: false);
    if (track != null) await _play(track);
  }

  /// Downloads [track] (keeps its audio for good). Returns why it failed,
  /// or null on success.
  Future<String?> download(Track track) async {
    final storage = player.storage;
    if (storage == null) return 'no storage';
    if (!track.inLibrary) return 'not in your library';
    try {
      // A Download does not go through the player's check of the file:
      // a song whose VK file was swapped keeps its chosen version instead.
      // A file already on disk was measured when it played, so it is only
      // marked kept, at once and without asking VK.
      if (!storage.hasFile(track)) await player.checkVersion(track);
      await storage.download(track, () async {
        final resolved = await player.resolveStream(track);
        if (resolved == null) return null;
        if (resolved.stream.link == null) {
          throw StateError(noStreamReason(resolved.stream));
        }
        return resolved.stream.link;
      });
      return null;
    } catch (error) {
      return describePlayError(error);
    }
  }

  /// The version that plays for [track] changed: the song starts again
  /// with the new one when it is the song playing. A version playing from
  /// the versions list goes on as it is.
  Future<void> versionChanged(Track track) async {
    if (player.current?.id == track.id) await _play(track, record: false);
  }

  /// Makes a downloaded song plain cache again.
  void removeDownload(Track track) =>
      player.storage?.removeDownload(track, keep: {?player.current?.id});

  void toggleShuffle() {
    queue.shuffle = !queue.shuffle;
    _writeSetting?.call(shuffleSetting, queue.shuffle ? 'on' : 'off');
    notifyListeners();
  }

  void cycleRepeat() {
    queue.cycleRepeat();
    _writeSetting?.call(repeatSetting, queue.repeat.name);
    notifyListeners();
  }

  void toggleRemaining() {
    _showRemaining = !_showRemaining;
    _writeSetting?.call(remainingSetting, _showRemaining ? 'on' : 'off');
    notifyListeners();
  }

  /// Sets the volume (0 to 100); moving the slider also unmutes. Called for
  /// every step of a drag, so it does not save: see [saveVolume].
  Future<void> setVolume(double volume) async {
    _volume = volume.clamp(0, 100);
    if (_mutedByUser && _volume > 0) {
      _mutedByUser = false;
      await player.setMuted(false);
    }
    notifyListeners();
    await player.setVolume(_volume);
  }

  /// Moves the volume by [by] and keeps it, for the arrow keys.
  Future<void> stepVolume(double by) async {
    await setVolume(_volume + by);
    saveVolume();
  }

  /// Keeps the volume for the next run, once the slider is let go.
  void saveVolume() {
    _writeSetting?.call(volumeSetting, _volume.toStringAsFixed(1));
    _saveMute();
  }

  void _saveMute() =>
      _writeSetting?.call(muteSetting, _mutedByUser ? 'on' : 'off');

  Future<void> toggleMute() async {
    _mutedByUser = !_mutedByUser;
    _saveMute();
    notifyListeners();
    await player.setMuted(_mutedByUser);
  }

  /// Takes over a new version of the library after a sync: the play list and
  /// the queue get [find]'s songs, so the old version can be freed. The ids
  /// stay the same, so a list already saved is not written again.
  void refreshTracks(Track? Function(int id) find) {
    final listSaved = identical(queue.context, _savedList);
    queue.refreshTracks(find);
    // The saved list was the old one: holding it would keep the old songs.
    _savedList = listSaved ? queue.context : null;
    notifyListeners();
  }

  /// Saves the current song and its place, so the next run can go on from
  /// there. A song that failed is left out: the last one that played stays.
  void saveSession() {
    final write = _writeSetting;
    final track = queue.current;
    if (write == null || track == null || track.id != player.current?.id) {
      return;
    }
    if (!player.currentLoaded && player.resumeAt == null) return;
    final position = player.position;
    final length = player.duration;
    final atEnd = length > Duration.zero && position >= length - nearEnd;
    write(
      songSetting,
      jsonEncode({
        'id': track.id,
        'ms': atEnd ? 0 : position.inMilliseconds,
        'index': queue.contextIndex,
      }),
    );
    if (!identical(queue.context, _savedList)) {
      _savedList = queue.context;
      write(listSetting, jsonEncode([for (final t in queue.context) t.id]));
    }
    final queued = jsonEncode([for (final t in queue.queued) t.id]);
    if (queued != _savedQueued) {
      _savedQueued = queued;
      write(queuedSetting, queued);
    }
  }

  /// Brings back the song, list and queue of the last run, paused at the
  /// saved position; [find] gives the library's song for an id. Songs no
  /// longer in the library are left out, and without the song nothing comes
  /// back. Runs before the first frame, and nothing loads until Play.
  void restoreSession(Track? Function(int id) find) {
    final read = _readSetting;
    final song = _decode(read?.call(songSetting));
    if (read == null || song is! Map<String, Object?>) return;
    final id = song['id'];
    final track = id is int ? find(id) : null;
    if (track == null) return;
    final savedIndex = song['index'];
    final ms = song['ms'];

    final ids = _decode(read(listSetting));
    final list = <Track>[];
    var index = 0;
    if (ids is List<Object?>) {
      for (final (i, listId) in ids.indexed) {
        // Songs before the saved one may have left the library.
        if (i == savedIndex) index = list.length;
        final listed = listId is int ? find(listId) : null;
        if (listed != null) list.add(listed);
      }
    }
    if (list.isEmpty) list.add(track);
    queue.start(list, index.clamp(0, list.length - 1));
    if (queue.current?.id != track.id) {
      // A queued song was playing, or its place in the list is gone.
      queue.playNext(track);
      queue.next(auto: false);
    }
    final queued = _decode(read(queuedSetting));
    if (queued is List<Object?>) {
      for (final queuedId in queued) {
        final waiting = queuedId is int ? find(queuedId) : null;
        if (waiting != null) queue.addToQueue(waiting);
      }
    }
    // Not idle: a song queued now waits for this one, as for any paused song.
    _idle = false;
    player.restore(track, Duration(milliseconds: ms is int ? ms : 0));
  }

  /// [text] parsed as JSON, or null when it is missing or broken.
  static Object? _decode(String? text) {
    if (text == null) return null;
    try {
      return jsonDecode(text);
    } on FormatException {
      return null;
    }
  }

  /// Plays [track] from [from] (the start when null). Once sound starts it
  /// is saved for the next run and, when [record], added to the History.
  Future<PlayTiming> _play(
    Track track, {
    Duration? from,
    bool record = true,
  }) async {
    final request = ++_request;
    _idle = false;
    final timing = await player.play(track, from: from);
    if (request == _request) {
      if (timing.ok) {
        // History points at library rows; an album's song outside the
        // library has none.
        if (record && track.inLibrary) recordPlay(track);
        saveSession();
      } else {
        _idle = true;
      }
    }
    notifyListeners();
    return timing;
  }

  /// A song played to its end: the next one per shuffle and repeat. Songs
  /// that cannot play are skipped, up to [maxSkips] in a row.
  Future<void> _onEnded() async {
    for (var skips = 0; skips < maxSkips; skips++) {
      final track = queue.next(auto: true);
      if (track == null) {
        _idle = true;
        saveSession();
        return;
      }
      final request = _request + 1;
      final timing = await _play(track);
      // Stop once a song plays, when the user picked another song meanwhile,
      // or when repeat one would retry the same failing song.
      if (timing.ok || request != _request) return;
      if (queue.repeat == Repeat.one && queue.queued.isEmpty) return;
    }
  }

  @override
  void dispose() {
    player.playing.removeListener(_onPlayingChanged);
    _saveTimer?.cancel();
    _ended.cancel();
    super.dispose();
  }
}

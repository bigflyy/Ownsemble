/// The On VK part of search place A (plan 06, C3): under the user's own
/// results, the songs VK's catalog finds for the same words, each one
/// playable with a click and added to the library and the VK account with +.
///
/// A keystroke never waits for VK: own results filter at once, as before,
/// and VK is asked only after a pause in typing ([CatalogSearch.pause]),
/// since one search page takes 2-4 s (C1). Each query's answer is kept for a
/// while, so Backspace back to an earlier query asks nothing again.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../library/found_match.dart';
import '../library/library_store.dart';
import '../library/track.dart';
import '../playback/version_book.dart' show searchFailure;
import '../vk/vk_catalog.dart';
import '../vk/vk_client.dart';
import 'library_controller.dart';

/// Setting: the accounts + adds to, as source ids joined by commas, or
/// "all" for every account (new ones too).
const catalogTargetsSetting = 'catalog.add_to';

/// Setting: "folded" when the On VK part is folded to its header.
const catalogFoldedSetting = 'catalog.vk_folded';

/// Fewer letters than this ask VK nothing: one letter finds everything.
const catalogMinQueryLength = 2;

/// How many queries' answers are kept.
const _answersKept = 12;

/// Ids of found songs start here and go down, apart from album songs
/// outside the library (-1, -2, ...) and versions (-1e9 - n).
const _firstFoundId = -2000000000;

/// One song outside the library that + can add, as its row and the player
/// show it: a song the catalog found, an album's song the library does not
/// have, or another upload in a song's Versions (C4).
@immutable
class FoundSong {
  const FoundSong({
    required this.song,
    required this.track,
    this.except = const {},
  });

  /// The song as VK listed it, for adding.
  final NewTrack song;

  /// The same song as a track outside the library (negative id), streamed
  /// through the account that searched.
  final Track track;

  /// Library songs that do not count as "already in the library" for this
  /// one: in Versions, the song whose versions they are.
  final Set<int> except;

  String get key => song.sourceKey;
}

/// Where a found song stands.
enum FoundState {
  /// Not in the library: + adds it.
  addable,

  /// + was clicked; VK has not answered yet.
  adding,

  /// Added in this run, or already in the library: a check.
  inLibrary,
}

/// What VK answered for one query, page by page.
class _Answer {
  _Answer(this.query);

  final String query;
  final songs = <FoundSong>[];
  final keys = <String>{};
  int total = 0;
  int nextOffset = 0;
  bool loading = false;
  Object? error;

  bool get hasMore => error == null && nextOffset < total;
}

/// State of the On VK part: the query it is for, VK's answer, the accounts +
/// adds to, and each found song's + state.
///
/// Reads the search text and the view from [library]; the part is there
/// only on Songs, with at least [catalogMinQueryLength] letters and a
/// logged-in VK account.
class CatalogSearch extends ChangeNotifier {
  CatalogSearch({
    required this.library,
    required this.store,
    required this._sources,
    required this.apiOfSource,
    required this.onLibraryChanged,
    this.onAdded,
    String? Function(String key)? readSetting,
    this._writeSetting,
    this.pause = const Duration(milliseconds: 500),
    this.reloadAfter = const Duration(milliseconds: 350),
    this.log,
  }) {
    _folded = readSetting?.call(catalogFoldedSetting) == 'folded';
    _targetsText = readSetting?.call(catalogTargetsSetting);
    library.addListener(_onLibraryChanged);
    _sources.addListener(_onSourcesChanged);
    _onLibraryChanged();
  }

  final LibraryController library;
  final LibraryStore store;
  final ValueListenable<List<SourceInfo>> _sources;

  /// Calls VK as a source's account; null when it is not logged in.
  final VkApiCall? Function(int sourceId) apiOfSource;

  /// Reloads the lists from [store] after songs were added (main.dart:
  /// loadAll, the search index, the sources' counts). [severalAccounts]:
  /// the song went to more than one account, and a sync should run soon:
  /// it reads the copies' files, which merges them into one listed song
  /// (Stage L), until then each account lists its own copy.
  final void Function({required bool severalAccounts}) onLibraryChanged;

  /// After the reload: the songs outside the library just added, by their
  /// outside id, with the library's copy of each (main.dart: the player and
  /// the play list take the copies, see PlaybackController.adoptAdded).
  final void Function(Map<int, Track> copies)? onAdded;

  final void Function(String key, String? value)? _writeSetting;

  /// The pause in typing after which VK is asked.
  final Duration pause;

  /// The wait between VK's yes and the lists' reload, so the reload's
  /// frame does not land inside the 0.3 s add animation.
  final Duration reloadAfter;

  /// One line to perf.log: counts and times only.
  final void Function(String line)? log;

  var _folded = false;
  String? _targetsText;

  /// The query the part shows; null when the part is not shown.
  String? _query;
  Timer? _wait;
  _Answer? _answer;
  final _answers = <String, _Answer>{};

  /// Ids handed to found songs, by "sourceId:key", so a song keeps its id
  /// (and the playing mark) while the app runs.
  final _ids = <String, int>{};
  final _byId = <int, FoundSong>{};

  /// Songs being added, and the accounts each song was added to in this run.
  final _adding = <String>{};
  final _addedTo = <String, List<int>>{};

  /// Ids of the found or outside songs added since the last reload.
  final _justAdded = <int>{};

  FoundMatcher? _matcher;
  List<Track>? _matcherOf;
  Timer? _reload;
  var _disposed = false;

  // ---- What the part shows ----

  /// Whether the part is shown under the own results.
  bool get active => _query != null;

  /// The words VK is asked for.
  String get query => _query ?? '';

  /// Whether the part is folded to its header.
  bool get folded => _folded;

  void toggleFolded() {
    _folded = !_folded;
    _writeSetting?.call(catalogFoldedSetting, _folded ? 'folded' : null);
    notifyListeners();
  }

  /// The found songs so far, in VK's order.
  List<FoundSong> get songs => _answer?.songs ?? const [];

  /// How many songs VK says it found; null until its first page is in.
  int? get total {
    final answer = _answer;
    if (answer == null || (answer.loading && answer.songs.isEmpty)) {
      return null;
    }
    if (answer.error != null && answer.songs.isEmpty) return null;
    return answer.total;
  }

  /// Whether the first page is on its way (or waiting for the pause).
  bool get searching {
    final answer = _answer;
    return answer == null || (answer.songs.isEmpty && answer.loading);
  }

  /// Whether a next page is on its way.
  bool get loadingMore {
    final answer = _answer;
    return answer != null && answer.songs.isNotEmpty && answer.loading;
  }

  /// Why the last ask failed, in words; null when it did not.
  String? get error => switch (_answer?.error) {
    null => null,
    final error => searchFailure(error),
  };

  /// Whether Show more has more to show.
  bool get hasMore => _answer?.hasMore ?? false;

  /// How many more songs VK says there are.
  int get moreCount {
    final answer = _answer;
    return answer == null ? 0 : answer.total - answer.songs.length;
  }

  /// The found song with id [id], if it was found in this run (or shown
  /// as an album's or a version's row: [outsideSong]).
  FoundSong? foundById(int id) => _byId[id];

  /// The library's song for the found or outside song with id [id], once
  /// the library lists it; null otherwise.
  Track? libraryCopyOf(int id) {
    final found = _byId[id];
    return found == null ? null : _listedOf(found);
  }

  /// [track], a song outside the library (an album's song, another upload
  /// in a song's Versions), as a song + can add. The same song gives the
  /// same object every time, so its + state and the player's + follow it.
  /// [vkTrackId] and the album key go into the added row, as a sync would
  /// write them; [except] as [FoundSong.except].
  FoundSong outsideSong(
    Track track, {
    int? vkTrackId,
    String? vkAlbumKey,
    String? vkAlbumAccessKey,
    Set<int> except = const {},
  }) {
    final kept = _byId[track.id];
    if (kept != null && kept.key == track.sourceKey) return kept;
    final found = FoundSong(
      song: NewTrack(
        artist: track.artist,
        title: track.title,
        album: track.album,
        durationSec: track.durationSec,
        addedAt: 0,
        sourceKey: track.sourceKey ?? '',
        accessKey: track.accessKey,
        coverUrl: track.coverUrl,
        coverLargeUrl: track.coverLargeUrl,
        coverMidUrl: track.coverMidUrl,
        coverFullUrl: track.coverFullUrl,
        tint: track.tint,
        vkTrackId: vkTrackId,
        vkAlbumKey: vkAlbumKey,
        vkAlbumAccessKey: vkAlbumAccessKey,
      ),
      track: track,
      except: except,
    );
    _byId[track.id] = found;
    return found;
  }

  // ---- Accounts ----

  /// The VK accounts that are logged in: + can add to these.
  List<SourceInfo> get accounts => [
    for (final source in _sources.value)
      if (source.kind == TrackSource.vk && apiOfSource(source.id) != null)
        source,
  ];

  /// Whether every account is ticked ("All").
  bool get allTicked => _targetsText == 'all';

  /// The accounts + adds to, in the sources' order: the ticked ones that are
  /// logged in, or the first account when none of them is.
  List<SourceInfo> get targets {
    final all = accounts;
    if (all.isEmpty) return const [];
    if (allTicked) return all;
    final ticked = {
      for (final part in (_targetsText ?? '').split(','))
        ?int.tryParse(part.trim()),
    };
    final chosen = [
      for (final source in all)
        if (ticked.contains(source.id)) source,
    ];
    return chosen.isEmpty ? [all.first] : chosen;
  }

  /// Ticks or unticks account [sourceId]. The last ticked account stays.
  void toggleTarget(int sourceId) {
    final now = {for (final source in targets) source.id};
    if (now.contains(sourceId)) {
      if (now.length == 1) return;
      now.remove(sourceId);
    } else {
      now.add(sourceId);
    }
    final ids = [
      for (final source in accounts)
        if (now.contains(source.id)) source.id,
    ];
    _setTargets(ids.length == accounts.length ? 'all' : ids.join(','));
  }

  /// Ticks every account, or only the first one again.
  void toggleAll() {
    if (allTicked) {
      final first = accounts.firstOrNull;
      _setTargets(first == null ? null : '${first.id}');
    } else {
      _setTargets('all');
    }
  }

  /// Makes [sourceId] the only account + adds to.
  void onlyTarget(int sourceId) => _setTargets('$sourceId');

  void _setTargets(String? text) {
    _targetsText = text;
    _writeSetting?.call(catalogTargetsSetting, text);
    notifyListeners();
  }

  /// The account that searches and streams found songs: the first target.
  SourceInfo? get _searcher => targets.firstOrNull;

  // ---- A found song's + ----

  FoundState stateOf(FoundSong found) {
    if (_adding.contains(found.key)) return FoundState.adding;
    if (_addedTo.containsKey(found.key)) return FoundState.inLibrary;
    return _listedOf(found) == null ? FoundState.addable : FoundState.inLibrary;
  }

  /// The accounts that have [found] (added in this run, or listed in the
  /// library), for the check's colours; empty for a song not in the library.
  List<int> haveSources(FoundSong found) {
    final added = _addedTo[found.key];
    if (added != null) return added;
    final listed = _listedOf(found);
    if (listed == null) return const [];
    return {for (final copy in listed.allCopies) copy.sourceId}.toList();
  }

  /// The library's song that [found] is, if the library has it.
  Track? _listedOf(FoundSong found) {
    final tracks = library.all;
    if (!identical(tracks, _matcherOf)) {
      _matcher = FoundMatcher(store.songRows());
      _matcherOf = tracks;
    }
    final id = _matcher!.listedIdOf(found.song, except: found.except);
    return id == null ? null : library.byId(id);
  }

  /// Adds [found] to the library and to each target account's VK library,
  /// one account after another. Returns what the note at the bottom says:
  /// where the song went, or why it did not.
  Future<String> add(FoundSong found) async {
    if (stateOf(found) != FoundState.addable) return 'Already in your library';
    final to = targets;
    if (to.isEmpty) return 'Log in to VK to add songs';
    final clock = Stopwatch()..start();
    final (added, refused) = await _addOne(found, to);
    if (_disposed) return '';
    _afterAdds(several: added.length > 1, any: added.isNotEmpty);
    log?.call(
      'catalog add: ${added.length} of ${to.length} accounts in '
      '${clock.elapsedMilliseconds} ms',
    );
    final names = [for (final source in added) source.name].join(' and ');
    final title = '"${found.song.title}"';
    if (refused.isEmpty) return 'Added $title to $names';
    if (added.isEmpty) return '$title not added: ${refused.join('; ')}';
    return 'Added $title to $names. Not added: ${refused.join('; ')}';
  }

  /// Adds each of [songs] that + still offers, one after another (an
  /// album's "Add the other N"): VK took 5 add rounds back to back without
  /// a captcha (A2). Returns the note: how many went where, and what failed.
  Future<String> addAll(List<FoundSong> songs) async {
    final to = targets;
    if (to.isEmpty) return 'Log in to VK to add songs';
    final waiting = [
      for (final found in songs)
        if (stateOf(found) == FoundState.addable) found,
    ];
    if (waiting.isEmpty) return 'Already in your library';
    // All of them show as being added at once, then turn one by one.
    _adding.addAll([for (final found in waiting) found.key]);
    notifyListeners();
    final clock = Stopwatch()..start();
    var addedSongs = 0;
    var several = false;
    final failed = <String>[];
    for (final found in waiting) {
      if (_disposed) return '';
      final (added, refused) = await _addOne(found, to);
      if (added.isNotEmpty) addedSongs++;
      if (added.length > 1) several = true;
      if (refused.isNotEmpty) {
        failed.add('"${found.song.title}" (${refused.join('; ')})');
      }
      if (!_disposed) notifyListeners();
    }
    if (_disposed) return '';
    _afterAdds(several: several, any: addedSongs > 0);
    log?.call(
      'catalog add all: $addedSongs of ${waiting.length} songs to '
      '${to.length} accounts in ${clock.elapsedMilliseconds} ms',
    );
    final names = [for (final source in to) source.name].join(' and ');
    final count = addedSongs == 1 ? '1 song' : '$addedSongs songs';
    if (failed.isEmpty) return 'Added $count to $names';
    if (addedSongs == 0) return 'Nothing added: ${failed.join('; ')}';
    return 'Added $count to $names. Not added: ${failed.join('; ')}';
  }

  /// Adds [found] to each account of [to] and puts the account's copy into
  /// the library. Returns the accounts that took it and why the others did
  /// not. Does not reload the lists ([_afterAdds] does).
  Future<(List<SourceInfo>, List<String>)> _addOne(
    FoundSong found,
    List<SourceInfo> to,
  ) async {
    _adding.add(found.key);
    notifyListeners();
    final added = <SourceInfo>[];
    final refused = <String>[];
    try {
      for (final source in to) {
        final call = apiOfSource(source.id);
        if (call == null) {
          refused.add('${source.name}: not logged in');
          continue;
        }
        try {
          final result = await addVkSong(
            call,
            found.key,
            accessKey: found.song.accessKey,
          );
          final newKey = result.newKey;
          if (newKey == null) {
            refused.add(
              '${source.name}: '
              '${result.noAccess ? 'VK gives no access to this song' : result.errorText ?? 'VK refused'}',
            );
            continue;
          }
          store.upsertAll(source.id, [
            found.song.asAddedCopy(
              newKey,
              addedAt: DateTime.now().millisecondsSinceEpoch ~/ 1000,
            ),
          ]);
          added.add(source);
        } catch (error) {
          refused.add('${source.name}: ${searchFailure(error)}');
        }
      }
    } finally {
      _adding.remove(found.key);
    }
    if (added.isNotEmpty) {
      _addedTo[found.key] = [for (final source in added) source.id];
      _justAdded.add(found.track.id);
    }
    return (added, refused);
  }

  /// Reloads the lists [reloadAfter] after the last add, when any song went
  /// in.
  void _afterAdds({required bool several, required bool any}) {
    if (any) {
      _reload?.cancel();
      _reload = Timer(reloadAfter, () {
        if (_disposed) return;
        onLibraryChanged(severalAccounts: several);
        final copies = <int, Track>{
          for (final id in _justAdded) id: ?libraryCopyOf(id),
        };
        _justAdded.clear();
        onAdded?.call(copies);
      });
    }
    notifyListeners();
  }

  // ---- Asking VK ----

  /// Shows the next page of VK's answer.
  void showMore() {
    final answer = _answer;
    if (answer == null || answer.loading || !answer.hasMore) return;
    unawaited(_ask(answer));
  }

  /// Asks again after a failure.
  void retry() {
    final answer = _answer;
    if (answer == null || answer.loading) return;
    answer.error = null;
    unawaited(_ask(answer));
  }

  void _onSourcesChanged() {
    _onLibraryChanged();
    notifyListeners();
  }

  /// The search text or the view changed (or the library: nothing to do).
  void _onLibraryChanged() {
    final words = library.searchText.text.trim();
    final wanted =
        library.view.kind == ViewKind.songs &&
            words.length >= catalogMinQueryLength &&
            accounts.isNotEmpty
        ? words
        : null;
    if (wanted == _query) return;
    _showQuery(wanted);
    notifyListeners();
  }

  void _showQuery(String? wanted) {
    _query = wanted;
    _wait?.cancel();
    if (wanted == null) {
      _answer = null;
      return;
    }
    final kept = _answers[wanted];
    if (kept != null && kept.error == null) {
      _answer = kept;
      return;
    }
    _answer = _Answer(wanted)..loading = true;
    _wait = Timer(pause, () {
      final answer = _answer;
      if (answer == null || answer.query != wanted || _disposed) return;
      _answers.remove(wanted);
      _answers[wanted] = answer;
      while (_answers.length > _answersKept) {
        _answers.remove(_answers.keys.first);
      }
      unawaited(_ask(answer));
    });
  }

  /// Asks VK for [answer]'s next page. A hedged copy of the request goes out
  /// only after 6 s: searches come often, and many at once make VK ask for
  /// a captcha (Stage M findings).
  Future<void> _ask(_Answer answer) async {
    final source = _searcher;
    final call = source == null ? null : apiOfSource(source.id);
    if (source == null || call == null) {
      answer
        ..loading = false
        ..error = VkException('log in to VK to search it');
      notifyListeners();
      return;
    }
    answer.loading = true;
    notifyListeners();
    final clock = Stopwatch()..start();
    try {
      final page = await hedgedVkRequest(
        () => searchVkSongs(call, answer.query, offset: answer.nextOffset),
        attempts: 2,
        after: const Duration(seconds: 6),
      );
      var added = 0;
      for (final song in page.songs) {
        if (!answer.keys.add(song.sourceKey)) continue;
        answer.songs.add(_found(song, source.id));
        added++;
      }
      // The total grows from page to page (C1): the latest one counts, and
      // never less than what is shown.
      answer
        ..total = page.total < answer.songs.length
            ? answer.songs.length
            : page.total
        ..nextOffset = page.nextOffset;
      // A page with nothing new ends the list, or Show more would ask
      // forever.
      if (added == 0) answer.total = answer.songs.length;
      log?.call(
        'catalog search: page ${page.nextOffset ~/ vkSearchPageSize} '
        '${page.songs.length} songs of ${page.total} in '
        '${clock.elapsedMilliseconds} ms',
      );
    } catch (error) {
      answer.error = error;
      log?.call(
        'catalog search failed after ${clock.elapsedMilliseconds} ms: '
        '${searchFailure(error)}',
      );
    } finally {
      answer.loading = false;
    }
    if (!_disposed) notifyListeners();
  }

  FoundSong _found(NewTrack song, int sourceId) {
    final id = _ids.putIfAbsent(
      '$sourceId:${song.sourceKey}',
      () => _firstFoundId - _ids.length,
    );
    final found = FoundSong(
      song: song,
      track: Track(
        id: id,
        sourceId: sourceId,
        source: TrackSource.vk,
        artist: song.artist,
        title: song.title,
        album: song.album,
        durationSec: song.durationSec,
        sourceKey: song.sourceKey,
        accessKey: song.accessKey,
        coverUrl: song.coverUrl,
        coverLargeUrl: song.coverLargeUrl,
        coverMidUrl: song.coverMidUrl,
        coverFullUrl: song.coverFullUrl,
        tint: song.tint,
      ),
    );
    _byId[id] = found;
    return found;
  }

  @override
  void dispose() {
    _disposed = true;
    _wait?.cancel();
    _reload?.cancel();
    library.removeListener(_onLibraryChanged);
    _sources.removeListener(_onSourcesChanged);
    super.dispose();
  }
}

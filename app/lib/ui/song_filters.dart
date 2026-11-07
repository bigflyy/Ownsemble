import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../library/day_range.dart';
import '../library/play_period.dart';
import '../library/play_stats.dart';
import '../library/song_filter.dart';
import '../library/track.dart';

/// What the song list is sorted by. [library] is the library's own order,
/// newest added first.
enum SongSort {
  library,
  title,
  album,
  plays,
  listened,
  lastPlayed,
  added,
  length,
}

/// A filter the user saved, in the sidebar under Views.
class SavedView {
  const SavedView({
    required this.id,
    required this.name,
    required this.filter,
    required this.period,
    this.sort = SongSort.library,
    this.descending = true,
  });

  final int id;
  final String name;
  final SongFilter filter;

  /// Fixed dates, or the current week, month or year, which move with time
  /// (see [PlayPeriod.fixedAt]).
  final PlayPeriod period;
  final SongSort sort;
  final bool descending;

  SavedView renamed(String name) => SavedView(
    id: id,
    name: name,
    filter: filter,
    period: period,
    sort: sort,
    descending: descending,
  );

  Object toJson() => {
    'id': id,
    'name': name,
    'filter': filter.toJson(),
    'period': period.toJson(),
    'sort': sort.name,
    'desc': descending,
  };

  static SavedView? fromJson(Object? json) {
    if (json is! Map || json['id'] is! int || json['name'] is! String) {
      return null;
    }
    return SavedView(
      id: json['id'] as int,
      name: json['name'] as String,
      filter: SongFilter.fromJson(json['filter']),
      period: PlayPeriod.fromJson(json['period']) ?? const PlayPeriod.all(),
      sort: SongSort.values.asNameMap()[json['sort']] ?? SongSort.library,
      descending: json['desc'] != false,
    );
  }
}

/// The song list's filter chips, period, sort and saved views, with the
/// play numbers they need (plan 04, C2).
///
/// Play numbers are read when the period or a chip's own dates change, and
/// for one song when its play begins or ends ([playsChanged]); a keystroke
/// in the search box never reads them, so search stays fast. The order of
/// the list follows new plays only when something here changes, so rows do
/// not move under the pointer while a song ends.
class SongFilters extends ChangeNotifier {
  SongFilters(
    this._source, {
    String? Function(String key)? readSetting,
    this._writeSetting,
    DateTime Function()? clock,
    bool Function(Track track)? isOffline,
  }) : _clock = clock ?? DateTime.now,
       isOffline = isOffline ?? ((track) => track.isCached) {
    _views = _readViews(readSetting?.call(viewsSetting));
    _readState(readSetting?.call(stateSetting));
  }

  /// Setting with the chips, period and sort shown when the app closed.
  static const stateSetting = 'ui.filters';

  /// Setting with the saved views.
  static const viewsSetting = 'library.views';

  final PlayStatsSource _source;
  final void Function(String key, String? value)? _writeSetting;
  final DateTime Function() _clock;

  /// Whether a song plays without the network (downloaded or cached).
  bool Function(Track track) isOffline;

  SongFilter _filter = const SongFilter();
  PlayPeriod _period = const PlayPeriod.month();
  SongSort _sort = SongSort.library;
  bool _descending = true;
  List<SavedView> _views = const [];
  int? _viewId;

  Map<int, SongPlays>? _allTime;
  Map<int, SongPlays> _inPeriod = const {};
  DayRange? _loadedRange;
  bool _periodLoaded = false;
  final _own = <PlayPeriod, Map<int, SongPlays>>{};

  /// Bumped whenever what [apply] returns may change.
  int get generation => _generation;
  int _generation = 0;

  DateTime get now => _clock();
  SongFilter get filter => _filter;
  PlayPeriod get period => _period;
  SongSort get sort => _sort;
  bool get descending => _descending;
  List<SavedView> get views => _views;

  /// The saved view shown, until a chip, the period or the sort changes.
  SavedView? get view => _views.where((v) => v.id == _viewId).firstOrNull;

  /// Whether play numbers are read (see [load]).
  bool get loaded => _allTime != null;

  /// Whether [apply] changes the library's list.
  bool get active => !_filter.isEmpty || _sort != SongSort.library;

  /// Plays of [trackId] in the page's period; null when none (or not read).
  SongPlays? periodPlays(int trackId) => _inPeriod[trackId];

  /// Plays of [trackId] of all time.
  SongPlays? allTimePlays(int trackId) => _allTime?[trackId];

  /// Reads the play numbers, once. The list can show before: rows show no
  /// numbers yet, and a filter that needs them waits for this.
  void load() {
    if (_allTime != null) return;
    _allTime = _source.songPlays();
    _loadPeriodStats();
    _bump();
  }

  /// Reads all play numbers again (after a sync that merged songs).
  void reload() {
    _allTime = null;
    _periodLoaded = false;
    _own.clear();
    load();
  }

  /// A play of [trackId] began or ended: its numbers are read again (all
  /// of them when the song is not known).
  void playsChanged(int? trackId) {
    if (_allTime == null) return;
    if (trackId == null) return reload();
    void update(Map<int, SongPlays> map, DayRange? range) {
      final fresh = _source.songPlays(range: range, trackId: trackId);
      map.remove(trackId);
      map.addAll(fresh);
    }

    update(_allTime!, null);
    if (_periodLoaded) update(_inPeriod, _loadedRange);
    for (final MapEntry(key: period, value: map) in _own.entries) {
      update(map, period.rangeAt(now));
    }
    notifyListeners();
  }

  /// Reads the page period's numbers, and each own period's, when the
  /// period changed (or today moved it).
  void _loadPeriodStats() {
    if (_allTime == null) return;
    final range = _period.rangeAt(now);
    if (!_periodLoaded || range != _loadedRange) {
      _inPeriod = range == null
          ? _allTime!
          : Map.of(_source.songPlays(range: range));
      _loadedRange = range;
      _periodLoaded = true;
    }
    final wanted = _filter.ownPeriods.toSet();
    _own.removeWhere((period, _) => !wanted.contains(period));
    for (final period in wanted) {
      _own[period] ??= Map.of(_source.songPlays(range: period.rangeAt(now)));
    }
  }

  /// [all] filtered by the chips and in the chosen order.
  List<Track> apply(List<Track> all) {
    final facts = SongFacts(
      now: now,
      allTime: _allTime ?? const {},
      period: _inPeriod,
      own: _own,
      isOffline: isOffline,
    );
    final kept = _filter.isEmpty
        ? all
        : [
            for (final track in all)
              if (_filter.matches(track, facts)) track,
          ];
    if (_sort == SongSort.library) {
      return _descending ? kept : kept.reversed.toList();
    }
    final order = List<int>.generate(kept.length, (i) => i);
    final direction = _descending ? -1 : 1;
    // Dart's sort is not stable: the library's order breaks ties.
    void byKey<K extends Comparable<Object>>(K Function(Track) key) {
      final keys = [for (final track in kept) key(track)];
      order.sort((a, b) {
        final c = keys[a].compareTo(keys[b]) * direction;
        return c != 0 ? c : a - b;
      });
    }

    switch (_sort) {
      case SongSort.library:
        break;
      case SongSort.title:
        byKey((t) => t.title.toLowerCase());
      case SongSort.album:
        byKey((t) => (t.album ?? '').toLowerCase());
      case SongSort.plays:
        byKey((t) => _inPeriod[t.id]?.plays ?? 0);
      case SongSort.listened:
        byKey((t) => _inPeriod[t.id]?.listenedMs ?? 0);
      case SongSort.lastPlayed:
        byKey((t) => _allTime?[t.id]?.lastMs ?? 0);
      case SongSort.added:
        byKey((t) => t.addedAt);
      case SongSort.length:
        byKey((t) => t.durationSec);
    }
    return [for (final i in order) kept[i]];
  }

  // Changes.

  /// Sets the chip for [rule]'s field (removes it when it has no values).
  void setRule(FilterRule rule) => setFilter(_filter.withRule(rule));

  void removeField(FilterField field) => setFilter(_filter.without(field));

  void setFilter(SongFilter filter) {
    if (filter == _filter) return;
    _filter = filter;
    _viewId = null;
    _changed();
  }

  /// Removes every chip; the period and sort stay.
  void clear() => setFilter(const SongFilter());

  void setPeriod(PlayPeriod period) {
    if (period == _period) return;
    _period = period;
    _viewId = null;
    _changed();
  }

  /// The arrows: the period [by] steps later or earlier.
  void stepPeriod(int by) {
    if (by > 0 && !_period.canStepForward(now)) return;
    setPeriod(_period.step(by));
  }

  /// A column title was clicked: sorts by it, or turns the order around.
  /// Names sort A to Z first, numbers and dates largest first.
  void sortBy(SongSort sort) {
    if (sort == _sort) {
      _descending = !_descending;
    } else {
      _sort = sort;
      _descending = sort != SongSort.title && sort != SongSort.album;
    }
    _viewId = null;
    _changed();
  }

  /// All songs: no chips, the library's order, no saved view. The period
  /// stays.
  void showAllSongs() {
    _filter = const SongFilter();
    _sort = SongSort.library;
    _descending = true;
    _viewId = null;
    _changed();
  }

  /// Sorts by [sort] in the given direction (a saved state put back).
  void setSort(SongSort sort, {bool descending = true}) {
    if (sort == _sort && descending == _descending) return;
    _sort = sort;
    _descending = descending;
    _viewId = null;
    _changed();
  }

  /// Back to the library's order.
  void resetSort() {
    if (_sort == SongSort.library && _descending) return;
    _sort = SongSort.library;
    _descending = true;
    _viewId = null;
    _changed();
  }

  // Saved views.

  /// The name a new view gets: the period, then the chips.
  String suggestedName() => autoViewName(_filter, _period, now);

  /// Saves what is shown as a view named [name]; returns its id.
  int saveView(String name) {
    final id = _views.fold(0, (top, v) => v.id > top ? v.id : top) + 1;
    final saved = SavedView(
      id: id,
      name: name.trim().isEmpty ? suggestedName() : name.trim(),
      filter: _filter,
      period: _period.fixedAt(now),
      sort: _sort,
      descending: _descending,
    );
    _views = [..._views, saved];
    _period = saved.period;
    _viewId = id;
    _writeViews();
    _changed();
    return id;
  }

  void renameView(int id, String name) {
    if (name.trim().isEmpty) return;
    _views = [for (final v in _views) v.id == id ? v.renamed(name.trim()) : v];
    _writeViews();
    notifyListeners();
  }

  void deleteView(int id) {
    _views = [
      for (final v in _views)
        if (v.id != id) v,
    ];
    if (_viewId == id) _viewId = null;
    _writeViews();
    _changed();
  }

  /// Shows saved view [id]: its chips, period and sort.
  void openView(int id) {
    final saved = _views.where((v) => v.id == id).firstOrNull;
    if (saved == null) return;
    _filter = saved.filter;
    _period = saved.period;
    _sort = saved.sort;
    _descending = saved.descending;
    _viewId = id;
    _changed();
  }

  /// Leaves the saved view, keeping what it shows.
  void leaveView() {
    if (_viewId == null) return;
    _viewId = null;
    _writeState();
    notifyListeners();
  }

  /// Monthly or daily listening for the Custom picker's tiles.
  List<int> listenedIn(List<DayRange> ranges) => _source.listenedIn(ranges);

  void _changed() {
    _loadPeriodStats();
    _writeState();
    _bump();
  }

  void _bump() {
    _generation++;
    notifyListeners();
  }

  void _writeState() => _writeSetting?.call(
    stateSetting,
    jsonEncode({
      'filter': _filter.toJson(),
      'period': _period.toJson(),
      'sort': _sort.name,
      'desc': _descending,
      'view': ?_viewId,
    }),
  );

  void _readState(String? text) {
    if (text == null) return;
    try {
      final json = jsonDecode(text);
      if (json is! Map) return;
      _filter = SongFilter.fromJson(json['filter']);
      _period = PlayPeriod.fromJson(json['period']) ?? _period;
      _sort = SongSort.values.asNameMap()[json['sort']] ?? SongSort.library;
      _descending = json['desc'] != false;
      final id = json['view'];
      _viewId = _views.any((v) => v.id == id) ? id as int : null;
    } on FormatException {
      return;
    }
  }

  void _writeViews() => _writeSetting?.call(
    viewsSetting,
    jsonEncode([for (final v in _views) v.toJson()]),
  );

  static List<SavedView> _readViews(String? text) {
    if (text == null) return const [];
    try {
      final json = jsonDecode(text);
      if (json is! List) return const [];
      return [for (final item in json) ?SavedView.fromJson(item)];
    } on FormatException {
      return const [];
    }
  }
}

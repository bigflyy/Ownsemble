import 'play_period.dart';
import 'play_stats.dart';
import 'track.dart';

/// What a filter chip asks about (plan 04, C2). The first four are always
/// in the chip row; the rest come from "+ Filter" when used.
enum FilterField {
  artist,
  added,
  plays,
  lastPlayed,
  never,
  offline,
  length,
  cover,
  skipped,
}

/// How a chip's values are chosen.
enum FieldShape {
  /// Several values; any of them matches (OR).
  many,

  /// One value from a list.
  one,

  /// On or off: its one value is "yes".
  toggle,
}

/// One value a chip can take, with the words for it.
typedef FieldOption = ({String value, String label, String short});

/// What the chip row and the Filters panel show for each [FilterField].
class FieldInfo {
  const FieldInfo(
    this.label,
    this.shape, {
    this.options = const [],
    this.pinned = false,
    this.about = '',
    this.notLabel = '',
  });

  final String label;
  final FieldShape shape;

  /// Fixed choices; Artist's come from the library.
  final List<FieldOption> options;

  /// Always shown as a chip, used or not.
  final bool pinned;

  /// One line under the name in the "+ Filter" menu.
  final String about;

  /// A toggle's label when negated ("Not offline").
  final String notLabel;

  /// [value]'s option, if it is one of [options].
  FieldOption? option(String value) =>
      options.where((o) => o.value == value).firstOrNull;
}

const fieldInfo = <FilterField, FieldInfo>{
  FilterField.artist: FieldInfo('Artist', FieldShape.many, pinned: true),
  FilterField.added: FieldInfo(
    'Added',
    FieldShape.one,
    pinned: true,
    options: [
      (value: '7d', label: 'In the last 7 days', short: 'added this week'),
      (value: '30d', label: 'In the last 30 days', short: 'added this month'),
      (value: 'year', label: 'This year', short: 'added this year'),
      (value: 'old', label: 'Over a year ago', short: 'added over a year ago'),
    ],
  ),
  FilterField.plays: FieldInfo(
    'Plays',
    FieldShape.one,
    pinned: true,
    options: [
      (value: '0', label: 'Not played', short: 'not played'),
      (value: '1', label: '1 or more', short: 'played'),
      (value: '5', label: '5 or more', short: '5+ plays'),
      (value: '20', label: '20 or more', short: '20+ plays'),
    ],
  ),
  FilterField.lastPlayed: FieldInfo(
    'Last played',
    FieldShape.one,
    pinned: true,
    options: [
      (value: 'today', label: 'Today', short: 'played today'),
      (value: '7d', label: 'In the last 7 days', short: 'played this week'),
      (
        value: 'month+',
        label: 'Over a month ago',
        short: 'not played for a month',
      ),
      (
        value: 'half+',
        label: 'Over 6 months ago',
        short: 'not played for 6 months',
      ),
    ],
  ),
  FilterField.never: FieldInfo(
    'Never played',
    FieldShape.toggle,
    about: 'Songs with no play at all',
    notLabel: 'Played before',
  ),
  FilterField.offline: FieldInfo(
    'Offline',
    FieldShape.toggle,
    about: 'Downloaded or cached, plays without internet',
    notLabel: 'Not offline',
  ),
  FilterField.length: FieldInfo(
    'Length',
    FieldShape.many,
    about: 'Short or long songs',
    options: [
      (value: 'short', label: 'Under 3:30', short: 'under 3:30'),
      (value: 'mid', label: '3:30 to 4:30', short: '3:30 to 4:30'),
      (value: 'long', label: 'Over 4:30', short: 'over 4:30'),
    ],
  ),
  FilterField.cover: FieldInfo(
    'Has a cover',
    FieldShape.toggle,
    about: 'Songs with or without a cover',
    notLabel: 'No cover',
  ),
  FilterField.skipped: FieldInfo(
    'Often skipped',
    FieldShape.toggle,
    about: 'You skip it early most times',
    notLabel: 'Not often skipped',
  ),
};

/// What matching a song needs besides the song: its play numbers and
/// whether it plays offline.
class SongFacts {
  SongFacts({
    required this.now,
    required this.allTime,
    required this.period,
    required this.isOffline,
    this.own = const {},
  });

  final DateTime now;

  /// Plays of all time, by song id (last played, never played, skips).
  final Map<int, SongPlays> allTime;

  /// Plays in the page's period, by song id.
  final Map<int, SongPlays> period;

  /// Plays in each Plays chip's own dates.
  final Map<PlayPeriod, Map<int, SongPlays>> own;

  final bool Function(Track track) isOffline;

  // Where the date chips cut, Unix ms, each worked out once: a local
  // DateTime per song made a chip over 10,000 songs take 0.2 s.
  late final int _todayMs = _dayMs(0);
  late final int _weekMs = _dayMs(-6);
  late final int _thirtyDaysMs = _dayMs(-29);
  late final int _yearStartMs = DateTime(now.year).millisecondsSinceEpoch;
  late final int _yearAgoMs = DateTime(
    now.year - 1,
    now.month,
    now.day,
  ).millisecondsSinceEpoch;
  late final int _monthAgoMs = DateTime(
    now.year,
    now.month - 1,
    now.day,
  ).millisecondsSinceEpoch;
  late final int _halfYearAgoMs = DateTime(
    now.year,
    now.month - 6,
    now.day,
  ).millisecondsSinceEpoch;

  int _dayMs(int days) =>
      DateTime(now.year, now.month, now.day + days).millisecondsSinceEpoch;
}

/// A node of the filter's rule tree: a rule, or a group of nodes.
sealed class FilterNode {
  const FilterNode();

  bool matches(Track track, SongFacts facts);

  Object toJson();

  /// Reads [toJson]'s form back; null when it is not one.
  static FilterNode? fromJson(Object? json) {
    if (json is! Map) return null;
    for (final (key, all) in [('all', true), ('any', false)]) {
      final children = json[key];
      if (children is! List) continue;
      return FilterGroup(all: all, [
        for (final child in children) ?FilterNode.fromJson(child),
      ]);
    }
    return FilterRule.fromJson(json);
  }
}

/// Nodes that must all match ([all]) or any of them. The chip row is one
/// group of all its chips; nested groups are kept for later (docs/IDEAS.md).
class FilterGroup extends FilterNode {
  const FilterGroup(this.children, {this.all = true});

  final List<FilterNode> children;
  final bool all;

  @override
  bool matches(Track track, SongFacts facts) => all
      ? children.every((c) => c.matches(track, facts))
      : children.isEmpty || children.any((c) => c.matches(track, facts));

  @override
  Object toJson() => {
    all ? 'all' : 'any': [for (final child in children) child.toJson()],
  };

  @override
  bool operator ==(Object other) =>
      other is FilterGroup &&
      other.all == all &&
      _listEquals(other.children, children);

  @override
  int get hashCode => Object.hash(all, Object.hashAll(children));
}

/// One chip: [field] is any of [values] (or none of them, [negate]). A
/// Plays chip may count in its own [period] instead of the page's.
class FilterRule extends FilterNode {
  const FilterRule(
    this.field, {
    required this.values,
    this.negate = false,
    this.period,
  });

  final FilterField field;
  final Set<String> values;
  final bool negate;
  final PlayPeriod? period;

  FilterRule copyWith({
    Set<String>? values,
    bool? negate,
    PlayPeriod? Function()? period,
  }) => FilterRule(
    field,
    values: values ?? this.values,
    negate: negate ?? this.negate,
    period: period == null ? this.period : period(),
  );

  @override
  bool matches(Track track, SongFacts facts) {
    if (values.isEmpty) return true;
    final hit = values.any((value) => _matchesValue(track, facts, value));
    return negate ? !hit : hit;
  }

  bool _matchesValue(Track track, SongFacts facts, String value) {
    switch (field) {
      case FilterField.artist:
        return track.artist == value;
      case FilterField.added:
        final added = track.addedAt * 1000;
        return switch (value) {
          '7d' => added >= facts._weekMs,
          '30d' => added >= facts._thirtyDaysMs,
          'year' => added >= facts._yearStartMs,
          'old' => added < facts._yearAgoMs,
          _ => false,
        };
      case FilterField.plays:
        final source = period == null ? facts.period : facts.own[period];
        final count = source?[track.id]?.plays ?? 0;
        final atLeast = int.tryParse(value);
        if (atLeast == null) return false;
        return atLeast == 0 ? count == 0 : count >= atLeast;
      case FilterField.lastPlayed:
        final lastMs = facts.allTime[track.id]?.lastMs;
        if (lastMs == null) return false;
        return switch (value) {
          'today' => lastMs >= facts._todayMs,
          '7d' => lastMs >= facts._weekMs,
          'month+' => lastMs < facts._monthAgoMs,
          'half+' => lastMs < facts._halfYearAgoMs,
          _ => false,
        };
      case FilterField.never:
        return (facts.allTime[track.id]?.plays ?? 0) == 0;
      case FilterField.offline:
        return facts.isOffline(track);
      case FilterField.length:
        final sec = track.durationSec;
        return switch (value) {
          'short' => sec < 210,
          'mid' => sec >= 210 && sec <= 270,
          'long' => sec > 270,
          _ => false,
        };
      case FilterField.cover:
        return track.hasCover;
      case FilterField.skipped:
        return facts.allTime[track.id]?.oftenSkipped ?? false;
    }
  }

  /// What the chip says: "Artist: Кино, Сплин", "Artist is not: Кино",
  /// "Plays in 2025: 5 or more", "Not offline". [pageLabel] names the
  /// page's period for a Plays chip without its own dates.
  String chipText(DateTime now, {required String pageLabel}) {
    final info = fieldInfo[field]!;
    if (info.shape == FieldShape.toggle) {
      return negate ? info.notLabel : info.label;
    }
    final name = field == FilterField.plays
        ? 'Plays in ${period?.label(now) ?? pageLabel}'
        : info.label;
    final shown = _valueLabels(info, long: true);
    return '$name${negate ? ' is not' : ''}: $shown';
  }

  /// The chip's part of a saved view's automatic name: "Кино", "not Кино
  /// +2", "5+ plays in 2025", "offline".
  String namePart(DateTime now) {
    final info = fieldInfo[field]!;
    if (info.shape == FieldShape.toggle) {
      final words = negate ? info.notLabel : info.label;
      return words[0].toLowerCase() + words.substring(1);
    }
    final shown = _valueLabels(info, long: false);
    final own = field == FilterField.plays && period != null
        ? ' in ${period!.label(now)}'
        : '';
    return '${negate ? 'not ' : ''}$shown$own';
  }

  String _valueLabels(FieldInfo info, {required bool long}) {
    final words = [
      for (final value in values)
        switch (info.option(value)) {
          final option? => long ? option.label : option.short,
          null => value,
        },
    ];
    if (long || words.length <= 2) return words.join(', ');
    return '${words.first} +${words.length - 1}';
  }

  @override
  Object toJson() => {
    'f': field.name,
    'v': values.toList(),
    if (negate) 'not': true,
    if (period case final own?) 'period': own.toJson(),
  };

  static FilterRule? fromJson(Map<Object?, Object?> json) {
    final field = FilterField.values.asNameMap()[json['f']];
    final values = json['v'];
    if (field == null || values is! List) return null;
    return FilterRule(
      field,
      values: {for (final value in values) '$value'},
      negate: json['not'] == true,
      period: PlayPeriod.fromJson(json['period']),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is FilterRule &&
      other.field == field &&
      other.negate == negate &&
      other.period == period &&
      other.values.length == values.length &&
      other.values.containsAll(values);

  @override
  int get hashCode =>
      Object.hash(field, negate, period, Object.hashAllUnordered(values));
}

/// The song list's filter: the chips, all of which must match (AND), held
/// as a rule tree so nested groups can come later without a rewrite.
class SongFilter {
  const SongFilter([this.root = const FilterGroup([])]);

  /// Reads a saved filter; anything unreadable is no filter.
  factory SongFilter.fromJson(Object? json) {
    final node = FilterNode.fromJson(json);
    return switch (node) {
      final FilterGroup group => SongFilter(group),
      final FilterRule rule => SongFilter(FilterGroup([rule])),
      null => const SongFilter(),
    };
  }

  final FilterGroup root;

  /// The chips: the top group's rules that have values.
  List<FilterRule> get rules => [
    for (final node in root.children)
      if (node is FilterRule && node.values.isNotEmpty) node,
  ];

  bool get isEmpty =>
      root.children.every((node) => node is FilterRule && node.values.isEmpty);

  FilterRule? ruleFor(FilterField field) =>
      rules.where((rule) => rule.field == field).firstOrNull;

  /// This filter with [rule] as its chip for the field (replacing one), or
  /// without that chip when [rule] has no values.
  SongFilter withRule(FilterRule rule) {
    final children = [...root.children];
    final at = children.indexWhere(
      (node) => node is FilterRule && node.field == rule.field,
    );
    if (rule.values.isEmpty) {
      if (at >= 0) children.removeAt(at);
    } else if (at >= 0) {
      children[at] = rule;
    } else {
      children.add(rule);
    }
    return SongFilter(FilterGroup(children, all: root.all));
  }

  SongFilter without(FilterField field) =>
      withRule(FilterRule(field, values: const {}));

  /// The Plays chips' own dates, each once.
  List<PlayPeriod> get ownPeriods {
    final found = <PlayPeriod>[];
    void walk(FilterNode node) {
      switch (node) {
        case FilterGroup(:final children):
          children.forEach(walk);
        case FilterRule(:final period?) when !found.contains(period):
          found.add(period);
        case FilterRule():
          break;
      }
    }

    walk(root);
    return found;
  }

  bool matches(Track track, SongFacts facts) => root.matches(track, facts);

  Object toJson() => root.toJson();

  @override
  bool operator ==(Object other) => other is SongFilter && other.root == root;

  @override
  int get hashCode => root.hashCode;
}

/// The name a new saved view gets: the period, then the chips: "November
/// 2025 - Кино, 5+ plays", "This month - 5+ plays", "Кино" (all time).
String autoViewName(SongFilter filter, PlayPeriod period, DateTime now) {
  final when = period.nameAt(now);
  final what = [for (final rule in filter.rules) rule.namePart(now)].join(', ');
  if (when == null) return what.isEmpty ? 'All songs' : what;
  return what.isEmpty ? when : '$when - $what';
}

bool _listEquals<T>(List<T> a, List<T> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

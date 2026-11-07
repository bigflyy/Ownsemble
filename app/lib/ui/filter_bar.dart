import 'package:flutter/material.dart';

import '../library/play_period.dart';
import '../library/search_text.dart';
import '../library/song_filter.dart';
import '../library/track.dart';
import 'anchored_panel.dart';
import 'period_picker.dart';
import 'shell_settings.dart';
import 'song_filters.dart';
import 'theme.dart';

/// The period above the Songs list (plan 04, B3 option 2): back and forward
/// arrows around the period's dates, and Week / Month / Year / All time /
/// Custom (one menu button in a narrow window). Custom opens the month tile
/// picker.
class PeriodControls extends StatelessWidget {
  const PeriodControls({
    super.key,
    required this.filters,
    required this.settings,
    required this.narrow,
    this.compact = false,
  });

  final SongFilters filters;
  final ShellSettings settings;
  final bool narrow;

  /// A short window: one button with the dates, whose menu has the periods
  /// and Earlier / Later, so the song list keeps its rows.
  final bool compact;

  static const _choices = [
    (PeriodKind.week, 'Week'),
    (PeriodKind.month, 'Month'),
    (PeriodKind.year, 'Year'),
    (PeriodKind.all, 'All time'),
    (PeriodKind.custom, 'Custom'),
  ];

  Future<void> _choose(BuildContext anchor, PeriodKind kind) async {
    switch (kind) {
      case PeriodKind.week:
        filters.setPeriod(const PlayPeriod.week());
      case PeriodKind.month:
        filters.setPeriod(const PlayPeriod.month());
      case PeriodKind.year:
        filters.setPeriod(const PlayPeriod.year());
      case PeriodKind.all:
        filters.setPeriod(const PlayPeriod.all());
      case PeriodKind.custom:
        final range = await pickDays(
          anchor,
          initial: filters.period.rangeAt(filters.now),
          listenedIn: filters.listenedIn,
          settings: settings,
          clock: () => filters.now,
        );
        if (range != null) filters.setPeriod(PlayPeriod.custom(range));
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = OwnColors.of(context);
    final period = filters.period;
    final arrows = period.kind != PeriodKind.all;
    if (compact) return _compactButton(period);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (arrows)
          IconButton(
            key: const ValueKey('period-back'),
            tooltip: 'Earlier',
            visualDensity: VisualDensity.compact,
            onPressed: () => filters.stepPeriod(-1),
            icon: const Icon(Icons.chevron_left),
          ),
        ConstrainedBox(
          constraints: BoxConstraints(minWidth: narrow ? 0 : 130),
          child: Text(
            period.label(filters.now),
            key: const ValueKey('period-label'),
            textAlign: TextAlign.center,
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
        ),
        if (arrows)
          IconButton(
            key: const ValueKey('period-next'),
            tooltip: 'Later',
            visualDensity: VisualDensity.compact,
            onPressed: period.canStepForward(filters.now)
                ? () => filters.stepPeriod(1)
                : null,
            icon: const Icon(Icons.chevron_right),
          ),
        const SizedBox(width: 8),
        if (narrow)
          Builder(
            builder: (anchor) => OutlinedButton.icon(
              key: const ValueKey('period-menu'),
              onPressed: () async {
                final kind = await showAnchoredPanel<PeriodKind>(
                  anchor,
                  width: 170,
                  alignRight: true,
                  builder: (context) => Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      for (final (kind, label) in _choices)
                        _OptionRow(
                          key: ValueKey('period-${kind.name}'),
                          label: label,
                          selected: period.kind == kind,
                          radio: true,
                          onTap: () => Navigator.of(context).pop(kind),
                        ),
                    ],
                  ),
                );
                if (kind != null && anchor.mounted) _choose(anchor, kind);
              },
              iconAlignment: IconAlignment.end,
              icon: const Icon(Icons.expand_more, size: 18),
              label: Text(_choices.firstWhere((c) => c.$1 == period.kind).$2),
            ),
          )
        else
          Container(
            padding: const EdgeInsets.all(3),
            decoration: BoxDecoration(
              color: colors.surface,
              border: Border.all(color: colors.line),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final (kind, label) in _choices)
                  Builder(
                    builder: (anchor) => _Segment(
                      key: ValueKey('period-${kind.name}'),
                      label: label,
                      selected: period.kind == kind,
                      onTap: () => _choose(anchor, kind),
                    ),
                  ),
              ],
            ),
          ),
      ],
    );
  }
}

extension on PeriodControls {
  Widget _compactButton(PlayPeriod period) => Builder(
    builder: (anchor) => TextButton.icon(
      key: const ValueKey('period-compact'),
      style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
      onPressed: () async {
        final pick = await showAnchoredPanel<String>(
          anchor,
          width: 200,
          builder: (context) => Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final (kind, label) in PeriodControls._choices)
                _OptionRow(
                  key: ValueKey('period-${kind.name}'),
                  label: label,
                  selected: period.kind == kind,
                  radio: true,
                  onTap: () => Navigator.of(context).pop(kind.name),
                ),
              if (period.kind != PeriodKind.all) ...[
                _OptionRow(
                  key: const ValueKey('period-back'),
                  label: 'Earlier',
                  about:
                      'The ${PeriodControls._choices.firstWhere((c) => c.$1 == period.kind).$2.toLowerCase()} before',
                  onTap: () => Navigator.of(context).pop('back'),
                ),
                if (period.canStepForward(filters.now))
                  _OptionRow(
                    key: const ValueKey('period-next'),
                    label: 'Later',
                    about: 'The one after',
                    onTap: () => Navigator.of(context).pop('next'),
                  ),
              ],
            ],
          ),
        );
        if (pick == null || !anchor.mounted) return;
        switch (pick) {
          case 'back':
            filters.stepPeriod(-1);
          case 'next':
            filters.stepPeriod(1);
          default:
            await _choose(anchor, PeriodKind.values.byName(pick));
        }
      },
      iconAlignment: IconAlignment.end,
      icon: const Icon(Icons.expand_more, size: 18),
      label: Text(
        period.label(filters.now),
        key: const ValueKey('period-label'),
        style: const TextStyle(fontWeight: FontWeight.w600),
      ),
    ),
  );
}

class _Segment extends StatelessWidget {
  const _Segment({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = OwnColors.of(context);
    return Semantics(
      button: true,
      selected: selected,
      child: Material(
        color: selected ? colors.accentBg : Colors.transparent,
        borderRadius: BorderRadius.circular(7),
        child: InkWell(
          borderRadius: BorderRadius.circular(7),
          onTap: onTap,
          child: Container(
            height: 30,
            alignment: Alignment.center,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Text(
              label,
              style: TextStyle(
                fontSize: 13,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                color: selected ? colors.accent : colors.dim,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The chips under the Songs heading (plan 04, B3: mockup A): Artist,
/// Added, Plays and Last played always, the other filters once used or
/// picked from "+ Filter"; the row wraps. Several values in one chip mean
/// any of them, different chips must all match. Then Clear all, the source
/// chips and Save as view. In a narrow window the chips fold into one
/// Filters button with a panel.
class FilterBar extends StatefulWidget {
  const FilterBar({
    super.key,
    required this.filters,
    required this.songs,
    required this.settings,
    required this.narrow,
    this.sources,
    this.period,
  });

  /// The period controls, first in the row (a narrow window).
  final Widget? period;

  final SongFilters filters;

  /// The library's songs, for the Artist chip's choices.
  final List<Track> songs;
  final ShellSettings settings;
  final bool narrow;

  /// The source chips, at the end of the row.
  final Widget? sources;

  @override
  State<FilterBar> createState() => _FilterBarState();
}

class _FilterBarState extends State<FilterBar> {
  /// Chips picked from "+ Filter" that have no values yet.
  final _added = <FilterField>{};
  final _chipKeys = {for (final f in FilterField.values) f: GlobalKey()};

  SongFilters get filters => widget.filters;

  List<FilterField> get _shown => [
    for (final field in FilterField.values)
      if (fieldInfo[field]!.pinned ||
          filters.filter.ruleFor(field) != null ||
          _added.contains(field))
        field,
  ];

  Future<void> _openRule(BuildContext anchor, FilterField field) async {
    await showAnchoredPanel<void>(
      anchor,
      width: field == FilterField.artist ? 320 : 280,
      builder: (context) => RuleMenu(
        filters: filters,
        field: field,
        songs: widget.songs,
        settings: widget.settings,
      ),
    );
    if (!mounted) return;
    setState(
      () => _added.removeWhere((f) => filters.filter.ruleFor(f) == null),
    );
  }

  Future<void> _openMore(BuildContext anchor) async {
    final shown = _shown;
    final field = await showAnchoredPanel<FilterField>(
      anchor,
      width: 300,
      builder: (context) => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const _MenuTitle('More filters'),
          for (final field in FilterField.values)
            if (!shown.contains(field))
              _OptionRow(
                key: ValueKey('more-${field.name}'),
                label: fieldInfo[field]!.label,
                about: fieldInfo[field]!.about,
                onTap: () => Navigator.of(context).pop(field),
              ),
          if (shown.length == FilterField.values.length)
            const Padding(
              padding: EdgeInsets.fromLTRB(14, 4, 14, 12),
              child: Text('All filters are in the row already.'),
            ),
          const SizedBox(height: 6),
        ],
      ),
    );
    if (field == null || !mounted) return;
    if (fieldInfo[field]!.shape == FieldShape.toggle) {
      filters.setRule(FilterRule(field, values: const {'yes'}));
      return;
    }
    setState(() => _added.add(field));
    // The new chip opens its menu once it is on screen.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final chip = _chipKeys[field]!.currentContext;
      if (chip != null && chip.mounted) _openRule(chip, field);
    });
  }

  Future<void> _openPanel(BuildContext anchor) => showAnchoredPanel<void>(
    anchor,
    width: 380,
    builder: (context) => FiltersPanel(
      filters: filters,
      songs: widget.songs,
      settings: widget.settings,
    ),
  );

  @override
  Widget build(BuildContext context) {
    final colors = OwnColors.of(context);
    final filter = filters.filter;
    final pageLabel = filters.period.label(filters.now);
    final canSave =
        filters.view == null &&
        (!filter.isEmpty || filters.sort != SongSort.library);
    return Wrap(
      key: const ValueKey('filter-bar'),
      spacing: 8,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        ?widget.period,
        if (widget.narrow)
          Builder(
            builder: (anchor) => _ChipShape(
              key: const ValueKey('filters-button'),
              active: filter.rules.isNotEmpty,
              icon: Icons.filter_alt_outlined,
              text: filter.rules.isEmpty
                  ? 'Filters'
                  : 'Filters (${filter.rules.length})',
              onTap: () => _openPanel(anchor),
            ),
          )
        else ...[
          for (final field in _shown)
            Builder(
              key: _chipKeys[field],
              builder: (anchor) {
                final rule = filter.ruleFor(field);
                final info = fieldInfo[field]!;
                return _ChipShape(
                  key: ValueKey('chip-${field.name}'),
                  active: rule != null,
                  dashed: rule?.period != null,
                  icon: rule == null && info.pinned ? Icons.add : null,
                  text:
                      rule?.chipText(filters.now, pageLabel: pageLabel) ??
                      info.label,
                  menu: true,
                  onTap: () => _openRule(anchor, field),
                  onClear: rule != null || !info.pinned
                      ? () => setState(() {
                          _added.remove(field);
                          filters.removeField(field);
                        })
                      : null,
                  clearLabel: 'Remove the ${info.label} filter',
                );
              },
            ),
          Builder(
            builder: (anchor) => _ChipShape(
              key: const ValueKey('add-filter'),
              icon: Icons.add,
              text: 'Filter',
              onTap: () => _openMore(anchor),
            ),
          ),
        ],
        // A narrow window has these in the Filters panel.
        if (filter.rules.isNotEmpty && !widget.narrow)
          TextButton(
            key: const ValueKey('clear-filters'),
            onPressed: () => setState(() {
              _added.clear();
              filters.clear();
            }),
            child: const Text('Clear all'),
          ),
        ?widget.sources,
        if (canSave && !widget.narrow)
          OutlinedButton.icon(
            key: const ValueKey('save-view'),
            onPressed: () async {
              final name = await askViewName(
                context,
                title: 'Save as view',
                initial: filters.suggestedName(),
                action: 'Save',
              );
              if (name != null) filters.saveView(name);
            },
            icon: Icon(Icons.bookmark_add_outlined, color: colors.accent),
            label: const Text('Save as view'),
          ),
      ],
    );
  }
}

/// The narrow window's Filters panel: each filter on its own line with what
/// it is set to; a line opens that filter's menu.
class FiltersPanel extends StatelessWidget {
  const FiltersPanel({
    super.key,
    required this.filters,
    required this.songs,
    required this.settings,
  });

  final SongFilters filters;
  final List<Track> songs;
  final ShellSettings settings;

  @override
  Widget build(BuildContext context) {
    final colors = OwnColors.of(context);
    return ListenableBuilder(
      listenable: filters,
      builder: (context, _) {
        final pageLabel = filters.period.label(filters.now);
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const _MenuTitle('Filters'),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final field in FilterField.values)
                    Builder(
                      builder: (anchor) {
                        final rule = filters.filter.ruleFor(field);
                        return ListTile(
                          key: ValueKey('panel-${field.name}'),
                          dense: true,
                          title: Text(fieldInfo[field]!.label),
                          subtitle: Text(
                            rule?.chipText(filters.now, pageLabel: pageLabel) ??
                                'Any',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: rule == null ? colors.dim2 : colors.accent,
                            ),
                          ),
                          trailing: rule == null
                              ? const Icon(Icons.chevron_right)
                              : IconButton(
                                  tooltip: 'Remove',
                                  onPressed: () => filters.removeField(field),
                                  icon: const Icon(Icons.close, size: 18),
                                ),
                          onTap: () => showAnchoredPanel<void>(
                            anchor,
                            width: 300,
                            builder: (context) => RuleMenu(
                              filters: filters,
                              field: field,
                              songs: songs,
                              settings: settings,
                            ),
                          ),
                        );
                      },
                    ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 4, 12, 10),
              child: Wrap(
                spacing: 8,
                runSpacing: 6,
                alignment: WrapAlignment.end,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  TextButton(
                    onPressed: filters.clear,
                    child: const Text('Clear all'),
                  ),
                  if (filters.view == null &&
                      (!filters.filter.isEmpty ||
                          filters.sort != SongSort.library)) ...[
                    OutlinedButton(
                      key: const ValueKey('panel-save-view'),
                      onPressed: () async {
                        final name = await askViewName(
                          context,
                          title: 'Save as view',
                          initial: filters.suggestedName(),
                          action: 'Save',
                        );
                        if (name != null) filters.saveView(name);
                      },
                      child: const Text('Save as view'),
                    ),
                  ],
                  FilledButton(
                    key: const ValueKey('filters-done'),
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('Done'),
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

/// One filter's menu: "is / is not", its values (ticks for several, one
/// choice otherwise; Artist has a search box), and for Plays the dates it
/// counts in. Each change applies at once.
class RuleMenu extends StatefulWidget {
  const RuleMenu({
    super.key,
    required this.filters,
    required this.field,
    required this.songs,
    required this.settings,
  });

  final SongFilters filters;
  final FilterField field;
  final List<Track> songs;
  final ShellSettings settings;

  @override
  State<RuleMenu> createState() => _RuleMenuState();
}

class _RuleMenuState extends State<RuleMenu> {
  late bool _negate;
  PlayPeriod? _own;
  final _search = TextEditingController();
  late final List<({String name, int songs})> _artists;

  FieldInfo get _info => fieldInfo[widget.field]!;
  FilterRule? get _rule => widget.filters.filter.ruleFor(widget.field);

  @override
  void initState() {
    super.initState();
    _negate = _rule?.negate ?? false;
    _own = _rule?.period;
    if (widget.field == FilterField.artist) {
      final counts = <String, int>{};
      for (final track in widget.songs) {
        counts[track.artist] = (counts[track.artist] ?? 0) + 1;
      }
      _artists = [
        for (final MapEntry(:key, :value) in counts.entries)
          (name: key, songs: value),
      ]..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    } else {
      _artists = const [];
    }
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  void _write(Set<String> values) => widget.filters.setRule(
    FilterRule(widget.field, values: values, negate: _negate, period: _own),
  );

  void _toggleValue(String value) {
    final values = {...?_rule?.values};
    if (_info.shape == FieldShape.many) {
      values.contains(value) ? values.remove(value) : values.add(value);
    } else if (values.contains(value)) {
      values.clear();
    } else {
      values
        ..clear()
        ..add(value);
    }
    setState(() => _write(values));
  }

  void _setNegate(bool negate) {
    setState(() {
      _negate = negate;
      if (_rule != null) _write(_rule!.values);
    });
  }

  Future<void> _pickOwn(BuildContext anchor) async {
    final range = await pickDays(
      anchor,
      initial: (_own ?? widget.filters.period).rangeAt(widget.filters.now),
      listenedIn: widget.filters.listenedIn,
      settings: widget.settings,
      clock: () => widget.filters.now,
      alignRight: false,
    );
    if (range == null || !mounted) return;
    setState(() {
      _own = PlayPeriod.custom(range);
      if (_rule != null) _write(_rule!.values);
    });
  }

  void _samePeriod() => setState(() {
    _own = null;
    if (_rule != null) _write(_rule!.values);
  });

  @override
  Widget build(BuildContext context) {
    final colors = OwnColors.of(context);
    final values = _rule?.values ?? const <String>{};
    if (_info.shape == FieldShape.toggle) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _MenuTitle(_info.about),
          for (final negate in [false, true])
            _OptionRow(
              key: ValueKey('toggle-${negate ? 'not' : 'is'}'),
              label: negate ? _info.notLabel : _info.label,
              radio: true,
              selected: _rule != null && _rule!.negate == negate,
              onTap: () => setState(() {
                _negate = negate;
                _write(const {'yes'});
              }),
            ),
          const SizedBox(height: 6),
        ],
      );
    }
    final query = searchWords(_search.text);
    final options = widget.field == FilterField.artist
        ? [
            for (final artist in _artists)
              if (query.isEmpty ||
                  matchesAllWords(normalizeForSearch(artist.name), query))
                (
                  value: artist.name,
                  label: artist.name,
                  short: '${artist.songs}',
                ),
          ]
        : _info.options;
    // Chosen artists first, so they stay in reach in a long list.
    if (widget.field == FilterField.artist) {
      options.sort(
        (a, b) => (values.contains(a.value) ? 0 : 1).compareTo(
          values.contains(b.value) ? 0 : 1,
        ),
      );
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 10, 10, 6),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  _info.label,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
              SegmentedButton<bool>(
                key: const ValueKey('rule-negate'),
                showSelectedIcon: false,
                style: const ButtonStyle(
                  visualDensity: VisualDensity.compact,
                  textStyle: WidgetStatePropertyAll(
                    TextStyle(fontSize: 12, fontFamily: appFontFamily),
                  ),
                ),
                segments: const [
                  ButtonSegment(value: false, label: Text('is')),
                  ButtonSegment(value: true, label: Text('is not')),
                ],
                selected: {_negate},
                onSelectionChanged: (value) => _setNegate(value.single),
              ),
            ],
          ),
        ),
        if (widget.field == FilterField.artist)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
            child: TextField(
              key: const ValueKey('artist-search'),
              controller: _search,
              autofocus: true,
              decoration: const InputDecoration(
                isDense: true,
                hintText: 'Find an artist',
                prefixIcon: Icon(Icons.search, size: 18),
              ),
              onChanged: (_) => setState(() {}),
            ),
          ),
        if (_info.shape == FieldShape.many && values.length > 1)
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 0, 14, 4),
            child: Text(
              'Any of the ${values.length} chosen',
              style: TextStyle(fontSize: 12, color: colors.dim2),
            ),
          ),
        Flexible(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 320),
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: options.length,
              itemExtent: 36,
              itemBuilder: (context, i) => _OptionRow(
                key: ValueKey('option-${options[i].value}'),
                label: options[i].label,
                trailing: widget.field == FilterField.artist
                    ? options[i].short
                    : null,
                radio: _info.shape == FieldShape.one,
                selected: values.contains(options[i].value),
                onTap: () => _toggleValue(options[i].value),
              ),
            ),
          ),
        ),
        if (widget.field == FilterField.plays) ...[
          Divider(height: 12, color: colors.line),
          const _MenuTitle('Count plays in'),
          _OptionRow(
            key: const ValueKey('plays-same-period'),
            label:
                'Same as the page (${widget.filters.period.label(widget.filters.now)})',
            radio: true,
            selected: _own == null,
            onTap: _samePeriod,
          ),
          Builder(
            builder: (anchor) => _OptionRow(
              key: const ValueKey('plays-own-period'),
              label: _own == null
                  ? 'Pick dates...'
                  : 'Own dates: ${_own!.label(widget.filters.now)}',
              radio: true,
              selected: _own != null,
              onTap: () => _pickOwn(anchor),
            ),
          ),
        ],
        const SizedBox(height: 6),
      ],
    );
  }
}

class _MenuTitle extends StatelessWidget {
  const _MenuTitle(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(14, 10, 14, 4),
    child: Text(
      text,
      style: TextStyle(fontSize: 12, color: OwnColors.of(context).dim2),
    ),
  );
}

/// A line of a menu: a tick box or a round mark, the label, and a note.
class _OptionRow extends StatelessWidget {
  const _OptionRow({
    super.key,
    required this.label,
    required this.onTap,
    this.selected = false,
    this.radio = false,
    this.about,
    this.trailing,
  });

  final String label;
  final VoidCallback onTap;

  /// Null shows no mark at all ("+ Filter" lines).
  final bool selected;
  final bool radio;

  /// A second line under the label.
  final String? about;
  final String? trailing;

  @override
  Widget build(BuildContext context) {
    final colors = OwnColors.of(context);
    final marked = about == null;
    return Semantics(
      selected: selected,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: 12,
            vertical: about == null ? 6 : 8,
          ),
          child: Row(
            children: [
              if (marked) ...[
                Icon(
                  radio
                      ? selected
                            ? Icons.radio_button_checked
                            : Icons.radio_button_unchecked
                      : selected
                      ? Icons.check_box
                      : Icons.check_box_outline_blank,
                  size: 18,
                  color: selected ? colors.accent : colors.dim2,
                ),
                const SizedBox(width: 10),
              ],
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 14,
                        color: selected ? colors.accent : colors.text,
                      ),
                    ),
                    if (about case final about?)
                      Text(
                        about,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 12, color: colors.dim2),
                      ),
                  ],
                ),
              ),
              if (trailing case final trailing?)
                Text(
                  trailing,
                  style: TextStyle(fontSize: 12, color: colors.dim2),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A filter chip: a pill with its text, a menu arrow and a remove button;
/// filled when in use, dashed when a Plays chip has its own dates.
class _ChipShape extends StatelessWidget {
  const _ChipShape({
    super.key,
    required this.text,
    required this.onTap,
    this.active = false,
    this.dashed = false,
    this.menu = false,
    this.icon,
    this.onClear,
    this.clearLabel,
  });

  final String text;
  final VoidCallback onTap;
  final bool active;
  final bool dashed;
  final bool menu;
  final IconData? icon;
  final VoidCallback? onClear;
  final String? clearLabel;

  @override
  Widget build(BuildContext context) {
    final colors = OwnColors.of(context);
    final color = active ? colors.accent : colors.dim;
    final pill = Material(
      color: active ? colors.accentBg : Colors.transparent,
      shape: StadiumBorder(
        side: dashed
            ? BorderSide.none
            : BorderSide(color: active ? colors.accent : colors.line),
      ),
      child: InkWell(
        customBorder: const StadiumBorder(),
        onTap: onTap,
        child: Padding(
          padding: EdgeInsets.fromLTRB(
            icon == null ? 12 : 8,
            0,
            onClear == null ? 10 : 4,
            0,
          ),
          child: SizedBox(
            height: 30,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (icon != null) ...[
                  Icon(icon, size: 16, color: color),
                  const SizedBox(width: 4),
                ],
                if (dashed) ...[
                  Icon(Icons.calendar_month_outlined, size: 15, color: color),
                  const SizedBox(width: 4),
                ],
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 320),
                  child: Text(
                    text,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: active ? FontWeight.w600 : FontWeight.w400,
                      color: color,
                    ),
                  ),
                ),
                if (menu) Icon(Icons.expand_more, size: 16, color: color),
                if (onClear != null)
                  IconButton(
                    tooltip: clearLabel,
                    visualDensity: VisualDensity.compact,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints.tightFor(
                      width: 26,
                      height: 26,
                    ),
                    iconSize: 15,
                    onPressed: onClear,
                    icon: Icon(Icons.close, color: color),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
    if (!dashed) return pill;
    return CustomPaint(
      foregroundPainter: _DashedStadium(colors.accent),
      child: pill,
    );
  }
}

/// A dashed outline around a pill: a Plays chip counting its own dates.
class _DashedStadium extends CustomPainter {
  _DashedStadium(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final path = Path()
      ..addRRect(
        RRect.fromRectAndRadius(
          rect.deflate(0.5),
          Radius.circular(size.height / 2),
        ),
      );
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    for (final metric in path.computeMetrics()) {
      for (var d = 0.0; d < metric.length; d += 7) {
        canvas.drawPath(metric.extractPath(d, d + 4), paint);
      }
    }
  }

  @override
  bool shouldRepaint(_DashedStadium old) => old.color != color;
}

/// Asks for a view's name; null when cancelled.
Future<String?> askViewName(
  BuildContext context, {
  required String title,
  required String initial,
  required String action,
}) => showDialog<String>(
  context: context,
  builder: (context) =>
      _NameDialog(title: title, initial: initial, action: action),
);

class _NameDialog extends StatefulWidget {
  const _NameDialog({
    required this.title,
    required this.initial,
    required this.action,
  });

  final String title;
  final String initial;
  final String action;

  @override
  State<_NameDialog> createState() => _NameDialogState();
}

class _NameDialogState extends State<_NameDialog> {
  late final _name = TextEditingController(text: widget.initial)
    ..selection = TextSelection(
      baseOffset: 0,
      extentOffset: widget.initial.length,
    );

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _done() {
    final name = _name.text.trim();
    if (name.isNotEmpty) Navigator.of(context).pop(name);
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.title),
    content: SizedBox(
      width: 380,
      child: TextField(
        key: const ValueKey('view-name'),
        controller: _name,
        autofocus: true,
        decoration: const InputDecoration(labelText: 'Name'),
        onSubmitted: (_) => _done(),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('Cancel'),
      ),
      FilledButton(
        key: const ValueKey('view-name-ok'),
        onPressed: _done,
        child: Text(widget.action),
      ),
    ],
  );
}

/// The pieces of the On VK part under the own search results (plan 06, C3):
/// its header (folds on a click, says how many VK found, and the account
/// toggle "+ adds to"), the line under its songs (searching, failed, Show
/// more), and a found song's + and mark.
///
/// Each piece is one song row tall, so the song list keeps its fixed row
/// height and builds only the rows on screen.
library;

import 'package:flutter/material.dart';

import '../library/library_records.dart';
import '../vk/vk_catalog.dart' show vkSearchPageSize;
import 'add_song_button.dart';
import 'catalog_search.dart';
import 'sources_scope.dart';
import 'theme.dart';

/// The colour of source [sourceId] as its songs' marks show it.
Color _colorOfId(BuildContext context, int sourceId) {
  final source = SourcesScope.of(context)
      .where((source) => source.id == sourceId)
      .firstOrNull;
  return source == null
      ? OwnColors.of(context).source1
      : colorOfSource(context, source);
}

/// The colours + takes: the account it adds to, or one per ticked account.
List<Color> targetColors(BuildContext context, CatalogSearch catalog) => [
  for (final source in catalog.targets) colorOfSource(context, source),
];

/// The + of a found song, or the check once the library has it.
Widget foundAddButton(
  BuildContext context,
  CatalogSearch catalog,
  FoundSong found, {
  required void Function(FoundSong found) onAdd,
  bool large = false,
}) {
  final state = catalog.stateOf(found);
  final have = catalog.haveSources(found);
  final targets = catalog.targets;
  final names = [for (final source in targets) source.name].join(' and ');
  return AddSongButton(
    key: ValueKey('add-${found.track.id}'),
    state: state,
    large: large,
    colors: state == FoundState.inLibrary
        ? [for (final id in have) _colorOfId(context, id)]
        : targetColors(context, catalog),
    onAdd: () => onAdd(found),
    addTip: targets.isEmpty
        ? 'Log in to VK to add songs'
        : 'Add to your library and to $names on VK',
    haveTip: _haveTip(context, have),
  );
}

String _haveTip(BuildContext context, List<int> sourceIds) {
  final sources = SourcesScope.of(context);
  final names = [
    for (final id in sourceIds)
      sources.where((source) => source.id == id).firstOrNull?.name ?? 'VK',
  ];
  return names.isEmpty
      ? 'In your library'
      : 'In your library: ${names.join(' and ')}';
}

/// A found song's mark: the globe of a song outside the library, in the
/// colour of the account it streams through; once added, it fades to the
/// cloud of a library song in the colour of the account that has it.
Widget foundMark(BuildContext context, CatalogSearch catalog, FoundSong found) {
  final inLibrary = catalog.stateOf(found) == FoundState.inLibrary;
  final have = catalog.haveSources(found);
  final icon = inLibrary
      ? Icon(
          Icons.cloud_outlined,
          key: const ValueKey('found-cloud'),
          size: 18,
          color: _colorOfId(context, have.firstOrNull ?? found.track.sourceId),
        )
      : Icon(
          Icons.public,
          key: const ValueKey('found-globe'),
          size: 18,
          color: sourceColor(context, found.track),
        );
  return Tooltip(
    message: inLibrary
        ? 'In your library: streams from VK'
        : 'On VK, not in your library: streams while you listen; + adds it '
              'to your library and VK',
    child: AnimatedSwitcher(
      duration: MediaQuery.of(context).disableAnimations
          ? Duration.zero
          : const Duration(milliseconds: 200),
      child: icon,
    ),
  );
}

/// The header of the On VK part: a click folds or unfolds it; on the right
/// the account toggle when there is more than one account.
class CatalogHeader extends StatelessWidget {
  const CatalogHeader({super.key, required this.catalog, required this.wide});

  final CatalogSearch catalog;

  /// Room for the line that says what the part is.
  final bool wide;

  @override
  Widget build(BuildContext context) {
    final total = catalog.total;
    final count = catalog.searching
        ? 'searching...'
        : total == null
        ? ''
        : total == 1
        ? '1 found'
        : '$total found';
    final names = [for (final source in catalog.targets) source.name];
    final note = catalog.folded
        ? 'Folded: click to show what VK found'
        : 'Not in your library yet. Click a song to play it, + to add it to '
              'your library and to ${names.isEmpty ? 'VK' : names.join(' and ')}.';
    return PartHeader(
      headerKey: const ValueKey('catalog-header'),
      countKey: const ValueKey('catalog-count'),
      title: 'ON VK',
      count: count,
      note: wide ? note : null,
      folded: catalog.folded,
      onTap: catalog.toggleFolded,
      lineAbove: true,
      trailing: catalog.accounts.length > 1
          ? CatalogTargetButton(catalog: catalog)
          : null,
    );
  }
}

/// The header of your own songs in search, above them (C4d): a click folds
/// or unfolds them, remembered like the On VK part's.
class OwnResultsHeader extends StatelessWidget {
  const OwnResultsHeader({
    super.key,
    required this.catalog,
    required this.count,
    required this.wide,
  });

  final CatalogSearch catalog;

  /// How many of your songs match.
  final int count;

  /// Room for the line that says what the part is.
  final bool wide;

  @override
  Widget build(BuildContext context) => PartHeader(
    headerKey: const ValueKey('own-header'),
    countKey: const ValueKey('own-count'),
    title: 'IN YOUR LIBRARY',
    count: count == 1 ? '1 song' : '$count songs',
    note: !wide
        ? null
        : catalog.ownFolded
        ? 'Folded: click to show your songs that match'
        : 'Your songs that match. Click here to fold them.',
    folded: catalog.ownFolded,
    onTap: catalog.toggleOwnFolded,
    lineAbove: false,
  );
}

/// One row of a search part's header: the fold arrow, the part's name in
/// small capitals, its count, and an optional line under them.
class PartHeader extends StatelessWidget {
  const PartHeader({
    super.key,
    required this.headerKey,
    required this.countKey,
    required this.title,
    required this.count,
    required this.note,
    required this.folded,
    required this.onTap,
    required this.lineAbove,
    this.trailing,
  });

  /// Keys of the clickable header and of its count, for tests.
  final Key headerKey;
  final Key countKey;
  final String title;
  final String count;

  /// The line under the name; null shows none (a narrow list).
  final String? note;
  final bool folded;
  final VoidCallback onTap;

  /// A line above the header, parting it from the rows before it.
  final bool lineAbove;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final colors = OwnColors.of(context);
    final note = this.note;
    return Padding(
      padding: EdgeInsets.only(top: lineAbove ? 6 : 0),
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: lineAbove
              ? Border(top: BorderSide(color: colors.line))
              : null,
        ),
        child: InkWell(
          key: headerKey,
          borderRadius: BorderRadius.circular(8),
          hoverColor: colors.hover,
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(10, 4, 8, 2),
            child: Row(
              children: [
                AnimatedRotation(
                  turns: folded ? -0.25 : 0,
                  duration: const Duration(milliseconds: 150),
                  child: Icon(Icons.expand_more, size: 20, color: colors.dim),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Text(
                            title,
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              letterSpacing: 0.7,
                              color: colors.dim2,
                            ),
                          ),
                          const SizedBox(width: 10),
                          Text(
                            count,
                            key: countKey,
                            style: TextStyle(fontSize: 12, color: colors.dim2),
                          ),
                        ],
                      ),
                      if (note != null)
                        Text(
                          note,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 12, color: colors.dim2),
                        ),
                    ],
                  ),
                ),
                ?trailing,
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// "+ adds to [account]": a click lists the accounts, where several or All
/// can be ticked (B3). The list stays open while ticking.
class CatalogTargetButton extends StatelessWidget {
  const CatalogTargetButton({super.key, required this.catalog});

  final CatalogSearch catalog;

  @override
  Widget build(BuildContext context) {
    final colors = OwnColors.of(context);
    final targets = catalog.targets;
    final label = catalog.allTicked
        ? 'All accounts'
        : targets.length == 1
        ? targets.single.name
        : '${targets.length} accounts';
    Widget dot(SourceInfo source) => Container(
      width: 8,
      height: 8,
      margin: const EdgeInsets.only(right: 3),
      decoration: BoxDecoration(
        color: colorOfSource(context, source),
        shape: BoxShape.circle,
      ),
    );
    return MenuAnchor(
      menuChildren: [
        for (final source in catalog.accounts)
          CheckboxMenuButton(
            key: ValueKey('catalog-target-${source.id}'),
            value: targets.any((target) => target.id == source.id),
            closeOnActivate: false,
            onChanged: (_) => catalog.toggleTarget(source.id),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                dot(source),
                const SizedBox(width: 4),
                Text(source.name),
              ],
            ),
          ),
        const Divider(height: 1),
        CheckboxMenuButton(
          key: const ValueKey('catalog-target-all'),
          value: catalog.allTicked,
          closeOnActivate: false,
          onChanged: (_) => catalog.toggleAll(),
          child: const Text('All accounts'),
        ),
      ],
      builder: (context, menu, _) => Tooltip(
        message: 'Which VK accounts + adds songs to',
        child: OutlinedButton(
          key: const ValueKey('catalog-targets'),
          style: OutlinedButton.styleFrom(
            foregroundColor: colors.text,
            side: BorderSide(color: colors.line),
            padding: const EdgeInsets.fromLTRB(10, 0, 4, 0),
            minimumSize: const Size(0, 32),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
            ),
          ),
          onPressed: () => menu.isOpen ? menu.close() : menu.open(),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '+ adds to ',
                style: TextStyle(fontSize: 13, color: colors.dim2),
              ),
              for (final source in targets) dot(source),
              const SizedBox(width: 3),
              Text(label, style: const TextStyle(fontSize: 13)),
              Icon(Icons.arrow_drop_down, size: 20, color: colors.dim),
            ],
          ),
        ),
      ),
    );
  }
}

/// The line under the found songs: searching, why it failed, nothing
/// found, or Show more. Null when there is nothing to say.
Widget? catalogStatusRow(BuildContext context, CatalogSearch catalog) {
  final colors = OwnColors.of(context);
  final dim = TextStyle(fontSize: 13, color: colors.dim);
  Widget line(List<Widget> children) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 22),
    child: Row(children: children),
  );
  const spinner = SizedBox(
    width: 14,
    height: 14,
    child: CircularProgressIndicator(strokeWidth: 2),
  );
  if (catalog.searching) {
    return line([
      spinner,
      const SizedBox(width: 12),
      Text(
        'Searching VK...',
        key: const ValueKey('catalog-searching'),
        style: dim,
      ),
    ]);
  }
  final error = catalog.error;
  if (error != null) {
    return line([
      Flexible(
        child: Text(
          "VK's search failed: $error",
          key: const ValueKey('catalog-error'),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: dim,
        ),
      ),
      const SizedBox(width: 8),
      TextButton(
        key: const ValueKey('catalog-retry'),
        onPressed: catalog.retry,
        child: const Text('Try again'),
      ),
    ]);
  }
  if (catalog.songs.isEmpty) {
    return line([
      Text(
        'VK found nothing for "${catalog.query}"',
        key: const ValueKey('catalog-nothing'),
        style: dim,
      ),
    ]);
  }
  if (catalog.loadingMore) {
    return line([
      spinner,
      const SizedBox(width: 12),
      Text('Loading more from VK...', style: dim),
    ]);
  }
  if (catalog.hasMore) {
    final more = catalog.moreCount < vkSearchPageSize
        ? catalog.moreCount
        : vkSearchPageSize;
    return Align(
      alignment: Alignment.centerLeft,
      child: Padding(
        padding: const EdgeInsets.only(left: 10),
        child: TextButton(
          key: const ValueKey('catalog-more'),
          onPressed: catalog.showMore,
          child: Text('Show $more more from VK'),
        ),
      ),
    );
  }
  return null;
}

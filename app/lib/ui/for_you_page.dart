/// The For you place (plan 07, design A picked by the user 2026-11-17): VK
/// Mix on top, VK's lists for the account as cards (Play on a card plays it,
/// a click opens it as an ordinary song list), then songs similar to one
/// the account played. Also the helpers the song list uses for recommended
/// songs: their + , a greyed tag for songs VK gives no file for, and
/// "Similar songs" on any song (C5).
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../library/track.dart';
import '../playback/playback_controller.dart';
import '../vk/vk_recommendations.dart';
import 'albums.dart';
import 'catalog_part.dart';
import 'catalog_search.dart';
import 'card_play.dart';
import 'cover_tile.dart';
import 'for_you.dart';
import 'library_controller.dart';
import 'outside_songs.dart';
import 'playing_mark.dart';
import 'theme.dart';
import 'version_marks.dart' show lengthText;

/// "1 song", "12 songs".
String songCountText(int count) => count == 1 ? '1 song' : '$count songs';

/// How many songs of a "Similar to" shelf the page shows.
const similarRowsShown = 3;

/// "today 06:10", "yesterday 21:40" or "16 Nov 06:10" for when VK's lists
/// came.
String whenText(DateTime at, DateTime now) {
  String two(int n) => n.toString().padLeft(2, '0');
  final time = '${two(at.hour)}:${two(at.minute)}';
  final day = DateTime(at.year, at.month, at.day);
  final today = DateTime(now.year, now.month, now.day);
  final days = today.difference(day).inDays;
  if (days == 0) return 'today $time';
  if (days == 1) return 'yesterday $time';
  const months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', //
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];
  return '${at.day} ${months[at.month - 1]} $time';
}

/// The line under the For you title.
String? forYouDetail(ForYou? forYou, {DateTime? now}) {
  if (forYou == null) return null;
  final account = forYou.account;
  if (account == null) {
    return 'Log in to a VK account to see what VK recommends';
  }
  final at = forYou.fetchedAt;
  if (at == null) {
    return forYou.refreshing ? "Getting today's lists from VK..." : 'From VK';
  }
  final when = whenText(at, now ?? DateTime.now());
  return forYou.refreshing
      ? 'From VK, $when; asking VK for new lists...'
      : 'From VK for ${account.name}, updated $when';
}

/// The line under a recommended list's title.
String? listDetail(ForYou? forYou, AlbumRef ref, AlbumStatus status) {
  final key = ref.link?.key ?? '';
  final yours = status.inLibrary == 1
      ? '1 in your library'
      : '${status.inLibrary} in your library';
  if (status.load == AlbumLoad.loading) return 'Getting the songs from VK...';
  if (status.load == AlbumLoad.failed) return status.reason;
  if (key == forYouMixKey) {
    return 'The songs VK Mix played and lined up so far; more come as you '
        'listen. $yours';
  }
  if (key.startsWith('similar:')) return 'Songs VK finds similar. $yours';
  final list = forYou?.listOf(ref);
  final subtitle = list == null || list.subtitle.isEmpty
      ? ''
      : '${list.subtitle}. ';
  return 'Made by VK for you. $subtitle$yours';
}

/// [track], a song of a VK list (recommended or a playlist) outside the
/// library, as a song + can add (through the On VK part's accounts); null
/// for every other song and for a song VK gives no file for.
FoundSong? recFoundSong(
  OutsideSongs? outside,
  CatalogSearch catalog,
  Track track,
) {
  if (outside == null || track.inLibrary || catalog.accounts.isEmpty) {
    return null;
  }
  final rec = outside.songOf(track.id);
  if (rec == null || !rec.playable) return null;
  return catalog.outsideSong(
    track,
    vkTrackId: rec.song.vkTrackId,
    vkAlbumKey: rec.song.vkAlbumKey,
    vkAlbumAccessKey: rec.song.vkAlbumAccessKey,
  );
}

/// The greyed tag of a VK list's song VK gives no file for ("Not in your
/// region"), or null.
Widget? restrictedTag(
  OutsideSongs? outside,
  Track track, {
  bool compact = false,
}) {
  final code = outside?.restrictionOf(track.id);
  if (code == null) return null;
  return RestrictedTag(code: code, compact: compact);
}

/// VK's reason a song cannot play, as a small greyed tag with the longer
/// reason as its tooltip.
class RestrictedTag extends StatelessWidget {
  const RestrictedTag({super.key, required this.code, this.compact = false});

  final int code;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final colors = OwnColors.of(context);
    final warn = Theme.of(context).colorScheme.error;
    return Tooltip(
      message: vkRestrictionReason(code)!,
      child: Container(
        key: ValueKey('restricted-$code'),
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
        decoration: BoxDecoration(
          color: warn.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(6),
        ),
        child: compact
            ? Icon(Icons.block, size: 13, color: colors.dim)
            : Text(
                vkRestrictionLabel(code)!,
                maxLines: 1,
                style: TextStyle(fontSize: 11, color: warn),
              ),
      ),
    );
  }
}

/// Whether "Similar songs" is offered for [track]: a VK account is logged
/// in (any song: one without a VK key is looked up by name).
bool canFindSimilar(ForYou? forYou, Track track) =>
    forYou != null && forYou.account != null;

/// "Similar songs" on [track]: asks VK and opens the songs as a place, or
/// says VK knows none.
Future<void> openSimilar(
  BuildContext context,
  ForYou forYou,
  LibraryController library,
  Track track,
) async {
  final messenger = ScaffoldMessenger.of(context);
  messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        content: Text('Asking VK for songs like ${track.title}...'),
        duration: const Duration(seconds: 3),
      ),
    );
  try {
    final ref = await forYou.similarTo(
      sourceId: track.sourceId,
      artist: track.artist,
      title: track.title,
      sourceKey: track.source == TrackSource.vk ? track.sourceKey : null,
    );
    messenger.hideCurrentSnackBar();
    if (ref == null) {
      messenger.showSnackBar(
        SnackBar(content: Text('VK knows no songs similar to ${track.title}')),
      );
      return;
    }
    library.openList(ref);
  } catch (error) {
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        const SnackBar(content: Text('VK did not answer. Try again')),
      );
  }
}

/// The For you page.
class ForYouPage extends StatefulWidget {
  const ForYouPage({
    super.key,
    required this.forYou,
    required this.library,
    required this.playback,
    required this.onAdd,
    this.catalog,
  });

  final ForYou forYou;
  final LibraryController library;
  final PlaybackController playback;
  final CatalogSearch? catalog;
  final void Function(FoundSong found) onAdd;

  @override
  State<ForYouPage> createState() => _ForYouPageState();
}

class _ForYouPageState extends State<ForYouPage> {
  ForYou get forYou => widget.forYou;

  @override
  void initState() {
    super.initState();
    final clock = Stopwatch()..start();
    forYou.open();
    final cached = forYou.hasLists;
    // C4: from the click to the first frame of the place (times only).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      forYou.log?.call(
        'for-you page: first frame in ${clock.elapsedMilliseconds} ms, '
        'lists ${cached ? 'from the cache' : 'not yet in'}',
      );
    });
  }

  /// Opens [ref] as a song list and logs how long its rows took (C4).
  void _open(AlbumRef ref) {
    final clock = Stopwatch()..start();
    widget.library.openList(ref);
    final count = widget.library.visible.length;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      forYou.log?.call(
        'for-you list open: $count rows in ${clock.elapsedMilliseconds} ms',
      );
    });
  }

  /// The songs of [list] as tracks, in VK's order: the library's own song
  /// in place of each one it has, so its plays count as the library's.
  List<Track> _tracksOf(List<VkRecSong> songs) => [
    for (final song in songs) _ownOr(forYou.trackOf(song)),
  ];

  Track _ownOr(Track track) {
    final own = forYou.libraryCopyOf((track: track, vkTrackId: null));
    return own == null ? track : widget.library.byId(own.id) ?? own;
  }

  /// Plays [songs] of the list [ref] from [index], skipping songs VK gives
  /// no file for.
  Future<void> _play(List<Track> songs, int index, AlbumRef ref) async {
    final playable = [
      for (final track in songs)
        if (forYou.restrictionOf(track.id) == null) track,
    ];
    if (playable.isEmpty) return;
    final start = playable.indexOf(songs[index]);
    final from = playedFromList(ref);
    widget.library.notePlayedFrom(view: from.place! as LibraryView);
    await widget.playback.playFrom(playable, start < 0 ? 0 : start, from: from);
  }

  Future<void> _playMix() async {
    final playback = widget.playback;
    if (forYou.isMixList(playback.queue.context)) {
      await playback.playOrPause();
      return;
    }
    // VK Mix's own tracks, even for a song the library has: the mix is
    // told apart by them, to keep adding songs.
    var songs = [
      for (final song in forYou.mixSongs)
        if (song.playable) forYou.trackOf(song),
    ];
    if (songs.isEmpty) songs = await forYou.moreMix();
    if (songs.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('VK Mix gave no songs. Try again')),
      );
      return;
    }
    final from = playedFromList(forYou.mixRef);
    widget.library.notePlayedFrom(view: from.place! as LibraryView);
    await playback.playFrom(
      songs,
      songs.length > 3 ? songs.length - 3 : 0,
      from: from,
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = OwnColors.of(context);
    return ListenableBuilder(
      listenable: Listenable.merge([forYou, widget.playback, ?widget.catalog]),
      builder: (context, _) {
        if (forYou.account == null) {
          return PageMessage(
            'Log in to a VK account (the account button at the bottom) to '
            'see what VK recommends.',
            colors: colors,
          );
        }
        if (!forYou.hasLists) {
          return forYou.error != null && !forYou.refreshing
              ? PageMessage(
                  'VK did not answer: ${forYou.error}',
                  colors: colors,
                  action: TextButton(
                    key: const ValueKey('for-you-retry'),
                    onPressed: forYou.refresh,
                    child: const Text('Try again'),
                  ),
                )
              : _Loading(colors: colors);
        }
        final mixPlays = forYou.isMixList(widget.playback.queue.context);
        return ListView(
          key: const ValueKey('for-you-page'),
          padding: const EdgeInsets.fromLTRB(24, 4, 24, 24),
          children: [
            if (forYou.error != null && !forYou.refreshing)
              _Banner(forYou: forYou, colors: colors),
            if (forYou.hasMix)
              _MixCard(
                playing: mixPlays && widget.playback.player.playing.value,
                active: mixPlays,
                onPlay: _playMix,
                onOpen: forYou.mixSongs.isEmpty
                    ? null
                    : () => _open(forYou.mixRef),
                colors: colors,
              ),
            if (forYou.lists.isNotEmpty) ...[
              SectionTitle(
                'Made for you by VK',
                note: 'new every day',
                colors: colors,
              ),
              Wrap(
                spacing: 14,
                runSpacing: 14,
                children: [
                  for (final list in forYou.lists)
                    ListCard(
                      title: list.title,
                      detail: forYou.songsOf(list.key).isEmpty
                          ? (list.count == 0
                                ? 'loading...'
                                : songCountText(list.count))
                          : songCountText(forYou.songsOf(list.key).length),
                      coverUrl: list.coverUrl,
                      tint: list.tint,
                      songs: _tracksOf(forYou.songsOf(list.key)),
                      playable: _tracksOf([
                        for (final song in forYou.songsOf(list.key))
                          if (song.playable) song,
                      ]),
                      onPlay: (songs, index) =>
                          _play(songs, index, forYou.refOf(list)),
                      listKey: playedFromList(forYou.refOf(list)).key,
                      onOpen: () => _open(forYou.refOf(list)),
                      colors: colors,
                    ),
                ],
              ),
            ],
            for (final shelf in forYou.similar) ...[
              SectionTitle(
                shelf.title,
                // VK picks this shelf's song and does not say why.
                note: 'Picked by VK',
                colors: colors,
                onAll: shelf.songs.length > similarRowsShown
                    ? () => _open(forYou.refOfShelf(shelf))
                    : null,
              ),
              for (final (i, track) in _tracksOf(
                shelf.songs,
              ).take(similarRowsShown).indexed)
                _ShelfRow(
                  track: track,
                  own: widget.library.vkLists?.libraryCopyOf((
                    track: track,
                    vkTrackId: null,
                  )),
                  restricted: forYou.restrictionOf(track.id),
                  add: widget.catalog == null
                      ? null
                      : recFoundSong(forYou.outside, widget.catalog!, track),
                  catalog: widget.catalog,
                  onAdd: widget.onAdd,
                  onTap: () => _play(
                    _tracksOf(shelf.songs),
                    i,
                    forYou.refOfShelf(shelf),
                  ),
                  colors: colors,
                ),
            ],
            // Own "Similar to" shelves (Stage E): songs like ones the user
            // plays a lot or has not heard in a while.
            for (final shelf in forYou.ownShelves)
              if (forYou.songsOf(shelf.ref.link!.key) case final songs
                  when songs.isNotEmpty) ...[
                SectionTitle(
                  shelf.ref.title,
                  note: shelf.note,
                  colors: colors,
                  onAll: songs.length > similarRowsShown
                      ? () => _open(shelf.ref)
                      : null,
                ),
                for (final (i, track) in _tracksOf(
                  songs,
                ).take(similarRowsShown).indexed)
                  _ShelfRow(
                    track: track,
                    own: widget.library.vkLists?.libraryCopyOf((
                      track: track,
                      vkTrackId: null,
                    )),
                    restricted: forYou.restrictionOf(track.id),
                    add: widget.catalog == null
                        ? null
                        : recFoundSong(forYou.outside, widget.catalog!, track),
                    catalog: widget.catalog,
                    onAdd: widget.onAdd,
                    onTap: () => _play(_tracksOf(songs), i, shelf.ref),
                    colors: colors,
                  ),
              ],
          ],
        );
      },
    );
  }
}

/// A page's one message, with an action under it.
class PageMessage extends StatelessWidget {
  const PageMessage(this.text, {super.key, required this.colors, this.action});

  final String text;
  final OwnColors colors;
  final Widget? action;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(48),
    child: Column(
      children: [
        Text(
          text,
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 15, color: colors.dim),
        ),
        if (action != null) ...[const SizedBox(height: 12), action!],
      ],
    ),
  );
}

/// The first open: VK is asked, the shapes wait (B2 board).
class _Loading extends StatelessWidget {
  const _Loading({required this.colors});

  final OwnColors colors;

  @override
  Widget build(BuildContext context) {
    Widget box(double w, double h) => Container(
      width: w,
      height: h,
      decoration: BoxDecoration(
        color: colors.raised,
        borderRadius: BorderRadius.circular(10),
      ),
    );
    // Shapes only: a short window cuts them off instead of overflowing
    // (the smallest window, 440 px high).
    return SingleChildScrollView(
      key: const ValueKey('for-you-loading'),
      physics: const NeverScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(24, 4, 24, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            "Getting today's lists from VK...",
            style: TextStyle(fontSize: 13, color: colors.dim),
          ),
          const SizedBox(height: 14),
          box(double.infinity, 64),
          const SizedBox(height: 18),
          Wrap(
            spacing: 14,
            runSpacing: 14,
            children: [for (var i = 0; i < 4; i++) box(ListCard.side, 150)],
          ),
        ],
      ),
    );
  }
}

/// VK did not answer: the lists from before stay, with Try again.
class _Banner extends StatelessWidget {
  const _Banner({required this.forYou, required this.colors});

  final ForYou forYou;
  final OwnColors colors;

  @override
  Widget build(BuildContext context) {
    final at = forYou.fetchedAt;
    return Container(
      key: const ValueKey('for-you-banner'),
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: colors.raised,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: colors.line),
      ),
      child: Row(
        children: [
          Icon(Icons.cloud_off_outlined, size: 16, color: colors.dim),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'VK is not answering. These are the lists from '
              '${at == null ? 'before' : whenText(at, DateTime.now())}.',
              style: TextStyle(fontSize: 13, color: colors.dim),
            ),
          ),
          TextButton(
            key: const ValueKey('for-you-retry'),
            onPressed: forYou.refresh,
            child: const Text('Try again'),
          ),
        ],
      ),
    );
  }
}

/// A section's title on the For you and Playlists pages, with a note and
/// Show all.
class SectionTitle extends StatelessWidget {
  const SectionTitle(
    this.title, {
    super.key,
    required this.colors,
    this.note,
    this.onAll,
  });

  final String title;
  final String? note;
  final OwnColors colors;
  final VoidCallback? onAll;

  /// Below this width the note goes under the title, so a long note and
  /// Show all never squeeze the title away (narrow window, side panel).
  static const _noteInlineFrom = 520.0;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 18, bottom: 8),
    child: LayoutBuilder(
      builder: (context, constraints) {
        final inline = constraints.maxWidth >= _noteInlineFrom;
        final noteText = note == null
            ? null
            : Text(
                note!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 11, color: colors.dim2),
              );
        final titleRow = Row(
          children: [
            Flexible(
              child: Text(
                title.toUpperCase(),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.6,
                  color: colors.dim,
                ),
              ),
            ),
            if (inline && noteText != null) ...[
              const SizedBox(width: 8),
              Flexible(child: noteText),
            ],
            if (onAll != null) ...[
              const SizedBox(width: 8),
              TextButton(
                key: ValueKey('show-all-$title'),
                onPressed: onAll,
                child: const Text('Show all'),
              ),
            ],
          ],
        );
        if (inline || noteText == null) return titleRow;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [titleRow, noteText],
        );
      },
    ),
  );
}

/// VK Mix: one big card with Play; VK keeps adding songs while it plays.
class _MixCard extends StatelessWidget {
  const _MixCard({
    required this.playing,
    required this.active,
    required this.onPlay,
    required this.onOpen,
    required this.colors,
  });

  final bool playing;
  final bool active;
  final VoidCallback onPlay;
  final VoidCallback? onOpen;
  final OwnColors colors;

  @override
  Widget build(BuildContext context) => Material(
    color: colors.raised,
    borderRadius: BorderRadius.circular(12),
    child: InkWell(
      key: const ValueKey('vk-mix-card'),
      borderRadius: BorderRadius.circular(12),
      onTap: onOpen,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 10, 12, 10),
        child: Row(
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: colors.accentBg,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(Icons.all_inclusive, color: colors.accent),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text(
                    'VK Mix',
                    style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
                  ),
                  Text(
                    active
                        ? 'Playing now. VK keeps adding songs while you listen'
                        : 'Endless: VK picks songs for you as you listen',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 12, color: colors.dim),
                  ),
                ],
              ),
            ),
            _RoundPlay(
              key: const ValueKey('vk-mix-play'),
              playing: playing,
              size: 40,
              onPressed: onPlay,
              colors: colors,
            ),
          ],
        ),
      ),
    ),
  );
}

class _RoundPlay extends StatelessWidget {
  const _RoundPlay({
    super.key,
    required this.playing,
    required this.size,
    required this.onPressed,
    required this.colors,
  });

  final bool playing;
  final double size;
  final VoidCallback? onPressed;
  final OwnColors colors;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: playing ? 'Pause' : 'Play',
    child: Material(
      color: colors.accent,
      shape: const CircleBorder(),
      elevation: 1,
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onPressed,
        child: SizedBox(
          width: size,
          height: size,
          child: Icon(
            playing ? Icons.pause : Icons.play_arrow,
            color: colors.onAccent,
            size: size * 0.6,
          ),
        ),
      ),
    ),
  );
}

/// A VK list as a card (For you's lists, the playlists): its cover (or
/// initials), Play, name and a detail line (the song count).
class ListCard extends StatelessWidget {
  const ListCard({
    super.key,
    required this.title,
    required this.detail,
    this.coverUrl,
    this.tint,
    required this.songs,
    required this.playable,
    required this.onPlay,
    required this.onOpen,
    required this.colors,
    this.listKey,
  });

  static const side = 128.0;

  /// The list's `PlayedFrom.key`: the card shows its list playing whenever
  /// the player plays from it, in any order (Shuffle, a row click).
  final String? listKey;

  final String title;

  /// The line under the title ("12 songs").
  final String detail;
  final String? coverUrl;
  final int? tint;
  final List<Track> songs;

  /// [songs] without those VK gives no file for: what Play plays.
  final List<Track> playable;
  final Future<void> Function(List<Track> songs, int index) onPlay;
  final VoidCallback onOpen;
  final OwnColors colors;

  String get _initials {
    final daily = RegExp(r'(\d+)$').firstMatch(title);
    if (daily != null) return daily[1]!;
    return title
        .split(' ')
        .where((w) => w.isNotEmpty)
        .take(2)
        .map((w) => w[0].toUpperCase())
        .join();
  }

  @override
  Widget build(BuildContext context) {
    final state = NowPlaying.listStateFor(context, playable, key: listKey);
    final tint = this.tint;
    final color = tint == null ? colors.accentBg : Color(tint);
    return SizedBox(
      width: side,
      child: CardHover(
        child: InkWell(
          key: ValueKey('list-card-$title'),
          borderRadius: BorderRadius.circular(10),
          onTap: onOpen,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Stack(
                children: [
                  Container(
                    width: side,
                    height: side,
                    decoration: BoxDecoration(
                      color: color.withValues(alpha: 0.35),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    alignment: Alignment.center,
                    child: coverUrl != null
                        ? TrackTile(
                            track: Track(
                              id: -1,
                              sourceId: 0,
                              source: TrackSource.vk,
                              artist: title,
                              title: title,
                              album: title,
                              durationSec: 0,
                              coverUrl: coverUrl,
                              coverMidUrl: coverUrl,
                              coverLargeUrl: coverUrl,
                            ),
                            size: side,
                            radius: 10,
                          )
                        : Text(
                            _initials,
                            style: TextStyle(
                              fontSize: 28,
                              fontWeight: FontWeight.w700,
                              color: colors.text.withValues(alpha: 0.7),
                            ),
                          ),
                  ),
                  // The playing list's cover is outlined in the accent colour.
                  if (state != null)
                    Positioned.fill(
                      child: IgnorePointer(
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(color: colors.accent, width: 2),
                          ),
                        ),
                      ),
                    ),
                  Positioned(
                    right: 8,
                    bottom: 8,
                    child: CardPlayButton(
                      key: ValueKey('list-play-$title'),
                      state: state,
                      onPlay: playable.isEmpty
                          ? null
                          : () => onPlay(playable, 0),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              // The list that plays: its title in the accent colour (user,
              // 2026-11-18: "not very clear which playlist is playing now");
              // its moving bars are in the card's Play (user, 2026-11-21).
              Row(
                children: [
                  Expanded(
                    child: Text(
                      title,
                      key: state != null
                          ? ValueKey('list-playing-$title')
                          : null,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: state != null ? colors.accent : null,
                      ),
                    ),
                  ),
                ],
              ),
              Text(
                detail,
                maxLines: 1,
                style: TextStyle(fontSize: 12, color: colors.dim),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A song of a "Similar to" shelf: cover, title and artist, + or the check,
/// length. A song VK gives no file for is greyed with VK's reason.
/// The width of a shelf row's + or check: the + button's tap target.
const _actionSlot = 40.0;

class _ShelfRow extends StatelessWidget {
  const _ShelfRow({
    required this.track,
    required this.own,
    required this.restricted,
    required this.add,
    required this.catalog,
    required this.onAdd,
    required this.onTap,
    required this.colors,
  });

  final Track track;
  final Track? own;
  final int? restricted;
  final FoundSong? add;
  final CatalogSearch? catalog;
  final void Function(FoundSong found) onAdd;
  final VoidCallback onTap;
  final OwnColors colors;

  @override
  Widget build(BuildContext context) {
    final state = NowPlaying.stateFor(context, track.id);
    final dimmed = restricted != null;
    final shown = own ?? track;
    return InkWell(
      key: ValueKey('shelf-row-${track.id}'),
      borderRadius: BorderRadius.circular(8),
      onTap: dimmed ? null : onTap,
      child: Opacity(
        opacity: dimmed ? 0.55 : 1,
        child: SizedBox(
          height: 48,
          child: Row(
            children: [
              const SizedBox(width: 4),
              TrackTile(track: shown, size: 34, radius: 6),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      shown.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 14,
                        color: state != null ? colors.currentText : null,
                      ),
                    ),
                    Text(
                      shown.artist,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 12, color: colors.dim),
                    ),
                  ],
                ),
              ),
              if (state != null)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: PlayingMark(
                    playing: state,
                    size: 14,
                    color: colors.currentText,
                  ),
                ),
              if (restricted != null) RestrictedTag(code: restricted!),
              if (track.inLibrary)
                Tooltip(
                  message: 'In your library',
                  // In the + button's slot (its 40 px tap target), so the
                  // check and the + of the other rows stand in one column.
                  child: SizedBox(
                    width: _actionSlot,
                    height: 28,
                    child: Center(
                      child: Icon(
                        Icons.check_circle,
                        key: const ValueKey('shelf-owned'),
                        size: 21,
                        color: colors.accent,
                      ),
                    ),
                  ),
                ),
              if (add != null && catalog != null)
                SizedBox(
                  width: _actionSlot,
                  child: Center(
                    child: foundAddButton(
                      context,
                      catalog!,
                      add!,
                      onAdd: onAdd,
                    ),
                  ),
                ),
              SizedBox(
                width: 52,
                child: Text(
                  lengthText(track.durationSec.toDouble()),
                  textAlign: TextAlign.right,
                  style: TextStyle(fontSize: 13, color: colors.dim),
                ),
              ),
              const SizedBox(width: 8),
            ],
          ),
        ),
      ),
    );
  }
}

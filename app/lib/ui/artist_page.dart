/// One artist's page (plan 09, D2; design A picked by the user 2026-11-20:
/// one scroll, yours first, VK below). The header: the round photo, the
/// name, what the library has and, once VK answered, what VK has; Play and
/// Shuffle play the library's songs. Then the sections: In your library (5
/// rows, "Show all" opens them as a song list), Your albums, and VK's
/// Popular (6 rows, a check on the songs the library has, + on the others,
/// "Show more" opens them as a VK list), Releases and You may like. The
/// library part shows at once; VK's part loads after (1-2 s) and stays while
/// the app runs.
library;

import 'dart:math';

import 'package:flutter/material.dart';

import '../library/artist_index.dart';
import '../library/library_records.dart' show StoredArtistPhoto;
import '../library/track.dart';
import '../playback/play_queue.dart' show PlayedFrom;
import '../playback/playback_controller.dart';
import '../vk/vk_artists.dart';
import 'albums.dart';
import 'artists.dart';
import 'artists_page.dart' show ArtistPhoto;
import 'cover_tile.dart';
import 'for_you_page.dart' show SectionTitle, songCountText;
import 'library_controller.dart';
import 'outside_songs.dart';
import 'theme.dart';

/// Builds one song row of a page with every usual action (the library
/// screen's row): [number] is its place in its section, [onTap] plays it.
/// A row of VK's Popular ([popular]) shows a check on a song the library
/// has instead of the heart.
typedef PageSongRow = Widget Function(
  Track track, {
  required int number,
  required VoidCallback onTap,
  bool popular,
});

/// How many library songs the page lists before "Show all".
const artistSongsShown = 5;

/// How many Popular songs the page lists before "Show more".
const artistPopularShown = 6;

/// The VK artist id or address name the artist [key] is asked for by, or
/// null for a name-only artist.
String? vkRefOf(String key, Artist? artist) {
  if (artist?.vkId case final id?) return id;
  if (key.startsWith('vk:')) return key.substring(3);
  if (key.startsWith('domain:')) return key.substring('domain:'.length);
  return null;
}

/// "12 songs and 3 albums in your library", "1 song in your library".
String libraryPartText(Artist? artist) {
  final songs = artist?.songs.length ?? 0;
  if (songs == 0) return 'None of their songs in your library';
  final albums = artist!.albums.length;
  final songText = songCountText(songs);
  if (albums == 0) return '$songText in your library';
  return '$songText and ${albums == 1 ? '1 album' : '$albums albums'} '
      'in your library';
}

/// "On VK: 74 songs, 22 releases" once VK's page is in; the song count only
/// when VK gave one or paging ended (R7).
String? vkPartText(int? songs, VkArtistPage? page) {
  if (page == null) return null;
  final releases = page.releases.length;
  final parts = [
    if (songs != null) songCountText(songs),
    if (releases > 0) releases == 1 ? '1 release' : '$releases releases',
  ];
  return parts.isEmpty ? null : 'On VK: ${parts.join(', ')}';
}

/// "2022, album", "2012, single".
String releaseLine(VkArtistRelease release) {
  final kind = release.single ? 'single' : 'album';
  return release.year == null ? kind : '${release.year}, $kind';
}

/// The page.
class ArtistPage extends StatefulWidget {
  const ArtistPage({
    super.key,
    required this.artistKey,
    required this.artists,
    required this.library,
    required this.playback,
    required this.songRow,
    this.outside,
  });

  /// LibraryView.artist of the page.
  final String artistKey;
  final LibraryArtists artists;
  final LibraryController library;
  final PlaybackController playback;
  final PageSongRow songRow;

  /// VK songs the library lacks, for the songs VK gives no file for.
  final OutsideSongs? outside;

  @override
  State<ArtistPage> createState() => _ArtistPageState();
}

class _ArtistPageState extends State<ArtistPage> {
  LibraryArtists get artists => widget.artists;

  @override
  void initState() {
    super.initState();
    final clock = Stopwatch()..start();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final artist = artists.artistOf(widget.artistKey);
      artists.log?.call(
        'artist page: library part in ${clock.elapsedMilliseconds} ms, '
        '${artist?.songs.length ?? 0} songs',
      );
      _loadVk();
    });
  }

  @override
  void didUpdateWidget(ArtistPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.artistKey != widget.artistKey) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _loadVk();
      });
    }
  }

  void _loadVk({bool again = false}) {
    final key = widget.artistKey;
    final ref = vkRefOf(key, artists.artistOf(key));
    if (ref != null) artists.loadVk(ref, again: again);
  }

  /// The "Playing from" of the artist's library songs: their song list,
  /// so Go to the playing song finds the row there (R6).
  PlayedFrom _fromLibrary(Artist artist) {
    final view = LibraryView(ViewKind.artistSongs, artist: artist.key);
    return PlayedFrom(label: artist.name, key: view.playKey, place: view);
  }

  Future<void> _playLibrary(Artist artist, int index) async {
    final from = _fromLibrary(artist);
    widget.library.notePlayedFrom(view: from.place! as LibraryView);
    await widget.playback.playFrom(artist.songs, index, from: from);
  }

  Future<void> _shuffleLibrary(Artist artist) async {
    final songs = artist.songs;
    if (songs.isEmpty) return;
    final playback = widget.playback;
    if (!playback.shuffle) playback.toggleShuffle();
    // Never the song playing now: playFrom takes that one as play / pause.
    final playingId = playback.player.current?.id;
    var picks = [
      for (var i = 0; i < songs.length; i++)
        if (songs[i].id != playingId) i,
    ];
    if (picks.isEmpty) picks = [for (var i = 0; i < songs.length; i++) i];
    await _playLibrary(artist, picks[Random().nextInt(picks.length)]);
  }

  /// Plays the Popular list [ref] from [track], the library's own song in
  /// place of each one it has, without the songs VK gives no file for.
  Future<void> _playPopular(
    List<Track> songs,
    Track track,
    AlbumRef ref,
  ) async {
    final playable = [
      for (final song in songs)
        if (widget.outside?.restrictionOf(song.id) == null) song,
    ];
    if (playable.isEmpty) return;
    final start = playable.indexOf(track);
    final from = playedFromList(ref);
    widget.library.notePlayedFrom(view: from.place! as LibraryView);
    await widget.playback.playFrom(playable, start < 0 ? 0 : start, from: from);
  }

  /// A Popular song as its row shows it: the library's own song when it
  /// has it, so its plays count as the library's.
  Track _ownOr(Track track) {
    final own = widget.outside?.libraryCopyOf(track.id);
    return own == null ? track : widget.library.byId(own.id) ?? own;
  }

  @override
  Widget build(BuildContext context) {
    final colors = OwnColors.of(context);
    return ListenableBuilder(
      listenable: Listenable.merge([artists, widget.library]),
      builder: (context, _) {
        final key = widget.artistKey;
        var artist = artists.artistOf(key);
        final vkRef = vkRefOf(key, artist);
        final vk = vkRef == null ? null : artists.vkOf(vkRef);
        final page = vk?.page;
        // A page opened by address name: the library may know the artist
        // by the id VK's page gave.
        if (artist == null && page != null) {
          artist = artists.index['vk:${page.id}'];
        }
        final popularRef = page == null || vk?.sourceId == null
            ? null
            : artists.popularRef(page, vk!.sourceId!);
        final popular = page == null || vk?.sourceId == null
            ? const <Track>[]
            : [
                for (final track in artists.popularTracks(page, vk!.sourceId!))
                  _ownOr(track),
              ];
        final name = artist?.name ?? page?.name ?? '';
        return LayoutBuilder(
          builder: (context, box) {
            final narrow = box.maxWidth < 640;
            return ListView(
              key: ValueKey('artist-page-$key'),
              padding: const EdgeInsets.fromLTRB(12, 0, 24, 28),
              children: [
                _Header(
                  name: name,
                  artist: artist,
                  photo: artist != null
                      ? artists.photoOf(artist)
                      : page == null
                      ? null
                      : artists.photoOfId(page.id),
                  detail: [
                    libraryPartText(artist),
                    ?vkPartText(
                      popularRef == null
                          ? null
                          : artists.popularTotal(popularRef),
                      page,
                    ),
                  ].join('. '),
                  narrow: narrow,
                  onBack: widget.library.goBack,
                  onPlay: artist == null || artist.songs.isEmpty
                      ? null
                      : () => _playLibrary(artist!, 0),
                  onShuffle: artist == null || artist.songs.length < 2
                      ? null
                      : () => _shuffleLibrary(artist!),
                  colors: colors,
                ),
                if (artist != null && artist.songs.isNotEmpty)
                  ..._librarySection(artist, colors),
                if (artist != null && artist.albums.isNotEmpty)
                  ..._albumsSection(artist, colors),
                ..._vkSection(
                  artist: artist,
                  vk: vk,
                  popular: popular,
                  popularRef: popularRef,
                  colors: colors,
                  narrow: narrow,
                ),
              ],
            );
          },
        );
      },
    );
  }

  List<Widget> _librarySection(Artist artist, OwnColors colors) {
    final songs = artist.songs;
    return [
      Padding(
        padding: const EdgeInsets.only(left: 12),
        child: SectionTitle(
          'In your library (${songs.length})',
          colors: colors,
        ),
      ),
      for (final (i, track) in songs.take(artistSongsShown).indexed)
        SizedBox(
          height: rowHeight,
          child: widget.songRow(
            track,
            number: i + 1,
            onTap: () => _playLibrary(artist, i),
          ),
        ),
      if (songs.length > artistSongsShown)
        Align(
          alignment: Alignment.centerLeft,
          child: Padding(
            padding: const EdgeInsets.only(left: 12, top: 2),
            child: TextButton(
              key: const ValueKey('artist-show-all'),
              onPressed: () => widget.library.openArtistSongs(artist.key),
              child: Text('Show all ${songs.length}'),
            ),
          ),
        ),
    ];
  }

  List<Widget> _albumsSection(Artist artist, OwnColors colors) => [
    Padding(
      padding: const EdgeInsets.only(left: 12),
      child: SectionTitle('Your albums', colors: colors),
    ),
    Padding(
      padding: const EdgeInsets.only(left: 12),
      child: Wrap(
        spacing: 16,
        runSpacing: 14,
        children: [
          for (final album in artist.albums)
            _Card(
              key: ValueKey('artist-album-${album.first.id}'),
              tile: TrackTile(track: album.first, size: _Card.wide, radius: 10),
              title: album.title,
              line: songCountText(album.songs),
              tooltip: 'Open the album',
              onOpen: () => widget.library.openAlbum(album.first),
              colors: colors,
            ),
        ],
      ),
    ),
  ];

  List<Widget> _vkSection({
    required Artist? artist,
    required ArtistVkState? vk,
    required List<Track> popular,
    required AlbumRef? popularRef,
    required OwnColors colors,
    required bool narrow,
  }) {
    Widget note(String text, {Widget? action, Key? key}) => Padding(
      key: key,
      padding: const EdgeInsets.fromLTRB(12, 22, 0, 0),
      child: Row(
        children: [
          Icon(Icons.public, size: 16, color: colors.dim2),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              text,
              style: TextStyle(fontSize: 13, color: colors.dim),
            ),
          ),
          ?action,
        ],
      ),
    );
    final divider = Padding(
      padding: const EdgeInsets.only(left: 12, top: 18),
      child: Divider(height: 1, color: colors.line),
    );
    if (vk == null) {
      return [
        divider,
        note(
          'VK has no artist page for this name: its songs are grouped by '
          'their artist text.',
          key: const ValueKey('artist-vk-none'),
        ),
      ];
    }
    switch (vk.load) {
      case ArtistVkLoad.noAccount:
        return [
          divider,
          note(
            "Log in to a VK account to see the artist's songs and releases "
            'on VK.',
            key: const ValueKey('artist-vk-login'),
          ),
        ];
      case ArtistVkLoad.none:
        return [
          divider,
          note(
            'VK has no page for this artist.',
            key: const ValueKey('artist-vk-none'),
          ),
        ];
      case ArtistVkLoad.failed:
        return [
          divider,
          note(
            'VK did not answer: ${vk.error}',
            key: const ValueKey('artist-vk-failed'),
            action: TextButton(
              key: const ValueKey('artist-vk-retry'),
              onPressed: () => _loadVk(again: true),
              child: const Text('Try again'),
            ),
          ),
        ];
      case ArtistVkLoad.loading:
        return [divider, _Loading(colors: colors)];
      case ArtistVkLoad.loaded:
        break;
    }
    final page = vk.page!;
    final sourceId = vk.sourceId!;
    final total = popularRef == null ? null : artists.popularTotal(popularRef);
    final block = artists.popularTracks(page, sourceId);
    final more =
        popularRef != null &&
        (block.length > artistPopularShown || page.popular.hasMore);
    return [
      divider,
      if (popular.isNotEmpty) ...[
        Padding(
          padding: const EdgeInsets.only(left: 12),
          child: SectionTitle(
            'Popular on VK',
            note: 'a check means you have it; + adds it',
            colors: colors,
          ),
        ),
        for (final (i, track) in popular.take(artistPopularShown).indexed)
          SizedBox(
            height: rowHeight,
            child: widget.songRow(
              track,
              number: i + 1,
              popular: true,
              onTap: () => _playPopular(popular, track, popularRef!),
            ),
          ),
        if (more)
          Align(
            alignment: Alignment.centerLeft,
            child: Padding(
              padding: const EdgeInsets.only(left: 12, top: 2),
              child: TextButton(
                key: const ValueKey('artist-popular-more'),
                onPressed: () {
                  widget.library.openList(popularRef);
                  artists.morePopular(popularRef);
                },
                child: Text(
                  total == null ? 'Show more' : 'Show more ($total on VK)',
                ),
              ),
            ),
          ),
      ],
      if (page.releases.isNotEmpty) ...[
        Padding(
          padding: const EdgeInsets.only(left: 12),
          child: SectionTitle('Releases on VK', colors: colors),
        ),
        Padding(
          padding: const EdgeInsets.only(left: 12),
          child: Wrap(
            spacing: 16,
            runSpacing: 14,
            children: [
              for (final release in page.releases)
                _Card(
                  key: ValueKey('artist-release-${release.key}'),
                  tile: TrackTile(
                    track: Track(
                      id: 0,
                      sourceId: sourceId,
                      source: TrackSource.vk,
                      artist: page.name,
                      title: release.title,
                      album: release.title,
                      durationSec: 0,
                      coverUrl: release.coverUrl,
                    ),
                    size: narrow ? _Card.narrowSide : _Card.wide,
                    radius: 10,
                  ),
                  side: narrow ? _Card.narrowSide : _Card.wide,
                  title: release.title,
                  line: releaseLine(release),
                  tooltip: 'Open the release',
                  onOpen: () => widget.library.openAlbumRef(
                    AlbumRef(
                      title: release.title,
                      artist: page.name,
                      link: (
                        sourceId: sourceId,
                        key: release.key,
                        accessKey: release.accessKey,
                      ),
                    ),
                  ),
                  colors: colors,
                ),
            ],
          ),
        ),
      ],
      if (page.similar.isNotEmpty) ...[
        Padding(
          padding: const EdgeInsets.only(left: 12),
          child: SectionTitle('You may like (from VK)', colors: colors),
        ),
        Padding(
          padding: const EdgeInsets.only(left: 12),
          child: Wrap(
            spacing: 20,
            runSpacing: 14,
            children: [
              for (final similar in page.similar)
                _SimilarTile(
                  similar: similar,
                  known: similar.domain == null
                      ? null
                      : artists.byDomain(similar.domain!),
                  onOpen: similar.domain == null
                      ? null
                      : () {
                          final known = artists.byDomain(similar.domain!);
                          widget.library.openArtist(
                            known?.key ?? 'domain:${similar.domain}',
                          );
                        },
                  colors: colors,
                ),
            ],
          ),
        ),
      ],
    ];
  }
}

/// The page's top: Back, the round photo, the name, what the library and
/// VK have, Play and Shuffle.
class _Header extends StatelessWidget {
  const _Header({
    required this.name,
    required this.artist,
    required this.photo,
    required this.detail,
    required this.narrow,
    required this.onBack,
    required this.onPlay,
    required this.onShuffle,
    required this.colors,
  });

  final String name;
  final Artist? artist;
  final StoredArtistPhoto? photo;
  final String detail;
  final bool narrow;
  final VoidCallback onBack;
  final VoidCallback? onPlay;
  final VoidCallback? onShuffle;
  final OwnColors colors;

  @override
  Widget build(BuildContext context) {
    final side = narrow ? 104.0 : 156.0;
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          IconButton(
            key: const ValueKey('album-back'),
            tooltip: 'Back (Alt+Left)',
            onPressed: onBack,
            icon: const Icon(Icons.arrow_back),
          ),
          const SizedBox(width: 8),
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: ArtistPhoto(
              key: const ValueKey('artist-page-photo'),
              name: name.isEmpty ? '?' : name,
              size: side,
              photo: photo,
              tint: artist?.tint,
              nameOnly: artist?.nameOnly ?? false,
            ),
          ),
          SizedBox(width: narrow ? 16 : 24),
          Expanded(
            child: Padding(
              padding: EdgeInsets.only(top: narrow ? 4 : 18),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'ARTIST',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 0.8,
                      color: colors.dim,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    name,
                    key: const ValueKey('artist-page-name'),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: narrow ? 24 : 34,
                      fontWeight: FontWeight.w800,
                      height: 1.15,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    detail,
                    key: const ValueKey('artist-page-detail'),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 13, color: colors.dim),
                  ),
                  if (onPlay != null) ...[
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 10,
                      runSpacing: 8,
                      children: [
                        FilledButton.icon(
                          key: const ValueKey('artist-play'),
                          onPressed: onPlay,
                          icon: const Icon(Icons.play_arrow, size: 20),
                          label: const Text('Play'),
                        ),
                        if (onShuffle != null)
                          OutlinedButton.icon(
                            key: const ValueKey('artist-shuffle'),
                            onPressed: onShuffle,
                            icon: const Icon(Icons.shuffle, size: 18),
                            label: const Text('Shuffle'),
                          ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// A card of an album or a release: its cover, title and one line.
class _Card extends StatelessWidget {
  const _Card({
    super.key,
    required this.tile,
    required this.title,
    required this.line,
    required this.tooltip,
    required this.onOpen,
    required this.colors,
    this.side = _Card.wide,
  });

  static const wide = 150.0;
  static const narrowSide = 120.0;

  final Widget tile;
  final String title;
  final String line;
  final String tooltip;
  final VoidCallback onOpen;
  final OwnColors colors;
  final double side;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: side,
    child: Tooltip(
      message: tooltip,
      waitDuration: const Duration(milliseconds: 600),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        hoverColor: colors.hover,
        onTap: onOpen,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            tile,
            const SizedBox(height: 6),
            Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
            ),
            Text(
              line,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12, color: colors.dim),
            ),
          ],
        ),
      ),
    ),
  );
}

/// An artist VK suggests: round photo, name, how many of their songs the
/// library has; a click opens their page.
class _SimilarTile extends StatelessWidget {
  const _SimilarTile({
    required this.similar,
    required this.known,
    required this.onOpen,
    required this.colors,
  });

  final VkSimilarArtist similar;
  final Artist? known;
  final VoidCallback? onOpen;
  final OwnColors colors;

  @override
  Widget build(BuildContext context) {
    final songs = known?.songs.length ?? 0;
    return SizedBox(
      width: 130,
      child: InkWell(
        key: ValueKey('artist-similar-${similar.domain ?? similar.name}'),
        borderRadius: BorderRadius.circular(12),
        hoverColor: colors.hover,
        onTap: onOpen,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Column(
            children: [
              ArtistPhoto(
                name: similar.name,
                size: 104,
                photoUrl: similar.photoUrl,
              ),
              const SizedBox(height: 6),
              Text(
                similar.name,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
              Text(
                songs == 0
                    ? 'none in your library'
                    : '${songCountText(songs)} in your library',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 12, color: colors.dim),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// VK's part while it loads: the shapes of the rows and cards.
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
        borderRadius: BorderRadius.circular(8),
      ),
    );
    return Padding(
      key: const ValueKey('artist-vk-loading'),
      padding: const EdgeInsets.fromLTRB(12, 22, 0, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Getting the artist\'s page from VK...',
            style: TextStyle(fontSize: 13, color: colors.dim),
          ),
          const SizedBox(height: 12),
          for (var i = 0; i < 4; i++) ...[
            box(double.infinity, 44),
            const SizedBox(height: 8),
          ],
          const SizedBox(height: 10),
          Wrap(
            spacing: 16,
            children: [for (var i = 0; i < 4; i++) box(_Card.wide, 150)],
          ),
        ],
      ),
    );
  }
}

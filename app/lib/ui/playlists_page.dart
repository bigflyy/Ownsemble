/// The Playlists place (plan 08, B2): the playlists each logged-in VK
/// account made and follows, as cards like For you's lists (Play on a card
/// plays it, a click opens it as an ordinary song list). Followed albums are
/// left for an Albums view (user, 2026-11-17).
library;

import 'package:flutter/material.dart';

import '../library/track.dart';
import '../playback/playback_controller.dart';
import '../vk/vk_playlists.dart';
import '../vk/vk_recommendations.dart';
import 'albums.dart';
import 'for_you_page.dart';
import 'library_controller.dart';
import 'playlists.dart';
import 'theme.dart';

/// The line under the Playlists title.
String? playlistsDetail(VkPlaylists? playlists) {
  if (playlists == null) return null;
  if (playlists.accounts().isEmpty) {
    return 'Log in to a VK account to see its playlists';
  }
  return playlists.refreshing
      ? 'From VK; asking VK for changes...'
      : 'From VK, updated at each sync';
}

/// The line under an open playlist's title.
String? playlistDetail(
  VkPlaylists? playlists,
  AlbumRef ref,
  AlbumStatus status,
) {
  if (status.load == AlbumLoad.loading) return 'Getting the songs from VK...';
  if (status.load == AlbumLoad.failed) return status.reason;
  final yours = '${status.inLibrary} in your library';
  final list = playlists?.playlistOf(ref);
  final kind = switch (list?.kind) {
    VkPlaylistKind.followed => 'A playlist you follow on VK',
    _ => 'Your playlist on VK',
  };
  return '$kind. $yours';
}

class PlaylistsPage extends StatefulWidget {
  const PlaylistsPage({
    super.key,
    required this.playlists,
    required this.library,
    required this.playback,
  });

  final VkPlaylists playlists;
  final LibraryController library;
  final PlaybackController playback;

  @override
  State<PlaylistsPage> createState() => _PlaylistsPageState();
}

class _PlaylistsPageState extends State<PlaylistsPage> {
  VkPlaylists get playlists => widget.playlists;

  @override
  void initState() {
    super.initState();
    final clock = Stopwatch()..start();
    playlists.open();
    final cached = playlists.hasLists;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      playlists.log?.call(
        'playlists page: first frame in ${clock.elapsedMilliseconds} ms, '
        'lists ${cached ? 'from the cache' : 'not yet in'}',
      );
    });
  }

  /// The songs of [songs] as tracks of [sourceId], in VK's order: the
  /// library's own song in place of each one it has, so its plays count as
  /// the library's.
  List<Track> _tracksOf(List<VkRecSong> songs, int sourceId) => [
    for (final song in playlists.outside.albumSongs(songs, sourceId))
      _ownOr(song.track),
  ];

  Track _ownOr(Track track) {
    final own = playlists.outside.libraryCopyOf(track.id);
    return own == null ? track : widget.library.byId(own.id) ?? own;
  }

  Future<void> _play(List<Track> songs, int index) =>
      widget.playback.playFrom(songs, index);

  String _detailOf(VkPlaylist list) {
    final songs = playlists.songsOf(list.key);
    if (songs.isEmpty && list.count > 0) return 'loading...';
    return songCountText(songs.isEmpty ? list.count : songs.length);
  }

  @override
  Widget build(BuildContext context) {
    final colors = OwnColors.of(context);
    return ListenableBuilder(
      listenable: Listenable.merge([playlists, widget.playback]),
      builder: (context, _) {
        final accounts = playlists.accounts();
        if (accounts.isEmpty) {
          return PageMessage(
            'Log in to a VK account (the account button at the bottom) to '
            'see its playlists.',
            colors: colors,
          );
        }
        final shown = playlists.shown;
        if (shown.isEmpty) {
          final error = [
            for (final account in accounts) ?playlists.errorOf(account.id),
          ].firstOrNull;
          if (playlists.refreshing || !playlists.hasLists && error == null) {
            return PageMessage(
              'Getting your playlists from VK...',
              colors: colors,
            );
          }
          if (error != null) {
            return PageMessage(
              'VK did not answer: $error',
              colors: colors,
              action: TextButton(
                key: const ValueKey('playlists-retry'),
                onPressed: playlists.refresh,
                child: const Text('Try again'),
              ),
            );
          }
          return PageMessage(
            'No playlists on VK yet. Playlists you make or follow on VK show '
            'up here at the next sync.',
            colors: colors,
          );
        }
        final several = shown.length > 1;
        return ListView(
          key: const ValueKey('playlists-page'),
          padding: const EdgeInsets.fromLTRB(24, 4, 24, 24),
          children: [
            for (final (:account, :lists) in shown)
              for (final (kind, title) in const [
                (VkPlaylistKind.made, 'Your playlists'),
                (VkPlaylistKind.followed, 'Playlists you follow'),
              ])
                if ([
                      for (final list in lists)
                        if (list.kind == kind) list,
                    ]
                    case final ofKind when ofKind.isNotEmpty) ...[
                  SectionTitle(
                    title,
                    note: several ? account.name : null,
                    colors: colors,
                  ),
                  Wrap(
                    spacing: 14,
                    runSpacing: 14,
                    children: [
                      for (final list in ofKind)
                        _card(account.id, list, colors),
                    ],
                  ),
                ],
          ],
        );
      },
    );
  }

  Widget _card(int sourceId, VkPlaylist list, OwnColors colors) {
    final songs = playlists.songsOf(list.key);
    final tracks = _tracksOf(songs, sourceId);
    return ListCard(
      key: ValueKey('playlist-${list.key}'),
      title: list.title,
      detail: _detailOf(list),
      coverUrl: list.coverUrl,
      songs: tracks,
      // A song VK blocks in the playlist plays as the library's song when
      // the library has it (its row is the library's, as a click plays).
      playable: [
        for (final track in tracks)
          if (playlists.outside.restrictionOf(track.id) == null) track,
      ],
      onPlay: _play,
      onOpen: () => widget.library.openList(playlists.refOf(sourceId, list)),
      colors: colors,
    );
  }
}

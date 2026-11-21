/// Artist names as links (plan 09, D3): in song rows, the side panel and
/// the player bar each artist VK names on a song is its own link to the
/// artist's page, when the song's artist text is exactly those names
/// ("A, B feat. C"); otherwise the whole text links to its first artist.
library;

import 'package:flutter/widgets.dart';

import '../library/artist_credit.dart';
import '../library/track.dart';
import 'artists.dart';

/// One piece of an artist line: a name with the key of the artist page it
/// opens (LibraryView.artist), or plain text between names (key null).
typedef ArtistLinkPart = ({String text, String? key});

/// The pieces of the artist [text] of a song VK names [credits] on (main
/// ones first, as LibraryStore keeps them). When [text] is the main names
/// joined with ", " plus " feat. " and the featured names, each name is its
/// own link; else the whole text links to the first main artist. A song
/// with no credits is one piece linking to [wholeKey] (the artist its text
/// joined), or plain text when that is null.
List<ArtistLinkPart> artistLinkParts(
  String text,
  List<ArtistCredit> credits, {
  String? wholeKey,
}) {
  if (credits.isEmpty) return [(text: text, key: wholeKey)];
  final mains = [
    for (final credit in credits)
      if (!credit.featured) credit,
  ];
  final featured = [
    for (final credit in credits)
      if (credit.featured) credit,
  ];
  final joined = StringBuffer(mains.map((c) => c.name).join(', '));
  if (featured.isNotEmpty) {
    joined.write(' feat. ${featured.map((c) => c.name).join(', ')}');
  }
  if (mains.isEmpty || joined.toString() != text) {
    return [
      (text: text, key: 'vk:${(mains.firstOrNull ?? credits.first).vkId}'),
    ];
  }
  final parts = <ArtistLinkPart>[];
  for (final (i, credit) in mains.indexed) {
    if (i > 0) parts.add((text: ', ', key: null));
    parts.add((text: credit.name, key: 'vk:${credit.vkId}'));
  }
  for (final (i, credit) in featured.indexed) {
    parts.add((text: i == 0 ? ' feat. ' : ', ', key: null));
    parts.add((text: credit.name, key: 'vk:${credit.vkId}'));
  }
  return parts;
}

/// Gives the song lines under it their artist links: the artists of each
/// song and what a click on a name does. Lines rebuild when the artists
/// change (the index built, a sync).
class ArtistLinkScope extends InheritedNotifier<LibraryArtists> {
  const ArtistLinkScope({
    super.key,
    required LibraryArtists artists,
    required this.onOpen,
    required super.child,
  }) : super(notifier: artists);

  /// Opens the page of the artist with this key (LibraryView.artist).
  final void Function(String key) onOpen;

  static ArtistLinkScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<ArtistLinkScope>();

  /// The pieces of [track]'s artist line. A library song before the index
  /// is built (just after start) is one link that finds its artist when
  /// clicked (`song:<id>`); a song outside the library links its names by
  /// the credits it came with.
  List<ArtistLinkPart> partsOf(Track track) {
    if (!track.inLibrary) return artistLinkParts(track.artist, track.artists);
    final index = notifier!.builtIndex;
    if (index == null) return [(text: track.artist, key: 'song:${track.id}')];
    return artistLinkParts(
      track.artist,
      index.creditsOf(track.id),
      wholeKey: index.artistsOf(track.id).firstOrNull?.key,
    );
  }

  /// Opens the page a piece links to; `song:<id>` builds the index and
  /// opens the song's first artist.
  void open(String key) {
    if (key.startsWith('song:')) {
      final id = int.tryParse(key.substring('song:'.length));
      final artist = id == null
          ? null
          : notifier!.index.artistsOf(id).firstOrNull;
      if (artist != null) onOpen(artist.key);
      return;
    }
    onOpen(key);
  }
}

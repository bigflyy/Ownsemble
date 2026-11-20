/// The library's artists (plan 09, C2): every listed song under each artist
/// VK names on it, grouped by VK's artist id, never by name alone (the
/// probe of 2026-11-20 found one name with two ids and ten ids under two
/// spellings). Songs VK gives no id for join the one VK artist of that name,
/// or make a name-only artist (the user's pick, 2026-11-20; review R4).
///
/// Built on demand from the listed tracks and their credits
/// (LibraryStore.songArtistCredits), never on the cold-start path (R12).
library;

import 'artist_credit.dart';
import 'play_stats.dart';
import 'track.dart';

/// How the Artists place orders its tiles.
enum ArtistSort { mostSongs, name, recentlyAdded, mostHeard }

/// One album among an artist's library songs. Songs with VK's album key are
/// one album by that key, as the album place opens it (so "A" and
/// "A feat. B" on one release are one card, and two releases of one name
/// are two); songs without one go by title and artist text (C2 review).
class ArtistAlbum {
  ArtistAlbum._(this.title, this.vkAlbumKey, this.first);

  final String title;

  /// VK's album key ("ownerId_albumId"); null for an album known only by
  /// its songs' title and artist text.
  final String? vkAlbumKey;

  /// Its newest song of the artist's: the card's cover, and what the album
  /// place opens from.
  final Track first;

  /// How many of the artist's songs are on it.
  int songs = 1;

  /// The artist text the album is filed under (its newest song's).
  String get artist => first.artist;
}

/// One artist of the library.
class Artist {
  Artist._(this.key, this.vkId);

  /// `vk:<id>` for an artist VK knows, `name:<name key>` ([artistNameKey])
  /// for a name-only one.
  final String key;

  /// VK's artist id; null for a name-only artist.
  final String? vkId;

  /// The most common spelling among its songs (the newest song's wins a
  /// tie).
  String name = '';

  /// The artist's address name on VK, when a song gave one.
  String? domain;

  /// Its listed songs, in the order the index was given them (the library's:
  /// newest added first). A song is here once even when it names the artist
  /// twice.
  final List<Track> songs = [];

  /// Its albums, newest first.
  final List<ArtistAlbum> albums = [];

  /// Whether VK has no id for it: the place draws its tile with a dashed
  /// ring, and its page has no VK part.
  bool get nameOnly => vkId == null;

  /// When its newest song was added, Unix seconds (0: unknown).
  int newestAddedAt = 0;

  /// The color of its newest song that has one, for the letter tile.
  int? tint;

  /// Its songs' counted plays, time heard and the start of the last counted
  /// play (null: never), from [plays] (PlayStatsSource.songPlays). Asked
  /// each time, so a counted play shows at once (R5).
  ({int plays, int listenedMs, int? lastMs}) heard(Map<int, SongPlays> plays) {
    var count = 0;
    var listened = 0;
    int? last;
    for (final song in songs) {
      final stat = plays[song.id];
      if (stat == null) continue;
      count += stat.plays;
      listened += stat.listenedMs;
      final at = stat.lastMs;
      if (at != null && (last == null || at > last)) last = at;
    }
    return (plays: count, listenedMs: listened, lastMs: last);
  }

  @override
  String toString() => 'Artist($key, $name, ${songs.length} songs)';
}

/// The text two artist names must share to be one name: lower case, ё as
/// е, runs of spaces as one. Punctuation stays: "Дайте танк (!)" and
/// "Дайте танк", or "A+" and "A", are two names unless VK's ids join them,
/// and a broken "???4???" never folds into the artist "4" (C2 review).
String artistNameKey(String name) =>
    name.trim().toLowerCase().replaceAll('ё', 'е').replaceAll(_spaces, ' ');

final _spaces = RegExp(r'\s+');

/// The artist text before a featured part: "A feat. B" is "A". Null when
/// the text names no featured artist.
String? withoutFeatured(String text) {
  final match = _featured.firstMatch(text);
  if (match == null || match.start == 0) return null;
  final head = text.substring(0, match.start).trim();
  return head.isEmpty ? null : head;
}

final _featured = RegExp(
  r'\s+[(\[]?(?:feat\.?|ft\.|featuring)\s',
  caseSensitive: false,
);

class ArtistIndex {
  ArtistIndex._(this._byKey, this._ofSong, this._credits);

  /// Groups [tracks] (the listed songs) by artist. [credits] are each
  /// song's artists by listed row id (LibraryStore.songArtistCredits); a
  /// song with none is placed by its artist text. [albumKeys] are the
  /// songs' VK album keys by listed row id (LibraryStore.listedVkAlbumKeys).
  factory ArtistIndex.build(
    Iterable<Track> tracks,
    Map<int, List<ArtistCredit>> credits, {
    Map<int, String> albumKeys = const {},
  }) {
    final byKey = <String, Artist>{};
    final ofSong = <int, List<Artist>>{};
    final spellings = <String, Map<String, int>>{};

    // The ids each name belongs to, over every spelling VK uses.
    final idsOfName = <String, Set<String>>{};
    for (final list in credits.values) {
      for (final credit in list) {
        (idsOfName[artistNameKey(credit.name)] ??= {}).add(credit.vkId);
      }
    }
    String? onlyIdNamed(String text) {
      final ids = idsOfName[artistNameKey(text)];
      return ids != null && ids.length == 1 ? ids.single : null;
    }

    void place(Track track, String key, String? vkId, String spelling) {
      final artist = byKey.putIfAbsent(key, () => Artist._(key, vkId));
      final mine = ofSong[track.id] ??= [];
      if (mine.contains(artist)) return;
      mine.add(artist);
      artist.songs.add(track);
      final counts = spellings[key] ??= {};
      counts[spelling] = (counts[spelling] ?? 0) + 1;
    }

    for (final track in tracks) {
      final own = credits[track.id] ?? const [];
      if (own.isNotEmpty) {
        for (final credit in own) {
          place(track, 'vk:${credit.vkId}', credit.vkId, credit.name);
          final artist = byKey['vk:${credit.vkId}']!;
          artist.domain ??= credit.domain;
        }
        continue;
      }
      final text = track.artist.trim();
      if (text.isEmpty) continue;
      // The whole text first; only when no id has that name, the text
      // without its featured part (R4).
      final whole = onlyIdNamed(text);
      final hasWholeName = idsOfName.containsKey(artistNameKey(text));
      final cut = hasWholeName ? null : withoutFeatured(text);
      final id = whole ?? (cut == null ? null : onlyIdNamed(cut));
      if (id != null) {
        place(track, 'vk:$id', id, whole != null ? text : cut!);
      } else {
        place(track, 'name:${artistNameKey(text)}', null, text);
      }
    }

    for (final artist in byKey.values) {
      // Most common spelling; the first counted (newest song) wins a tie.
      var best = 0;
      for (final MapEntry(key: spelling, value: count)
          in spellings[artist.key]!.entries) {
        if (count > best) {
          best = count;
          artist.name = spelling;
        }
      }
      final albums = <String, ArtistAlbum>{};
      for (final song in artist.songs) {
        if (song.addedAt > artist.newestAddedAt) {
          artist.newestAddedAt = song.addedAt;
        }
        artist.tint ??= song.tint;
        final title = song.album;
        if (title == null || title.isEmpty) continue;
        final vkKey = albumKeys[song.id];
        final key = vkKey != null ? 'vk:$vkKey' : 'text:$title|${song.artist}';
        final album = albums[key];
        if (album != null) {
          album.songs++;
        } else {
          final made = albums[key] = ArtistAlbum._(title, vkKey, song);
          artist.albums.add(made);
        }
      }
    }
    return ArtistIndex._(byKey, ofSong, credits);
  }

  final Map<String, Artist> _byKey;
  final Map<int, List<Artist>> _ofSong;
  final Map<int, List<ArtistCredit>> _credits;

  /// Every artist, in no set order: see [sorted].
  Iterable<Artist> get artists => _byKey.values;

  int get length => _byKey.length;

  /// The artist with identity [key] (`vk:<id>` or `name:<name key>`), or
  /// null.
  Artist? operator [](String key) => _byKey[key];

  /// The artists of the listed song [trackId]: VK's main ones, then the
  /// featured ones; or the one its text names. Empty for a song with no
  /// artist text and for one the index was not built with.
  List<Artist> artistsOf(int trackId) => _ofSong[trackId] ?? const [];

  /// The artists VK names on the listed song [trackId], as that song spells
  /// them, in its order (main, then featured): what a row's name links are
  /// cut from; each one's artist is `this['vk:${credit.vkId}']`. Empty for a
  /// song VK names none on: [artistsOf] then holds the one its text joined,
  /// or its name-only artist.
  List<ArtistCredit> creditsOf(int trackId) => _credits[trackId] ?? const [];

  /// The artists ordered by [sort]; Most heard reads [plays]. Ties go by
  /// name, then key, so the order never jumps.
  List<Artist> sorted(ArtistSort sort, {Map<int, SongPlays> plays = const {}}) {
    final list = _byKey.values.toList();
    int byName(Artist a, Artist b) {
      final names = a.name.toLowerCase().compareTo(b.name.toLowerCase());
      return names != 0 ? names : a.key.compareTo(b.key);
    }

    switch (sort) {
      case ArtistSort.mostSongs:
        list.sort((a, b) {
          final songs = b.songs.length.compareTo(a.songs.length);
          return songs != 0 ? songs : byName(a, b);
        });
      case ArtistSort.name:
        list.sort(byName);
      case ArtistSort.recentlyAdded:
        list.sort((a, b) {
          final added = b.newestAddedAt.compareTo(a.newestAddedAt);
          return added != 0 ? added : byName(a, b);
        });
      case ArtistSort.mostHeard:
        final heard = {for (final artist in list) artist: artist.heard(plays)};
        list.sort((a, b) {
          final x = heard[a]!;
          final y = heard[b]!;
          final count = y.plays.compareTo(x.plays);
          if (count != 0) return count;
          final time = y.listenedMs.compareTo(x.listenedMs);
          if (time != 0) return time;
          final last = (y.lastMs ?? 0).compareTo(x.lastMs ?? 0);
          return last != 0 ? last : byName(a, b);
        });
    }
    return list;
  }
}

/// Songs whose VK file was swapped for another recording (Stage K).
///
/// VK sometimes replaces the file behind a library row with another
/// recording (seen: a studio song became its official release, 7 s longer)
/// and keeps the length it listed for the old one. The listed recording
/// often still exists as other uploads of the same song. This file holds the
/// choice of which upload plays, and how the uploads VK's search finds are
/// ranked: the user's rule is that a file within 1 s of the listed length is
/// the song, and one more than 3 s off is not (user, 2026-11-04/05).
library;

import '../playback/mp3_length.dart';
import 'same_song.dart' show songMatchText;

/// How the version that plays for a song was chosen.
enum VersionState {
  /// The app found an upload within [matchSeconds] of the listed length and
  /// plays it until the user picks.
  suggested,

  /// The user picked the upload.
  picked,

  /// No upload matches: VK's file plays, marked as another recording than
  /// the one in the library.
  none,
}

/// Which file plays for one song whose VK file was found swapped.
class VersionChoice {
  const VersionChoice({
    required this.trackId,
    required this.state,
    required this.ownSeconds,
    required this.listedSec,
    required this.decidedAtMs,
    this.fileKey,
    this.fileAccessKey,
    this.fileSeconds,
    this.ownBytes,
    this.stored = true,
  });

  /// The library row.
  final int trackId;
  final VersionState state;

  /// The upload that plays, "ownerId_audioId"; null when VK's own file for
  /// the song plays ([VersionState.none]).
  final String? fileKey;
  final String? fileAccessKey;

  /// How long the chosen upload's file plays.
  final double? fileSeconds;

  /// How long VK's own file for the song played when the swap was found,
  /// and its size.
  final double ownSeconds;
  final int? ownBytes;

  /// The length the library listed when the choice was made. A sync that
  /// brings another length makes the choice stale.
  final int listedSec;
  final int decidedAtMs;

  /// False for a choice made when VK's search failed: it lasts until the
  /// app closes, so the next run searches again.
  final bool stored;

  /// How long the file that plays should last: the check of the next play
  /// holds it to this.
  double get expectSeconds => fileSeconds ?? ownSeconds;

  /// Whether VK's own file for the song plays (nothing else matched).
  bool get playsOwnFile => fileKey == null;
}

/// One upload of a song that VK's search found, or VK's current file for
/// the library row itself ([isCurrentFile]).
class SongVersion {
  const SongVersion({
    required this.key,
    required this.artist,
    required this.title,
    required this.listedSec,
    this.accessKey,
    this.album,
    this.file,
    this.official = false,
    this.vkTrackId,
    this.isCurrentFile = false,
  });

  /// "ownerId_audioId".
  final String key;
  final String? accessKey;
  final String artist;
  final String title;
  final String? album;

  /// The length VK lists for this upload.
  final int listedSec;

  /// The upload's file as measured; null when VK gave no link or the file
  /// could not be read.
  final FileFacts? file;

  /// VK marks it as the artist's official release.
  final bool official;
  final int? vkTrackId;

  /// VK's file for the library row now (the swapped one, usually).
  final bool isCurrentFile;

  /// Whether the file plays within [matchSeconds] of [listedSec] seconds.
  bool matches(int listedSec) =>
      file != null && (file!.seconds - listedSec).abs() <= matchSeconds;

  /// Whether the upload's own listed length and its file agree.
  bool get agrees => file != null && !file!.differsFrom(listedSec.toDouble());
}

/// Whether a search result is an upload of the row's song: the same VK
/// `track_id`, or the same artist and title (see [songMatchText]).
bool isUploadOfSong({
  required String rowArtist,
  required String rowTitle,
  required int? rowTrackId,
  required String artist,
  required String title,
  required int? trackId,
}) {
  if (rowTrackId != null && trackId == rowTrackId) return true;
  final text = songMatchText(rowArtist, rowTitle);
  return text.isNotEmpty && text == songMatchText(artist, title);
}

/// [versions] best first for a song listed at [listedSec] seconds: files
/// within [matchSeconds] of that length first, then uploads whose own listed
/// length and file agree, then sizes that more uploads share (one rip copied
/// around is likelier the listed recording than a one-off), then the
/// closest length. VK's current file goes last among equals.
List<SongVersion> rankVersions(int listedSec, Iterable<SongVersion> versions) {
  final list = versions.toList();
  final copiesOfSize = <int, int>{};
  for (final version in list) {
    final bytes = version.file?.bytes;
    if (bytes != null) copiesOfSize[bytes] = (copiesOfSize[bytes] ?? 0) + 1;
  }
  int rank(bool good) => good ? 0 : 1;
  double distance(SongVersion version) => version.file == null
      ? double.infinity
      : (version.file!.seconds - listedSec).abs();
  list.sort((a, b) {
    final byMatch = rank(a.matches(listedSec)) - rank(b.matches(listedSec));
    if (byMatch != 0) return byMatch;
    final byAgreeing = rank(a.agrees) - rank(b.agrees);
    if (byAgreeing != 0) return byAgreeing;
    final copies =
        (copiesOfSize[b.file?.bytes] ?? 0) - (copiesOfSize[a.file?.bytes] ?? 0);
    if (copies != 0) return copies;
    final byDistance = distance(a).compareTo(distance(b));
    if (byDistance != 0) return byDistance;
    return rank(!a.isCurrentFile) - rank(!b.isCurrentFile);
  });
  return list;
}

/// The version to play until the user picks: the best of [ranked] that is
/// not VK's current file and plays within [matchSeconds] of [listedSec];
/// null when none does.
SongVersion? suggestedVersion(int listedSec, List<SongVersion> ranked) {
  for (final version in ranked) {
    if (!version.isCurrentFile && version.matches(listedSec)) return version;
  }
  return null;
}

/// The choice for a song listed at [listedSec] seconds whose VK file plays
/// [ownSeconds] instead (more than 3 s off): the best upload of [found] within
/// [matchSeconds] of the listed length as the suggested version; with none,
/// VK's file plays, marked. The player decides this when a play finds the
/// swap (Stage K), the background check after a sync before any play
/// (Stage M2).
VersionChoice decideVersion({
  required int trackId,
  required int listedSec,
  required double ownSeconds,
  required int? ownBytes,
  required Iterable<SongVersion> found,
  required int nowMs,
}) {
  final best = suggestedVersion(listedSec, rankVersions(listedSec, found));
  return VersionChoice(
    trackId: trackId,
    state: best == null ? VersionState.none : VersionState.suggested,
    fileKey: best?.key,
    fileAccessKey: best?.accessKey,
    fileSeconds: best?.file?.seconds,
    ownSeconds: ownSeconds,
    ownBytes: ownBytes,
    listedSec: listedSec,
    decidedAtMs: nowMs,
  );
}

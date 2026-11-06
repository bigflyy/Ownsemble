/// The mark of a song whose VK file was swapped for another recording, and
/// the player's button for the song's versions (Stage K). Both open the
/// versions place, a song list like an album (plan 03, user 2026-11-06: the
/// old pop-up "shouldnt look like something from outside").
library;

import 'package:flutter/material.dart';

import '../library/song_version.dart';
import '../library/track.dart';
import '../playback/playback_controller.dart';
import '../playback/version_book.dart';
import 'theme.dart';

/// "m:ss" of [seconds]; "?" when unknown.
String lengthText(double? seconds) {
  if (seconds == null) return '?';
  final whole = seconds.round();
  return '${whole ~/ 60}:${(whole % 60).toString().padLeft(2, '0')}';
}

/// Whether [version] is what the library song plays now, by its
/// [choice] (null: no choice, VK's own file plays).
bool versionInUse(VersionChoice? choice, SongVersion version) {
  if (choice == null || choice.playsOwnFile) return version.isCurrentFile;
  return choice.fileKey == version.key;
}

/// Opens the versions of a library song.
typedef OpenVersions = void Function(Track track);

/// The small tag on a song whose VK file was swapped: what plays instead,
/// with the details in its tooltip. A click opens the song's versions.
/// Shows nothing for every other song.
class VersionTag extends StatelessWidget {
  const VersionTag({
    super.key,
    required this.playback,
    required this.track,
    this.onOpen,
    this.compact = false,
  });

  final PlaybackController playback;
  final Track track;
  final OpenVersions? onOpen;

  /// Shown as an icon only, for rows without room for the label.
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final versions = playback.player.versions;
    if (versions == null) return const SizedBox.shrink();
    final mark = versionMark(
      versions.choiceFor(track),
      searching: versions.isSearching(track),
    );
    if (mark == null) return const SizedBox.shrink();
    final colors = OwnColors.of(context);
    final warn = versions.choiceFor(track)?.state == VersionState.none;
    final color = warn ? Theme.of(context).colorScheme.error : colors.dim;
    final open = onOpen;
    return Tooltip(
      message: mark.explanation,
      child: MouseRegion(
        cursor: open == null ? MouseCursor.defer : SystemMouseCursors.click,
        child: GestureDetector(
          key: ValueKey('version-tag-${track.id}'),
          onTap: open == null ? null : () => open(track),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
            decoration: BoxDecoration(
              border: Border.all(color: warn ? color : colors.line),
              borderRadius: BorderRadius.circular(6),
            ),
            child: compact
                ? Icon(Icons.swap_horiz, size: 13, color: color)
                : Text(
                    mark.label,
                    maxLines: 1,
                    style: TextStyle(fontSize: 11, color: color),
                  ),
          ),
        ),
      ),
    );
  }
}

/// Whether [track] offers "Choose version...": every library song that a
/// logged-in VK account has, checked or not (Stage M1, user 2026-11-06: an
/// item that shows only after a swap was found cannot be discovered).
bool canChooseVersion(PlaybackController playback, Track track) =>
    playback.player.versions != null &&
    track.inLibrary &&
    playback.player.ownRoutesFor(track).isNotEmpty;

/// The player's button that opens the playing song's versions; nothing for
/// a song without them (see [canChooseVersion]).
class VersionsButton extends StatelessWidget {
  const VersionsButton({
    super.key,
    required this.playback,
    required this.track,
    required this.onOpen,
  });

  final PlaybackController playback;
  final Track track;
  final OpenVersions? onOpen;

  @override
  Widget build(BuildContext context) {
    final open = onOpen;
    if (open == null || !canChooseVersion(playback, track)) {
      return const SizedBox.shrink();
    }
    return IconButton(
      key: const ValueKey('versions-button'),
      tooltip: 'Versions: other uploads of this song on VK',
      onPressed: () => open(track),
      icon: const Icon(Icons.swap_horiz),
    );
  }
}

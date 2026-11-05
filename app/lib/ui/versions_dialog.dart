/// The mark of a song whose VK file was swapped for another recording, and
/// the dialog that lists the song's versions on VK (Stage K, user
/// 2026-11-05: "show a list of available versions, so user could choose the
/// matching one").
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

/// The small tag on a song whose VK file was swapped: what plays instead,
/// with the details in its tooltip. A click opens the versions dialog.
/// Shows nothing for every other song.
class VersionTag extends StatelessWidget {
  const VersionTag({
    super.key,
    required this.playback,
    required this.track,
    this.compact = false,
  });

  final PlaybackController playback;
  final Track track;

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
    return Tooltip(
      message: mark.explanation,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          key: ValueKey('version-tag-${track.id}'),
          onTap: () => showVersionsDialog(context, playback, track),
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

/// Opens the list of [track]'s versions on VK.
Future<void> showVersionsDialog(
  BuildContext context,
  PlaybackController playback,
  Track track,
) => showDialog<void>(
  context: context,
  builder: (context) => VersionsDialog(playback: playback, track: track),
);

/// Lists VK's current file for the song and the other uploads VK's search
/// finds, each with its listed and real length, album and whether VK calls
/// it official. Each can be played to listen; the suggested match is marked;
/// the pick is kept per song, and can be changed or reset.
class VersionsDialog extends StatefulWidget {
  const VersionsDialog({
    super.key,
    required this.playback,
    required this.track,
  });

  final PlaybackController playback;
  final Track track;

  @override
  State<VersionsDialog> createState() => _VersionsDialogState();
}

class _VersionsDialogState extends State<VersionsDialog> {
  late Future<List<SongVersion>> _versions = _load();

  VersionBook get _book => widget.playback.player.versions!;
  Track get _track => widget.track;

  Future<List<SongVersion>> _load() async {
    final routes = widget.playback.player.ownRoutesFor(_track);
    if (routes.isEmpty) {
      throw StateError('no logged-in VK account has this song');
    }
    return _book.versionsOf(_track, routes.first);
  }

  @override
  Widget build(BuildContext context) {
    final colors = OwnColors.of(context);
    return ListenableBuilder(
      listenable: Listenable.merge([_book, widget.playback]),
      builder: (context, _) {
        final choice = _book.choiceFor(_track);
        return AlertDialog(
          title: Text('Versions of ${_track.title}'),
          content: SizedBox(
            width: 720,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${_track.artist} - ${_track.title}: your library lists '
                  '${lengthText(_track.durationSec.toDouble())}.'
                  '${choice == null ? '' : " VK's file for it now plays ${lengthText(choice.ownSeconds)}: another recording."}'
                  ' A version within 1 s of the listed length is the '
                  'recording in your library.',
                  style: TextStyle(color: colors.dim, fontSize: 13),
                ),
                const SizedBox(height: 12),
                Flexible(
                  child: FutureBuilder<List<SongVersion>>(
                    future: _versions,
                    builder: (context, snapshot) {
                      if (snapshot.hasError) {
                        return Row(
                          children: [
                            Expanded(
                              child: Text(
                                "VK's search failed: ${snapshot.error}",
                              ),
                            ),
                            TextButton(
                              onPressed: () =>
                                  setState(() => _versions = _load()),
                              child: const Text('Try again'),
                            ),
                          ],
                        );
                      }
                      final versions = snapshot.data;
                      if (versions == null) {
                        return const Padding(
                          padding: EdgeInsets.all(24),
                          child: Row(
                            children: [
                              SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              ),
                              SizedBox(width: 12),
                              Text('Looking for versions on VK...'),
                            ],
                          ),
                        );
                      }
                      final suggested = suggestedVersion(
                        _track.durationSec,
                        versions,
                      );
                      return ListView(
                        shrinkWrap: true,
                        children: [
                          // VK's current file first, for comparison; then
                          // the uploads, best first.
                          for (final version in [
                            ...versions.where((v) => v.isCurrentFile),
                            ...versions.where((v) => !v.isCurrentFile),
                          ])
                            _VersionRow(
                              key: ValueKey('version-${version.key}'),
                              version: version,
                              listedSec: _track.durationSec,
                              suggested: identical(version, suggested),
                              playing: _plays(choice, version),
                              onListen: () => widget.playback.previewVersion(
                                _track,
                                version,
                              ),
                              onUse: () => _use(version),
                            ),
                          if (suggested == null)
                            Padding(
                              padding: const EdgeInsets.only(top: 8),
                              child: Text(
                                'No version plays within 1 s of the listed '
                                'length: what plays is a different recording '
                                'than in your library.',
                                style: TextStyle(
                                  color: Theme.of(context).colorScheme.error,
                                ),
                              ),
                            ),
                        ],
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
          actions: [
            if (choice != null && choice.state != VersionState.suggested)
              TextButton(
                key: const ValueKey('versions-reset'),
                onPressed: () {
                  _book.reset(_track);
                  Navigator.of(context).pop();
                },
                child: const Text('Back to automatic'),
              ),
            TextButton(
              key: const ValueKey('versions-close'),
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Close'),
            ),
          ],
        );
      },
    );
  }

  /// Whether [version] is what plays for the song now.
  bool _plays(VersionChoice? choice, SongVersion version) {
    if (choice == null) return version.isCurrentFile;
    if (choice.playsOwnFile) return version.isCurrentFile;
    return choice.fileKey == version.key;
  }

  Future<void> _use(SongVersion version) async {
    _book.pick(_track, version);
    Navigator.of(context).pop();
    await widget.playback.versionChanged(_track);
  }
}

/// One version in the dialog.
class _VersionRow extends StatelessWidget {
  const _VersionRow({
    super.key,
    required this.version,
    required this.listedSec,
    required this.suggested,
    required this.playing,
    required this.onListen,
    required this.onUse,
  });

  final SongVersion version;
  final int listedSec;
  final bool suggested;

  /// Whether this version is what the song plays now.
  final bool playing;
  final VoidCallback onListen;
  final VoidCallback onUse;

  @override
  Widget build(BuildContext context) {
    final colors = OwnColors.of(context);
    final file = version.file;
    final matches = version.matches(listedSec);
    final notes = [
      if (version.isCurrentFile) "VK's current file",
      if (suggested) 'suggested match',
      if (version.official) 'official',
      if (playing) 'plays now',
    ];
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          IconButton(
            key: ValueKey('version-listen-${version.key}'),
            tooltip: 'Listen',
            onPressed: file == null ? null : onListen,
            icon: const Icon(Icons.play_arrow_rounded),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${version.artist} - ${version.title}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontWeight: suggested ? FontWeight.w600 : FontWeight.w400,
                  ),
                ),
                Text(
                  [?version.album, ...notes].join(' - '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12, color: colors.dim),
                ),
              ],
            ),
          ),
          SizedBox(
            width: 150,
            child: Text(
              'listed ${lengthText(version.listedSec.toDouble())}, '
              'plays ${lengthText(file?.seconds)}',
              style: TextStyle(
                fontSize: 13,
                color: matches ? colors.accent : colors.dim,
              ),
            ),
          ),
          const SizedBox(width: 8),
          TextButton(
            key: ValueKey('version-use-${version.key}'),
            onPressed: playing ? null : onUse,
            child: Text(playing ? 'In use' : 'Use this'),
          ),
        ],
      ),
    );
  }
}

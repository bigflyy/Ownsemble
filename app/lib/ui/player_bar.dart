import 'package:flutter/material.dart';

import '../library/track.dart';
import '../playback/play_queue.dart';
import '../playback/playback_controller.dart';

/// The player bar: previous / play-pause / next, shuffle, repeat, the song,
/// a seek bar with its time, and volume with mute.
class PlayerBar extends StatelessWidget {
  const PlayerBar({super.key, required this.playback});

  final PlaybackController playback;

  @override
  Widget build(BuildContext context) {
    final player = playback.player;
    final theme = Theme.of(context);
    return SizedBox(
      height: 76,
      child: ListenableBuilder(
        listenable: playback,
        builder: (context, _) => StreamBuilder<Track?>(
          stream: player.currentStream,
          initialData: player.current,
          builder: (context, current) {
            final track = current.data;
            final hasSong = track != null && player.isReady;
            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Row(
                children: [
                  IconButton(
                    key: const ValueKey('prev'),
                    tooltip: 'Previous (restarts the song after 3 s)',
                    onPressed: hasSong ? playback.previous : null,
                    icon: const Icon(Icons.skip_previous),
                  ),
                  ValueListenableBuilder(
                    valueListenable: player.playing,
                    builder: (context, playing, _) => IconButton.filledTonal(
                      key: const ValueKey('play-pause'),
                      tooltip: playing ? 'Pause' : 'Play',
                      onPressed: hasSong ? playback.playOrPause : null,
                      icon: Icon(playing ? Icons.pause : Icons.play_arrow),
                    ),
                  ),
                  IconButton(
                    key: const ValueKey('next'),
                    tooltip: 'Next',
                    onPressed: hasSong ? playback.next : null,
                    icon: const Icon(Icons.skip_next),
                  ),
                  const SizedBox(width: 4),
                  IconButton(
                    key: const ValueKey('shuffle'),
                    tooltip: playback.shuffle ? 'Shuffle: on' : 'Shuffle: off',
                    isSelected: playback.shuffle,
                    onPressed: playback.toggleShuffle,
                    icon: const Icon(Icons.shuffle),
                  ),
                  IconButton(
                    key: const ValueKey('repeat'),
                    tooltip: switch (playback.repeat) {
                      Repeat.off => 'Repeat: off',
                      Repeat.list => 'Repeat: list',
                      Repeat.one => 'Repeat: this song',
                    },
                    isSelected: playback.repeat != Repeat.off,
                    onPressed: playback.cycleRepeat,
                    icon: Icon(
                      playback.repeat == Repeat.one
                          ? Icons.repeat_one
                          : Icons.repeat,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: hasSong
                        ? Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Padding(
                                padding: const EdgeInsets.only(left: 8),
                                child: Text(
                                  track.source == TrackSource.generated
                                      ? '${track.artist} - ${track.title}  '
                                            '(test filler: plays a sample '
                                            'song)'
                                      : '${track.artist} - ${track.title}',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              _SeekRow(playback: playback),
                            ],
                          )
                        : Center(
                            child: Text(
                              'Click a song to play it',
                              style: theme.textTheme.bodySmall,
                            ),
                          ),
                  ),
                  const SizedBox(width: 12),
                  if (hasSong && player.storage != null)
                    _DownloadButton(playback: playback, track: track),
                  IconButton(
                    key: const ValueKey('mute'),
                    tooltip: playback.mutedByUser ? 'Unmute' : 'Mute',
                    onPressed: playback.toggleMute,
                    icon: Icon(
                      playback.mutedByUser || playback.volume == 0
                          ? Icons.volume_off
                          : Icons.volume_up,
                    ),
                  ),
                  SizedBox(
                    width: 110,
                    child: Slider(
                      key: const ValueKey('volume'),
                      value: playback.mutedByUser ? 0 : playback.volume,
                      max: 100,
                      label: 'Volume ${playback.volume.round()}',
                      onChanged: playback.setVolume,
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

/// Downloads the current song, or removes its download.
class _DownloadButton extends StatelessWidget {
  const _DownloadButton({required this.playback, required this.track});

  final PlaybackController playback;
  final Track track;

  @override
  Widget build(BuildContext context) {
    final storage = playback.player.storage!;
    return ListenableBuilder(
      listenable: storage,
      builder: (context, _) {
        final downloading = storage.isDownloading(track);
        final downloaded = storage.stateOf(track).pinned;
        return IconButton(
          key: const ValueKey('download'),
          tooltip: downloading
              ? 'Downloading...'
              : downloaded
              ? 'Downloaded. Click to remove the download'
              : 'Download: keep this song on this computer',
          isSelected: downloaded,
          onPressed: downloading
              ? null
              : () async {
                  if (downloaded) {
                    playback.removeDownload(track);
                    return;
                  }
                  final messenger = ScaffoldMessenger.of(context);
                  final error = await playback.download(track);
                  if (error != null) {
                    messenger.showSnackBar(
                      SnackBar(content: Text('Download failed: $error')),
                    );
                  }
                },
          icon: Icon(
            downloading
                ? Icons.downloading
                : downloaded
                ? Icons.download_done
                : Icons.download,
          ),
        );
      },
    );
  }
}

/// The seek bar and the time label under the song title.
///
/// While the handle is dragged the bar follows the mouse, not the playing
/// position, and the song moves there when the mouse is released; a click
/// moves there at once. The label shows the position with the total or the
/// remaining time (click to switch).
class _SeekRow extends StatefulWidget {
  const _SeekRow({required this.playback});

  final PlaybackController playback;

  @override
  State<_SeekRow> createState() => _SeekRowState();
}

class _SeekRowState extends State<_SeekRow> {
  /// Where the handle is while dragging, in seconds; null when not dragging.
  double? _dragSeconds;

  @override
  Widget build(BuildContext context) {
    final playback = widget.playback;
    final player = playback.player;
    final style = Theme.of(context).textTheme.bodySmall;
    return StreamBuilder<Duration>(
      stream: player.player.stream.position,
      builder: (context, _) {
        final total = player.duration;
        final totalSeconds = total.inMilliseconds / 1000;
        final playingSeconds = (player.position.inMilliseconds / 1000).clamp(
          0.0,
          totalSeconds,
        );
        final shown = _dragSeconds ?? playingSeconds;
        final at = Duration(milliseconds: (shown * 1000).round());
        final end = playback.showRemaining
            ? '-${formatDuration(total - at)}'
            : formatDuration(total);
        return Row(
          children: [
            Expanded(
              child: SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  trackHeight: 3,
                  thumbShape: const RoundSliderThumbShape(
                    enabledThumbRadius: 6,
                  ),
                  overlayShape: const RoundSliderOverlayShape(
                    overlayRadius: 12,
                  ),
                  showValueIndicator: ShowValueIndicator.onDrag,
                ),
                child: Slider(
                  key: const ValueKey('seek'),
                  value: shown,
                  max: totalSeconds <= 0 ? 1 : totalSeconds,
                  label: formatDuration(at),
                  onChangeStart: totalSeconds <= 0
                      ? null
                      : (value) => setState(() => _dragSeconds = value),
                  onChanged: totalSeconds <= 0
                      ? null
                      : (value) => setState(() => _dragSeconds = value),
                  onChangeEnd: (value) async {
                    await playback.seek(
                      Duration(milliseconds: (value * 1000).round()),
                    );
                    if (mounted) setState(() => _dragSeconds = null);
                  },
                ),
              ),
            ),
            TextButton(
              key: const ValueKey('time'),
              onPressed: playback.toggleRemaining,
              style: TextButton.styleFrom(
                minimumSize: const Size(0, 28),
                padding: const EdgeInsets.symmetric(horizontal: 6),
              ),
              child: Text('${formatDuration(at)} / $end', style: style),
            ),
          ],
        );
      },
    );
  }
}

/// Formats a duration as m:ss.
String formatDuration(Duration duration) {
  final seconds = duration.inSeconds;
  return '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';
}

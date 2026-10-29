import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../library/track.dart';
import '../playback/player_service.dart';
import 'library_controller.dart';

/// Height of one song row; fixed so the list can skip layout of hidden rows.
const rowHeight = 52.0;

/// The whole speed-gate UI: search box, song list and player bar.
class LibraryScreen extends StatefulWidget {
  const LibraryScreen({super.key, required this.library, required this.player});

  final LibraryController library;
  final PlayerService player;

  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen> {
  final _searchFocus = FocusNode();
  PlayTiming? _lastTiming;
  final _subscriptions = <StreamSubscription<Object?>>[];

  LibraryController get library => widget.library;

  @override
  void initState() {
    super.initState();
    _subscriptions.add(
      widget.player.timings.listen(
        (timing) => setState(() => _lastTiming = timing),
      ),
    );
    HardwareKeyboard.instance.addHandler(_onKey);
  }

  /// App-wide keys. Handled before focus routing, so they work wherever the
  /// focus is, including nowhere after clicking a song.
  bool _onKey(KeyEvent event) {
    if (event is! KeyDownEvent) return false;
    final key = event.logicalKey;
    // The physical key, so Ctrl+F also works with the Russian layout, where
    // the same key types "а".
    if (event.physicalKey == PhysicalKeyboardKey.keyF &&
        HardwareKeyboard.instance.isControlPressed) {
      _searchFocus.requestFocus();
      library.searchText.selection = TextSelection(
        baseOffset: 0,
        extentOffset: library.searchText.text.length,
      );
      return true;
    }
    if (key == LogicalKeyboardKey.escape &&
        library.searchText.text.isNotEmpty) {
      library.searchText.clear();
      return true;
    }
    return false;
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onKey);
    for (final subscription in _subscriptions) {
      subscription.cancel();
    }
    _searchFocus.dispose();
    super.dispose();
  }

  void _play(Track track) {
    if (!widget.player.isReady) return;
    widget.player.play(track);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: TextField(
              controller: library.searchText,
              focusNode: _searchFocus,
              autofocus: true,
              decoration: const InputDecoration(
                prefixIcon: Icon(Icons.search),
                hintText: 'Search artist, title or album  (Ctrl+F)',
                border: OutlineInputBorder(),
                isDense: true,
              ),
              onSubmitted: (_) {
                if (library.visible.isNotEmpty) _play(library.visible.first);
              },
            ),
          ),
          ListenableBuilder(
            listenable: library,
            builder: (context, _) => _StatusLine(
              shown: library.visible.length,
              total: library.all.length,
              timing: _lastTiming,
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: ListenableBuilder(
              listenable: library,
              builder: (context, _) => StreamBuilder<Track?>(
                stream: widget.player.currentStream,
                initialData: widget.player.current,
                builder: (context, current) => Scrollbar(
                  controller: library.scroll,
                  child: ListView.builder(
                    controller: library.scroll,
                    itemExtent: rowHeight,
                    itemCount: library.visible.length,
                    itemBuilder: (context, index) {
                      final track = library.visible[index];
                      return _SongRow(
                        track: track,
                        isCurrent: track.id == current.data?.id,
                        onTap: () => _play(track),
                      );
                    },
                  ),
                ),
              ),
            ),
          ),
          const Divider(height: 1),
          _PlayerBar(player: widget.player, theme: theme),
        ],
      ),
    );
  }
}

class _StatusLine extends StatelessWidget {
  const _StatusLine({
    required this.shown,
    required this.total,
    required this.timing,
  });

  final int shown;
  final int total;
  final PlayTiming? timing;

  @override
  Widget build(BuildContext context) {
    final count = shown == total ? '$total songs' : '$shown of $total songs';
    final play = switch (timing) {
      null => '',
      PlayTiming(ok: false, :final error) => 'Play failed: $error',
      PlayTiming(cached: true, :final toSoundMs) =>
        'Cached song: sound in $toSoundMs ms',
      PlayTiming(:final resolveMs, :final toSoundMs) =>
        'Stream: sound in $toSoundMs ms (VK link $resolveMs ms)',
    };
    final style = Theme.of(context).textTheme.bodySmall;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
      child: Row(
        children: [
          Text(count, style: style),
          const Spacer(),
          Text(play, style: style),
        ],
      ),
    );
  }
}

class _SongRow extends StatelessWidget {
  const _SongRow({
    required this.track,
    required this.isCurrent,
    required this.onTap,
  });

  final Track track;
  final bool isCurrent;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent = theme.colorScheme.primary;
    final dim = theme.textTheme.bodySmall?.color;
    return InkWell(
      onTap: onTap,
      child: Container(
        color: isCurrent ? accent.withValues(alpha: 0.12) : null,
        padding: const EdgeInsets.symmetric(horizontal: 20),
        child: Row(
          children: [
            SizedBox(
              width: 28,
              child: Icon(
                track.source == TrackSource.vk
                    ? Icons.cloud_outlined
                    : Icons.music_note_outlined,
                size: 16,
                color: isCurrent ? accent : dim,
              ),
            ),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    track.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: isCurrent ? accent : null),
                  ),
                  Text(
                    track.artist,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall,
                  ),
                ],
              ),
            ),
            if (track.source == TrackSource.generated) ...[
              const SizedBox(width: 16),
              const _FillerTag(),
            ],
            const SizedBox(width: 16),
            Text(
              formatDuration(Duration(seconds: track.durationSec)),
              style: theme.textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}

/// Marks generated speed-test songs, whose names are made up and which play
/// one of a few cached real songs.
class _FillerTag extends StatelessWidget {
  const _FillerTag();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        border: Border.all(color: theme.colorScheme.outline),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text('filler', style: theme.textTheme.labelSmall),
    );
  }
}

class _PlayerBar extends StatelessWidget {
  const _PlayerBar({required this.player, required this.theme});

  final PlayerService player;
  final ThemeData theme;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 72,
      child: StreamBuilder<Track?>(
        stream: player.currentStream,
        initialData: player.current,
        builder: (context, current) {
          final track = current.data;
          if (track == null || !player.isReady) {
            return Center(
              child: Text(
                'Click a song to play it',
                style: theme.textTheme.bodySmall,
              ),
            );
          }
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              children: [
                ValueListenableBuilder(
                  valueListenable: player.playing,
                  builder: (context, playing, _) => IconButton.filledTonal(
                    onPressed: player.playOrPause,
                    icon: Icon(playing ? Icons.pause : Icons.play_arrow),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        track.source == TrackSource.generated
                            ? '${track.artist} - ${track.title}  '
                                  '(test filler: plays a sample song)'
                            : '${track.artist} - ${track.title}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 8),
                      _Progress(player: player, theme: theme),
                    ],
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _Progress extends StatelessWidget {
  const _Progress({required this.player, required this.theme});

  final PlayerService player;
  final ThemeData theme;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<Duration>(
      stream: player.player.stream.position,
      builder: (context, position) {
        final now = position.data ?? Duration.zero;
        final total = player.player.state.duration;
        final fraction = total.inMilliseconds == 0
            ? 0.0
            : (now.inMilliseconds / total.inMilliseconds).clamp(0.0, 1.0);
        return Row(
          children: [
            Expanded(child: LinearProgressIndicator(value: fraction)),
            const SizedBox(width: 12),
            Text(
              '${formatDuration(now)} / ${formatDuration(total)}',
              style: theme.textTheme.bodySmall,
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

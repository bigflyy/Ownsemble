import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../library/track.dart';
import '../playback/playback_controller.dart';
import '../playback/player_service.dart';
import '../storage/audio_storage.dart';
import 'library_controller.dart';
import 'player_bar.dart';
import 'sync_controller.dart';
import 'sync_status_bar.dart';

/// Height of one song row; fixed so the list can skip layout of hidden rows.
const rowHeight = 52.0;

/// The whole UI for now: search box, song list, player bar and sync status.
class LibraryScreen extends StatefulWidget {
  const LibraryScreen({
    super.key,
    required this.library,
    required this.playback,
    this.sync,
  });

  final LibraryController library;
  final PlaybackController playback;

  PlayerService get player => playback.player;

  /// Sync state for the status bar; no status bar when null.
  final SyncController? sync;

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
    // Media keys of keyboards and headsets.
    if (key == LogicalKeyboardKey.mediaPlayPause) {
      widget.playback.playOrPause();
      return true;
    }
    if (key == LogicalKeyboardKey.mediaTrackNext) {
      widget.playback.next();
      return true;
    }
    if (key == LogicalKeyboardKey.mediaTrackPrevious) {
      widget.playback.previous();
      return true;
    }
    // Space plays or pauses, except while typing in a text field.
    if (key == LogicalKeyboardKey.space && !_typing) {
      widget.playback.playOrPause();
      return true;
    }
    return false;
  }

  /// Whether the keyboard focus is in a text field.
  bool get _typing =>
      FocusManager.instance.primaryFocus?.context?.widget is EditableText;

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onKey);
    for (final subscription in _subscriptions) {
      subscription.cancel();
    }
    _searchFocus.dispose();
    super.dispose();
  }

  AudioStorage? get _storage => widget.player.storage;

  /// The right-click menu of a song: Download, or Remove download.
  Future<void> _showSongMenu(Track track, Offset position) async {
    final storage = _storage!;
    final downloaded = storage.stateOf(track).pinned;
    final choice = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(
        position.dx,
        position.dy,
        position.dx,
        position.dy,
      ),
      items: [
        if (!downloaded)
          const PopupMenuItem(
            key: ValueKey('menu-download'),
            value: 'download',
            child: Text('Download'),
          )
        else
          const PopupMenuItem(
            key: ValueKey('menu-remove-download'),
            value: 'remove',
            child: Text('Remove download'),
          ),
      ],
    );
    if (choice == 'download') await _download(track);
    if (choice == 'remove') widget.playback.removeDownload(track);
  }

  /// Downloads [track]; a failure is shown at the bottom of the window.
  Future<void> _download(Track track) async {
    final messenger = ScaffoldMessenger.of(context);
    final error = await widget.playback.download(track);
    if (error != null) {
      messenger.showSnackBar(
        SnackBar(content: Text('Download failed: $error')),
      );
    }
  }

  /// Plays the visible song at [index], with the visible list as the list
  /// next and previous move in; clicking the song that is already loaded
  /// pauses or resumes it instead of restarting it.
  void _play(int index) => widget.playback.playFrom(library.visible, index);

  @override
  Widget build(BuildContext context) {
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
                if (library.visible.isNotEmpty) _play(0);
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
              listenable: Listenable.merge([library, ?_storage]),
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
                        key: ValueKey('song-${track.id}'),
                        track: track,
                        stored:
                            _storage?.stateOf(track) ??
                            (path: track.localPath, pinned: track.pinned),
                        downloading: _storage?.isDownloading(track) ?? false,
                        isCurrent: track.id == current.data?.id,
                        onTap: () => _play(index),
                        onMenu: _storage == null
                            ? null
                            : (position) => _showSongMenu(track, position),
                      );
                    },
                  ),
                ),
              ),
            ),
          ),
          const Divider(height: 1),
          PlayerBar(playback: widget.playback),
          if (widget.sync case final sync?) ...[
            const Divider(height: 1),
            SyncStatusBar(sync: sync),
          ],
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
    super.key,
    required this.track,
    required this.stored,
    required this.downloading,
    required this.isCurrent,
    required this.onTap,
    this.onMenu,
  });

  final Track track;

  /// How the song's audio is stored now (may be newer than [track]).
  final StoredState stored;
  final bool downloading;
  final bool isCurrent;
  final VoidCallback onTap;

  /// Opens the song's menu at a position on screen (right click).
  final void Function(Offset position)? onMenu;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent = theme.colorScheme.primary;
    final dim = theme.textTheme.bodySmall?.color;
    // A song gone from VK without stored audio cannot play: shown faded.
    final unplayable = track.isGone && stored.path == null;
    final (icon, meaning) = switch (stored) {
      _ when downloading => (Icons.downloading, 'Downloading'),
      (path: String _, pinned: true) => (
        Icons.download_done,
        'Downloaded: kept until you remove it',
      ),
      (path: String _, pinned: false) => (
        Icons.cloud_done_outlined,
        'Cached: plays without the network',
      ),
      _ when track.source == TrackSource.vk => (
        Icons.cloud_outlined,
        'Streams from VK',
      ),
      _ => (Icons.music_note_outlined, 'Generated test song'),
    };
    return InkWell(
      onTap: onTap,
      onSecondaryTapUp: onMenu == null
          ? null
          : (details) => onMenu!(details.globalPosition),
      child: Container(
        color: isCurrent ? accent.withValues(alpha: 0.12) : null,
        padding: const EdgeInsets.symmetric(horizontal: 20),
        child: Opacity(
          opacity: unplayable ? 0.5 : 1,
          child: Row(
            children: [
              SizedBox(
                width: 28,
                child: Tooltip(
                  message: meaning,
                  child: Icon(
                    icon,
                    key: ValueKey('mark-${track.id}-${icon.codePoint}'),
                    size: 16,
                    color: isCurrent ? accent : dim,
                  ),
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
              if (track.isGone) ...[
                const SizedBox(width: 16),
                _Tag(
                  key: const ValueKey('gone-tag'),
                  label: 'gone from VK',
                  explanation: stored.path != null
                      ? 'VK no longer has this song. It stays in your '
                            'library and plays from the stored copy.'
                      : 'VK no longer has this song. It stays in your '
                            'library, History and Stacks, but there is no '
                            'stored copy to play.',
                ),
              ],
              if (track.source == TrackSource.generated) ...[
                const SizedBox(width: 16),
                const _Tag(
                  label: 'filler',
                  explanation:
                      'Generated speed-test song: made-up name, plays one of a '
                      'few cached real songs.',
                ),
              ],
              const SizedBox(width: 16),
              Text(
                formatDuration(Duration(seconds: track.durationSec)),
                style: theme.textTheme.bodySmall,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A small outlined label on a song row, explained on hover.
class _Tag extends StatelessWidget {
  const _Tag({super.key, required this.label, required this.explanation});

  final String label;
  final String explanation;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Tooltip(
      message: explanation,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
        decoration: BoxDecoration(
          border: Border.all(color: theme.colorScheme.outline),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Text(label, style: theme.textTheme.labelSmall),
      ),
    );
  }
}
